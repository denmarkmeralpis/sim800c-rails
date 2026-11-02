import { html } from './dom.js';

export function timeAgo(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  const s = Math.round((Date.now() - d.getTime()) / 1000);
  if (s < 45) return 'just now';
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  if (s < 86400 && new Date().getDate() === d.getDate()) return d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  if (s < 7 * 86400) return d.toLocaleDateString([], { weekday: 'short', hour: 'numeric', minute: '2-digit' });
  return d.toLocaleDateString([], { month: 'short', day: 'numeric', year: d.getFullYear() === new Date().getFullYear() ? undefined : 'numeric' });
}

export function dateTime(iso) {
  return iso ? new Date(iso).toLocaleString([], { dateStyle: 'medium', timeStyle: 'medium' }) : '—';
}

export function duration(sec) {
  if (sec === null || sec === undefined) return '—';
  const s = Math.max(0, Math.floor(sec));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const r = String(s % 60).padStart(2, '0');
  return h ? `${h}:${String(m).padStart(2, '0')}:${r}` : `${m}:${r}`;
}

export function talkTime(sec) {
  if (!sec) return '0m';
  if (sec < 60) return `${sec}s`;
  const m = Math.round(sec / 60);
  return m < 60 ? `${m}m` : `${Math.floor(m / 60)}h ${m % 60}m`;
}

export const SMS_STATUS = {
  queued: ['Queued', 'info'],
  sending: ['Sending…', 'info'],
  sent: ['Sent', 'accent'],
  delivered: ['Delivered', 'ok'],
  failed: ['Failed', 'err'],
  cancelled: ['Cancelled', ''],
  received: ['Received', 'info'],
};

export const CALL_STATUS = {
  dialing: ['Dialing…', 'info'],
  ringing: ['Ringing…', 'info'],
  active: ['In progress', 'ok'],
  completed: ['Completed', 'ok'],
  missed: ['Missed', 'err'],
  rejected: ['Rejected', 'warn'],
  busy: ['Busy', 'warn'],
  no_answer: ['No answer', 'warn'],
  cancelled: ['Cancelled', ''],
  failed: ['Failed', 'err'],
};

export const USSD_STATUS = {
  pending: ['Waiting…', 'info'],
  open: ['Reply needed', 'accent'],
  completed: ['Done', 'ok'],
  cancelled: ['Cancelled', ''],
  failed: ['Failed', 'err'],
};

export function badge([label, tone] = ['—', '']) {
  return html`<span class="badge ${tone ? `badge-${tone}` : ''}">${label}</span>`;
}

export const smsBadge = (status) => badge(SMS_STATUS[status] ?? [status, '']);
export const callBadge = (status) => badge(CALL_STATUS[status] ?? [status, '']);
export const ussdBadge = (status) => badge(USSD_STATUS[status] ?? [status, '']);

export function signalLevel(signal) {
  const r = signal?.rssi;
  if (r === null || r === undefined) return 0;
  return r < 10 ? 1 : r < 15 ? 2 : r < 20 ? 3 : 4;
}

export function bars(signal, large = false) {
  const level = signalLevel(signal);
  const tone = level === 1 ? 'poor' : level === 2 ? 'fair' : '';
  return html`<span class="bars ${large ? 'bars-lg' : ''} ${tone}" title="${signal?.dbm ?? '—'} dBm"
    >${[1, 2, 3, 4].map((i) => html`<i class="${i <= level ? 'on' : ''}"></i>`)}</span
  >`;
}

const CONNECTION = {
  ready: ['Online', 'ok'],
  connecting: ['Connecting…', 'warn'],
  initializing: ['Initializing…', 'warn'],
  disconnected: ['Offline', 'err'],
};

/** One-line health summary used by the sidebar pill and dashboard. */
export function modemSummary(modem, canOperate, reason) {
  if (!modem) return { tone: 'warn', label: 'Unknown', sub: 'Waiting for status…' };
  const [label, tone] = CONNECTION[modem.connection] ?? ['Unknown', 'warn'];
  if (modem.connection !== 'ready') {
    const sub = modem.nextReconnectAt ? `Retrying ${timeUntil(modem.nextReconnectAt)}` : modem.lastError ?? modem.port;
    return { tone, label, sub };
  }
  if (!canOperate) return { tone: 'warn', label: 'Limited', sub: reason ?? 'Not ready' };
  const op = modem.network.operator ?? 'Network';
  return { tone: 'ok', label, sub: `${op} · ${modem.signal.dbm ?? '—'} dBm` };
}

export function timeUntil(iso) {
  const s = Math.max(0, Math.round((new Date(iso).getTime() - Date.now()) / 1000));
  return s < 1 ? 'now' : `in ${s}s`;
}

export const REGISTRATION = {
  home: 'Registered (home)',
  roaming: 'Registered (roaming)',
  searching: 'Searching…',
  denied: 'Registration denied',
  not_registered: 'Not registered',
  unknown: 'Unknown',
};

export const SIM_STATE = {
  ready: ['Ready', 'ok'],
  pin_required: ['PIN required', 'warn'],
  puk_required: ['PUK required', 'err'],
  not_inserted: ['Not inserted', 'err'],
  error: ['Error', 'err'],
  unknown: ['Unknown', 'warn'],
};

export function pluralize(n, word, plural = `${word}s`) {
  return `${n} ${n === 1 ? word : plural}`;
}
