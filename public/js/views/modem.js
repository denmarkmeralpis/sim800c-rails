import { signalChart } from '../components/chart.js';
import { confirmDialog } from '../components/modal.js';
import { toast, toastError } from '../components/toast.js';
import { api } from '../lib/api.js';
import { busy, html, mount, on, raw } from '../lib/dom.js';
import { REGISTRATION, SIM_STATE, badge, bars, dateTime, modemSummary, timeAgo, timeUntil } from '../lib/format.js';
import { icon } from '../lib/icons.js';
import { can, state, subscribe } from '../lib/store.js';

const QUICK_AT = ['AT', 'ATI', 'AT+CSQ', 'AT+CREG?', 'AT+COPS?', 'AT+CPIN?', 'AT+CBC', 'AT+CPMS?', 'AT+CLCC'];
const LOG_FILTERS = [
  ['', 'All'],
  ['warn', 'Warnings'],
  ['error', 'Errors'],
];

function mask(value, keepStart = 5, keepEnd = 3) {
  if (!value) return '—';
  if (value.length <= keepStart + keepEnd) return value;
  return `${value.slice(0, keepStart)}•••••${value.slice(-keepEnd)}`;
}

function logItem(e) {
  const ic = e.level === 'error' ? 'x-circle' : e.level === 'warn' ? 'alert' : 'info';
  return html`<div class="log-item ${e.level}">
    <span class="ic">${icon(ic, 15)}</span>
    <div><span class="chip">${e.category}</span> ${e.message}</div>
    <span class="faint nowrap" style="font-size:12px" title="${dateTime(e.createdAt)}">${timeAgo(e.createdAt)}</span>
  </div>`;
}

