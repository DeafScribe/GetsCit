/*
 * password.js
 *
 * Self-service password change — the original's `.Enter Password`.
 *
 * Deliberately handles TWO paths through one function, because they're
 * the same operation:
 *
 *   1. A logged-in user voluntarily changing a password they still know.
 *   2. A user who was just given a temp password by an aide, and is
 *      being forced to set a real one before the setup-gate-style
 *      middleware will let them reach anything else.
 *
 * In case 2 the "current password" IS the temp password, so verification
 * works identically. One code path, no special-casing — which matters,
 * because a separate forced-reset path would be a second place the
 * session-invalidation and audit rules could drift out of sync.
 */

const { checkRateLimit, recordAttempt } = require('./rate-limiter');
const { logEvent } = require('./audit');

const MIN_LENGTH = 12;   // matches setup.js

const ARGON2 = {
  algorithm: 'argon2id',
  memoryCost: 19456,   // ~19 MiB — OWASP baseline
  timeCost: 2,
};

/**
 * @param db
 * @param userId         the authenticated user
 * @param currentPassword
 * @param newPassword
 * @param newPasswordConfirm
 * @param ip
 * @param currentSessionToken  kept alive; every OTHER session is destroyed
 * @returns { ok: true } | { ok: false, status, message, retryAfterSeconds? }
 */
async function changePassword(db, {
  userId,
  currentPassword,
  newPassword,
  newPasswordConfirm,
  ip,
  currentSessionToken,
}) {
  const user = db
    .prepare(`SELECT id, username, password_hash, must_reset_password,
                     temp_password_expires_at
              FROM users WHERE id = ?`)
    .get(userId);

  if (!user) return { ok: false, status: 401, message: 'Not authenticated.' };

  // Throttle BEFORE verifying, and skip the (deliberately slow) hash
  // comparison entirely when throttled — same reasoning as /login.
  const check = checkRateLimit(db, {
    action: 'password_change',
    username: user.username,
    ip,
  });
  if (!check.allowed) {
    return {
      ok: false,
      status: 429,
      message: 'Too many attempts. Try again shortly.',
      retryAfterSeconds: check.retryAfterSeconds,
    };
  }

  // If this is the forced path after an aide reset, the one-hour window
  // applies to the temp password itself. Expired means the aide has to
  // issue a new one — the user can't extend it by retrying.
  if (user.must_reset_password) {
    const now = Math.floor(Date.now() / 1000);
    if (!user.temp_password_expires_at || user.temp_password_expires_at < now) {
      return {
        ok: false,
        status: 403,
        message: 'This temporary password has expired. Ask an aide to issue a new one.',
      };
    }
  }

  const currentOk = await Bun.password.verify(currentPassword, user.password_hash);
  recordAttempt(db, {
    action: 'password_change',
    username: user.username,
    ip,
    success: currentOk,
  });

  if (!currentOk) {
    return { ok: false, status: 403, message: 'Current password is incorrect.' };
  }

  // --- New-password validation ---
  if (newPassword !== newPasswordConfirm) {
    return { ok: false, status: 400, message: 'New passwords do not match.' };
  }
  if (typeof newPassword !== 'string' || newPassword.length < MIN_LENGTH) {
    return {
      ok: false,
      status: 400,
      message: `New password must be at least ${MIN_LENGTH} characters.`,
    };
  }
  if (newPassword === currentPassword) {
    // Matters most on the forced path: without this, "changing" the temp
    // password to itself would clear must_reset_password and leave the
    // aide-issued credential live indefinitely, quietly defeating the
    // one-hour expiry.
    return { ok: false, status: 400, message: 'New password must differ from the current one.' };
  }

  const newHash = await Bun.password.hash(newPassword, ARGON2);

  // Hash first (slow, may throw), then commit everything atomically.
  // A partial write here could leave must_reset_password cleared while
  // the stored hash still matches the expired temp password.
  db.transaction(() => {
    db.prepare(
      `UPDATE users
       SET password_hash = ?, must_reset_password = 0, temp_password_expires_at = NULL
       WHERE id = ?`
    ).run(newHash, userId);

    // Destroy every other session for this user. If the password change
    // was prompted by a suspected compromise, leaving the attacker's
    // session alive makes the change close to pointless — and there's no
    // other moment in the system where that cleanup would happen.
    db.prepare(
      `DELETE FROM sessions WHERE user_id = ? AND token != ?`
    ).run(userId, currentSessionToken);
  })();

  logEvent(db, {
    actorUserId: userId,
    action: 'password_change',
    ip,
    // Not in NOTABLE_ACTIONS — a routine self-service change shouldn't
    // post into the Aide room. It's in audit_log if anyone ever asks.
    // (An aide-initiated RESET does post, and still does; that's a
    // different action.)
  });

  return { ok: true };
}

module.exports = { changePassword };

/*
 * Route wiring (illustrative):
 *
 *   app.post('/password', async (req, res) => {
 *     const result = await changePassword(db, {
 *       userId: req.session.userId,
 *       currentPassword: req.body.currentPassword,
 *       newPassword: req.body.newPassword,
 *       newPasswordConfirm: req.body.newPasswordConfirm,
 *       ip: req.ip,
 *       currentSessionToken: req.session.token,
 *     });
 *     if (!result.ok) {
 *       if (result.retryAfterSeconds) res.set('Retry-After', String(result.retryAfterSeconds));
 *       return res.status(result.status).json({ message: result.message });
 *     }
 *     res.json({ ok: true });
 *   });
 *
 * NOTE on the forced path: whatever middleware enforces
 * must_reset_password must allow POST /password through, exactly as
 * setup-gate-middleware.js allows /setup through when setup is
 * incomplete. Same shape of gate, same failure mode if missed — a user
 * locked out of the only route that could unlock them.
 */
