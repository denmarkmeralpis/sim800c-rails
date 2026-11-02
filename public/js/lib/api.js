let csrfToken = null;

/** Where the gateway is mounted in the Rails app (e.g. "/sms-gateway"), from the page's meta tag. */
export const BASE = document.querySelector('meta[name="sim800c-base"]')?.content ?? '';

export function setCsrf(token) {
  csrfToken = token;
}

export class ApiError extends Error {
  constructor(status, code, message, details) {
    super(message);
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

/**
 * Calls the gateway API. Paths without an /api prefix are relative to /api/v1; all are relative to BASE.
 * Session cookies are sent automatically; mutating requests carry the CSRF token.
 * `headers` adds request headers, e.g. Idempotency-Key.
 */
export async function api(path, { method = 'GET', body, query, headers: extraHeaders } = {}) {
  const route = path.startsWith('/api') ? path : `/api/v1${path}`;
  let url = BASE + route;
  if (query) {
    const qs = new URLSearchParams();
    for (const [k, v] of Object.entries(query)) if (v !== undefined && v !== null && v !== '') qs.set(k, v);
    const s = qs.toString();
    if (s) url += `?${s}`;
  }
  const headers = { accept: 'application/json', ...extraHeaders };
  if (body !== undefined) headers['content-type'] = 'application/json';
  if (method !== 'GET' && csrfToken) headers['x-csrf-token'] = csrfToken;

  let res;
  try {
    res = await fetch(url, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      credentials: 'same-origin',
    });
  } catch {
    throw new ApiError(0, 'network_error', 'Cannot reach the gateway server');
  }
  if (res.status === 204) return null;
  const data = await res.json().catch(() => null);
  if (!res.ok) {
    const e = data?.error ?? {};
    if (res.status === 401 && !route.startsWith('/api/auth/')) window.dispatchEvent(new CustomEvent('auth:expired'));
    throw new ApiError(res.status, e.code ?? 'error', e.message ?? `Request failed (${res.status})`, e.details);
  }
  return data;
}
