const form = document.getElementById('setupForm');
const errorEl = document.getElementById('formError');

function showError(message) {
  // textContent, not innerHTML — same discipline as everywhere else in
  // this app. Error text could echo back something a user typed
  // (e.g. "username already taken: <value>"), so it must never be
  // parsed as markup.
  errorEl.textContent = message;
  errorEl.hidden = false;
}

function clearError() {
  errorEl.hidden = true;
  errorEl.textContent = '';
}

form.addEventListener('submit', async (e) => {
  e.preventDefault();
  clearError();

  const siteName = document.getElementById('siteName').value.trim();
  const aideName = document.getElementById('aideName').value.trim();
  const password = document.getElementById('aidePassword').value;
  const confirm = document.getElementById('aidePasswordConfirm').value;

  if (!siteName || !aideName || !password) {
    showError('All required fields must be filled in.');
    return;
  }
  if (password !== confirm) {
    showError('Passwords do not match.');
    return;
  }
  if (password.length < 12) {
    showError('Password must be at least 12 characters.');
    return;
  }

  const payload = {
    siteName,
    policy: {
      unlogReadOk: document.getElementById('unlogReadOk').checked,
      unlogEnterOk: document.getElementById('unlogEnterOk').checked,
      nonAideRoomOk: document.getElementById('nonAideRoomOk').checked,
      chatEnabled: document.getElementById('chatEnabled').checked,
    },
    aide: { username: aideName, password },
  };

  // Real endpoint, guarded server-side by setup-gate-middleware.js.
  // The client-side checks above are for a good error message, not
  // security — the server re-validates everything and is the only
  // thing that can actually write setup_complete = true.
  let res;
  try {
    res = await fetch('/setup', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
  } catch (err) {
    showError('Could not reach the server. Try again.');
    return;
  }

  if (res.ok) {
    window.location.href = '/login';
    return;
  }

  if (res.status === 404) {
    showError('Setup has already been completed on this instance.');
    return;
  }

  const body = await res.json().catch(() => ({}));
  showError(body.message || 'Setup failed. Check your entries and try again.');
});
