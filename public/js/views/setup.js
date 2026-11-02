import { api } from '../lib/api.js';
import { busy, html, mount } from '../lib/dom.js';
import { brandMark } from '../lib/icons.js';
import { loginArt, loginFoot } from './login.js';

/** First-time setup: creates the admin account, then signs it in. */
export function renderSetup(root, { username, onLogin, onAlreadyDone }) {
  mount(
    root,
    html`<div class="login">
      ${loginArt()}
      <form class="card login-card" novalidate>
        <div class="login-brand">
          <span class="brand-mark brand-mark-lg">${brandMark(28)}</span>
          <h1>Set up your gateway</h1>
          <p>Create the administrator account to get started</p>
        </div>
        <div class="stack">
          <div class="field">
            <label for="s-user">Username</label>
            <input id="s-user" class="input" name="username" value="${username}" autocomplete="username" required minlength="3" maxlength="40" />
          </div>
          <div class="field">
            <label for="s-pass">Password</label>
            <input id="s-pass" class="input" name="password" type="password" autocomplete="new-password" required minlength="8" />
          </div>
          <div class="field">
            <label for="s-rep">Repeat password</label>
            <input id="s-rep" class="input" name="repeat" type="password" autocomplete="new-password" required />
          </div>
          <span class="hint">At least 8 characters.</span>
          <div class="form-error hidden" data-error></div>
          <button class="btn btn-primary btn-lg btn-block" type="submit">Create admin account</button>
        </div>
      </form>
      ${loginFoot()}
    </div>`,
  );

  const form = root.querySelector('form');
  const error = root.querySelector('[data-error]');
  root.querySelector('#s-pass').focus();
  form.addEventListener('submit', (e) => {
    e.preventDefault();
    const btn = form.querySelector('button[type=submit]');
    busy(btn, async () => {
      error.classList.add('hidden');
      try {
        if (form.password.value !== form.repeat.value) throw new Error('Passwords do not match');
        const me = await api('/api/auth/setup', {
          method: 'POST',
          body: { username: form.username.value.trim(), password: form.password.value },
        });
        onLogin(me);
      } catch (err) {
        if (err.status === 409) return onAlreadyDone(err.message);
        error.textContent = err.message;
        error.classList.remove('hidden');
      }
    });
  });
}