export default {
  title: 'Modem',
  scope: 'modem:read',
  render(el) {
    const admin = can('admin');
    const write = can('modem:write');
    const view = { logLevel: '', log: [], signal: [], sim: null };

    mount(
      el,
      html`<div class="page">
        <div class="page-head">
          <div>
            <span class="eyebrow"><b>04</b> Hardware · SIM800C</span>
            <h1>Modem</h1>
            <p>SIM800C connection, SIM and network status, diagnostics and event log</p>
          </div>
          <div class="row row-wrap">
            <button class="btn" data-act="refresh">${icon('refresh', 16)} Refresh</button>
            ${write
              ? html`<button class="btn" data-act="reconnect">${icon('zap', 16)} Reconnect</button>
                  <button class="btn btn-danger" data-act="restart">${icon('modem', 16)} Restart modem</button>`
              : ''}
          </div>
        </div>
        <div data-status></div>
        <div class="grid grid-2">
          <div class="card">
            <div class="card-head"><h2>${icon('activity', 15)} Signal history</h2><span class="live-tag">Live</span></div>
            <div class="card-body" data-chart></div>
          </div>
          <div class="card">
            <div class="card-head">
              <h2>${icon('book', 15)} Event log</h2>
              <div class="tabs">${LOG_FILTERS.map(([k, label]) => html`<button data-level="${k}" class="${k === view.logLevel ? 'active' : ''}">${label}</button>`)}</div>
            </div>
            <div data-log style="max-height:360px;overflow:auto"></div>
          </div>
        </div>
        ${state.simulator && write ? html`<div class="card" data-sim></div>` : ''}
        ${admin
          ? html`<div class="card">
              <div class="card-head">
                <h2>${icon('terminal', 15)} AT console</h2>
                <button class="btn btn-sm" data-act="traffic">${icon('activity', 14)} Show serial traffic</button>
              </div>
              <div class="card-body stack">
                <div class="console" data-console aria-live="polite"><span class="t">Send AT commands directly to the modem. Settings managed by the driver (echo, SMS mode, baud rate) are blocked.</span>\n</div>
                <form class="row" data-at-form>
                  <input class="input mono grow" name="command" placeholder="AT+CSQ" autocomplete="off" spellcheck="false" aria-label="AT command" />
                  <button class="btn btn-primary" type="submit">${icon('terminal', 16)} Send</button>
                </form>
                <div class="row row-wrap">${QUICK_AT.map((c) => html`<button class="btn btn-sm btn-ghost mono" data-quick="${c}">${c}</button>`)}</div>
              </div>
            </div>`
          : ''}
      </div>`,
    );

    const statusEl = el.querySelector('[data-status]');
    const chartEl = el.querySelector('[data-chart]');
    const logEl = el.querySelector('[data-log]');
    const simEl = el.querySelector('[data-sim]');
    const consoleEl = el.querySelector('[data-console]');

    const renderStatus = () => {
      const m = state.modem;
      if (!m) return mount(statusEl, html`<div class="card card-body muted">Waiting for modem status…</div>`);
      const s = modemSummary(m, state.canOperate, state.reason);
      mount(
        statusEl,
        html`<div class="stack">
          ${m.connection !== 'ready' && m.lastError
            ? html`<div class="banner banner-err">${icon('alert', 16)}<span class="grow">${m.lastError}</span>${m.nextReconnectAt ? html`<span>Retry ${timeUntil(m.nextReconnectAt)} (attempt ${m.reconnectAttempts})</span>` : ''}</div>`
            : ''}
          <div class="grid grid-3">
            <div class="card">
              <div class="card-head"><h2>${icon('zap', 15)} Connection</h2><span class="row"><span class="dot dot-${s.tone}"></span>${s.label}</span></div>
              <div class="card-body"><dl class="kv">
                <dt>Port</dt><dd class="mono">${m.port}</dd>
                <dt>Driver</dt><dd>${{ mock: 'Simulator', tcp: 'Serial bridge (TCP)', serial: 'Serial' }[m.driver] ?? m.driver}</dd>
                <dt>State</dt><dd>${m.connection}</dd>
                <dt>Connected</dt><dd>${m.connectedAt && m.connection === 'ready' ? timeAgo(m.connectedAt) : '—'}</dd>
                <dt>Last error</dt><dd>${m.lastError ?? '—'}</dd>
              </dl></div>
            </div>
            <div class="card">
              <div class="card-head"><h2>${icon('modem', 15)} Device</h2><span class="chip">${m.device?.model ?? 'SIM800C'}</span></div>
              <div class="card-body"><dl class="kv">
                <dt>Manufacturer</dt><dd>${m.device?.manufacturer ?? '—'}</dd>
                <dt>Model</dt><dd>${m.device?.model ?? '—'}</dd>
                <dt>Firmware</dt><dd class="mono">${m.device?.revision ?? '—'}</dd>
                <dt>IMEI</dt><dd class="mono">${m.device?.imei ?? '—'}</dd>
              </dl></div>
            </div>
            <div class="card">
              <div class="card-head"><h2>${icon('sim', 15)} SIM &amp; network</h2>${badge(SIM_STATE[m.sim.state])}</div>
              <div class="card-body"><dl class="kv">
                <dt>SIM</dt><dd>${m.sim.detail ?? m.sim.state}</dd>
                <dt>ICCID</dt><dd class="mono" title="${admin ? m.sim.iccid ?? '' : ''}">${admin ? (m.sim.iccid ?? '—') : mask(m.sim.iccid)}</dd>
                <dt>IMSI</dt><dd class="mono">${mask(m.sim.imsi)}</dd>
                <dt>Network</dt><dd>${REGISTRATION[m.network.registration]}</dd>
                <dt>Operator</dt><dd>${m.network.operator ?? '—'}</dd>
              </dl></div>
            </div>
          </div>
          <div class="grid grid-3">
            <div class="card stat">
              <span class="label">${icon('signal', 15)} Signal</span>
              <span class="value row">${bars(m.signal, true)} ${m.signal.dbm ?? '—'} <small>dBm</small></span>
              <span class="detail">RSSI ${m.signal.rssi ?? '—'}/31 · BER ${m.signal.ber ?? '—'} · ${m.signal.quality}</span>
            </div>
            <div class="card stat">
              <span class="label">${icon('battery', 15)} Supply voltage</span>
              <span class="value">${m.power.voltage ? (m.power.voltage / 1000).toFixed(2) : '—'} <small>V</small></span>
              <span class="detail">${m.power.voltage && m.power.voltage < 3500 ? 'Low — SIM800C needs 3.4–4.4 V with 2 A peaks' : 'SIM800C range 3.4–4.4 V'}</span>
            </div>
            <div class="card stat">
              <span class="label">${icon('sim', 15)} SIM message storage</span>
              <span class="value">${m.storage.used ?? '—'} <small>/ ${m.storage.total ?? '—'}</small></span>
              ${m.storage.total
                ? raw(`<div class="progress ${m.storage.used / m.storage.total > 0.8 ? 'warn' : ''}"><i style="width:${Math.min(100, Math.round((m.storage.used / m.storage.total) * 100))}%"></i></div>`)
                : ''}
              <span class="detail">Messages are moved to the database as they arrive</span>
            </div>
          </div>
        </div>`,
      );
    };

    const renderLog = () => {
      const items = view.log.filter((e) => !view.logLevel || e.level === view.logLevel);
      mount(logEl, items.length ? html`${items.map(logItem)}` : html`<div class="empty">No events</div>`);
    };

    const loadLog = async () => {
      try {
        view.log = (await api('/modem/events', { query: { limit: 150 } })).data;
        renderLog();
      } catch (err) {
        toastError(err);
      }
    };

    const loadSignal = async () => {
      try {
        view.signal = (await api('/modem/signal')).data;
        mount(chartEl, signalChart(view.signal, { width: 520, height: 300 }));
      } catch {
        /* ignore */
      }
    };

    const renderSim = () => {
      if (!simEl) return;
      const s = view.sim;
      mount(
        simEl,
        html`<div class="card-head"><h2>${icon('flask', 16)} Simulator controls</h2><span class="badge badge-warn">MODEM_DRIVER=mock</span></div>
          <div class="card-body stack">
            <div class="grid grid-3">
              <form class="stack" data-sim-form="sms">
                <h3>Incoming SMS</h3>
                <input class="input" name="from" value="+639171112222" aria-label="Sender" />
                <textarea class="textarea" name="message" style="min-height:76px" aria-label="Message">Hello from the simulated network!</textarea>
                <button class="btn btn-primary" type="submit">${icon('message', 16)} Deliver SMS</button>
              </form>
              <form class="stack" data-sim-form="call">
                <h3>Incoming call</h3>
                <input class="input" name="from" value="+639178889999" aria-label="Caller" />
                <button class="btn btn-primary" type="submit">${icon('phone-in', 16)} Ring the gateway</button>
                <button class="btn" type="button" data-sim="remote-hangup">${icon('phone-off', 16)} Remote party hangs up</button>
              </form>
              <div class="stack">
                <h3>Network &amp; faults</h3>
                <div class="row">
                  <input type="range" min="0" max="31" value="${s?.rssi ?? 20}" class="grow" data-rssi aria-label="Signal (RSSI)" />
                  <button class="btn btn-sm" data-sim="signal">Set RSSI</button>
                </div>
                <div class="row">
                  <select class="select grow" data-reg aria-label="Registration">
                    ${[
                      [1, 'Registered (home)'],
                      [5, 'Registered (roaming)'],
                      [2, 'Searching'],
                      [0, 'Not registered'],
                      [3, 'Denied'],
                    ].map(([v, l]) => html`<option value="${v}" ${s?.registration === v ? 'selected' : ''}>${l}</option>`)}
                  </select>
                  <button class="btn btn-sm" data-sim="network">Apply</button>
                </div>
                <div class="row row-wrap">
                  <button class="btn btn-sm" data-sim="sim">${s?.simInserted === false ? 'Insert SIM' : 'Remove SIM'}</button>
                  <button class="btn btn-sm" data-sim="unplug">Unplug 10 s</button>
                  <button class="btn btn-sm" data-sim="freeze">Freeze 20 s</button>
                  <button class="btn btn-sm" data-sim="reboot">Reboot</button>
                </div>
              </div>
            </div>
            <p class="hint" style="margin:0">
              Outgoing test numbers: SMS to <span class="mono">…0000</span> fails permanently, <span class="mono">…4444</span> is sent but not delivered.
              Calls to <span class="mono">…000</span> are busy, <span class="mono">…888</span> rejected, <span class="mono">…999</span> never answered; any other number answers after a few seconds.
              USSD <span class="mono">*123#</span> returns a balance, <span class="mono">*143#</span> opens a menu, <span class="mono">…999#</span> never replies; other codes are unsupported.
            </p>
          </div>`,
      );
    };

    const loadSim = async () => {
      if (!simEl) return;
      try {
        view.sim = (await api('/simulator')).data;
      } catch {
        /* ignore */
      }
      renderSim();
    };

    const simAction = (path, body, button) =>
      busy(button, async () => {
        try {
          view.sim = (await api(`/simulator/${path}`, { method: 'POST', body: body ?? {} })).data;
          renderSim();
        } catch (err) {
          toastError(err);
        }
      });

    const print = (text, cls = '') => {
      const line = document.createElement('div');
      if (cls) line.className = cls;
      line.textContent = text;
      consoleEl.appendChild(line);
      consoleEl.scrollTop = consoleEl.scrollHeight;
    };

    const runAt = async (command, button) => {
      if (!command) return;
      print(`> ${command}`, 'tx');
      await busy(button, async () => {
        try {
          const r = await api('/modem/at', { method: 'POST', body: { command } });
          if (r.ok) {
            for (const l of r.lines) print(l);
            print(`${r.final}  (${r.durationMs} ms)`, 't');
          } else print(r.error, 'err');
        } catch (err) {
          print(err.message, 'err');
        }
      });
    };

    const offs = [
      on(el, 'click', '[data-act]', async (_e, btn) => {
        const act = btn.dataset.act;
        if (act === 'refresh') {
          await busy(btn, async () => {
            try {
              await api('/modem/refresh', { method: 'POST' });
              await Promise.all([loadSignal(), loadLog(), loadSim()]);
            } catch (err) {
              toastError(err);
            }
          });
        } else if (act === 'reconnect') {
          await busy(btn, () => api('/modem/reconnect', { method: 'POST' }).then(() => toast('Reconnecting to modem…'), toastError));
        } else if (act === 'restart') {
          const ok = await confirmDialog({
            title: 'Restart modem',
            message: 'The SIM800C will reboot (AT+CFUN=1,1). Any call in progress is dropped and messaging pauses for ~10–20 seconds.',
            confirmLabel: 'Restart',
            danger: true,
          });
          if (ok) await busy(btn, () => api('/modem/restart', { method: 'POST' }).then(() => toast('Modem is restarting…'), toastError));
        } else if (act === 'traffic') {
          try {
            const { data } = await api('/modem/traffic');
            print('— last serial traffic —', 't');
            for (const t of data) {
              const time = new Date(t.t).toLocaleTimeString([], { hour12: false });
              print(`${time} ${t.dir === 'tx' ? '→' : t.dir === 'urc' ? '⚡' : '←'} ${t.line}`, t.dir === 'tx' ? 'tx' : t.dir === 'urc' ? 'urc' : '');
            }
          } catch (err) {
            toastError(err);
          }
        }
      }),
      on(el, 'click', '[data-level]', (_e, btn) => {
        view.logLevel = btn.dataset.level;
        el.querySelectorAll('[data-level]').forEach((b) => b.classList.toggle('active', b === btn));
        renderLog();
      }),
      on(el, 'submit', '[data-at-form]', (e, form) => {
        e.preventDefault();
        void runAt(form.command.value.trim(), form.querySelector('button'));
        form.command.select();
      }),
      on(el, 'click', '[data-quick]', (_e, btn) => void runAt(btn.dataset.quick, btn)),
      on(el, 'submit', '[data-sim-form]', (e, form) => {
        e.preventDefault();
        const btn = form.querySelector('[type=submit]');
        if (form.dataset.simForm === 'sms') {
          void simAction('incoming-sms', { from: form.from.value, message: form.message.value }, btn).then(() => toast('SMS delivered to the simulated SIM', 'ok'));
        } else {
          void simAction('incoming-call', { from: form.from.value }, btn);
        }
      }),
      on(el, 'click', '[data-sim]', (_e, btn) => {
        const a = btn.dataset.sim;
        if (a === 'signal') void simAction('signal', { rssi: Number(el.querySelector('[data-rssi]').value) }, btn);
        else if (a === 'network') void simAction('network', { registration: Number(el.querySelector('[data-reg]').value) }, btn);
        else if (a === 'sim') void simAction('sim', { inserted: view.sim?.simInserted === false }, btn);
        else if (a === 'unplug') void simAction('unplug', { seconds: 10 }, btn);
        else if (a === 'freeze') void simAction('freeze', { seconds: 20 }, btn);
        else void simAction(a, {}, btn);
      }),
      subscribe('state.modem', renderStatus),
      subscribe('log.entry', (entry) => {
        view.log.unshift(entry);
        view.log.length = Math.min(view.log.length, 300);
        renderLog();
      }),
    ];

    renderStatus();
    void loadLog();
    void loadSignal();
    void loadSim();
    const signalTimer = setInterval(loadSignal, 20_000);
    const tick = setInterval(() => state.modem?.connection !== 'ready' && renderStatus(), 1000);

    return () => {
      offs.forEach((off) => off());
      clearInterval(signalTimer);
      clearInterval(tick);
    };
  },
};
