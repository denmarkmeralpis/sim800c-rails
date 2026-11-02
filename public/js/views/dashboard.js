import { signalChart } from '../components/chart.js';
import { openCompose } from '../components/compose.js';
import { api } from '../lib/api.js';
import { debounce, html, mount, on } from '../lib/dom.js';
import {
  REGISTRATION,
  SIM_STATE,
  badge,
  bars,
  callBadge,
  modemSummary,
  smsBadge,
  talkTime,
  timeAgo,
} from '../lib/format.js';
import { icon } from '../lib/icons.js';
import { can, state, subscribe, subscribeAll } from '../lib/store.js';

const CHART = { width: 720, height: 260 };

function callIcon(c) {
  if (c.status === 'missed' || c.status === 'rejected') return ['phone-missed', 'avatar-err'];
  return c.direction === 'inbound' ? ['phone-in', 'avatar-in'] : ['phone-out', 'avatar-out'];
}

export default {
  title: 'Dashboard',
  render(el) {
    let data = { sms: null, calls: null, recentSms: [], recentCalls: [], signal: [] };

    /** Live link instrument: status, operator and the big dot-matrix signal readout. */
    const tiles = () => {
      const m = state.modem;
      const s = modemSummary(m, state.canOperate, state.reason);
      const sim = SIM_STATE[m?.sim.state ?? 'unknown'];
      const quality = m?.signal.quality;
      return html`
        <div class="hero-top">
          <span class="status-chip"><span class="dot dot-${s.tone} ${s.tone !== 'ok' ? 'dot-pulse' : ''}"></span>${s.label}</span>
          ${badge(sim)}
        </div>
        <div class="hero-operator">
          <strong class="truncate">${m?.network.operator ?? 'No network'}</strong>
          <span>${REGISTRATION[m?.network.registration ?? 'unknown']}</span>
        </div>
        <div>
          <div class="readout">
            <span class="readout-value">${m?.signal.dbm ?? '--'}</span>
            <div class="readout-side">${bars(m?.signal, true)}<span class="readout-unit">dBm</span></div>
          </div>
          <div class="readout-meta" style="margin-top:12px">
            ${!quality || quality === 'unknown' ? 'No signal reading' : html`<strong>${quality}</strong> · RSSI ${m.signal.rssi ?? '—'}/31`}
          </div>
        </div>
        <dl class="hero-specs">
          <div><dt>Device</dt><dd title="${m?.device?.model ?? ''}">${m?.device?.model ?? m?.port ?? '—'}</dd></div>
          <div><dt>Storage</dt><dd>${m?.storage.total ? `${m.storage.used} / ${m.storage.total}` : '—'}</dd></div>
          <div><dt>Supply</dt><dd>${m?.power.voltage ? `${(m.power.voltage / 1000).toFixed(2)} V` : '—'}</dd></div>
        </dl>`;
    };

    const metric = (n, label, tone = '') => html`<div class="metric ${n === 0 || n === '0m' ? 'is-zero' : tone}"><div class="n">${n}</div><div class="l">${label}</div></div>`;

    const banner = () =>
      state.modem && !state.canOperate
        ? html`<div class="banner ${state.modem.connection === 'ready' ? 'banner-warn' : 'banner-err'}">
            ${icon('alert', 16)}<span class="grow">${state.reason}</span>
            <a href="#/modem">Details</a>
          </div>`
        : '';

    const draw = () => {
      const { sms, calls } = data;
      mount(
        el,
        html`<div class="page">
          <div class="page-head">
            <div>
              <span class="eyebrow"><b>01</b> Overview</span>
              <h1>Dashboard</h1>
              <p>Live telemetry from your SIM800C gateway</p>
            </div>
            <div class="row">
              ${can('calls:write') ? html`<a class="btn" href="#/calls">${icon('phone', 16)} Dial</a>` : ''}
              ${can('sms:send') ? html`<button class="btn btn-primary" data-act="compose">${icon('plus', 16)} New message</button>` : ''}
            </div>
          </div>

          <div data-banner>${banner()}</div>

          <section class="card hero">
            <div class="hero-main" data-tiles>${tiles()}</div>
            <div class="hero-chart">
              <div class="hero-chart-head">
                <span class="label-sm">${icon('activity', 14)} Signal · last hour</span>
                <span class="live-tag">Live</span>
              </div>
              <div data-chart>${signalChart(data.signal, CHART)}</div>
            </div>
          </section>

          ${sms || calls
            ? html`<section class="card metrics-panel">
                ${sms
                  ? html`<div class="metric-group">
                      <div class="metric-group-head"><span class="label-sm">${icon('message', 14)} Messaging · today</span></div>
                      <div class="metrics">
                        ${metric(sms.receivedToday, 'Received')}
                        ${metric(sms.sentToday, 'Sent')}
                        ${metric(sms.failedToday, 'Failed', 'is-err')}
                        ${metric(sms.queued, 'In queue')}
                        ${metric(sms.unread ?? 0, 'Unread', 'is-accent')}
                      </div>
                    </div>`
                  : ''}
                ${calls
                  ? html`<div class="metric-group">
                      <div class="metric-group-head"><span class="label-sm">${icon('phone', 14)} Voice · today</span></div>
                      <div class="metrics">
                        ${metric(calls.today, 'Calls')}
                        ${metric(calls.missedToday, 'Missed', 'is-warn')}
                        ${metric(talkTime(calls.talkTimeToday), 'Talk time')}
                      </div>
                    </div>`
                  : ''}
              </section>`
            : ''}

          <div class="grid grid-2">
            ${can('sms:read')
              ? html`<div class="card">
                  <div class="card-head"><h2>Recent messages</h2><a href="#/messages" class="btn btn-ghost btn-sm">View all</a></div>
                  ${data.recentSms.length
                    ? html`<ul class="list">
                        ${data.recentSms.map(
                          (m) => html`<li class="list-item ${m.read ? '' : 'unread'}" data-sms="${m.id}">
                            <span class="avatar ${m.direction === 'inbound' ? 'avatar-in' : 'avatar-out'}">${icon(m.direction === 'inbound' ? 'arrow-in' : 'arrow-out', 16)}</span>
                            <div class="grow">
                              <div class="row"><span class="who grow truncate">${m.phone}</span><span class="when">${timeAgo(m.createdAt)}</span></div>
                              <div class="row"><span class="preview grow truncate">${m.body}</span>${m.direction === 'outbound' ? smsBadge(m.status) : ''}</div>
                            </div>
                          </li>`,
                        )}
                      </ul>`
                    : html`<div class="empty">${icon('inbox', 28)}<span>No messages yet</span></div>`}
                </div>`
              : ''}
            ${can('calls:read')
              ? html`<div class="card">
                  <div class="card-head"><h2>Recent calls</h2><a href="#/calls" class="btn btn-ghost btn-sm">View all</a></div>
                  ${data.recentCalls.length
                    ? html`<ul class="list">
                        ${data.recentCalls.map((c) => {
                          const [ic, tone] = callIcon(c);
                          return html`<li class="list-item" data-call="${c.id}">
                            <span class="avatar ${tone}">${icon(ic, 16)}</span>
                            <div class="grow">
                              <div class="row"><span class="who grow truncate">${c.phone ?? 'Unknown number'}</span><span class="when">${timeAgo(c.startedAt)}</span></div>
                              <div class="row"><span class="preview grow">${c.direction === 'inbound' ? 'Incoming' : 'Outgoing'}${c.duration ? ` · ${talkTime(c.duration)}` : ''}</span>${callBadge(c.status)}</div>
                            </div>
                          </li>`;
                        })}
                      </ul>`
                    : html`<div class="empty">${icon('phone', 28)}<span>No calls yet</span></div>`}
                </div>`
              : ''}
          </div>
        </div>`,
      );
    };

    const load = async () => {
      try {
        const [status, sms, calls, signal] = await Promise.all([
          api('/status'),
          can('sms:read') ? api('/sms', { query: { limit: 6 } }) : null,
          can('calls:read') ? api('/calls', { query: { limit: 6 } }) : null,
          api('/modem/signal'),
        ]);
        data = {
          sms: status.sms,
          calls: status.calls,
          recentSms: sms?.data ?? [],
          recentCalls: calls?.data ?? [],
          signal: signal.data,
        };
        draw();
      } catch {
        /* keep the last good render */
      }
    };
    const reload = debounce(load, 500);

    draw();
    void load();

    const offs = [
      on(el, 'click', '[data-act="compose"]', () => openCompose()),
      on(el, 'click', '[data-sms]', () => (location.hash = '#/messages')),
      on(el, 'click', '[data-call]', () => (location.hash = '#/calls')),
      subscribe('state.modem', () => {
        const tilesSlot = el.querySelector('[data-tiles]');
        if (tilesSlot) mount(tilesSlot, tiles());
        const bannerSlot = el.querySelector('[data-banner]');
        if (bannerSlot) mount(bannerSlot, banner());
      }),
      subscribeAll(['sms.received', 'sms.updated', 'sms.deleted', 'call.updated', 'call.deleted'], reload),
    ];
    const chartTimer = setInterval(async () => {
      try {
        data.signal = (await api('/modem/signal')).data;
        const slot = el.querySelector('[data-chart]');
        if (slot) mount(slot, signalChart(data.signal, CHART));
      } catch {
        /* ignore */
      }
    }, 30_000);

    return () => {
      offs.forEach((off) => off());
      clearInterval(chartTimer);
    };
  },
};
