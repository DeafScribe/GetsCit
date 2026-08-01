-- Lives in each instance's own SQLite file, same as everything else —
-- login_attempts for castletalk-two.db has nothing to do with castletalk-
-- three.db's, consistent with the rest of the per-subdomain isolation.

CREATE TABLE login_attempts (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    action     TEXT NOT NULL CHECK (action IN ('login', 'setup')),
    username   TEXT,              -- NULL for 'setup' attempts (no account exists yet)
    ip         TEXT NOT NULL,
    success    INTEGER NOT NULL,  -- 0 or 1
    created_at INTEGER NOT NULL   -- unix seconds, not ISO text — arithmetic is
                                  -- simpler and avoids timezone/parsing bugs
);

-- Two independent lookups happen per check (username-based, IP-based),
-- so both need their own index rather than sharing one.
CREATE INDEX idx_login_attempts_username ON login_attempts(action, username, created_at);
CREATE INDEX idx_login_attempts_ip       ON login_attempts(action, ip, created_at);
