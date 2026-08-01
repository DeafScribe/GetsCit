-- chat_sessions was originally specified without updated_at, but its
-- ended_at transition (open -> closed) is exactly the "existing row gets
-- edited later" case the backup script's MUTABLE_TABLES handling exists
-- for. backup.sh already lists chat_sessions there — this patch is what
-- makes that correct rather than silently no-op (an updated_at that
-- doesn't exist can't be queried against).

ALTER TABLE chat_sessions ADD COLUMN updated_at INTEGER;

-- Backfill existing rows so nothing has a NULL watermark the first time
-- backup.sh runs after this migration.
UPDATE chat_sessions SET updated_at = started_at WHERE updated_at IS NULL;

-- A trigger, not application discipline, maintains this column. Same
-- reasoning as the setup-gate middleware being a single choke point
-- rather than a check duplicated per-route: if "remember to bump
-- updated_at" lived in application code, it's one line someone forgets
-- to add the next time a new way of touching chat_sessions gets written
-- (ending a session, some future admin override, whatever). A trigger
-- can't be forgotten, because it fires on the write itself regardless of
-- which code path performed it.
--
-- SQLite does not recursively re-fire triggers by default (recursive_
-- triggers is OFF unless explicitly enabled), so this UPDATE-inside-an-
-- UPDATE-trigger is safe as written. The WHEN clause is a second,
-- independent safeguard: it skips the trigger body entirely when the
-- incoming write already set updated_at itself, so even if
-- recursive_triggers were ever turned on elsewhere, this can't loop.
CREATE TRIGGER trg_chat_sessions_updated_at
AFTER UPDATE ON chat_sessions
FOR EACH ROW
WHEN NEW.updated_at IS OLD.updated_at
BEGIN
  UPDATE chat_sessions SET updated_at = strftime('%s', 'now') WHERE id = NEW.id;
END;
