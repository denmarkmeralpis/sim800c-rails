import { openCompose } from '../components/compose.js';
import { confirmDialog, openModal } from '../components/modal.js';
import { toast, toastError } from '../components/toast.js';
import { api } from '../lib/api.js';
import { busy, debounce, html, mount, on } from '../lib/dom.js';
import { dateTime, pluralize, smsBadge, timeAgo } from '../lib/format.js';
import { icon } from '../lib/icons.js';
import { can, subscribe, subscribeAll } from '../lib/store.js';

const TABS = [
  ['all', 'All', {}],
  ['inbound', 'Inbox', { direction: 'inbound' }],
  ['outbound', 'Sent', { direction: 'outbound' }],
  ['failed', 'Failed', { status: 'failed' }],
];
const LIMIT = 25;

function avatar(m) {
  if (m.status === 'failed') return html`<span class="avatar avatar-err">${icon('alert', 16)}</span>`;
  return m.direction === 'inbound'
    ? html`<span class="avatar avatar-in">${icon('arrow-in', 16)}</span>`
    : html`<span class="avatar avatar-out">${icon('arrow-out', 16)}</span>`;
}

export default {
  title: 'Messages',
  scope: 'sms:read',
  render(el) {
    const view = { tab: 'all', q: '', page: 1, data: [], total: 0, loading: true, selected: new Set() };

    mount(
      el,
      html`<div class="page">
        <div class="page-head">
          <div>
            <span class="eyebrow"><b>02</b> Inbox · SMS</span>
            <h1>Messages</h1>
            <p>Received and sent SMS. New messages arrive in real time.</p>
          </div>
          ${can('sms:send') ? html`<button class="btn btn-primary" data-act="compose">${icon('plus', 16)} New message</button>` : ''}
        </div>
        <div class="card">
          <div class="toolbar">
            ${can('sms:delete') ? html`<input type="checkbox" class="checkbox" data-act="select-all" aria-label="Select all" />` : ''}
            <div class="tabs" role="tablist">
              ${TABS.map(([key, label]) => html`<button role="tab" data-tab="${key}" class="${key === view.tab ? 'active' : ''}">${label}</button>`)}
            </div>
            <input class="input input-search grow" style="max-width:340px" type="search" placeholder="Search number or text" data-search aria-label="Search messages" />
            <button class="btn btn-ghost btn-icon" data-act="refresh" title="Refresh" aria-label="Refresh">${icon('refresh', 16)}</button>
          </div>
          <div data-bulk></div>
          <div data-list></div>
          <div class="card-foot" data-foot></div>
        </div>
      </div>`,
    );

    const listEl = el.querySelector('[data-list]');
    const bulkEl = el.querySelector('[data-bulk]');
    const footEl = el.querySelector('[data-foot]');
    const selectAll = el.querySelector('[data-act="select-all"]');

    const renderList = () => {
      if (view.loading && !view.data.length) {
        mount(listEl, html`<div class="empty">Loading…</div>`);
      } else if (!view.data.length) {
        mount(
          listEl,
          html`<div class="empty">${icon('inbox', 32)}<strong>No messages</strong><span>${view.q ? 'Nothing matches your search.' : 'Messages you send or receive will appear here.'}</span></div>`,
        );
      } else {
        mount(
          listEl,
          html`<ul class="list">
            ${view.data.map(
              (m) => html`<li class="list-item ${m.read ? '' : 'unread'} ${view.selected.has(m.id) ? 'selected' : ''}" data-id="${m.id}">
                ${can('sms:delete') ? html`<input type="checkbox" class="checkbox" data-check="${m.id}" ${view.selected.has(m.id) ? 'checked' : ''} aria-label="Select message" />` : ''}
                ${avatar(m)}
                <div class="grow">
                  <div class="row">
                    <span class="who grow truncate">${m.direction === 'outbound' ? html`<span class="faint">To:</span> ` : ''}${m.phone}</span>
                    <span class="when" title="${dateTime(m.createdAt)}">${timeAgo(m.createdAt)}</span>
                  </div>
                  <div class="row">
                    <span class="preview grow truncate">${m.body}</span>
                    ${m.parts > 1 ? html`<span class="chip hide-sm">${m.parts} parts</span>` : ''}
                    ${m.direction === 'outbound' ? smsBadge(m.status) : ''}
                  </div>
                </div>
              </li>`,
            )}
          </ul>`,
        );
      }

      const n = view.selected.size;
      // Unfiltered, the Failed tab's total is every failed message, which is what Retry all re-queues.
      const retryAll = !n && view.tab === 'failed' && !view.q && view.total > 0 && can('sms:send');
      mount(
        bulkEl,
        n
          ? html`<div class="bulkbar">
              <span class="grow">${pluralize(n, 'message')} selected</span>
              <button class="btn btn-sm" data-act="mark-read">${icon('check', 14)} Mark read</button>
              <button class="btn btn-sm" data-act="mark-unread">Mark unread</button>
              <button class="btn btn-sm btn-danger" data-act="delete-selected">${icon('trash', 14)} Delete</button>
              <button class="btn btn-sm btn-ghost" data-act="clear-selection">Clear</button>
            </div>`
          : retryAll
            ? html`<div class="bulkbar">
                <span class="grow">${pluralize(view.total, 'failed message')}</span>
                <button class="btn btn-sm" data-act="retry-failed">${icon('refresh', 14)} Retry all</button>
              </div>`
            : '',
      );
      if (selectAll) {
        selectAll.checked = n > 0 && view.data.every((m) => view.selected.has(m.id));
        selectAll.indeterminate = n > 0 && !selectAll.checked;
      }

      const from = view.total ? (view.page - 1) * LIMIT + 1 : 0;
      const to = Math.min(view.total, view.page * LIMIT);
      mount(
        footEl,
        html`<span>${view.total ? `${from}–${to} of ${view.total}` : ''}</span>
          <div class="pager">
            <button class="btn btn-sm btn-icon" data-act="prev" ${view.page <= 1 ? 'disabled' : ''} aria-label="Previous page">${icon('chevron-left', 16)}</button>
            <button class="btn btn-sm btn-icon" data-act="next" ${to >= view.total ? 'disabled' : ''} aria-label="Next page">${icon('chevron-right', 16)}</button>
          </div>`,
      );
    };

    let requestId = 0;
    const load = async () => {
      const id = ++requestId;
      view.loading = true;
      renderList();
      try {
        const filter = TABS.find(([k]) => k === view.tab)[2];
        const res = await api('/sms', { query: { ...filter, q: view.q, page: view.page, limit: LIMIT } });
        if (id !== requestId) return;
        view.data = res.data;
        view.total = res.total;
        if (!res.data.length && view.page > 1) {
          view.page--;
          return load();
        }
        const ids = new Set(res.data.map((m) => m.id));
        for (const s of view.selected) if (!ids.has(s)) view.selected.delete(s);
      } catch (err) {
        toastError(err);
      } finally {
        if (id === requestId) {
          view.loading = false;
          renderList();
        }
      }
    };
    const reload = debounce(load, 300);

    const bulk = async (button, fn) =>
      busy(button, async () => {
        try {
          await fn([...view.selected]);
          view.selected.clear();
          await load();
        } catch (err) {
          toastError(err);
        }
      });

    const offs = [
      on(el, 'click', '[data-tab]', (_e, btn) => {
        view.tab = btn.dataset.tab;
        view.page = 1;
        view.selected.clear();
        el.querySelectorAll('[data-tab]').forEach((b) => b.classList.toggle('active', b === btn));
        void load();
      }),
      on(el, 'input', '[data-search]', debounce((_e, input) => {
        view.q = input.value.trim();
        view.page = 1;
        void load();
      }, 300)),
      on(el, 'click', '[data-act]', (e, btn) => {
        const act = btn.dataset.act;
        if (act === 'compose') openCompose();
        else if (act === 'refresh') void load();
        else if (act === 'prev' && view.page > 1) (view.page--, void load());
        else if (act === 'next') (view.page++, void load());
        else if (act === 'clear-selection') (view.selected.clear(), renderList());
        else if (act === 'mark-read' || act === 'mark-unread') {
          void bulk(btn, (ids) => api('/sms/read', { method: 'POST', body: { ids, read: act === 'mark-read' } }));
        } else if (act === 'delete-selected') {
          const n = view.selected.size;
          void confirmDialog({
            title: 'Delete messages',
            message: `Permanently delete ${pluralize(n, 'message')}? This cannot be undone.`,
            confirmLabel: 'Delete',
            danger: true,
          }).then((ok) => {
            if (!ok) return;
            return bulk(btn, async (ids) => {
              const res = await api('/sms/delete', { method: 'POST', body: { ids } });
              toast(`Deleted ${pluralize(res.deleted.length, 'message')}`, 'ok');
            });
          });
        } else if (act === 'retry-failed') {
          void confirmDialog({
            title: 'Retry failed messages',
            message: `Send all ${pluralize(view.total, 'failed message')} again? They go back in the queue with a fresh set of attempts.`,
            confirmLabel: 'Retry all',
          }).then((ok) => {
            if (!ok) return;
            return bulk(btn, async () => {
              const res = await api('/sms/retry-failed', { method: 'POST' });
              toast(`Re-queued ${pluralize(res.retried.length, 'message')}`, 'ok');
            });
          });
        }
      }),
      on(el, 'change', '[data-act="select-all"]', (_e, box) => {
        for (const m of view.data) box.checked ? view.selected.add(m.id) : view.selected.delete(m.id);
        renderList();
      }),
      on(el, 'click', '[data-check]', (e, box) => {
        e.stopPropagation();
        const id = Number(box.dataset.check);
        box.checked ? view.selected.add(id) : view.selected.delete(id);
        renderList();
      }),
      on(el, 'click', '.list-item[data-id]', (e, item) => {
        if (e.target.closest('[data-check]')) return;
        const m = view.data.find((x) => x.id === Number(item.dataset.id));
        if (m) openMessage(m);
      }),
      subscribeAll(['sms.received', 'sms.updated', 'sms.deleted'], reload),
    ];

    void load();
    return () => offs.forEach((off) => off());
  },
};

