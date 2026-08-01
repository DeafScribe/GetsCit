/*
 * mail.js
 *
 * Internal mail only — no cross-instance/networked mail, matching this
 * project's scope boundary everywhere else. Built on the same table
 * every other room uses (messages.recipient_id), not a separate system,
 * following the original's own precedent: hack.doc describes Mail> as
 * "otherwise behaves pretty much as any other room," special-cased only
 * in how it's addressed and read.
 */

function getMailRoomId(db) {
  return db.prepare(`SELECT id FROM rooms WHERE name = 'Mail' AND deleted_at IS NULL`).get()?.id;
}

/**
 * Composing mail. The original "kludged MakeMessage() to ask for the
 * name of the recipient whenever a message is entered in Mail>" — same
 * idea here, just as an explicit required field rather than a special-
 * cased prompt bolted onto the ordinary compose flow.
 */
function postMail(db, { senderId, recipientUsername, body }) {
  const mailRoomId = getMailRoomId(db);
  if (!mailRoomId) throw new Error('Mail room does not exist on this instance.');

  const recipient = db
    .prepare(`SELECT id FROM users WHERE username = ?`)
    .get(recipientUsername);

  if (!recipient) {
    // Same principle as the login error message discussion earlier:
    // don't leak whether a username exists via different error wording
    // elsewhere, but mail composition already requires knowing the
    // recipient's name, so a direct "no such user" here isn't an
    // enumeration risk the way a login failure message would be.
    throw new Error(`No such user: ${recipientUsername}`);
  }

  return db.prepare(
    `INSERT INTO messages (room_id, author_id, recipient_id, body)
     VALUES (?, ?, ?, ?)`
  ).run(mailRoomId, senderId, recipient.id, body);
}

/**
 * Reading mail. THIS is the one room-read in the whole system that
 * doesn't look like every other room's "show everyone everything since
 * X." Filtering to recipient-only is what makes it private at all — get
 * this query wrong (e.g. copy-paste the ordinary room-read query
 * without noticing Mail is different) and every user's private mail
 * becomes visible to every other user instantly, silently, with no
 * error to signal the mistake.
 *
 * Recipient-only, by decision: once sent, a message is gone from the
 * sender's own view — there's no "sent mail" folder. If that turns out
 * to be an unwelcome surprise in practice, it's a one-line change back
 * to `(recipient_id = ? OR author_id = ?)`.
 */
function getMailMessages(db, { userId, sinceId = 0 }) {
  const mailRoomId = getMailRoomId(db);
  if (!mailRoomId) return [];

  return db.prepare(
    `SELECT * FROM messages
     WHERE room_id = ?
       AND id > ?
       AND recipient_id = ?
     ORDER BY id`
  ).all(mailRoomId, sinceId, userId);
}

module.exports = { postMail, getMailMessages, getMailRoomId };

/*
 * Open design questions, deliberately not resolved here:
 *
 *   - No read/unread tracking specific to mail is designed yet — it
 *     rides on whatever general room-unread mechanism ends up built
 *     for ordinary rooms, which itself isn't implemented as real route
 *     code yet either.
 */
