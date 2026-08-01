-- Not a full feature build yet — that's part of the command-list review
-- you're holding for later. This is just the schema shape, done now
-- because it directly touches something already built (backup.sh) and
-- is cheap to get right early rather than retrofit.

-- --- Role split: sysop vs aide vs user ---
--
-- "sysop" isn't a third value alongside 'user'/'aide' in a role column —
-- it's a single flag on top of 'aide', because you described it as ONE
-- designated aide who can grant a specific power to others, not a
-- separate tier with its own permission set. A partial unique index
-- enforces "at most one sysop per instance" at the database level,
-- rather than trusting application code to never create a second one.
ALTER TABLE users ADD COLUMN is_sysop INTEGER NOT NULL DEFAULT 0;
CREATE UNIQUE INDEX idx_one_sysop ON users(is_sysop) WHERE is_sysop = 1;

-- The account created via /setup should have this set at creation time.

-- --- Per-aide permission toggle: can this specific aide remove rooms? ---
--
-- Sysop-only by default (can_delete_rooms = 0 for every aide until the
-- sysop explicitly grants it to one). This is the "toggle" you described
-- — a flag the sysop sets on individual aide accounts, not a global
-- switch and not something an aide can grant themselves.
ALTER TABLE users ADD COLUMN can_delete_rooms INTEGER NOT NULL DEFAULT 0;

-- Enforce in application code: only a request from a user where
-- is_sysop = 1 may modify another user's can_delete_rooms. This isn't
-- something a CHECK constraint can express (it depends on who's making
-- the request, not just the row's own values), so it has to live in the
-- route handler — flagging that explicitly since it's exactly the kind
-- of check that's easy to add correctly once and forget on a second
-- route later if it's not centralized the same way the setup gate was.

-- --- Soft delete on rooms, not a real DELETE ---
--
-- rooms is already in backup.sh's MUTABLE_TABLES list, tracked by
-- updated_at. A hard DELETE leaves no watermark trace — the row just
-- vanishes, and a restore from baseline+deltas would silently bring it
-- back, exactly the gap flagged when backup.sh was written. Soft-
-- deleting turns "delete a room" into an ordinary update, which the
-- existing backup logic already knows how to carry forward correctly,
-- with no special-casing needed anywhere.
ALTER TABLE rooms ADD COLUMN deleted_at INTEGER;

-- Every query that lists or reads rooms needs `WHERE deleted_at IS NULL`
-- added — this is a real, easy-to-miss retrofit across existing room
-- routes once deletion is actually wired up, worth a deliberate pass
-- rather than assuming it's covered.
