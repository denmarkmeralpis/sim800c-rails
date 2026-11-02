import { api } from '../lib/api.js';
import { busy, html, mount, on } from '../lib/dom.js';
import { duration } from '../lib/format.js';
import { icon } from '../lib/icons.js';
import { ACTIVE_USSD, can, state } from '../lib/store.js';
import { toastError } from './toast.js';

let timer = null;

export function callElapsed(call) {
  return call?.answeredAt ? (Date.now() - new Date(call.answeredAt).getTime()) / 1000 : 0;
}

export function callTitle(call) {
  if (call.direction === 'inbound' && call.status === 'ringing') return 'Incoming call';
  if (call.status === 'dialing') return 'Calling…';
  if (call.status === 'ringing') return 'Ringing…';
  return call.direction === 'inbound' ? 'On call (incoming)' : 'On call';
}

export async function callAction(action, button) {
  return busy(button, async () => {
    try {
      await api(`/calls/${action}`, { method: 'POST' });
    } catch (err) {
      toastError(err);
    }
  });
}

/**
 * Floating "island" shown on every page (except Calls) while a call is in progress, or while a
 * USSD request is waiting for the network or a menu is waiting for a reply.
 */
export function renderCallBar(slot, { hidden = false } = {}) {
  clearInterval(timer);
  const call = state.call;
  if (hidden || (!call && !ACTIVE_USSD.has(state.ussd?.status))) {
    slot.innerHTML = '';
    return;
  }
  if (!call) return renderUssdBar(slot);
  const ringingIn = call.direction === 'inbound' && call.status === 'ringing';
  const control = can('calls:write');
  mount(
    slot,
    html`<div class="call-bar" role="status">
      <span class="ring-icon ${call.status !== 'active' ? 'ringing' : ''}">${icon(ringingIn ? 'phone-in' : 'phone', 20)}</span>
      <div class="grow">
        <div class="title">${callTitle(call)}</div>
        <div class="sub truncate">${call.phone ?? 'Unknown number'}${call.status === 'active' ? html` · <span data-timer>${duration(callElapsed(call))}</span>` : ''}</div>
      </div>
      ${call.status === 'active' ? html`<span class="wave" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i></span>` : ''}
      <a class="btn btn-ghost btn-sm hide-sm" href="#/calls">${icon('grid', 16)} Keypad</a>
      ${control && ringingIn
        ? html`<button class="btn btn-ok" data-act="answer">${icon('phone', 16)} Answer</button>
            <button class="btn btn-danger" data-act="reject">${icon('phone-off', 16)} Reject</button>`
        : ''}
      ${control && !ringingIn ? html`<button class="btn btn-danger" data-act="hangup">${icon('phone-off', 16)} Hang up</button>` : ''}
    </div>`,
  );
  if (call.status === 'active') {
    timer = setInterval(() => {
      const t = slot.querySelector('[data-timer]');
      if (t) t.textContent = duration(callElapsed(state.call));
    }, 1000);
  }
}

function renderUssdBar(slot) {
  const u = state.ussd;
  const open = u.status === 'open';
  const firstLine = (u.response ?? '').split('\n')[0];
  mount(
    slot,
    html`<div class="call-bar" role="status">
      <span class="ring-icon ${open ? '' : 'ringing'}">${icon('hash', 20)}</span>
      <div class="grow">
        <div class="title">${open ? 'USSD menu waiting for your reply' : 'Waiting for the network…'}</div>
        <div class="sub truncate">${u.code ?? 'Network message'}${open && firstLine ? ` · ${firstLine}` : ''}</div>
      </div>
      <a class="btn ${open ? 'btn-ok' : 'btn-ghost'} btn-sm" href="#/calls">${open ? html`${icon('reply', 16)} Reply` : 'Open'}</a>
      ${can('calls:write') ? html`<button class="btn btn-ghost btn-sm" data-ussd-cancel>${icon('x', 16)} Cancel</button>` : ''}
    </div>`,
  );
}

export function bindCallBar(slot) {
  const offs = [
    on(slot, 'click', '[data-act]', (_e, btn) => callAction(btn.dataset.act, btn)),
    on(slot, 'click', '[data-ussd-cancel]', (_e, btn) =>
      busy(btn, () => api('/ussd/cancel', { method: 'POST' }).catch((err) => err.status !== 409 && toastError(err))),
    ),
  ];
  return () => offs.forEach((off) => off());
}
