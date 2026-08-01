-- schema.sql
--
-- Consolidated base schema. Supersedes schema-rate-limiting.sql,
-- schema-chat-sessions-updated-at.sql, schema-room-deletion-permissions.sql,
-- and schema-audit-log.sql as separate files — their contents are folded
-- in below rather than kept as sequential ALTERs, since nothing is
-- deployed yet and there's no live data a migration would need to
-- preserve. Those four files can be treated as historical from here on.
--
-- One file per instance, named [system].[domain].db (e.g.
-- two.castletalk.com.db) — the same stem the Caddy access log uses
-- (two.castletalk.com.log), so backup, cleanup, and digest scripts can
-- derive one from the other. This schema is
-- applied identically to each; nothing here is shared across instances.

PRAGMA journal_mode = WAL;
-- Foreign key enforcement is OFF by default per SQLite connection, not
-- persistent in the file itself — the app must run `PRAGMA foreign_keys
-- = ON;` on every connection it opens, or the REFERENCES below are
-- documentation only, not enforced.

-- ============================================================
-- USERS
-- ============================================================
CREATE TABLE users (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    username            TEXT NOT NULL UNIQUE,
    password_hash       TEXT NOT NULL,   -- opaque string from Bun.password;
                                          -- algorithm + params are self-
                                          -- describing inside the hash itself,
                                          -- no separate columns needed
    role                TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('user', 'aide')),
    is_sysop            INTEGER NOT NULL DEFAULT 0,
    can_delete_rooms    INTEGER NOT NULL DEFAULT 0,
    must_reset_password INTEGER NOT NULL DEFAULT 0,
    temp_password_expires_at INTEGER,  -- set when an aide issues a temp
                                -- password; the one-hour window decided for
                                -- aide-mediated recovery. must_reset_password
                                -- alone is only a flag — without this column
                                -- there's nothing to expire against, and a
                                -- temp password handed over out-of-band would
                                -- stay valid indefinitely if never used.
                                -- Login must reject when the flag is set and
                                -- this timestamp has passed; the aide
                                -- regenerates rather than the user retrying.
    bio                 TEXT,   -- shown by the <M>eet User command. This is
                                -- user-authored text displayed to OTHER users,
                                -- so it carries the same two obligations as a
                                -- message body: textContent-only rendering, and
                                -- aide moderation reach (an aide needs to be
                                -- able to clear an abusive bio — no route for
                                -- that exists yet).

    -- ---- Preferences (the surviving half of .Enter Configuration) ----
    -- Columns rather than a key-value prefs table: the set is small,
    -- fixed, and known, users is already carried by the mutable-table
    -- backup path, and a join per page load buys nothing here. Revisit
    -- only if preferences become user-extensible, which is not planned.
    expert_mode      INTEGER NOT NULL DEFAULT 0,  -- terser prompts, fewer
                                                  -- explanatory blurbs
    show_timestamps  INTEGER NOT NULL DEFAULT 1,  -- ".Enter Configuration
                                                  -- Time of Messages"
    old_on_new       INTEGER NOT NULL DEFAULT 0,  -- show a little prior
                                                  -- context above unread
    floor_mode       INTEGER NOT NULL DEFAULT 0,  -- dormant until floors are
                                                  -- activated; harmless at 0
    phosphor         TEXT NOT NULL DEFAULT 'green'
                     CHECK (phosphor IN ('green', 'amber')),
                     -- the CRT theme toggle. Previously client-side only with
                     -- no persistence anywhere; storing it server-side means
                     -- it follows the user across devices instead of resetting
                     -- on every new browser.
    baud_rate        INTEGER NOT NULL DEFAULT 0,
                     -- 0 = off (instant render). Otherwise a classic rate
                     -- (300/1200/2400/9600/14400) driving the streaming-text
                     -- effect. Descends directly from the original's
                     -- ".Enter Configuration Delay Time". Default stays 0
                     -- until the effect has been tested at real rates.
    created_at          INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    updated_at          INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);

-- At most one sysop per instance, enforced by the database itself rather
-- than trusted to application code.
CREATE UNIQUE INDEX idx_one_sysop ON users(is_sysop) WHERE is_sysop = 1;

