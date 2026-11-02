// Tiny global store + pub/sub. Server-sent events are re-published here under their own names.

export const state = {
  me: null,
  scopes: new Set(),
  modem: null,
  canOperate: false,
  reason: null,
  call: null,
  /** Latest USSD session started from the dashboard or pushed by the network (API sessions are ignored). */
  ussd: null,
  unread: 0,
  simulator: false,
};

const listeners = new Map();

export function subscribe(event, fn) {
  if (!listeners.has(event)) listeners.set(event, new Set());
  listeners.get(event).add(fn);
  return () => listeners.get(event)?.delete(fn);
}

/** Subscribes to several events with one handler; returns a single unsubscribe. */
export function subscribeAll(events, fn) {
  const offs = events.map((e) => subscribe(e, fn));
  return () => offs.forEach((off) => off());
}

export function publish(event, data) {
  for (const fn of listeners.get(event) ?? []) {
    try {
      fn(data, event);
    } catch (err) {
      console.error(`Listener for ${event} failed`, err);
    }
  }
}

export const can = (scope) => state.scopes.has(scope);

export const ACTIVE_CALL = new Set(['dialing', 'ringing', 'active']);
export const ACTIVE_USSD = new Set(['pending', 'open']);
