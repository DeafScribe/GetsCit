const body = document.body;
const sw = document.getElementById('themeSwitch');
const label = document.getElementById('modeLabel');

function setTheme(amber) {
  body.classList.toggle('theme-amber', amber);
  body.classList.toggle('theme-green', !amber);
  label.textContent = amber ? 'AMBER' : 'GREEN';
}

sw.addEventListener('click', () => setTheme(!body.classList.contains('theme-amber')));
sw.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); sw.click(); }
});

const textarea = document.querySelector('textarea');
textarea.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    // Wire this to POST /rooms/:id/messages in the real client.
    const val = textarea.value.trim();
    if (!val) return;
    const list = document.getElementById('messages');
    const div = document.createElement('div');
    div.className = 'msg';
    // textContent, not innerHTML — user-authored text is never parsed as markup.
    const meta = document.createElement('div');
    meta.className = 'meta';
    meta.textContent = '>> you (just now)';
    const messageBody = document.createElement('div');
    messageBody.className = 'body';
    messageBody.textContent = val;
    div.appendChild(meta);
    div.appendChild(messageBody);
    list.appendChild(div);
    list.scrollTop = list.scrollHeight;
    textarea.value = '';
  }
});
