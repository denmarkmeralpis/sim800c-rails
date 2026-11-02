import { api } from '../lib/api.js';
import { busy, html, mount } from '../lib/dom.js';
import { brandMark } from '../lib/icons.js';

/** Shared backdrop for the sign-in and setup screens: broadcast rings + a spec footer. */
export const loginArt = () => html`<div class="login-art" aria-hidden="true"><i></i><i></i><i></i><i></i></div>`;
export const loginFoot = () =>
  html`<div class="login-foot" aria-hidden="true"><span>SMS</span><span>Voice</span><span>USSD</span><span>SIM800C · Quad-band GSM</span></div>`;

export function renderLogin(root, { onLogin, notice }) {
  document.title = 'Sign in · SMS Gateway';
  mount(
    root,
    html`<div class="login">
      ${loginArt()}
      <form class="card login-card" novalidate>
        <div class="login-brand">
          <span class="brand-mark brand-mark-lg">${brandMark(28)}</span>
          <h1>SMS Gateway</h1>
          <p>Sign in to your SIM800C console</p>
        </div>
        <div class="stack">
          ${notice ? html`<div class="banner banner-info">${notice}</div>` : ''}
          <div class="field">
            <label for="l-user">Username</label>
            <input id="l-user" class="input" name="username" autocomplete="username" required autofocus />
          </div>
          <div class="field">
            <label for="l-pass">Password</label>
            <input id="l-pass" class="input" name="password" type="password" autocomplete="current-password" required />
          </div>
          <div class="form-error hidden" data-error></div>
          <button class="btn btn-primary btn-lg btn-block" type="submit">Sign in</button>
        </div>
      </form>
      ${loginFoot()}
    </div>`,
  );

  const form = root.querySelector('form');
  const error = root.querySelector('[data-error]');
  root.querySelector('#l-user').focus();
  form.addEventListener('submit', (e) => {
    e.preventDefault();
    const btn = form.querySelector('button[type=submit]');
    busy(btn, async () => {
      error.classList.add('hidden');
      try {
        const me = await api('/api/auth/login', {
          method: 'POST',
          body: { username: form.username.value.trim(), password: form.password.value },
        });
        onLogin(me);
      } catch (err) {
        error.textContent = err.message;
        error.classList.remove('hidden');
        form.password.select();
      }
    });
  });
}
