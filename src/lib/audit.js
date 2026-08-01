/*
 * audit.js
 *
 * Two tiers, on purpose:
 *
 *   logEvent()      -> always writes to audit_log. Silent, queryable,
 *                       cheap. Every login, every admin action, no
 *                       exceptions.
 *
 *   NOTABLE_ACTIONS  -> a short, deliberately small list of actions that
 *                       ALSO get posted into the aide room, because they're
 *                       the kind of thing a person should notice when it
 *                       happens, not just be able to find later if they
 *                       think to look. Same reasoning that put password
 *                       resets there in the first place.
 *
 * Keeping this list short is the point. If everything posts to the aide
 * room, the room stops being something anyone actually reads — it's the
 * same failure mode as an over-alerting monitoring system nobody
 * responds to anymore. Ordinary successful logins do NOT belong here;
 * they go to audit_log only, queryable if ever needed, invisible day to
 * day.
 */

const NOTABLE_ACTIONS = new Set([
  'room_delete',
  'grant_can_delete_rooms',
  'revoke_can_delete_rooms',
  'aide_create',
  'password_reset',       // already the existing behavior, now just
                           // expressed through the same shared function
]);

function logEvent(db, { actorUserId, action, target, detail, ip, postToAideRoom }) {
  const now = Math.floor(Date.now() / 1000);

  db.prepare(
    `INSERT INTO audit_log (actor_user_id, action, target, detail, ip, created_at)
     VALUES (?, ?, ?, ?, ?, ?)`
  ).run(actorUserId || null, action, target || null, detail || null, ip || null, now);

  const shouldPost = postToAideRoom !== undefined ? postToAideRoom : NOTABLE_ACTIONS.has(action);

  if (shouldPost) {
    const aideRoomId = db
      .prepare(`SELECT id FROM rooms WHERE name = 'Aide' AND deleted_at IS NULL`)
      .get()?.id;

    if (aideRoomId) {
      const actorName = actorUserId
        ? db.prepare(`SELECT username FROM users WHERE id = ?`).get(actorUserId)?.username
        : 'system';

      // textContent-equivalent discipline applies here too: this body
      // is rendered to aides the same way any other message is, so it
      // goes through the same plain-text-only path — no string
      // concatenation that could be mistaken for needing HTML escaping,
      // because nothing here is ever treated as markup in the first place.
      const body = `${actorName} — ${action}${target ? ` (${target})` : ''}${detail ? `: ${detail}` : ''}`;

      db.prepare(
        `INSERT INTO messages (room_id, author_id, body) VALUES (?, ?, ?)`
      ).run(aideRoomId, actorUserId || null, body);
    }
  }
}

module.exports = { logEvent, NOTABLE_ACTIONS };

/*
 * Usage at a few call sites, illustrative:
 *
 *   // ordinary login — audit_log only, no room clutter
 *   logEvent(db, { actorUserId: user.id, action: 'login_success', ip });
 *
 *   // room deletion — both audit_log AND the aide room, automatically,
 *   // because 'room_delete' is in NOTABLE_ACTIONS
 *   logEvent(db, {
 *     actorUserId: aide.id,
 *     action: 'room_delete',
 *     target: room.name,
 *     ip,
 *   });
 *
 *   // a one-off case where you want a post even for something not in
 *   // the default list — postToAideRoom overrides the lookup
 *   logEvent(db, {
 *     actorUserId: aide.id,
 *     action: 'bulk_content_edit',
 *     detail: '14 help pages updated',
 *     ip,
 *     postToAideRoom: true,
 *   });
 */
