/*
 * find.js
 *
 * The <F>ind command. Two modes (by user, by phrase), scoped to the
 * current room by default with a global toggle inside the mode.
 *
 * Replaces the original's <U>ser and <P>hrase options, which were
 * modifiers on a read verb (.Read User Forward) rather than standalone
 * commands. That grammar went away with F/N/O/R, so these became a
 * top-level command instead.
 *
 * THE ONE THING THAT MUST NOT BREAK:
 *
 * Mail privacy is enforced by a WHERE clause in mail.js, not by
 * anything in the data itself. A naive search over `messages` would
 * therefore return every user's private mail to anyone who searched a
 * common word — silently, with no error, looking exactly like a working
 * feature. Every query below applies the Mail filter unconditionally:
 * if the Mail room is in scope at all, only rows where
 * recipient_id = the searching user are eligible. This mirrors
 * getMailMessages()'s recipient-only rule; if that rule ever changes,
 * this file has to change with it.
 */

function getMailRoomId(db) {
  return db.prepare(`SELECT id FROM rooms WHERE name = 'Mail' AND deleted_at IS NULL`).get()?.id;
}

/*
 * Shared visibility predicate. Applied to every search regardless of
 * mode or scope — a single place to get this right, rather than the
 * same condition retyped per query and eventually mistyped in one of
 * them.
 *
 * Reads as: a row is visible if it's in an ordinary (non-Mail) room, OR
 * it's in the Mail room and addressed to the person searching.
 */
const VISIBILITY = `
  (m.room_id != :mailRoomId OR m.recipient_id = :userId)
  AND r.deleted_at IS NULL
`;

/**
 * @param mode    'user' | 'phrase'
 * @param term    username to match, or phrase to search for
 * @param scope   'room' (default) | 'global'
 * @param roomId  the current room — required when scope is 'room'
 */
function find(db, { userId, mode, term, scope = 'room', roomId = null }) {
  const mailRoomId = getMailRoomId(db) ?? -1; // -1 => predicate is inert if
                                              // the Mail room is missing

  if (scope === 'room' && roomId == null) {
    throw new Error('roomId is required when scope is "room".');
  }

  const scopeClause = scope === 'room' ? 'AND m.room_id = :roomId' : '';

  if (mode === 'user') {
    return db.prepare(`
      SELECT m.* FROM messages m
      JOIN rooms r ON r.id = m.room_id
      JOIN users u ON u.id = m.author_id
      WHERE u.username = :term
        ${scopeClause}
        AND ${VISIBILITY}
      ORDER BY m.id DESC
      LIMIT 100
    `).all({ term, userId, mailRoomId, roomId });
  }

  if (mode === 'phrase') {
    // LIKE with leading wildcard means a full scan — entirely fine at
    // this scale (a few hundred thousand rows before it's noticeable).
    // SQLite's FTS5 is the upgrade path if it ever stops being fine;
    // adding it now would be solving a problem that doesn't exist yet.
    // LIKE is case-insensitive for ASCII by default.
    return db.prepare(`
      SELECT m.* FROM messages m
      JOIN rooms r ON r.id = m.room_id
      WHERE m.body LIKE :pattern
        ${scopeClause}
        AND ${VISIBILITY}
      ORDER BY m.id DESC
      LIMIT 100
    `).all({ pattern: `%${term}%`, userId, mailRoomId, roomId });
  }

  throw new Error(`Unknown find mode: ${mode}`);
}

module.exports = { find };
