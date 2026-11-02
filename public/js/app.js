import { bindCallBar, renderCallBar } from './components/call-bar.js';
import { startRinging, stopRinging } from './components/ringer.js';
import { toast } from './components/toast.js';
import { api, setCsrf } from './lib/api.js';
import { $, $$, debounce, html, mount } from './lib/dom.js';
import { connectEvents, disconnectEvents } from './lib/events.js';
import { bars, modemSummary } from './lib/format.js';
import { brandMark, icon } from './lib/icons.js';
import { ACTIVE_CALL, can, publish, state, subscribe } from './lib/store.js';
import calls from './views/calls.js';
import dashboard from './views/dashboard.js';
import { renderLogin } from './views/login.js';
import messages from './views/messages.js';
import modem from './views/modem.js';
import settings from './views/settings.js';
import { renderSetup } from './views/setup.js';

const ROUTES = { dashboard, messages, calls, modem, settings };
const NAV = [
  ['dashboard', 'Dashboard', 'dashboard'],
  ['messages', 'Messages', 'message'],
  ['calls', 'Calls', 'phone'],
  ['modem', 'Modem', 'modem'],
  ['settings', 'Settings', 'settings'],
];

const root = document.getElementById('root');
let viewCleanup = null;
let appCleanups = [];
let currentRoute = null;
let enterTimer = null;

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------

const THEME_KEY = 'smsgw.theme';

function storedTheme() {
  try {
    return localStorage.getItem(THEME_KEY);
  } catch {
    return null;
  }
}

function applyTheme(theme) {
  if (theme === 'light' || theme === 'dark') document.documentElement.dataset.theme = theme;
  else delete document.documentElement.dataset.theme;
  for (const b of $$('[data-theme-toggle]')) mount(b, icon(effectiveTheme() === 'dark' ? 'sun' : 'moon', 16));
}