/** Message detail dialog; stays live while open (delivery status updates). */
function openMessage(initial) {
  let m = initial;
  const body = () => html`
    <div class="bubble ${m.direction === 'outbound' ? 'out' : ''}">${m.body}</div>
    ${m.error ? html`<div class="banner banner-err">${icon('alert', 16)}<span>${m.error}</span></div>` : ''}
    <dl class="kv">
      <dt>Status</dt><dd>${smsBadge(m.status)}</dd>
      <dt>${m.direction === 'inbound' ? 'From' : 'To'}</dt><dd>${m.phone}</dd>
      <dt>Parts</dt><dd>${m.parts} · ${m.encoding === 'ucs2' ? 'Unicode (UCS-2)' : m.encoding === 'gsm7' ? 'GSM-7' : (m.encoding ?? '—')}</dd>
      ${m.direction === 'inbound'
        ? html`<dt>Sent by sender</dt><dd>${dateTime(m.receivedAt)}</dd>
            <dt>Received</dt><dd>${dateTime(m.createdAt)}</dd>
            ${m.smsc ? html`<dt>SMS centre</dt><dd>${m.smsc}</dd>` : ''}`
        : html`<dt>Created</dt><dd>${dateTime(m.createdAt)}</dd>
            <dt>Sent</dt><dd>${dateTime(m.sentAt)}</dd>
            <dt>Delivered</dt><dd>${dateTime(m.deliveredAt)}</dd>
            <dt>Attempts</dt><dd>${m.attempts}${m.nextAttemptAt ? ` · next retry ${timeAgo(m.nextAttemptAt).replace(' ago', '')}` : ''}</dd>
            <dt>Source</dt><dd>${m.source === 'api' ? 'REST API' : 'Dashboard'}</dd>`}
    </dl>`;
  const footer = () => html`
    ${can('sms:delete') && m.status !== 'sending' ? html`<button class="btn btn-ghost" data-m="delete" style="margin-right:auto;color:var(--err)">${icon('trash', 16)} Delete</button>` : ''}
    ${m.direction === 'inbound' ? html`<button class="btn" data-m="unread">Mark unread</button>` : ''}
    ${can('sms:send') && m.status === 'queued' ? html`<button class="btn" data-m="cancel">Cancel sending</button>` : ''}
    ${can('sms:send') && (m.status === 'failed' || m.status === 'cancelled') ? html`<button class="btn" data-m="retry">${icon('refresh', 16)} Retry</button>` : ''}
    ${can('sms:send') && m.phone !== 'unknown'
      ? html`<button class="btn btn-primary" data-m="reply">${icon(m.direction === 'inbound' ? 'reply' : 'send', 16)} ${m.direction === 'inbound' ? 'Reply' : 'Send again'}</button>`
      : ''}`;

  const off = subscribe('sms.updated', (u) => {
    if (u.id !== m.id) return;
    m = u;
    mount(modal.el.querySelector('.modal-body'), body());
    mount(modal.el.querySelector('.modal-foot'), footer());
  });
  const offDeleted = subscribe('sms.deleted', ({ ids }) => ids.includes(m.id) && modal.close());
  const modal = openModal({
    title: m.direction === 'inbound' ? 'Received message' : 'Sent message',
    body: body(),
    footer: footer(),
    width: 560,
    onClose: () => (off(), offDeleted()),
  });

  if (m.direction === 'inbound' && !m.read) void api('/sms/read', { method: 'POST', body: { ids: [m.id], read: true } }).catch(() => {});

  modal.el.addEventListener('click', async (e) => {
    const btn = e.target.closest('[data-m]');
    if (!btn) return;
    const act = btn.dataset.m;
    if (act === 'reply') {
      modal.close();
      openCompose({ to: m.phone, message: m.direction === 'outbound' ? m.body : '' });
      return;
    }
    if (act === 'delete') {
      const ok = await confirmDialog({ title: 'Delete message', message: 'Delete this message permanently?', confirmLabel: 'Delete', danger: true });
      if (!ok) return;
    }
    await busy(btn, async () => {
      try {
        if (act === 'delete') {
          await api(`/sms/${m.id}`, { method: 'DELETE' });
          toast('Message deleted', 'ok');
          modal.close();
        } else if (act === 'unread') {
          await api('/sms/read', { method: 'POST', body: { ids: [m.id], read: false } });
          modal.close();
        } else if (act === 'retry' || act === 'cancel') {
          await api(`/sms/${m.id}/${act}`, { method: 'POST' });
          toast(act === 'retry' ? 'Message re-queued' : 'Sending cancelled', 'ok');
        }
      } catch (err) {
        toastError(err);
      }
    });
  });
}
