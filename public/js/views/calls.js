import { callAction, callElapsed, callTitle } from '../components/call-bar.js';
import { confirmDialog } from '../components/modal.js';
import { toast, toastError } from '../components/toast.js';
import { api } from '../lib/api.js';
import { busy, debounce, html, mount, on } from '../lib/dom.js';
import { bars, callBadge, dateTime, duration, pluralize, timeAgo, ussdBadge } from '../lib/format.js';
import { icon } from '../lib/icons.js';
import { ACTIVE_USSD, can, state, subscribe, subscribeAll } from '../lib/store.js';

const KEYS = [
  ['1', ''],
  ['2', 'ABC'],
  ['3', 'DEF'],
  ['4', 'GHI'],
  ['5', 'JKL'],
  ['6', 'MNO'],
  ['7', 'PQRS'],
  ['8', 'TUV'],
  ['9', 'WXYZ'],
  ['*', ''],
  ['0', '+'],
  ['#', ''],
];

const FILTERS = [
  ['all', 'All', {}],
  ['inbound', 'Incoming', { direction: 'inbound' }],
  ['outbound', 'Outgoing', { direction: 'outbound' }],
  ['missed', 'Missed', { status: 'missed' }],
  // Not a call filter: lists USSD sessions from /ussd/sessions instead.
  ['ussd', 'USSD', {}],
];
const LIMIT = 20;
/** Codes like *123# are sent to the network as USSD instead of placing a voice call. */
const USSD_CODE = /^[*#][0-9*#]{1,30}#$/;
const SOURCE_LABEL = { dashboard: 'Dashboard', api: 'REST API', modem: 'Network' };

const isUssdCode = (n) => USSD_CODE.test((n ?? '').replace(/\s/g, ''));

/** A menu's lines joined, so a reply fits on one ellipsized line. */
const oneLine = (text) => (text ?? '').replace(/\s*\n\s*/g, ' · ');

function callIcon(c) {
  if (c.status === 'missed' || c.status === 'rejected') return html`<span class="avatar avatar-err">${icon('phone-missed', 16)}</span>`;
  return c.direction === 'inbound'
    ? html`<span class="avatar avatar-in">${icon('phone-in', 16)}</span>`
    : html`<span class="avatar avatar-out">${icon('phone-out', 16)}</span>`;
}

export default {
  title: 'Calls',
  scope: 'calls:read',
  render(el) {
    const view = { number: '', dtmf: '', filter: 'all', page: 1, data: [], total: 0, selected: new Set(), loading: true, ussd: null, dismissedUssd: null, recent: null };
    const control = can('calls:write');
    /** The history card lists USSD sessions instead of calls. */
    const isUssd = () => view.filter === 'ussd';
    /** Rows that can be selected for deletion: a USSD session still in progress cannot be deleted. */
    const selectable = () => (isUssd() ? view.data.filter((s) => !ACTIVE_USSD.has(s.status)) : view.data);

    mount(
      el,
      html`<div class="page">
        <div class="page-head">
          <div>
            <span class="eyebrow"><b>03</b> Voice · USSD</span>
            <h1>Calls</h1>
            <p>Place and receive voice calls through the SIM800C, or dial USSD codes such as *123#. Audio uses the module's microphone and speaker pins.</p>
          </div>
        </div>
        <div class="grid grid-calls">
          <div class="card phone" data-phone></div>
          <div class="card">
            <div class="toolbar">
              ${control ? html`<input type="checkbox" class="checkbox" data-act="select-all" aria-label="Select all" />` : ''}
              <div class="tabs">${FILTERS.map(([k, label]) => html`<button data-filter="${k}" class="${k === view.filter ? 'active' : ''}">${label}</button>`)}</div>
              <span class="grow"></span>
              <button class="btn btn-ghost btn-icon" data-act="refresh" title="Refresh" aria-label="Refresh">${icon('refresh', 16)}</button>
            </div>
            <div data-bulk></div>
            <div data-history></div>
            <div class="card-foot" data-foot></div>
          </div>
        </div>
      </div>`,
    );

    const phoneEl = el.querySelector('[data-phone]');
    const historyEl = el.querySelector('[data-history]');
    const bulkEl = el.querySelector('[data-bulk]');
    const footEl = el.querySelector('[data-foot]');
    const selectAll = el.querySelector('[data-act="select-all"]');
    let timer = null;
    let lastOperate = state.canOperate;

    const netStatus = () => {
      const m = state.modem;
      return html`<span class="phone-net">${bars(m?.signal)}<span class="truncate" style="max-width:150px">${m?.network.operator ?? 'No service'}</span></span>`;
    };

    const dialLabel = () => (isUssdCode(view.number) ? html`${icon('hash', 18)} Send code` : html`${icon('phone', 18)} Call`);
    // Keeps the dial button in step with what is typed, without re-rendering the dialer.
    const syncDial = () => {
      const btn = el.querySelector('[data-act="dial"]');
      if (btn) mount(btn, dialLabel());
    };

    /** The whole session, oldest first: the code, each menu, each reply. */
    const transcript = (u) => {
      const msgs = u.messages?.length ? u.messages : u.response ? [{ direction: 'inbound', text: u.response }] : [];
      return html`<div class="ussd-text ussd-log" data-ussd-log>
        ${msgs.map((m) => html`<div class="ussd-msg ${m.direction}">${m.text}</div>`)}
        ${u.status === 'pending' ? html`<div class="ussd-msg wait">Waiting for the network…</div>` : ''}
      </div>`;
    };

    /** Chips for the last few codes sent from the dashboard (empty until they are loaded). */
    const recent = () => {
      if (!control || !view.recent) return '';
      return view.recent.length
        ? html`<div class="ussd-recent">
            <span class="label-sm">${icon('hash', 12)} Recent codes</span>
            <div class="row row-wrap">${view.recent.map((c) => html`<button type="button" class="code-chip" data-code="${c}">${c}</button>`)}</div>
          </div>`
        : html`<p class="hint ussd-hint">${icon('hash', 13)}<span>Dial USSD codes such as <span class="mono">*123#</span> to check your balance or open operator menus.</span></p>`;
    };

    // Updates only the chips, so the number being typed in the dialer is left alone.
    const loadRecent = async () => {
      if (!control) return;
      try {
        const res = await api('/ussd/sessions', { query: { source: 'dashboard', limit: 20 } });
        view.recent = [...new Set(res.data.map((s) => s.code).filter(Boolean))].slice(0, 4);
      } catch {
        return;
      }
      const slot = el.querySelector('[data-recent]');
      if (slot) mount(slot, recent());
    };

    const keypad = () =>
      html`<div class="keypad">${KEYS.map(([k, sub]) => html`<button type="button" data-key="${k}">${k}<small>${sub || ' '}</small></button>`)}</div>`;

    const renderUssd = (u) => {
      const waiting = u.status === 'pending';
      const open = u.status === 'open';
      mount(
        phoneEl,
        html`<div class="card-head"><h2>${u.code ? html`USSD <span class="mono">${u.code}</span>` : 'Network message'}</h2>${ussdBadge(u.status)}</div>
          <div class="card-body stack">
            ${transcript(u)}
            ${u.error ? html`<div class="banner banner-err">${icon('alert', 16)}<span>${u.error}</span></div>` : ''}
            ${control && open
              ? html`<form class="row" data-ussd-form>
                  <input class="input grow" name="reply" autocomplete="off" maxlength="160" placeholder="Reply" aria-label="Reply" />
                  <button class="btn btn-primary" type="submit">${icon('send', 16)} Send</button>
                </form>
                ${keypad()}`
              : ''}
            ${control && (waiting || open)
              ? html`<button class="btn btn-block" data-ussd="cancel">${icon('x', 16)} Cancel</button>`
              : html`<button class="btn btn-block" data-ussd="done">Done</button>`}
          </div>`,
      );
      const log = phoneEl.querySelector('[data-ussd-log]');
      if (log) log.scrollTop = log.scrollHeight;
      // On touch screens focusing would pop the keyboard over the menu; the keypad is there instead.
      if (matchMedia('(pointer: fine)').matches) phoneEl.querySelector('[data-ussd-form] input')?.focus();
    };

    const renderPhone = () => {
      clearInterval(timer);
      const c = state.call;
      if (!c && view.ussd) return renderUssd(view.ussd);
      if (!c) {
        mount(
          phoneEl,
          html`<div class="card-head"><h2>Dialer</h2>${netStatus()}</div>
            <div class="card-body stack">
              ${!state.canOperate ? html`<div class="banner banner-warn">${icon('alert', 16)}<span>${state.reason ?? 'Modem not ready'}</span></div>` : ''}
              <div class="row dial-display">
                <input class="input dial-input grow" data-number inputmode="tel" autocomplete="off" placeholder="Number or *code#" value="${view.number}" aria-label="Phone number" />
                <button class="btn btn-ghost btn-icon" data-act="backspace" aria-label="Delete digit">${icon('backspace', 18)}</button>
              </div>
              ${keypad()}
              ${control
                ? html`<button class="btn btn-ok btn-lg btn-block" data-act="dial" ${state.canOperate ? '' : 'disabled'}>${dialLabel()}</button>`
                : html`<p class="hint">You have read-only access to calls.</p>`}
              <div data-recent style="display:contents">${recent()}</div>
            </div>`,
        );
        return;
      }

      const ringingIn = c.direction === 'inbound' && c.status === 'ringing';
      mount(
        phoneEl,
        html`<div class="card-head"><h2>${callTitle(c)}</h2>${callBadge(c.status)}</div>
          <div class="card-body stack">
            <div class="call-panel">
              <span class="ring-icon ${c.status !== 'active' ? 'ringing' : ''}">${icon(ringingIn ? 'phone-in' : 'phone', 30)}</span>
              <div class="number">${c.phone ?? 'Unknown number'}</div>
              <div class="timer" data-timer>${c.status === 'active' ? duration(callElapsed(c)) : ' '}</div>
              <div class="muted">${c.direction === 'inbound' ? 'Incoming call' : 'Outgoing call'} · started ${timeAgo(c.startedAt)}</div>
            </div>
            ${c.status === 'active'
              ? html`<div class="stack">
                  <div class="hint" style="text-align:center">Keypad sends DTMF tones${view.dtmf ? html`: <span class="mono">${view.dtmf}</span>` : ''}</div>
                  ${keypad()}
                </div>`
              : ''}
            ${control
              ? ringingIn
                ? html`<div class="grid grid-2">
                    <button class="btn btn-danger btn-lg" data-call="reject">${icon('phone-off', 18)} Reject</button>
                    <button class="btn btn-ok btn-lg" data-call="answer">${icon('phone', 18)} Answer</button>
                  </div>`
                : html`<button class="btn btn-danger btn-lg btn-block" data-call="hangup">${icon('phone-off', 18)} Hang up</button>`
              : ''}
          </div>`,
      );
      if (c.status === 'active') {
        timer = setInterval(() => {
          const t = phoneEl.querySelector('[data-timer]');
          if (t && state.call) t.textContent = duration(callElapsed(state.call));
        }, 1000);
      }
    };

    const callTable = () =>
      html`<div class="table-wrap"><table class="table">
        <thead><tr>
          ${control ? html`<th style="width:36px"></th>` : ''}
          <th>Number</th><th>Status</th><th class="hide-sm">Started</th><th class="num">Duration</th><th></th>
        </tr></thead>
        <tbody>
          ${view.data.map(
            (c) => html`<tr>
              ${control ? html`<td><input type="checkbox" class="checkbox" data-check="${c.id}" ${view.selected.has(c.id) ? 'checked' : ''} aria-label="Select call" /></td>` : ''}
              <td>
                <div class="row">${callIcon(c)}<div style="min-width:0">
                  <div class="truncate" style="font-weight:600">${c.phone ?? 'Unknown number'}</div>
                  <div class="faint" style="font-size:12px">${c.direction === 'inbound' ? 'Incoming' : 'Outgoing'}${c.endReason ? ` · ${c.endReason}` : ''}</div>
                </div></div>
              </td>
              <td>${callBadge(c.status)}</td>
              <td class="hide-sm nowrap" title="${dateTime(c.startedAt)}">${timeAgo(c.startedAt)}</td>
              <td class="num">${c.status === 'completed' ? duration(c.duration) : '—'}</td>
              <td class="num nowrap">
                ${control && c.phone ? html`<button class="btn btn-ghost btn-icon btn-sm" data-callback="${c.phone}" title="Call back" aria-label="Call back">${icon('phone', 15)}</button>` : ''}
                ${control && !['dialing', 'ringing', 'active'].includes(c.status) ? html`<button class="btn btn-ghost btn-icon btn-sm" data-del="${c.id}" title="Delete" aria-label="Delete">${icon('trash', 15)}</button>` : ''}
              </td>
            </tr>`,
          )}
        </tbody>
      </table></div>`;

    // Response and error text come from the network: plain interpolation only, never raw().
    const ussdTable = () =>
      html`<div class="table-wrap"><table class="table">
        <thead><tr>
          ${control ? html`<th style="width:36px"></th>` : ''}
          <th>Code</th><th>Status</th><th class="hide-sm">Source</th><th class="hide-sm">Started</th><th></th>
        </tr></thead>
        <tbody>
          ${view.data.map((s) => {
            const active = ACTIVE_USSD.has(s.status);
            const full = s.error ?? s.response ?? '';
            const text = oneLine(full);
            return html`<tr>
              ${control ? html`<td>${active ? '' : html`<input type="checkbox" class="checkbox" data-check="${s.id}" ${view.selected.has(s.id) ? 'checked' : ''} aria-label="Select USSD session" />`}</td>` : ''}
              <td style="width:100%;max-width:0">
                <div class="row">${s.code ? html`<span class="avatar avatar-out">${icon('hash', 16)}</span>` : html`<span class="avatar avatar-in">${icon('bell', 16)}</span>`}<div style="min-width:0">
                  <div class="truncate ${s.code ? 'mono' : ''}" style="font-weight:600">${s.code ?? 'Network message'}</div>
                  <div class="faint truncate" style="font-size:12px" title="${full}">${text || '—'}</div>
                </div></div>
              </td>
              <td>${ussdBadge(s.status)}</td>
              <td class="hide-sm nowrap">${SOURCE_LABEL[s.source] ?? s.source}</td>
              <td class="hide-sm nowrap" title="${dateTime(s.startedAt)}">${timeAgo(s.startedAt)}</td>
              <td class="num nowrap">
                ${control && !active ? html`<button class="btn btn-ghost btn-icon btn-sm" data-del="${s.id}" title="Delete" aria-label="Delete">${icon('trash', 15)}</button>` : ''}
              </td>
            </tr>`;
          })}
        </tbody>
      </table></div>`;

    const renderHistory = () => {
      const ussd = isUssd();
      if (view.loading && !view.data.length) mount(historyEl, html`<div class="empty">Loading…</div>`);
      else if (!view.data.length) {
        mount(
          historyEl,
          ussd
            ? html`<div class="empty">${icon('hash', 32)}<strong>No USSD sessions</strong><span>Codes you send and messages from the network will appear here.</span></div>`
            : html`<div class="empty">${icon('phone', 32)}<strong>No calls</strong><span>Call history will appear here.</span></div>`,
        );
      } else mount(historyEl, ussd ? ussdTable() : callTable());
      const n = view.selected.size;
      mount(
        bulkEl,
        n
          ? html`<div class="bulkbar"><span class="grow">${pluralize(n, ussd ? 'session' : 'call')} selected</span>
              <button class="btn btn-sm btn-danger" data-act="delete-selected">${icon('trash', 14)} Delete</button>
              <button class="btn btn-sm btn-ghost" data-act="clear">Clear</button></div>`
          : '',
      );
      if (selectAll) {
        selectAll.checked = n > 0 && selectable().every((c) => view.selected.has(c.id));
        selectAll.indeterminate = n > 0 && !selectAll.checked;
      }
      const to = Math.min(view.total, view.page * LIMIT);
      mount(
        footEl,
        html`<span>${view.total ? `${(view.page - 1) * LIMIT + 1}–${to} of ${view.total}` : ''}</span>
          <div class="pager">
            <button class="btn btn-sm btn-icon" data-act="prev" ${view.page <= 1 ? 'disabled' : ''} aria-label="Previous page">${icon('chevron-left', 16)}</button>
            <button class="btn btn-sm btn-icon" data-act="next" ${to >= view.total ? 'disabled' : ''} aria-label="Next page">${icon('chevron-right', 16)}</button>
          </div>`,
      );
    };

    let req = 0;
    const load = async () => {
      const id = ++req;
      view.loading = true;
      try {
        const filter = FILTERS.find(([k]) => k === view.filter)[2];
        const res = await api(isUssd() ? '/ussd/sessions' : '/calls', { query: { ...filter, page: view.page, limit: LIMIT } });
        if (id !== req) return;
        view.data = res.data;
        view.total = res.total;
        const ids = new Set(res.data.map((c) => c.id));
        for (const s of view.selected) if (!ids.has(s)) view.selected.delete(s);
      } catch (err) {
        toastError(err);
      } finally {
        if (id === req) {
          view.loading = false;
          renderHistory();
        }
      }
    };
    const reload = debounce(load, 300);

    const showUssd = (u) => {
      if (!u || u.id === view.dismissedUssd) return;
      view.ussd = u;
      if (!state.call) renderPhone();
    };

    const ussdAction = (path, body, button) =>
      busy(button, async () => {
        try {
          const res = await api(`/ussd${path}`, { method: 'POST', body });
          showUssd(res.data);
          return res.data;
        } catch (err) {
          toastError(err);
          return null;
        }
      });

    const dial = (number, button) =>
      busy(button, async () => {
        const n = (number ?? '').trim();
        if (!n) return toast('Enter a number to call', 'warn');
        if (USSD_CODE.test(n.replace(/\s/g, ''))) {
          if (await ussdAction('', { code: n })) view.number = '';
          void loadRecent(); // even a failed code is recorded
          return;
        }
        try {
          await api('/calls', { method: 'POST', body: { number: n } });
          view.dtmf = '';
        } catch (err) {
          toastError(err);
        }
      });

    const sendDtmf = async (digit) => {
      view.dtmf = (view.dtmf + digit).slice(-24);
      renderPhone();
      try {
        await api('/calls/dtmf', { method: 'POST', body: { digits: digit } });
      } catch (err) {
        toastError(err);
      }
    };

    const offs = [
      on(el, 'input', '[data-number]', (_e, input) => {
        view.number = input.value;
        syncDial();
      }),
      on(el, 'keydown', '[data-number]', (e, input) => {
        if (e.key === 'Enter') void dial(input.value, el.querySelector('[data-act="dial"]'));
      }),
      on(el, 'click', '[data-key]', (_e, btn) => {
        const key = btn.dataset.key;
        if (state.call?.status === 'active') return void sendDtmf(key);
        if (state.call) return;
        const reply = el.querySelector('[data-ussd-form] input');
        if (reply) {
          reply.value += key;
          return;
        }
        view.number += key;
        const input = el.querySelector('[data-number]');
        if (input) input.value = view.number;
        syncDial();
      }),
      on(el, 'click', '[data-code]', (_e, btn) => {
        view.number = btn.dataset.code;
        const input = el.querySelector('[data-number]');
        if (input) input.value = view.number;
        syncDial();
      }),
      on(el, 'click', '[data-act]', (_e, btn) => {
        const act = btn.dataset.act;
        if (act === 'dial') void dial(view.number, btn);
        else if (act === 'backspace') {
          view.number = view.number.slice(0, -1);
          const input = el.querySelector('[data-number]');
          if (input) input.value = view.number;
          syncDial();
        } else if (act === 'refresh') void load();
        else if (act === 'prev') (view.page--, void load());
        else if (act === 'next') (view.page++, void load());
        else if (act === 'clear') (view.selected.clear(), renderHistory());
        else if (act === 'delete-selected') {
          const ussd = isUssd();
          const noun = ussd ? 'USSD session' : 'call record';
          void confirmDialog({
            title: ussd ? 'Delete USSD sessions' : 'Delete call records',
            message: `Delete ${pluralize(view.selected.size, noun)} from history?`,
            confirmLabel: 'Delete',
            danger: true,
          }).then(async (ok) => {
            if (!ok) return;
            try {
              const res = await api(ussd ? '/ussd/sessions/delete' : '/calls/delete', { method: 'POST', body: { ids: [...view.selected] } });
              toast(`Deleted ${pluralize(res.deleted.length, noun)}`, 'ok');
              view.selected.clear();
              await load();
            } catch (err) {
              toastError(err);
            }
          });
        }
      }),
      on(el, 'change', '[data-act="select-all"]', (_e, box) => {
        for (const c of selectable()) box.checked ? view.selected.add(c.id) : view.selected.delete(c.id);
        renderHistory();
      }),
      on(el, 'change', '[data-check]', (_e, box) => {
        const id = Number(box.dataset.check);
        box.checked ? view.selected.add(id) : view.selected.delete(id);
        renderHistory();
      }),
      on(el, 'click', '[data-filter]', (_e, btn) => {
        const switched = (btn.dataset.filter === 'ussd') !== isUssd();
        view.filter = btn.dataset.filter;
        view.page = 1;
        view.selected.clear();
        el.querySelectorAll('[data-filter]').forEach((b) => b.classList.toggle('active', b === btn));
        if (switched) {
          // Calls and USSD sessions have different rows: never draw one list with the other's layout.
          view.data = [];
          view.total = 0;
          view.loading = true;
          renderHistory();
        }
        void load();
      }),
      on(el, 'click', '[data-call]', (_e, btn) => void callAction(btn.dataset.call, btn)),
      on(el, 'submit', '[data-ussd-form]', (e, form) => {
        e.preventDefault();
        const text = form.reply.value.trim();
        if (text) void ussdAction('/reply', { text }, form.querySelector('[type=submit]'));
      }),
      on(el, 'click', '[data-ussd]', (_e, btn) => {
        if (!view.ussd) return;
        view.dismissedUssd = view.ussd.id;
        view.ussd = null;
        renderPhone();
        if (btn.dataset.ussd === 'cancel') {
          api('/ussd/cancel', { method: 'POST' }).catch((err) => err.status !== 409 && toastError(err));
        }
      }),
      on(el, 'click', '[data-callback]', (_e, btn) => {
        if (state.call) return toast('A call is already in progress', 'warn');
        view.number = btn.dataset.callback;
        renderPhone();
        void dial(view.number, btn);
      }),
      on(el, 'click', '[data-del]', async (_e, btn) => {
        const ussd = isUssd();
        try {
          await api(`${ussd ? '/ussd/sessions' : '/calls'}/${btn.dataset.del}`, { method: 'DELETE' });
          if (ussd) void load(); // no event announces deleted USSD sessions
        } catch (err) {
          toastError(err);
        }
      }),
      subscribe('state.call', (c) => {
        if (!c) view.dtmf = '';
        renderPhone();
      }),
      subscribe('state.modem', () => {
        // Only re-render when readiness flips, so typing in the dialer is not interrupted.
        if (state.canOperate === lastOperate) return;
        lastOperate = state.canOperate;
        if (!state.call) renderPhone();
      }),
      subscribeAll(['call.updated', 'call.deleted'], () => !isUssd() && reload()),
      subscribe('ussd.updated', () => isUssd() && reload()),
      // Sessions started by API clients would otherwise take over every open dialer.
      subscribe('ussd.updated', (u) => (u.id === view.ussd?.id || u.source !== 'api') && showUssd(u)),
    ];

    renderPhone();
    renderHistory();
    void load();
    void loadRecent();
    api('/ussd')
      .then(({ data: u }) => u && ['pending', 'open'].includes(u.status) && u.source !== 'api' && showUssd(u))
      .catch(() => {});

    return () => {
      clearInterval(timer);
      offs.forEach((off) => off());
    };
  },
};