-- ============================================================
-- FLOORS  (room groupings — schema only for now; feature stays dormant
-- and undocumented to users until explicitly activated. Kept nullable
-- on rooms.floor_id deliberately: whether every room MUST belong to a
-- floor, or floors are optional/ungrouped by default, is part of the
-- activation design still to be done — this doesn't force that
-- decision prematurely.)
-- ============================================================
CREATE TABLE floors (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT NOT NULL,
    deleted_at INTEGER,   -- soft delete, same reasoning as rooms.deleted_at
    created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);

CREATE TRIGGER trg_floors_updated_at
AFTER UPDATE ON floors
FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN
    UPDATE floors SET updated_at = strftime('%s', 'now') WHERE id = NEW.id;
END;

-- ============================================================
-- ROOMS
-- ============================================================
CREATE TABLE rooms (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL,
    description TEXT,   -- shown by the <I>nformation command; aide-editable.
                        -- User-visible text, so the same textContent-only
                        -- rendering discipline applies as to message bodies.
    floor_id   INTEGER REFERENCES floors(id),  -- nullable; see FLOORS note above
    deleted_at INTEGER,     -- soft delete — see backup.sh's mutable-table
                            -- handling; a hard DELETE would leave no
                            -- watermark trace and a restore could silently
                            -- resurrect the row
    created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
    -- NOTE: hack.doc describes several other room flags from the original
    -- (public/private, permanent, invitational, etc. — see OPER3.MAN
    -- section V for the fuller list). Not added here — this consolidation
    -- only captures what's already been decided, not new scope.
);

-- Every room list/lookup needs `WHERE deleted_at IS NULL` added at the
-- query level — easy to miss once room-deletion routes actually exist.

-- ============================================================
-- MESSAGES  (append-only — never edited after insert)
-- ============================================================
CREATE TABLE messages (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    room_id      INTEGER NOT NULL REFERENCES rooms(id),
    author_id    INTEGER REFERENCES users(id),  -- nullable: system-posted
                                                 -- messages (e.g. the daily
                                                 -- security digest) have no author
    recipient_id INTEGER REFERENCES users(id),  -- nullable; only meaningful
                                                 -- for messages posted in the
                                                 -- Mail room (see note below).
                                                 -- NULL means an ordinary
                                                 -- room message, visible to
                                                 -- anyone who enters the room.
    body         TEXT NOT NULL,
    created_at   INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);

-- Private mail, internal only (no cross-instance/networked mail — same
-- scope boundary as the rest of this project). Follows the original's
-- own model: reuse the ordinary message mechanism rather than build a
-- separate mailbox system. hack.doc's version stored the recipient's
-- message pointer in the recipient's own account record and copied it
-- into the Mail room's array on entry, purely because 256-byte account
-- records and a circular message file made anything simpler infeasible.
-- That constraint doesn't exist here, so the SQL equivalent is just:
--
--   - recipient_id is set ONLY when posting to the room named 'Mail'.
--     Enforced in application code at the point of composing a message,
--     not as a DB constraint — a CHECK referencing another table's
--     current name is unreliable in SQLite and would break silently if
--     the Mail room were ever renamed.
--   - Reading the Mail room is NOT "SELECT all messages WHERE room_id =
--     mail_room_id" the way every other room works. It must filter to
--     WHERE recipient_id = current_user_id OR author_id = current_user_id
--     — otherwise every user would see everyone's private mail.
--   - This is the one room in the whole system where "every message in
--     the room is visible to whoever enters it" — true everywhere else
--     — does NOT hold. Worth flagging clearly in any future room-
--     reading code, since it's an easy rule to apply uniformly by
--     accident.
CREATE INDEX idx_messages_recipient ON messages(room_id, recipient_id);

-- Supports both the polling pattern (WHERE room_id=? AND id > ?) and
-- plain per-room listing for every room other than Mail.
CREATE INDEX idx_messages_room_id ON messages(room_id, id);

-- ============================================================
-- CONTENT PAGES  (help/menu text, aide-editable)
-- ============================================================
CREATE TABLE content_pages (
    key        TEXT PRIMARY KEY,
    label      TEXT NOT NULL,     -- populates the admin dropdown
    body       TEXT NOT NULL,
    updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    updated_by INTEGER REFERENCES users(id)
);

-- ============================================================
-- SITE CONFIG  (system name, access policy toggles, setup_complete flag)
-- ============================================================
CREATE TABLE site_config (
    key        TEXT PRIMARY KEY,
    value      TEXT,
    updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    updated_by INTEGER REFERENCES users(id)
);

