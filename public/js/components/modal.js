import { html, mount } from '../lib/dom.js';
import { icon } from '../lib/icons.js';

/**
 * Opens a modal dialog. `body` and `footer` are html`` fragments. Returns { el, close }.
 * `onClose` runs once however the dialog is dismissed.
 */
export function openModal({ title, body, footer, width, onClose }) {
  const backdrop = document.createElement('div');
  backdrop.className = 'modal-backdrop';
  mount(
    backdrop,
    html`<div class="modal" role="dialog" aria-modal="true" aria-label="${title}">
      <div class="modal-head">
        <h2>${title}</h2>
        <button class="btn btn-ghost btn-icon btn-sm" data-close aria-label="Close">${icon('x')}</button>
      </div>
      <div class="modal-body">${body}</div>
      ${footer ? html`<div class="modal-foot">${footer}</div>` : ''}
    </div>`,
  );
  const modal = backdrop.querySelector('.modal');
  if (width) modal.style.width = `min(${width}px, 100%)`;
  const previouslyFocused = document.activeElement;

  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    document.removeEventListener('keydown', onKey);
    backdrop.remove();
    previouslyFocused?.focus?.();
    onClose?.();
  };
  const onKey = (e) => {
    if (e.key === 'Escape') close();
  };
  document.addEventListener('keydown', onKey);
  backdrop.addEventListener('mousedown', (e) => {
    if (e.target === backdrop) close();
  });
  backdrop.addEventListener('click', (e) => {
    if (e.target.closest('[data-close]')) close();
  });

  document.body.appendChild(backdrop);
  (modal.querySelector('[autofocus]') ?? modal.querySelector('input, textarea, select, button.btn-primary'))?.focus();
  return { el: modal, close };
}

export function confirmDialog({ title, message, confirmLabel = 'Confirm', danger = false }) {
  return new Promise((resolve) => {
    let result = false;
    const { el, close } = openModal({
      title,
      body: html`<p style="margin:0">${message}</p>`,
      footer: html`<button class="btn" data-close>Cancel</button>
        <button class="btn ${danger ? 'btn-danger' : 'btn-primary'}" data-ok>${confirmLabel}</button>`,
      width: 440,
      onClose: () => resolve(result),
    });
    el.querySelector('[data-ok]').addEventListener('click', () => {
      result = true;
      close();
    });
    el.querySelector('[data-ok]').focus();
  });
}
