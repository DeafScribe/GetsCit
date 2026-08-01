/*
 * setup-gate-middleware.js
 *
 * This is the ONE place first-run gating happens. It runs before any
 * route handler — including auth, room, message, and chat routes — so
 * no individual route can forget to check. That's the whole point:
 * a check duplicated per-route is a check someone eventually forgets
 * to add to a new route. A single middleware mounted first can't be
 * forgotten, because every request passes through it by construction.
 *
 * Framework-agnostic illustration (Express-shaped, adapt to whatever
 * you're actually running — the shape matters more than the syntax).
 */

const ALWAYS_ALLOWED = new Set([
  '/setup',           // GET: show the form: POST: submit it
  '/setup.css',
  '/setup.js',
]);

function setupGate(getDbForRequest) {
  return function (req, res, next) {
    const db = getDbForRequest(req); // selects the right SQLite file by Host header

    const row = db
      .prepare('SELECT value FROM site_config WHERE key = ?')
      .get('setup_complete');

    const isComplete = row && row.value === 'true';

    if (!isComplete) {
      // Instance not yet configured: ONLY /setup (and its assets) may load.
      // Everything else — login, rooms, messages, chat, admin panels —
      // is blocked here, at the gate, before those handlers ever run.
      if (ALWAYS_ALLOWED.has(req.path)) return next();
      return res.status(403).send('This instance has not been set up yet.');
    }

    // Setup IS complete: the reverse rule applies. /setup must now be
    // permanently unreachable — this is the dangerous direction to get
    // wrong, since /setup can create an aide account. A page that mints
    // admins must not still be live once the instance is running.
    if (req.path === '/setup') {
      return res.status(404).send('Not found.');
    }

    return next();
  };
}

module.exports = { setupGate };

/*
 * Mounting this — the part that actually matters:
 *
 *   const app = express();
 *   app.use(setupGate(getDbForRequest));   // <-- FIRST, before any route
 *   app.use('/auth', authRoutes);
 *   app.use('/rooms', roomRoutes);
 *   app.use('/chat', chatRoutes);
 *   ...
 *
 * If setupGate() is mounted after other routes, or duplicated inside
 * individual handlers instead of mounted globally like this, the whole
 * safety property disappears. The guarantee only holds because nothing
 * downstream of this line can execute without passing through it first.
 */
