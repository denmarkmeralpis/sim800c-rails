# sim800c-rails — design

Port of `sms-gateway` (Node.js/TypeScript SMS, voice call and USSD gateway for the SIMCom
SIM800C) to a Ruby gem that ships a mountable Rails engine. Same features, same REST API shapes,
same dashboard, same resilience behaviour.

## Decisions (brainstorming outcome)

| Question | Decision |
|---|---|
| Dashboard auth | Built-in accounts only (admin / operator / viewer, setup page, login, scoped API keys), exactly as in sms-gateway. |
| Where the modem runs | A dedicated **runtime process** (`bin/rails sim800c:run`, or `plugin :sim800c` in `config/puma.rb`, which forks and supervises it). |
| Gem | `sim800c-rails`, namespace `Sim800c`, `mount Sim800c::Engine => "/sms-gateway"`. |
| Rails / Ruby | Rails >= 7.2 (non-sticky Active Record connections), Ruby >= 3.2 (`Queue#pop(timeout:)`, `IO#timeout`). |
| Database | Host app's Active Record database (any adapter). Tables prefixed `sim800c_`, migrations installed with `sim800c:install:migrations`. |
| Serial I/O | No native gem: `File::RDWR | NOCTTY | NONBLOCK` + `flock` (exclusive, like node-serialport) + `stty` run against the open descriptor. Linux and macOS. |
| Live events | Server-Sent Events, same URL and payloads. Streams are handed off with a full Rack hijack, so an open dashboard never holds a Puma thread. |

## Why a separate runtime process

The Node app is one process that owns the serial port, is the only DB writer, and keeps the call
and USSD state machines in memory. A Rails app runs many processes (Puma workers, console, rake,
job workers) and only one of them may open the serial port. So:

```
 Browser / API ──HTTP──▶ Rails (any number of processes)
                          │  Sim800c::Engine controllers
                          │   ├─ reads & simple writes ──────────────▶ DB (sim800c_* tables)
                          │   └─ live ops, status, SSE ──RPC socket──┐
                          │                                          ▼
                          │                    sim800c runtime (exactly one process)
                          │                      Reactor (1 thread, fibers)
                          │                        ModemManager ─ Modem ─ AT::Client ─ Transport
                          │                        SmsService · CallService · UssdService
                          │                        EventLog · Webhooks · RPC server · EventBus
                          └──────────────────────────────────────────────▶ DB
```

* **Web processes** do everything that is a plain database operation: queue SMS (with
  `Idempotency-Key`), list / read / delete / retry / cancel, call and USSD history, users, API keys,
  sessions. After a write they send a best-effort `notify` RPC so the runtime broadcasts the
  matching events (`sms.updated`, `sms.deleted`, …) and wakes the SMS worker. A message queued while
  the runtime is down is still stored and goes out when it starts (the worker also polls every
  `sms.queue_poll_interval`).
* **The runtime** owns everything that needs the modem or in-memory state: the SMS send worker,
  inbox import, delivery reports, call control and supervision, USSD sessions, status polling,
  watchdog / reconnect, the AT console, the simulator, webhooks and the event stream.
* **RPC**: newline-delimited JSON over a Unix socket (default `tmp/sockets/sim800c.sock`, mode
  0600) or TCP (`tcp://host:port`, for a runtime in another container). Every request carries a
  token derived from `secret_key_base`, so processes of the same app agree on it with no setup.
  Operations are an allow-list. Errors travel as `{status, code, message}` and are re-raised as the
  same API errors.