-- setup-gate-middleware.js checks for a row here:
--   key = 'setup_complete', value = 'true'
-- Absent or false -> every route except /setup is blocked.
-- Present and true -> /setup itself becomes permanently unreachable.

-- ============================================================
-- CHAT SESSIONS  (user <-> aide live chat, one active session per aide)
-- ============================================================
CREATE TABLE chat_sessions (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    INTEGER NOT NULL REFERENCES users(id),
    aide_id    INTEGER NOT NULL REFERENCES users(id),
    started_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    ended_at   INTEGER,
    updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);

-- "Is this aide currently busy?" check, used by the /chat/request flow
-- (strict-fail, no fallback) — a partial index keeps that lookup cheap.
CREATE INDEX idx_chat_sessions_active ON chat_sessions(aide_id) WHERE ended_at IS NULL;

CREATE TABLE chat_messages (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL REFERENCES chat_sessions(id),
    sender_id  INTEGER NOT NULL REFERENCES users(id),
    body       TEXT NOT NULL,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);

CREATE INDEX idx_chat_messages_session ON chat_messages(session_id, id);

-- ============================================================
-- SESSIONS  (server-side session store — NOT backed up)
-- ============================================================
-- Backs the whole auth model: a random token issued at login, set as an
-- httpOnly; Secure; SameSite=Lax cookie, looked up on every request.
-- <T>erminate deletes the row — that's what makes "log out but keep the
-- tab open" mean something distinct from closing the tab.
--
-- Deliberately excluded from backup.sh: a restored session token would
-- be a live credential resurrected from a backup, which is worse than
-- useless. Everyone re-logs-in after a restore, by design.
CREATE TABLE sessions (
    token      TEXT PRIMARY KEY,   -- random, >=256 bits; never derived from
                                   -- anything about the user
    user_id    INTEGER NOT NULL REFERENCES users(id),
    created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    expires_at INTEGER NOT NULL
);

CREATE INDEX idx_sessions_user    ON sessions(user_id);
CREATE INDEX idx_sessions_expires ON sessions(expires_at);

-- ============================================================
-- READ STATE  (per user, per room — backs <G>, <S>, <K>, <Z>)
-- ============================================================
-- last_read_message_id advances on ROOM EXIT, not on display. That's
-- what makes <S>kip meaningful: skipping leaves the room without
-- advancing the watermark, so the messages stay unread. If the mark
-- happened at display time there would be nothing left to skip.
--
-- forgotten_at lives here rather than in its own table because it's the
-- same grain — per-user, per-room state. <Z>Forget sets it; entering the
-- room again clears it. Also backs the "<Z>Forgotten rooms" listing in
-- the Known-rooms modal.
CREATE TABLE read_state (
    user_id              INTEGER NOT NULL REFERENCES users(id),
    room_id              INTEGER NOT NULL REFERENCES rooms(id),
    last_read_message_id INTEGER NOT NULL DEFAULT 0,
    forgotten_at         INTEGER,
    updated_at           INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    PRIMARY KEY (user_id, room_id)
);

CREATE TRIGGER trg_read_state_updated_at
AFTER UPDATE ON read_state
FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN
    UPDATE read_state SET updated_at = strftime('%s', 'now')
    WHERE user_id = NEW.user_id AND room_id = NEW.room_id;
END;

-- ============================================================
-- AIDE STATUS  (live chat availability — NOT backed up)
-- ============================================================
-- One row per aide, one boolean. This is the entire presence system:
-- deliberately scoped to aides only, never generalised to the other 250
-- users, since <C>hat is user-to-aide only.
--
-- Reset to 0 for every aide on application startup — after a clean
-- deploy or a crash alike. A stale "available" flag surviving a restart
-- would route a chat request to someone who isn't there, and the
-- strict-fail rule means the user gets no fallback. Excluded from
-- backup for the same reason: restoring yesterday's availability would
-- be restoring a lie.
CREATE TABLE aide_status (
    aide_id      INTEGER PRIMARY KEY REFERENCES users(id),
    is_available INTEGER NOT NULL DEFAULT 0,
    updated_at   INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);

