/*
 * rate-limiter.js
 *
 * Two independent axes, checked separately, because collapsing them into
 * one counter creates a vulnerability: locking purely by username lets an
 * attacker lock a real user out just by deliberately failing their login
 * a few times. Locking purely by IP misses distributed credential-stuffing
 * across many IPs. Tracking both, with different responses, closes both
 * gaps without opening the other.
 *
 * Per-username: escalating delay, never a hard lock. Punishes a slow
 * guesser without ever fully denying a real user access to their own
 * account.
 *
 * Per-IP: a harder threshold and cooldown. Blocking an IP doesn't have
 * the same "attacker weaponizes it against a specific victim" problem,
 * so it can afford to be blunter — this is what actually catches a bot
 * trying many usernames from one source.
 *
 * Shared across both 'login' and 'setup' actions via the `action` column,
 * so the same table, same cleanup job, and same logic protect both
 * surfaces — /setup being throttled the same way /login is, since an
 * out-of-band-delivered password can still be brute-forced once it
 * exists; the private handoff protects against interception, not against
 * someone hammering the form with guesses afterward.
 */

const QUIET_RESET_SECONDS = 15 * 60;     // per-username: 15 min of no attempts resets the counter
const IP_WINDOW_SECONDS = 10 * 60;       // per-IP: rolling 10-minute window
const IP_THRESHOLD = 20;                 // per-IP: failures in that window before blocking
const IP_COOLDOWN_SECONDS = 20 * 60;     // per-IP: block duration once tripped
const MAX_USERNAME_DELAY_SECONDS = 30;   // per-username: cap on escalating delay

function now() {
  return Math.floor(Date.now() / 1000);
}

/**
 * Call BEFORE checking a password. If `allowed` is false, reject
 * immediately with the given retryAfterSeconds and do NOT run the
 * password comparison at all — there's no reason to pay argon2id's
 * deliberately-slow cost on a request you're rejecting anyway.
 *
 * @param db      an open better-sqlite3 (or equivalent) database handle
 * @param action  'login' or 'setup'
 * @param username  string for 'login', null for 'setup' (no account exists yet)
 * @param ip      request's source IP
 * @returns { allowed: boolean, retryAfterSeconds: number, reason?: string }
 */
function checkRateLimit(db, { action, username, ip }) {
  const t = now();

  // --- Per-IP check first: cheaper to fail fast on a known-bad IP,
  // regardless of which username (if any) it's currently trying. ---
  const ipFailures = db
    .prepare(
      `SELECT COUNT(*) AS n, MAX(created_at) AS last
       FROM login_attempts
       WHERE action = ? AND ip = ? AND success = 0 AND created_at > ?`
    )
    .get(action, ip, t - IP_WINDOW_SECONDS);

  if (ipFailures.n >= IP_THRESHOLD) {
    const retryAfter = ipFailures.last + IP_COOLDOWN_SECONDS - t;
    if (retryAfter > 0) {
      return { allowed: false, retryAfterSeconds: retryAfter, reason: 'ip_blocked' };
    }
  }

  // --- Per-username check, only meaningful for 'login' (setup has no
  // existing username to key off — IP-only protection applies there). ---
  if (action === 'login' && username) {
    const lastSuccess = db
      .prepare(
        `SELECT MAX(created_at) AS t FROM login_attempts
         WHERE action = 'login' AND username = ? AND success = 1`
      )
      .get(username).t || 0;

    const cutoff = Math.max(lastSuccess, t - QUIET_RESET_SECONDS);

    const row = db
      .prepare(
        `SELECT COUNT(*) AS n, MAX(created_at) AS last
         FROM login_attempts
         WHERE action = 'login' AND username = ? AND success = 0 AND created_at > ?`
      )
      .get(username, cutoff);

    const failCount = row.n;
    if (failCount >= 5) {
      // 5th failure -> 1s, 6th -> 2s, 7th -> 4s, doubling, capped.
      const delay = Math.min(2 ** (failCount - 5), MAX_USERNAME_DELAY_SECONDS);
      const retryAfter = row.last + delay - t;
      if (retryAfter > 0) {
        return { allowed: false, retryAfterSeconds: retryAfter, reason: 'username_backoff' };
      }
    }
  }

  return { allowed: true, retryAfterSeconds: 0 };
}

/**
 * Call AFTER a login/setup attempt resolves, whether it succeeded or not.
 * Recording failures is what makes the checks above possible; recording
 * successes is what lets a legitimate user's counter reset immediately
 * rather than waiting out the full quiet period.
 */
function recordAttempt(db, { action, username, ip, success }) {
  db.prepare(
    `INSERT INTO login_attempts (action, username, ip, success, created_at)
     VALUES (?, ?, ?, ?, ?)`
  ).run(action, username || null, ip, success ? 1 : 0, now());
}

module.exports = { checkRateLimit, recordAttempt };

/*
 * Wiring into a route (illustrative — adapt to whatever's actually
 * handling requests):
 *
 *   app.post('/login', (req, res) => {
 *     const { username, password } = req.body;
 *     const ip = req.ip;
 *
 *     const check = checkRateLimit(db, { action: 'login', username, ip });
 *     if (!check.allowed) {
 *       res.set('Retry-After', String(check.retryAfterSeconds));
 *       return res.status(429).json({ message: 'Too many attempts. Try again shortly.' });
 *     }
 *
 *     const user = db.prepare('SELECT * FROM users WHERE username = ?').get(username);
 *     // Same generic failure message whether the username doesn't exist
 *     // or the password is wrong — distinguishing the two lets an
 *     // attacker enumerate valid usernames for free.
 *     const ok = user && argon2.verifySync(user.password_hash, password);
 *
 *     recordAttempt(db, { action: 'login', username, ip, success: !!ok });
 *
 *     if (!ok) return res.status(401).json({ message: 'Invalid username or password.' });
 *     // ... issue session cookie, proceed
 *   });
 *
 *   app.post('/setup', (req, res) => {
 *     const ip = req.ip;
 *     const check = checkRateLimit(db, { action: 'setup', username: null, ip });
 *     if (!check.allowed) {
 *       res.set('Retry-After', String(check.retryAfterSeconds));
 *       return res.status(429).json({ message: 'Too many attempts. Try again shortly.' });
 *     }
 *     // ... validate payload, create aide account + site_config as before
 *     recordAttempt(db, { action: 'setup', username: null, ip, success: true });
 *   });
 */
