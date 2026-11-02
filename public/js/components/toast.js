import { html, mount } from '../lib/dom.js';
import { icon } from '../lib/icons.js';

const TONE_ICON = { ok: 'check', warn: 'alert', err: 'x-circle', info: 'bell' };

export function toast(message, tone = 'info', ms = 4500) {
  const host = document.getElementById('toasts');
  const el = document.createElement('div');
  el.className = `toast ${tone}`;
  el.setAttribute('role', tone === 'err' ? 'alert' : 'status');
  mount(
    el,
    html`<span class="ic">${icon(TONE_ICON[tone] ?? 'info', 13)}</span><div class="grow">${message}</div><button class="x" aria-label="Dismiss">${icon('x', 16)}</button>`,
  );
  const remove = () => el.remove();
  el.querySelector('.x').addEventListener('click', remove);
  host.appendChild(el);
  while (host.children.length > 5) host.firstElementChild.remove();
  if (ms) setTimeout(remove, ms);
  return remove;
}

export function toastError(err) {
  return toast(err?.message ?? String(err), 'err', 7000);
}