-- ============================================================
-- LOGIN ATTEMPTS  (rate limiting only — short-lived, excluded from backup)
-- ============================================================
CREATE TABLE login_attempts (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    action     TEXT NOT NULL CHECK (action IN ('login', 'setup', 'password_change')),
                           -- password_change verifies the CURRENT password, so
                           -- it's a password oracle like /login is and needs
                           -- the same throttling. Easy to overlook: the user
                           -- is already authenticated, which makes the
                           -- endpoint feel safe when it isn't — a hijacked
                           -- session could otherwise brute-force the existing
                           -- password at full speed.
    username   TEXT,       -- NULL for 'setup' attempts (no account yet)
    ip         TEXT NOT NULL,
    success    INTEGER NOT NULL,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);

CREATE INDEX idx_login_attempts_username ON login_attempts(action, username, created_at);
CREATE INDEX idx_login_attempts_ip       ON login_attempts(action, ip, created_at);

-- ============================================================
-- AUDIT LOG  (durable, queryable — see audit.js for the two-tier logging pattern)
-- ============================================================
CREATE TABLE audit_log (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    actor_user_id INTEGER REFERENCES users(id),
    action        TEXT NOT NULL,
    target        TEXT,
    detail        TEXT,
    ip            TEXT,
    created_at    INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);

CREATE INDEX idx_audit_log_created_at ON audit_log(created_at);
CREATE INDEX idx_audit_log_actor      ON audit_log(actor_user_id, created_at);

-- ============================================================
-- updated_at TRIGGERS
-- ============================================================
-- chat_sessions already had this reasoning applied on its own (its
-- ended_at transition is exactly the "existing row gets edited later"
-- case backup.sh's mutable-table handling exists for). Consolidating
-- everything into one file is a good moment to apply the same
-- reasoning uniformly rather than leave it a one-off: a trigger can't
-- be forgotten the way "remember to bump updated_at in every place
-- that touches this table" eventually will be. Extended here to
-- users, rooms, content_pages, and site_config as well — this is a
-- genuine addition beyond what was previously built, done for
-- consistency now that the full base schema exists in one place.
--
-- SQLite doesn't recursively re-fire triggers by default, and the WHEN
-- clause is a second, independent safeguard against ever looping even
-- if that default were changed elsewhere.

CREATE TRIGGER trg_users_updated_at
AFTER UPDATE ON users
FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN
    UPDATE users SET updated_at = strftime('%s', 'now') WHERE id = NEW.id;
END;

CREATE TRIGGER trg_rooms_updated_at
AFTER UPDATE ON rooms
FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN
    UPDATE rooms SET updated_at = strftime('%s', 'now') WHERE id = NEW.id;
END;

CREATE TRIGGER trg_content_pages_updated_at
AFTER UPDATE ON content_pages
FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN
    UPDATE content_pages SET updated_at = strftime('%s', 'now') WHERE key = NEW.key;
END;

CREATE TRIGGER trg_site_config_updated_at
AFTER UPDATE ON site_config
FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN
    UPDATE site_config SET updated_at = strftime('%s', 'now') WHERE key = NEW.key;
END;

CREATE TRIGGER trg_chat_sessions_updated_at
AFTER UPDATE ON chat_sessions
FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN
    UPDATE chat_sessions SET updated_at = strftime('%s', 'now') WHERE id = NEW.id;
END;

-- ============================================================
-- PRESET ROOMS
-- ============================================================
-- Every fresh instance starts with these three, matching the original's
-- defaults. floor_id left NULL — floors are dormant until activated.
--
-- Lobby: general-purpose default room. Name is just the ordinary `name`
-- column, so "sysop-configurable" needs no special mechanism — it's
-- editable the same way any room name would be, once room-editing
-- routes exist.
--
-- Mail: seeded here as a room, but its actual behavior in the original
-- (private, addressed messages — see hack.doc's lbslot[]/lbId[]
-- mechanism) is NOT designed yet for this rebuild. This creates the
-- room; it does not implement per-recipient message addressing or
-- visibility filtering. That's a real, separate, still-open design gap,
-- not something to assume is solved because the row exists.
--
-- Aide: seeded here because it's already a load-bearing assumption
-- elsewhere in the system — audit.js and security-digest.sh both look
-- up `WHERE name = 'Aide'` to post notable-event notices and the daily
-- digest. Nothing previously guaranteed this room actually exists;
-- seeding it here closes that latent gap.
INSERT INTO rooms (name) VALUES ('Lobby');
INSERT INTO rooms (name) VALUES ('Mail');
INSERT INTO rooms (name) VALUES ('Aide');