* A runtime that is not running surfaces as `503 modem_unavailable` ("Gateway runtime is not
  running") for live operations, and as an offline modem status in `/status` and the dashboard.

## Concurrency model: a reactor instead of threads + locks

The Node code relies on the event loop: state is only touched between `await`s, and code re-checks
state after each `await` (`if (this.current === call)`). Porting that to threads + mutexes invites
deadlocks (a URC handler that sends an AT command while the reader thread is the only one that can
deliver the reply). Instead the runtime runs on `Sim800c::Reactor`:

* one thread, a job queue (`Thread::Queue`) and a timer heap;
* every unit of work runs in a plain `Fiber` (no `Fiber.scheduler`, so database calls block the
  reactor exactly like better-sqlite3 blocks Node's loop, and cannot interleave inside a query or
  transaction);
* `reactor.await(promise)` suspends the current fiber; the promise's settlement posts a resume job.
  `await` raises if a database transaction is open, so a fiber can never yield inside one;
* `after` / `every` (= `setTimeout` / `setInterval`), `sleep`, `defer` (run blocking work such as a
  TCP connect on a helper thread), `call` (run a block on the reactor from another thread and wait
  for its result — used by the RPC server);
* serial / TCP transports read and write on their own threads and post bytes to the reactor.

This keeps a 1:1 correspondence with the original's control flow, which is the main defence against
porting mistakes.

Active Record: with Rails >= 7.2 model queries check a connection out only for the duration of the
query (or transaction), so fibers on the reactor thread never hold a connection while suspended.
The reactor also releases any leftover lease after each job.

## Components (bottom-up, mirroring sms-gateway)

| sms-gateway | sim800c-rails |
|---|---|
| `modem/transport/*` | `Sim800c::Transport::{Serial,Tcp,Simulator}` (simulator speaks AT on the reactor) |
| `modem/at/*` | `Sim800c::AT::Client`, `Sim800c::AT::CommandError` (+ CME/CMS tables) |
| `modem/pdu/*` | `Sim800c::PDU`, `Sim800c::PDU::GSM7` |
| `modem/sim800c.ts` | `Sim800c::Modem` (typed operations, URC → events) |
| `modem/manager.ts` | `Sim800c::ModemManager` |
| `modem/bridge.ts` + CLI | `Sim800c::Bridge` + `exe/sim800c-bridge` |
| `services/*` | runtime: `Sim800c::Runtime::{SmsService,CallService,UssdService,EventLog,Webhooks}`; shared DB logic in models |
| `context.ts` | `Sim800c::Runtime` |
| `http/*` | `Sim800c::Api::*Controller`, `Sim800c::DashboardController`, `Sim800c::Web::EventHub` (SSE) |
| `db/migrations.ts` | `db/migrate/*_create_sim800c_tables.rb` |
| `public/` | `public/` served by the engine (`ActionDispatch::Static` in the engine's middleware), `index.html` rendered with the mount path |
| CLI `ports`, `reset-password` | `bin/rails sim800c:ports`, `bin/rails "sim800c:reset_password[user,pass]"` |
| CLI `backup` | dropped: the host app owns its database and its backups |

## Behaviour kept identical

REST paths (`/api/auth/*`, `/api/v1/*`, `/healthz`, relative to the mount point), status codes,
error envelope `{"error": {code, message, details}}`, record JSON shapes (camelCase, ISO-8601
timestamps with milliseconds), scopes and roles, CSRF via `X-CSRF-Token`, API key format
`smsgw_…`, rate limits (API keys 120/min, sign-in 10 failures / 15 min), Idempotency-Key semantics,
SSE event names and scopes, webhook payloads / HMAC signature / retry schedule, simulator magic
numbers, password hash format (`scrypt$N$r$p$salt$hash`, so sms-gateway users can be migrated).

## Deliberate differences

* Configuration is `Sim800c.configure` (initializer), durations in seconds; the generated
  initializer reads `SIM800C_*` environment variables.
* `TRUST_PROXY` / `COOKIE_SECURE` come from the host app (`trusted_proxies`, `request.ssl?`);
  `cookie_secure` can still be forced.
* The session cookie is `sim800c_session`, scoped to the mount path.
* `/healthz` also reports `runtime: "running" | "offline"`.
* Windows serial ports are not supported (use the TCP bridge with a Windows serial-to-TCP tool).

## Testing

Minitest with a dummy Rails app on SQLite (file database, WAL). Ports of every sms-gateway suite:
PDU codec, AT client (scripted fake transport), end-to-end flows against the simulator at 20×
speed through the real runtime, serial bridge over TCP, webhooks against a local HTTP receiver, the
HTTP API through the full stack (integration tests + RPC to an in-process runtime), SSE through a
real Puma server (hijack path), first-time setup, plus reactor, RPC and serial (`stty` on a PTY)
unit tests.
