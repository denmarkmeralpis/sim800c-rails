import { api } from '../lib/api.js';
import { busy, html, mount } from '../lib/dom.js';
import { icon } from '../lib/icons.js';
import { pluralize } from '../lib/format.js';
import { smsInfo } from '../lib/sms-count.js';
import { state } from '../lib/store.js';
import { openModal } from './modal.js';
import { toast } from './toast.js';

/**
 * A random Idempotency-Key. Not crypto.randomUUID(): that needs a secure context, and the
 * dashboard is often served over plain HTTP on a LAN.
 */
function newIdempotencyKey() {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

/** Compose dialog. Messages are queued server-side and sent asynchronously. */
export function openCompose({ to = '', message = '' } = {}) {
  // One key per dialog: if a send fails on the network after the server queued it, retrying
  // returns the original messages instead of sending them twice.
  const idempotencyKey = newIdempotencyKey();

  const { el, close } = openModal({
    title: 'New message',
    width: 560,
    body: html`
      ${!state.canOperate
        ? html`<div class="banner banner-warn">${icon('alert', 16)}<span
              >Modem not ready (${state.reason ?? 'unknown'}). Messages will be queued and sent automatically once it
              is.</span
            ></div>`
        : ''}
      <div class="field">
        <label for="c-to">To</label>
        <input id="c-to" class="input" name="to" value="${to}" placeholder="+639171234567, 09181234567" autocomplete="off" ${to ? '' : 'autofocus'} />
        <span class="hint">Separate multiple recipients with commas.</span>
      </div>
      <div class="field">
        <label for="c-msg">Message</label>
        <textarea id="c-msg" class="textarea" name="message" rows="6" maxlength="5000" ${to ? 'autofocus' : ''}>${message}</textarea>
        <div class="row hint"><span class="grow" data-counter></span><span data-enc></span></div>
      </div>
      <div class="form-error hidden" data-error></div>
    `,
    footer: html`<button class="btn" data-close>Cancel</button>
      <button class="btn btn-primary" data-send>${icon('send', 16)} Send</button>`,
  });

  const toInput = el.querySelector('#c-to');
  const msg = el.querySelector('#c-msg');
  const counter = el.querySelector('[data-counter]');
  const enc = el.querySelector('[data-enc]');
  const error = el.querySelector('[data-error]');
  const sendBtn = el.querySelector('[data-send]');

  const update = () => {
    const info = smsInfo(msg.value);
    counter.textContent = info.length
      ? `${info.length} characters · ${pluralize(info.parts, 'SMS part')} · ${info.remaining} left in this part`
      : 'Up to 160 GSM characters (70 Unicode) per SMS part';
    enc.textContent = info.length ? info.encoding : '';
    enc.title = info.nonGsm.length ? `Unicode because of: ${info.nonGsm.join(' ')}` : '';
  };
  msg.addEventListener('input', update);
  update();
  if (to) msg.setSelectionRange(msg.value.length, msg.value.length);

  const submit = () =>
    busy(sendBtn, async () => {
      error.classList.add('hidden');
      try {
        const res = await api('/sms', {
          method: 'POST',
          body: { to: toInput.value, message: msg.value },
          headers: { 'idempotency-key': idempotencyKey },
        });
        toast(`Queued ${pluralize(res.data.length, 'message')} for sending`, 'ok');
        close();
      } catch (err) {
        const text =
          err.code === 'idempotency_key_reused'
            ? 'An earlier attempt from this dialog was already queued, so this edited version was not sent. Check Messages, or open a new message to send it.'
            : err.message;
        mount(error, html`${text}`);
        error.classList.remove('hidden');
      }
    });

  sendBtn.addEventListener('click', submit);
  msg.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) submit();
  });
}
