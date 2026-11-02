import { api, BASE } from './api.js';
import { publish } from './store.js';

const EVENTS = [
  'hello',
  'modem.status',
  'log.entry',
  'sms.received',
  'sms.updated',
  'sms.deleted',
  'call.updated',
  'call.incoming',
  'call.deleted',
  'ussd.updated',
];

let source = null;
let retryTimer = null;
let stopped = true;

/** Opens the Server-Sent Events stream and republishes events on the store. */
export function connectEvents() {
  stopped = false;
  open();
}

export function disconnectEvents() {
  stopped = true;
  clearTimeout(retryTimer);
  source?.close();
  source = null;
}

function open() {
  source?.close();
  const es = new EventSource(`${BASE}/api/v1/events`);
  source = es;
  for (const name of EVENTS) {
    es.addEventListener(name, (e) => {
      try {
        publish(name, JSON.parse(e.data));
      } catch (err) {
        console.error('Bad event payload', name, err);
      }
    });
  }
  es.onopen = () => publish('sse.state', 'open');
  es.onerror = () => {
    publish('sse.state', 'reconnecting');
    // EventSource retries by itself unless the server answered with an error (e.g. 401).
    if (es.readyState === EventSource.CLOSED && !stopped) {
      clearTimeout(retryTimer);
      retryTimer = setTimeout(async () => {
        try {
          await api('/api/auth/me');
          if (!stopped) open();
        } catch (err) {
          if (err.status === 401) window.dispatchEvent(new CustomEvent('auth:expired'));
          else if (!stopped) open();
        }
      }, 5000);
    }
  };
}
