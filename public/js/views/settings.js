import { confirmDialog, openModal } from '../components/modal.js';
import { toast, toastError } from '../components/toast.js';
import { api, BASE } from '../lib/api.js';
import { busy, copyText, html, mount, on } from '../lib/dom.js';
import { dateTime, timeAgo } from '../lib/format.js';
import { icon } from '../lib/icons.js';
import { can, state } from '../lib/store.js';

const SCOPE_INFO = {
  'sms:read': 'Read messages',
  'sms:send': 'Send / retry SMS',
  'sms:delete': 'Delete messages',
  'calls:read': 'Read call history',
  'calls:write': 'Dial / answer / hang up',
  'modem:read': 'Read modem status',
  'modem:write': 'Reconnect / restart modem',
};

const ENDPOINTS = [
  ['POST', '/sms', 'Send SMS — queued and sent asynchronously (202) · optional Idempotency-Key header', 'sms:send'],
  ['GET', '/sms', 'List messages · direction, status, q, unread, page, limit', 'sms:read'],
  ['GET', '/sms/:id', 'Message details and delivery status', 'sms:read'],
  ['POST', '/sms/read', 'Mark messages read/unread · {ids, read}', 'sms:read'],
  ['POST', '/sms/delete', 'Delete several messages · {ids}', 'sms:delete'],
  ['DELETE', '/sms/:id', 'Delete one message', 'sms:delete'],
  ['POST', '/sms/:id/retry', 'Retry a failed or cancelled message', 'sms:send'],
  ['POST', '/sms/retry-failed', 'Retry every failed message', 'sms:send'],
  ['POST', '/sms/:id/cancel', 'Cancel a queued message', 'sms:send'],
  ['POST', '/calls', 'Dial a number · {number}', 'calls:write'],
  ['GET', '/calls/active', 'Current call, or null', 'calls:read'],
  ['POST', '/calls/hangup', 'Hang up (also /answer, /reject)', 'calls:write'],
  ['POST', '/calls/dtmf', 'Send DTMF tones during a call · {digits}', 'calls:write'],
  ['GET', '/calls', 'Call history · direction, status, page, limit', 'calls:read'],
  ['POST', '/ussd', 'Send a USSD code · {code} — returns once the network replies', 'calls:write'],
  ['POST', '/ussd/reply', 'Answer an open USSD menu · {text}', 'calls:write'],
  ['POST', '/ussd/cancel', 'Close the open USSD menu', 'calls:write'],
  ['GET', '/ussd', 'Latest USSD session, or null', 'calls:read'],
  ['GET', '/ussd/sessions', 'USSD history · status, source, q, page, limit', 'calls:read'],
  ['GET', '/ussd/sessions/:id', 'One USSD session with its messages', 'calls:read'],
  ['POST', '/ussd/sessions/delete', 'Delete several USSD sessions · {ids}', 'calls:write'],
  ['DELETE', '/ussd/sessions/:id', 'Delete one USSD session', 'calls:write'],
  ['GET', '/modem', 'Modem, SIM, network and signal status', 'modem:read'],
  ['GET', '/events', 'Server-Sent Events stream (sms.*, call.*, ussd.updated, modem.status)', 'any read scope'],
];