function effectiveTheme() {
  return document.documentElement.dataset.theme ?? (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
}

function toggleTheme() {
  const next = effectiveTheme() === 'dark' ? 'light' : 'dark';
  try {
    localStorage.setItem(THEME_KEY, next);
  } catch {
    /* private mode */
  }
  applyTheme(next);
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

async function boot() {
  applyTheme(storedTheme());
  window.addEventListener('auth:expired', () => {
    if (state.me) showLogin('Your session has expired. Please sign in again.');
  });
  try {
    const me = await api('/api/auth/me');
    startSession(me);
  } catch (err) {
    if (err.status !== 401) return mount(root, html`<div class="boot">${err.message}</div>`);
    const setup = await api('/api/auth/setup').catch(() => null);
    if (setup?.required) showSetup(setup.username);
    else showLogin();
  }
}

function startSession(me) {
  state.me = me.user;
  state.scopes = new Set(me.scopes);
  setCsrf(me.csrfToken);
  void renderShell();
}

function teardown() {
  disconnectEvents();
  viewCleanup?.();
  viewCleanup = null;
  appCleanups.forEach((off) => off());
  appCleanups = [];
  stopRinging();
  window.removeEventListener('hashchange', route);
  currentRoute = null;
}

function showLogin(notice) {
  teardown();
  state.me = null;
  state.scopes = new Set();
  state.call = null;
  state.ussd = null;
  setCsrf(null);
  renderLogin(root, { notice, onLogin: startSession });
}

function showSetup(username) {
  document.title = 'Setup · SMS Gateway';
  renderSetup(root, { username, onLogin: startSession, onAlreadyDone: showLogin });
}

async function logout() {
  try {
    await api('/api/auth/logout', { method: 'POST' });
  } finally {
    showLogin('You have been signed out.');
  }
}

// ---------------------------------------------------------------------------
// Shell
// ---------------------------------------------------------------------------

async function renderShell() {
  teardown();
  const userControls = html`
    <button class="btn btn-ghost btn-icon btn-sm" data-theme-toggle title="Toggle dark mode" aria-label="Toggle dark mode"></button>
    <button class="btn btn-ghost btn-icon btn-sm" data-logout title="Sign out" aria-label="Sign out">${icon('logout', 16)}</button>`;

  mount(
    root,
    html`<div class="app">
      <aside class="sidebar">
        <div class="brand">
          <span class="brand-mark">${brandMark(20)}</span>
          <div class="brand-text"><strong>SMS Gateway</strong><small>SIM800C · GSM</small></div>
        </div>
        <div class="nav-label">Channels</div>
        <nav class="nav" aria-label="Main">
          ${NAV.filter(([r]) => !ROUTES[r].scope || can(ROUTES[r].scope)).map(
            ([r, label, ic], i) =>
              html`<a href="#/${r}" data-route="${r}">${icon(ic)}<span>${label}</span>${r === 'messages'
                  ? html`<span class="count hidden" data-unread></span>`
                  : ''}<span class="nav-idx">${String(i + 1).padStart(2, '0')}</span></a>`,
          )}
        </nav>
        <div class="sidebar-foot">
          <a class="modem-pill" href="#/modem" data-pill></a>
          <div class="user-row">
            <span class="user-avatar" aria-hidden="true">${state.me.username.slice(0, 1)}</span>
            <div class="grow" style="min-width:0">
              <div class="user-name truncate">${state.me.username}</div>
              <div class="user-role">${state.me.role}</div>
            </div>
            ${userControls}
          </div>
        </div>
      </aside>
      <main class="main">
        <div class="mobile-head">
          <div class="row" style="gap:10px"><span class="brand-mark brand-mark-sm">${brandMark(16)}</span><strong>SMS Gateway</strong></div>
          <div class="row"><a href="#/modem" class="pill-mini" data-pill-mini></a>${userControls}</div>
        </div>
        <div data-callbar></div>
        <div id="view"></div>
      </main>
    </div>`,
  );
  applyTheme(storedTheme());
  root.addEventListener('click', onShellClick);
  appCleanups.push(() => root.removeEventListener('click', onShellClick));
  appCleanups.push(bindCallBar($('[data-callbar]')));

  try {
    const s = await api('/status');
    state.modem = s.modem;
    state.canOperate = s.canOperate;
    state.reason = s.reason;
    state.call = s.call && ACTIVE_CALL.has(s.call.status) ? s.call : null;
    state.unread = s.sms?.unread ?? 0;
    state.simulator = s.simulator;
  } catch {
    /* rendered as unknown until the event stream delivers status */
  }
  renderPill();
  renderUnread();
  if (can('calls:read')) api('/ussd').then(({ data }) => setUssd(data, false), () => {});

  const refreshUnread = debounce(async () => {
    if (!can('sms:read')) return;
    try {
      state.unread = (await api('/sms', { query: { unread: 'true', limit: 1 } })).total;
      renderUnread();
      publish('state.unread', state.unread);
    } catch {
      /* ignore */
    }
  }, 400);

  appCleanups.push(
    subscribe('hello', (d) => {
      if (d.modem) setModem(d.modem);
      setCall(d.call && ACTIVE_CALL.has(d.call.status) ? d.call : null);
    }),
    subscribe('modem.status', setModem),
    subscribe('call.updated', (c) => {
      if (ACTIVE_CALL.has(c.status)) setCall(c);
      else if (state.call?.id === c.id) setCall(null);
    }),
    subscribe('call.incoming', (c) => notify('Incoming call', c.phone ?? 'Unknown number')),
    subscribe('sms.received', (m) => {
      toast(html`New message from <strong>${m.phone}</strong>`, 'info');
      notify(`SMS from ${m.phone}`, m.body);
      refreshUnread();
    }),
    subscribe('sms.updated', refreshUnread),
    subscribe('sms.deleted', refreshUnread),
    subscribe('ussd.updated', (u) => setUssd(u, true)),
  );

  connectEvents();
  window.addEventListener('hashchange', route);
  route();
  onCallChange();
}

function onShellClick(e) {
  if (e.target.closest('[data-theme-toggle]')) toggleTheme();
  else if (e.target.closest('[data-logout]')) void logout();
}

function computeOperate(m) {
  if (m.connection !== 'ready') return `Modem is ${m.connection}${m.lastError ? `: ${m.lastError}` : ''}`;
  if (m.sim.state !== 'ready') return `SIM not ready: ${m.sim.detail ?? m.sim.state}`;
  if (!m.network.registered) return `Not registered on the network (${m.network.registration.replace('_', ' ')})`;
  return null;
}

function setModem(m) {
  state.modem = m;
  state.reason = computeOperate(m);
  state.canOperate = state.reason === null;
  renderPill();
  publish('state.modem', m);
}

function setCall(call) {
  state.call = call;
  onCallChange();
}

/**
 * Tracks the USSD session for the island. Sessions started by API clients are left alone (as on
 * the Calls page); results that arrive while the Calls page is not open are shown as a toast.
 */
function setUssd(u, live) {
  if (!u || (u.source === 'api' && u.id !== state.ussd?.id)) return;
  state.ussd = u;
  renderBar();
  if (live && currentRoute !== 'calls' && (u.status === 'completed' || u.status === 'failed')) {
    const label = u.code ? `USSD ${u.code}` : 'Network message';
    const text = u.status === 'failed' ? u.error : (u.response ?? 'Done');
    toast(html`<strong>${label}</strong><div class="pre">${text}</div>`, u.status === 'failed' ? 'err' : 'ok', 12_000);
    notify(label, text ?? '');
  }
}

function renderBar() {
  const slot = $('[data-callbar]');
  if (slot) renderCallBar(slot, { hidden: currentRoute === 'calls' });
}

function onCallChange() {
  renderBar();
  const c = state.call;
  if (c && c.direction === 'inbound' && c.status === 'ringing') startRinging();
  else stopRinging();
  publish('state.call', c);
}

function renderPill() {
  const s = modemSummary(state.modem, state.canOperate, state.reason);
  const pill = $('[data-pill]');
  if (pill) {
    mount(
      pill,
      html`<div class="pill-top">
          <span class="dot dot-${s.tone} ${s.tone !== 'ok' ? 'dot-pulse' : ''}"></span>
          <span class="pill-label">Modem ${s.label}</span>
          ${state.modem ? bars(state.modem.signal) : ''}
        </div>
        <div class="sub truncate">${s.sub}</div>`,
    );
    pill.title = s.sub;
  }
  const mini = $('[data-pill-mini]');
  if (mini) mount(mini, html`<span class="dot dot-${s.tone}"></span><span>${s.label}</span>`);
}

function renderUnread() {
  const el = $('[data-unread]');
  if (!el) return;
  el.textContent = state.unread > 99 ? '99+' : String(state.unread);
  el.classList.toggle('hidden', !state.unread);
}

function notify(title, body) {
  if (!document.hidden || !('Notification' in window) || Notification.permission !== 'granted') return;
  try {
    const n = new Notification(title, { body, tag: title });
    n.onclick = () => window.focus();
  } catch {
    /* unsupported */
  }
}

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------

function route() {
  const [name, ...params] = location.hash.replace(/^#\/?/, '').split('/');
  const view = ROUTES[name];
  if (!view || (view.scope && !can(view.scope))) {
    location.replace('#/dashboard');
    return;
  }
  viewCleanup?.();
  viewCleanup = null;
  currentRoute = name;
  for (const a of $$('[data-route]')) a.classList.toggle('active', a.dataset.route === name);
  document.title = `${view.title} · SMS Gateway`;
  const el = $('#view');
  el.innerHTML = '';
  window.scrollTo(0, 0);
  // Entrance animation only on navigation; views that re-render on live data must not replay it.
  clearTimeout(enterTimer);
  el.classList.add('entering');
  enterTimer = setTimeout(() => el.classList.remove('entering'), 800);
  viewCleanup = view.render(el, { params }) ?? null;
  renderBar();
}

void boot();
