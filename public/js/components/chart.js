import { html, raw } from '../lib/dom.js';

// GSM quality bands in dBm (RSSI 10 / 15 / 20 → -93 / -83 / -73), matching signalLevel() in format.js.
const BANDS = [
  [-51, -73, 'EXCELLENT'],
  [-73, -83, 'GOOD'],
  [-83, -93, 'FAIR'],
  [-93, -113, 'POOR'],
];

let uid = 0;

const pt = ([a, b]) => `${a.toFixed(1)},${b.toFixed(1)}`;

/** Smooth path through the points (quadratic curves via segment midpoints). */
function smoothPath(pts) {
  if (pts.length < 3) return `M${pts.map(pt).join('L')}`;
  let d = `M${pt(pts[0])}`;
  for (let i = 1; i < pts.length - 1; i++) {
    d += `Q${pt(pts[i])} ${pt([(pts[i][0] + pts[i + 1][0]) / 2, (pts[i][1] + pts[i + 1][1]) / 2])}`;
  }
  return `${d}L${pt(pts.at(-1))}`;
}

/** Signal strength (dBm) over time as an inline SVG trace. Gaps where the signal was unknown. */
export function signalChart(samples, { width = 640, height = 190 } = {}) {
  if (!samples.length) {
    return html`<div class="empty" style="padding:28px;width:100%">No signal samples yet</div>`;
  }
  const pad = { l: 38, r: 74, t: 10, b: 24 };
  const w = width - pad.l - pad.r;
  const h = height - pad.t - pad.b;
  const min = -113;
  const max = -51;
  const t0 = new Date(samples[0].t).getTime();
  const t1 = Math.max(t0 + 60_000, new Date(samples[samples.length - 1].t).getTime());
  const x = (t) => pad.l + ((new Date(t).getTime() - t0) / (t1 - t0)) * w;
  const y = (dbm) => pad.t + (1 - (Math.min(max, Math.max(min, dbm)) - min) / (max - min)) * h;
  const id = `sig${++uid}`;

  const segments = [];
  let current = [];
  for (const s of samples) {
    if (s.dbm === null) {
      if (current.length) segments.push(current);
      current = [];
    } else current.push([x(s.t), y(s.dbm)]);
  }
  if (current.length) segments.push(current);

  const lines = segments
    .map((seg) => {
      const d = smoothPath(seg);
      const area = seg.length > 1 ? `<path d="${d}L${seg.at(-1)[0].toFixed(1)},${pad.t + h}L${seg[0][0].toFixed(1)},${pad.t + h}Z" fill="url(#${id})"/>` : '';
      return `${area}<path class="line" d="${d}"/>`;
    })
    .join('');

  const bands = BANDS.map(([top, bottom, label], i) => {
    const y0 = y(top);
    const y1 = y(bottom);
    return `${i % 2 ? `<rect class="band" x="${pad.l}" y="${y0.toFixed(1)}" width="${w}" height="${(y1 - y0).toFixed(1)}"/>` : ''}<text class="band-label" x="${pad.l + w + 12}" y="${((y0 + y1) / 2 + 3).toFixed(1)}">${label}</text>`;
  }).join('');

  const grid = [-51, -73, -83, -93, -113]
    .map((v) => `<line class="${v === min ? 'base-line' : 'grid-line'}" x1="${pad.l}" x2="${pad.l + w}" y1="${y(v)}" y2="${y(v)}"/><text class="axis-label" x="${pad.l - 8}" y="${y(v) + 3}" text-anchor="end">${v}</text>`)
    .join('');

  const fmt = (t) => new Date(t).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  const last = segments.at(-1)?.at(-1);
  return html`<svg class="chart" viewBox="0 0 ${width} ${height}" role="img" aria-label="Signal strength over time">
    <defs><linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" class="stop-a"/><stop offset="1" class="stop-b"/></linearGradient></defs>
    ${raw(bands)}${raw(grid)}${raw(lines)}
    ${last ? raw(`<circle class="ping" cx="${last[0]}" cy="${last[1]}" r="4"/><circle class="last" cx="${last[0]}" cy="${last[1]}" r="4.5"/>`) : ''}
    <text class="axis-label" x="${pad.l}" y="${height - 5}">${fmt(t0)}</text>
    <text class="axis-label" x="${pad.l + w / 2}" y="${height - 5}" text-anchor="middle">${fmt((t0 + t1) / 2)}</text>
    <text class="axis-label" x="${pad.l + w}" y="${height - 5}" text-anchor="end">${fmt(t1)}</text>
  </svg>`;
}
