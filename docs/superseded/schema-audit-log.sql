-- Append-only by nature — an audit entry is never edited after the fact,
-- which is exactly why this slots into backup.sh's APPEND_TABLES list
-- (see the accompanying diff below) rather than the updated_at/REPLACE
-- INTO handling used for mutable tables like users or rooms.

CREATE TABLE audit_log (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    actor_user_id  INTEGER,   -- who did it; NULL for system-initiated events
    action         TEXT NOT NULL,  -- e.g. 'login_success', 'room_delete',
                                    -- 'grant_can_delete_rooms', 'aide_create'
    target         TEXT,      -- what it was done to, e.g. a room name or username
    detail         TEXT,      -- free-form context, kept short
    ip             TEXT,
    created_at     INTEGER NOT NULL
);

CREATE INDEX idx_audit_log_created_at ON audit_log(created_at);
CREATE INDEX idx_audit_log_actor      ON audit_log(actor_user_id, created_at);