export default {
  title: 'Settings',
  render(el) {
    const admin = can('admin');
    const origin = location.origin + BASE;
    const view = { keys: [], users: [] };

    mount(
      el,
      html`<div class="page">
        <div class="page-head"><div><span class="eyebrow"><b>05</b> Access · Integrations</span><h1>Settings</h1><p>Account, API access and users</p></div></div>

        <div class="grid grid-2">
          <div class="card">
            <div class="card-head"><h2>${icon('user', 15)} Your account</h2></div>
            <div class="card-body stack">
              <dl class="kv">
                <dt>Username</dt><dd>${state.me.username}</dd>
                <dt>Role</dt><dd>${state.me.role}</dd>
                <dt>Permissions</dt><dd class="row row-wrap">${[...state.scopes].map((s) => html`<span class="chip">${s}</span>`)}</dd>
              </dl>
              <div class="row">
                <button class="btn btn-sm" data-act="notifications">${icon('bell', 14)} Desktop notifications</button>
                <span class="hint" data-notif-state></span>
              </div>
            </div>
          </div>
          <form class="card" data-form="password">
            <div class="card-head"><h2>${icon('key', 15)} Change password</h2></div>
            <div class="card-body stack">
              <div class="field"><label for="p-cur">Current password</label><input id="p-cur" class="input" name="current" type="password" autocomplete="current-password" required /></div>
              <div class="field"><label for="p-new">New password</label><input id="p-new" class="input" name="next" type="password" autocomplete="new-password" minlength="8" required /></div>
              <div class="field"><label for="p-rep">Repeat new password</label><input id="p-rep" class="input" name="repeat" type="password" autocomplete="new-password" required /></div>
              <div class="row"><span class="hint grow">Other sessions will be signed out.</span><button class="btn btn-primary" type="submit">Update password</button></div>
            </div>
          </form>
        </div>

        ${admin
          ? html`<div class="card">
                <div class="card-head"><h2>${icon('key', 16)} API keys</h2></div>
                <div data-keys></div>
                <form class="card-body stack" data-form="key" style="border-top:1px solid var(--border)">
                  <div class="row row-wrap" style="align-items:flex-end">
                    <div class="field grow" style="min-width:200px"><label for="k-name">New key name</label><input id="k-name" class="input" name="keyName" placeholder="e.g. CRM integration" required maxlength="80" /></div>
                    <button class="btn btn-primary" type="submit">${icon('plus', 16)} Create key</button>
                  </div>
                  <div class="check-grid">
                    ${Object.entries(SCOPE_INFO).map(
                      ([s, label]) => html`<label><input type="checkbox" class="checkbox" name="scopes" value="${s}" ${s === 'sms:send' || s === 'sms:read' ? 'checked' : ''} /><span><span class="mono">${s}</span><br /><span class="faint">${label}</span></span></label>`,
                    )}
                  </div>
                </form>
              </div>

              <div class="card">
                <div class="card-head"><h2>${icon('users', 16)} Users</h2></div>
                <div data-users></div>
                <form class="card-body row row-wrap" data-form="user" style="border-top:1px solid var(--border);align-items:flex-end">
                  <div class="field grow" style="min-width:150px"><label for="u-name">Username</label><input id="u-name" class="input" name="username" required minlength="3" maxlength="40" autocomplete="off" /></div>
                  <div class="field grow" style="min-width:150px"><label for="u-pass">Password</label><input id="u-pass" class="input" name="password" type="password" required minlength="8" autocomplete="new-password" /></div>
                  <div class="field"><label for="u-role">Role</label>
                    <select id="u-role" class="select" name="role"><option value="operator">Operator</option><option value="viewer">Viewer</option><option value="admin">Admin</option></select>
                  </div>
                  <button class="btn btn-primary" type="submit">${icon('plus', 16)} Add user</button>
                </form>
                <div class="card-foot"><span><strong>Admin</strong>: everything · <strong>Operator</strong>: send SMS, place calls, read status · <strong>Viewer</strong>: read-only</span></div>
              </div>`
          : ''}

        <div class="card">
          <div class="card-head"><h2>${icon('book', 16)} REST API</h2><span class="chip">${origin}/api/v1</span></div>
          <div class="card-body stack">
            <p style="margin:0" class="muted">Authenticate with an API key in the <span class="mono">X-API-Key</span> header (or <span class="mono">Authorization: Bearer</span>). Responses are JSON; errors look like <span class="mono">{"error": {"code", "message"}}</span>.</p>
            <pre class="code">curl -X POST ${origin}/api/v1/sms \\
  -H "X-API-Key: smsgw_…" -H "Content-Type: application/json" \\
  -d '{"to": ["+639171234567"], "message": "Hello from the gateway"}'</pre>
          </div>
          <div>
            ${ENDPOINTS.map(
              ([m, path, desc, scope]) => html`<div class="endpoint">
                <span class="method ${m.toLowerCase()}">${m}</span>
                <span class="mono">/api/v1${path}</span>
                <span class="muted">${desc}</span>
                <span class="chip">${scope}</span>
              </div>`,
            )}
          </div>
        </div>
      </div>`,
    );

    const renderNotif = () => {
      const s = el.querySelector('[data-notif-state]');
      if (!s) return;
      s.textContent = !('Notification' in window)
        ? 'Not supported by this browser'
        : Notification.permission === 'granted'
          ? 'Enabled — shown for SMS and calls while this tab is in the background'
          : Notification.permission === 'denied'
            ? 'Blocked in browser settings'
            : 'Off';
    };

    const renderKeys = () => {
      const slot = el.querySelector('[data-keys]');
      if (!slot) return;
      mount(
        slot,
        view.keys.length
          ? html`<div class="table-wrap"><table class="table">
              <thead><tr><th>Name</th><th>Key</th><th>Scopes</th><th class="hide-sm">Last used</th><th></th></tr></thead>
              <tbody>${view.keys.map(
                (k) => html`<tr>
                  <td><strong>${k.name}</strong><div class="faint" style="font-size:12px">Created ${dateTime(k.createdAt)}</div></td>
                  <td class="mono nowrap">${k.prefix}…</td>
                  <td><div class="row row-wrap">${k.scopes.map((s) => html`<span class="chip">${s}</span>`)}</div></td>
                  <td class="hide-sm nowrap">${k.lastUsedAt ? timeAgo(k.lastUsedAt) : 'Never'}</td>
                  <td class="num">${k.revokedAt
                    ? html`<span class="badge">Revoked</span>`
                    : html`<button class="btn btn-sm" data-revoke="${k.id}" data-name="${k.name}">Revoke</button>`}</td>
                </tr>`,
              )}</tbody>
            </table></div>`
          : html`<div class="empty">${icon('key', 28)}<span>No API keys yet. Create one below to integrate other systems.</span></div>`,
      );
    };

    const renderUsers = () => {
      const slot = el.querySelector('[data-users]');
      if (!slot) return;
      mount(
        slot,
        html`<div class="table-wrap"><table class="table">
          <thead><tr><th>User</th><th>Role</th><th class="hide-sm">Last sign-in</th><th></th></tr></thead>
          <tbody>${view.users.map(
            (u) => html`<tr>
              <td><strong>${u.username}</strong>${u.id === state.me.id ? html` <span class="badge badge-accent">You</span>` : ''}</td>
              <td>
                <select class="select" style="width:auto;height:30px" data-role="${u.id}" ${u.id === state.me.id ? 'disabled' : ''} aria-label="Role">
                  ${['admin', 'operator', 'viewer'].map((r) => html`<option value="${r}" ${u.role === r ? 'selected' : ''}>${r}</option>`)}
                </select>
              </td>
              <td class="hide-sm">${u.lastLoginAt ? timeAgo(u.lastLoginAt) : 'Never'}</td>
              <td class="num nowrap">
                <button class="btn btn-sm" data-reset="${u.id}" data-name="${u.username}">Reset password</button>
                ${u.id !== state.me.id ? html`<button class="btn btn-sm btn-ghost btn-icon" data-del-user="${u.id}" data-name="${u.username}" aria-label="Delete user">${icon('trash', 15)}</button>` : ''}
              </td>
            </tr>`,
          )}</tbody>
        </table></div>`,
      );
    };

    const loadAdmin = async () => {
      if (!admin) return;
      try {
        const [keys, users] = await Promise.all([api('/admin/keys'), api('/admin/users')]);
        view.keys = keys.data;
        view.users = users.data;
        renderKeys();
        renderUsers();
      } catch (err) {
        toastError(err);
      }
    };

    const showNewKey = (key, apiKey) => {
      const { el: modal } = openModal({
        title: 'API key created',
        width: 600,
        body: html`<div class="banner banner-warn">${icon('alert', 16)}<span>Copy this key now — it is not stored and cannot be shown again.</span></div>
          <div class="field"><label>${apiKey.name}</label>
            <div class="row"><input class="input mono grow" readonly value="${key}" data-key-value /><button class="btn" data-copy>${icon('copy', 16)} Copy</button></div>
          </div>
          <pre class="code">curl ${origin}/api/v1/sms -H "X-API-Key: ${key}"</pre>`,
        footer: html`<button class="btn btn-primary" data-close>Done</button>`,
      });
      modal.querySelector('[data-key-value]').select();
      modal.querySelector('[data-copy]').addEventListener('click', async () => {
        if (await copyText(key)) toast('API key copied', 'ok');
      });
    };

    const offs = [
      on(el, 'submit', '[data-form]', async (e, form) => {
        e.preventDefault();
        const btn = form.querySelector('[type=submit]');
        await busy(btn, async () => {
          try {
            if (form.dataset.form === 'password') {
              if (form.next.value !== form.repeat.value) throw new Error('New passwords do not match');
              await api('/api/auth/password', { method: 'POST', body: { currentPassword: form.current.value, newPassword: form.next.value } });
              form.reset();
              toast('Password updated', 'ok');
            } else if (form.dataset.form === 'key') {
              const scopes = [...form.querySelectorAll('[name=scopes]:checked')].map((c) => c.value);
              const res = await api('/admin/keys', { method: 'POST', body: { name: form.keyName.value, scopes } });
              form.keyName.value = '';
              showNewKey(res.key, res.data);
              await loadAdmin();
            } else if (form.dataset.form === 'user') {
              await api('/admin/users', { method: 'POST', body: { username: form.username.value.trim(), password: form.password.value, role: form.role.value } });
              toast(`User ${form.username.value} created`, 'ok');
              form.reset();
              await loadAdmin();
            }
          } catch (err) {
            toastError(err);
          }
        });
      }),
      on(el, 'click', '[data-revoke]', async (_e, btn) => {
        const ok = await confirmDialog({
          title: 'Revoke API key',
          message: `Revoke "${btn.dataset.name}"? Applications using it will immediately lose access.`,
          confirmLabel: 'Revoke',
          danger: true,
        });
        if (!ok) return;
        try {
          await api(`/admin/keys/${btn.dataset.revoke}`, { method: 'DELETE' });
          toast('API key revoked', 'ok');
          await loadAdmin();
        } catch (err) {
          toastError(err);
        }
      }),
      on(el, 'change', '[data-role]', async (_e, select) => {
        try {
          await api(`/admin/users/${select.dataset.role}`, { method: 'PATCH', body: { role: select.value } });
          toast('Role updated — the user must sign in again', 'ok');
        } catch (err) {
          toastError(err);
        }
        await loadAdmin();
      }),
      on(el, 'click', '[data-reset]', (_e, btn) => {
        const { el: modal, close } = openModal({
          title: `Reset password for ${btn.dataset.name}`,
          width: 440,
          body: html`<div class="field"><label for="r-pass">New password</label><input id="r-pass" class="input" type="password" minlength="8" autocomplete="new-password" autofocus /></div>
            <span class="hint">The user will be signed out of all sessions.</span>`,
          footer: html`<button class="btn" data-close>Cancel</button><button class="btn btn-primary" data-save>Set password</button>`,
        });
        modal.querySelector('[data-save]').addEventListener('click', (ev) =>
          busy(ev.currentTarget, async () => {
            try {
              await api(`/admin/users/${btn.dataset.reset}`, { method: 'PATCH', body: { password: modal.querySelector('#r-pass').value } });
              toast('Password reset', 'ok');
              close();
            } catch (err) {
              toastError(err);
            }
          }),
        );
      }),
      on(el, 'click', '[data-del-user]', async (_e, btn) => {
        const ok = await confirmDialog({ title: 'Delete user', message: `Delete user "${btn.dataset.name}"?`, confirmLabel: 'Delete', danger: true });
        if (!ok) return;
        try {
          await api(`/admin/users/${btn.dataset.delUser}`, { method: 'DELETE' });
          await loadAdmin();
        } catch (err) {
          toastError(err);
        }
      }),
      on(el, 'click', '[data-act="notifications"]', async () => {
        if (!('Notification' in window)) return;
        const result = await Notification.requestPermission();
        renderNotif();
        if (result === 'granted') new Notification('SMS Gateway', { body: 'Desktop notifications are enabled.' });
      }),
    ];

    renderNotif();
    void loadAdmin();
    return () => offs.forEach((off) => off());
  },
};
