# sim800c-rails

An SMS, voice call and USSD gateway for the **SIMCom SIM800C** GSM module, packaged as a Ruby gem
with a mountable Rails engine: a REST API, Server-Sent Events, signed webhooks and a web dashboard,
inside your Rails app.

- **SMS:** send from the dashboard or the API (queued, sent in the background, retried on
  transient errors, safe to retry with `Idempotency-Key`). Receive into a real-time inbox. Long
  (multipart) messages, Unicode and emoji, delivery reports.
- **Calls:** dial, hang up, answer, reject, DTMF, live call progress and call history.
- **USSD:** dial codes like `*123#`, navigate operator menus, keep the history.
- **Monitoring:** connection state, SIM, network registration, operator, signal history, supply
  voltage, SIM storage, a persistent event log, and an AT console for admins.
- **Resilience:** automatic reconnect with backoff when the modem is unplugged, reboots or stops
  responding. Messages wait in the queue while the network (or the gateway) is down.
- **Access control:** dashboard accounts with roles (admin / operator / viewer), scoped API keys,
  CSRF protection and rate limiting.
- **Built-in SIM800C simulator** to develop and test without hardware.

It is a port of the Node.js [sms-gateway](https://github.com/denmarkmeralpis/sms-gateway): same
API paths, payloads, status codes, webhooks and dashboard.

---

## Contents

1. [Requirements](#requirements)
2. [Installation](#installation)
3. [Running the gateway](#running-the-gateway)
4. [Configuration](#configuration)
5. [REST API](#rest-api)
6. [Webhooks](#webhooks)
7. [How it works](#how-it-works)
8. [Hardware setup](#hardware-setup)
9. [Deployment](#deployment)
10. [Development](#development)
11. [Troubleshooting](#troubleshooting)

---

## Requirements

- Ruby 3.2+ and Rails 7.2+ (tested with Ruby 4.0 and Rails 8.1).
- Any Active Record database (SQLite, PostgreSQL, MySQL).
- For a modem on a serial port: Linux or macOS with `stty` (part of coreutils). Windows serial
  ports are not supported directly; use the [TCP bridge](#reaching-the-modem) from a machine that
  has the modem.

## Installation

```ruby
# Gemfile
gem "sim800c-rails"
```

```bash
bundle install
bin/rails generate sim800c:install      # initializer, route, migrations
bin/rails db:migrate
```

The generator mounts the engine at `/sms-gateway` (change it with `--mount-path=/somewhere`):

```ruby
# config/routes.rb
mount Sim800c::Engine => "/sms-gateway"
```

## Running the gateway

Only one process may own the serial port, so the modem is driven by a separate **runtime**
process. Your web processes (any number of Puma workers, console, jobs…) store and read data
directly and talk to the runtime over a local socket for live operations.

Start the runtime one of two ways:

```ruby
# config/puma.rb — Puma starts the runtime after booting and restarts it if it crashes
plugin :sim800c
```

```bash
# or as its own process (Procfile, systemd, a second container...)
bin/rails sim800c:run
```

Then open `/sms-gateway`. On the first visit a setup page asks you to create the admin account.
To skip it, set `SIM800C_ADMIN_PASSWORD` (and optionally `SIM800C_ADMIN_USERNAME`) before the
first start.

**Without hardware:** `SIM800C_MODEM_DRIVER=mock` (the default outside production) runs the
built-in simulator. The Modem page then has controls to inject incoming SMS and calls, change the
signal and registration, pull the SIM, "unplug" the USB cable, freeze or reboot the modem.

**With a SIM800C:**

```bash
bin/rails sim800c:ports                  # find the serial device
SIM800C_MODEM_DRIVER=serial SIM800C_SERIAL_PORT=/dev/ttyUSB0 bin/rails sim800c:run
```

If the runtime is not running, the dashboard shows the modem as offline, live operations answer
`503 modem_unavailable`, and SMS can still be queued: they are sent once the runtime starts.

## Configuration

`config/initializers/sim800c.rb` (created by the generator) reads `SIM800C_*` environment
variables. Durations are in seconds. The most important settings:

| Setting | Env | Default | Purpose |
|---|---|---|---|
| `modem.driver` | `SIM800C_MODEM_DRIVER` | `serial` in production, else `mock` | `:serial`, `:tcp` (serial bridge) or `:mock` (simulator) |
| `modem.serial_port` | `SIM800C_SERIAL_PORT` | — | Serial device, required for `:serial` |
| `modem.baud_rate` | `SIM800C_BAUD_RATE` | `115200` | The SIM800C auto-bauds; 9600 and 115200 both work |
| `modem.tcp_host` / `tcp_port` | `SIM800C_MODEM_TCP_HOST` / `_PORT` | — / `7070` | The serial bridge, for `:tcp` |
| `modem.sim_pin` | `SIM800C_SIM_PIN` | — | Tried once only, so a wrong PIN cannot lock the SIM |
| `sms.delivery_reports` | `SIM800C_SMS_DELIVERY_REPORTS` | `true` | Request delivery reports (sent → delivered) |
| `sms.max_attempts` | `SIM800C_SMS_MAX_ATTEMPTS` | `3` | Attempts for transient send errors (exponential backoff) |
| `sms.max_parts` | `SIM800C_SMS_MAX_PARTS` | `6` | Longest message accepted, in SMS parts |
| `calls.ussd_timeout` | `SIM800C_USSD_TIMEOUT` | `30` | Give up on a USSD code the network does not answer |
| `auth.admin_password` | `SIM800C_ADMIN_PASSWORD` | — | Initial admin, first start only; skips the setup page |
| `auth.api_rate_limit_per_min` | `SIM800C_API_RATE_LIMIT_PER_MIN` | `120` | Per API key |
| `webhook.url` / `secret` / `events` | `SIM800C_WEBHOOK_*` | — | See [Webhooks](#webhooks) |
| `rpc.url` | `SIM800C_RPC_URL` | `tmp/sockets/sim800c.sock` | How web processes reach the runtime: `unix:///path` or `tcp://host:port` |

The initializer lists every setting with a comment. `Sim800c.config.validate!` runs when the
runtime starts and reports every invalid setting at once.

Other behaviour worth knowing:

- **Database:** the engine's tables are prefixed `sim800c_`. Timestamps use the app's time zone
  for "today" counters.
- **Rate limits** (API keys and failed sign-ins) are counted in `Rails.cache`, so they are shared
  by all web processes when the cache is (Redis, Solid Cache…). With the null store, each process
  counts on its own. Override with `config.auth.rate_limit_store`.
- **Cookies:** the dashboard session cookie (`sim800c_session`) is `HttpOnly`, `SameSite=Strict`,
  scoped to the mount path, and `Secure` on HTTPS requests (force with `config.auth.cookie_secure`).
  Client IPs come from Rails' `request.remote_ip`, so configure `config.action_dispatch.trusted_proxies`
  behind a proxy.
- **RPC token:** derived from `secret_key_base`, so every process of the app agrees on it. Set
  `config.rpc.token` if the runtime runs with a different secret.

## REST API

Base URL: `https://<your app><mount path>/api/v1`, e.g. `https://example.com/sms-gateway/api/v1`.
All bodies and responses are JSON.

### Authentication

Create an API key under **Settings → API keys** (admins only) and choose its scopes. The key is
shown once. Send it with every request:

```
X-API-Key: smsgw_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
# or
Authorization: Bearer smsgw_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

| Scope | Allows |
|---|---|
| `sms:read` | List and read messages, mark read/unread |
| `sms:send` | Send, retry and cancel messages |
| `sms:delete` | Delete messages |
| `calls:read` | Call and USSD history, the current call and the latest USSD session |
| `calls:write` | Dial, answer, reject, hang up, DTMF, USSD, delete history |
| `modem:read` | Modem status, signal history, event log |
| `modem:write` | Reconnect or restart the modem |

User and key management and the AT console are dashboard-only (admin role). Responses to API keys
carry `RateLimit` and `RateLimit-Policy` headers.

Errors always look like:

```json
{ "error": { "code": "validation_error", "message": "to: At least one recipient is required", "details": [ ... ] } }
```

| Status | Meaning |
|---|---|
| 400 | Invalid input (`validation_error`, `bad_request`, `invalid_json`) |
| 401 | Missing, invalid or revoked API key |
| 403 | Key lacks the required scope (`forbidden`), or a missing CSRF token (`csrf_failed`) |
| 404 | Not found |
| 409 | Conflict, e.g. a call already in progress, or an `Idempotency-Key` reused for a different request (`idempotency_key_reused`) |
| 413 | Body larger than 100 kB |
| 429 | Rate limited |
| 502 / 503 | Modem rejected the command / modem or runtime unavailable (`modem_unavailable`, `modem_error`, `call_failed`, `ussd_failed`) |

### Send SMS

```bash
curl -X POST https://example.com/sms-gateway/api/v1/sms \
  -H "X-API-Key: $KEY" -H "Content-Type: application/json" \
  -d '{"to": ["+639171234567", "09181234567"], "message": "Your order has shipped 📦", "priority": 5}'
```

- `to`: a string (comma, semicolon or newline separated) or an array, up to 100 recipients
- `message`: up to 5000 characters, limited further by `sms.max_parts`
- `priority`: optional, 0–10 (higher is sent first)

Returns **202 Accepted** with one record per recipient; sending happens in the background:

```json
{ "data": [ { "id": 42, "direction": "outbound", "phone": "+639171234567", "status": "queued",
              "encoding": "ucs2", "parts": 1, "attempts": 0, "error": null, "createdAt": "…" } ] }
```

Status flow: `queued → sending → sent → delivered`, or `failed` (with `error`), or `cancelled`.
Follow it by polling `GET /sms/:id`, through the event stream, or with webhooks.

To retry safely after a timeout, send an `Idempotency-Key` header (1–255 visible ASCII
characters). Repeating the same request with the same key within 24 hours sends nothing new: it
returns **202** with the original records, in their current state, and `Idempotent-Replayed: true`.
Reusing the key for a different request returns **409** `idempotency_key_reused`. Keys are separate
for each API key and dashboard user, and a request that fails validation does not use up its key.

### USSD

```bash
curl -X POST https://example.com/sms-gateway/api/v1/ussd \
  -H "X-API-Key: $KEY" -H "Content-Type: application/json" -d '{"code": "*123#"}'
```

The response arrives once the network answers (or after `calls.ussd_timeout`). `status` is
`completed`, `failed` (with `error`), or `open` when the network shows a menu: answer it with
`POST /ussd/reply {"text": "1"}` or close it with `POST /ussd/cancel`. One session runs at a time,
and dialing a new code closes an open menu. Every session, including messages the network pushes
on its own (`code: null`, `source: "modem"`), is kept in the history.

### Endpoints

| Method | Path | Scope | Description |
|---|---|---|---|
| `POST` | `/sms` | sms:send | Queue SMS to one or more recipients |
| `GET` | `/sms` | sms:read | List: `direction`, `status`, `phone`, `q`, `unread=true`, `page`, `limit` (≤200) |
| `GET` | `/sms/:id` | sms:read | One message |
| `POST` | `/sms/read` | sms:read | `{"ids": [1,2], "read": true}` |
| `POST` | `/sms/delete` | sms:delete | `{"ids": [1,2,3]}` → `{"deleted": [...]}` |
| `DELETE` | `/sms/:id` | sms:delete | Delete one message |
| `POST` | `/sms/:id/retry` | sms:send | Re-queue a failed or cancelled message |
| `POST` | `/sms/retry-failed` | sms:send | Re-queue every failed message → `{"retried": [...]}` |
| `POST` | `/sms/:id/cancel` | sms:send | Cancel a queued message |
| `POST` | `/calls` | calls:write | `{"number": "+639171234567"}`, returns 202 with the call record |
| `GET` | `/calls/active` | calls:read | Current call or `null` |
| `POST` | `/calls/hangup` | calls:write | End the current call |
| `POST` | `/calls/answer` | calls:write | Answer an incoming call |
| `POST` | `/calls/reject` | calls:write | Reject an incoming call |
| `POST` | `/calls/dtmf` | calls:write | `{"digits": "123#"}` during an active call |
| `GET` | `/calls` | calls:read | History: `direction`, `status`, `q`, `page`, `limit` |
| `GET` | `/calls/:id` | calls:read | One call |
| `POST` | `/calls/delete` | calls:write | `{"ids": [...]}` |
| `DELETE` | `/calls/:id` | calls:write | Delete one record |
| `POST` | `/ussd` | calls:write | `{"code": "*123#"}`, returns the session once the network answers |
| `POST` | `/ussd/reply` | calls:write | `{"text": "1"}` to answer an open menu |
| `POST` | `/ussd/cancel` | calls:write | Close the open menu |
| `GET` | `/ussd` | calls:read | Latest USSD session or `null` |
| `GET` | `/ussd/sessions` | calls:read | History: `status`, `source`, `q`, `page`, `limit` |
| `GET` | `/ussd/sessions/:id` | calls:read | One session with its messages |
| `POST` | `/ussd/sessions/delete` | calls:write | `{"ids": [...]}` (409 if one is still in progress) |
| `DELETE` | `/ussd/sessions/:id` | calls:write | Delete one session |
| `GET` | `/status` | modem:read | Modem status, current call, SMS/call counters |
| `GET` | `/modem` | modem:read | Modem, SIM, network, signal, power and storage |
| `GET` | `/modem/signal` | modem:read | Signal samples (last hour) |
| `GET` | `/modem/events` | modem:read | Event log: `level`, `category`, `limit`, `before` |
| `POST` | `/modem/refresh` | modem:read | Poll the modem now |
| `POST` | `/modem/reconnect` | modem:write | Drop and re-open the serial link |
| `POST` | `/modem/restart` | modem:write | Reboot the SIM800C (`AT+CFUN=1,1`) |
| `GET` | `/events` | any read scope | Server-Sent Events stream |
| `GET` | `/healthz` (no `/api/v1`) | none | `{"ok":true,"modem":"ready","runtime":"running"}` |

Call statuses: `dialing`, `ringing`, `active`, then `completed`, `missed`, `rejected`, `busy`,
`no_answer`, `cancelled` or `failed`, with `endReason` and `duration` (seconds).

### Event stream (SSE)

`GET /api/v1/events` keeps a connection open and pushes `modem.status`, `sms.received`,
`sms.updated`, `sms.deleted`, `call.updated`, `call.incoming`, `call.deleted`, `ussd.updated`
and `log.entry`, filtered by your scopes.

```bash
curl -N https://example.com/sms-gateway/api/v1/events -H "X-API-Key: $KEY"
```

Open streams are handed off from the web server (a Rack hijack, supported by Puma, Unicorn and
Passenger), so they do not occupy request threads. Proxies must not buffer the response; the
stream sends `X-Accel-Buffering: no` for nginx.

## Webhooks

Set `SIM800C_WEBHOOK_URL` to receive a `POST` for `sms.received`, `sms.status`, `call.incoming`,
`call.ended` and `ussd.ended`. Restrict the list with `SIM800C_WEBHOOK_EVENTS`. Failed deliveries
are retried after 2 s, 10 s and 30 s (a 4xx other than 429 is not retried).

```json
{ "event": "sms.received", "timestamp": "2026-10-30T08:15:30.000Z", "data": { "id": 51, "phone": "+639175551234", "body": "Hi!" } }
```

With `SIM800C_WEBHOOK_SECRET`, each request carries
`X-Webhook-Signature: sha256=<hex HMAC-SHA256 of the raw body>`:

```ruby
expected = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, request.raw_post)}"
ActiveSupport::SecurityUtils.secure_compare(expected, request.headers["X-Webhook-Signature"].to_s)
```

## How it works

```
 Browser / API ──HTTP──▶ Rails (any number of processes)
                          │  Sim800c::Engine: dashboard + REST API + SSE
                          │   ├── queries, queueing, history, accounts ─────────▶ DB (sim800c_*)
                          │   └── live operations, status, events ──RPC socket──┐
                          │                                                     ▼
                          │                         sim800c runtime (exactly one process)
                          │                           Reactor ── one thread, fibers
                          │                             SmsService · CallService · UssdService
                          │                             EventLog · Webhooks · RPC server
                          │                             ModemManager ── connect / poll / watchdog / reconnect
                          │                             Modem        ── typed operations, URC → events
                          │                             AT::Client   ── one command at a time, '>' prompt, URCs
                          │                             Transport    ── serial | TCP bridge | simulator
                          └─────────────────────────────────────────────────────────▶ DB
```

- **Runtime.** The modem stack runs on a single-threaded reactor: each piece of work is a fiber
  that suspends while it waits for the modem, much like `async`/`await` in Node. Serial and TCP
  I/O happen on their own threads, so a stalled device never blocks it.
- **AT engine:** serialises commands, matches responses by prefix, routes unsolicited result codes
  (`+CMTI`, `RING`, `+CUSD`…) even when they arrive mid-response, handles the `>` prompt for SMS
  submission, and maps `+CME/+CMS ERROR` codes to readable messages. Call control jumps the queue.
- **PDU mode:** SMS go out as PDUs in GSM-7 or UCS-2 with concatenation headers. Inbound PDUs
  are decoded (alphanumeric senders, multipart reassembly), stored, then deleted from the SIM;
  duplicates are discarded by PDU hash. Delivery reports are matched to each part.
- **Errors:** USB unplug and port errors reconnect with exponential backoff; three consecutive
  timeouts reset the link; modem reboots trigger re-initialisation. Permanent SMS errors fail
  immediately, transient ones retry with backoff, and multipart sends resume at the first unsent
  part. Messages interrupted by a crash are re-queued on restart.
- **Web processes** write to the database directly (e.g. queueing SMS) and send a notification
  over RPC so the runtime broadcasts the change and wakes the SMS worker. The runtime also polls
  the queue every `sms.queue_poll_interval` seconds.

## Hardware setup

| Item | Notes |
|---|---|
| **Network** | The SIM800C is **2G only (GSM 850/900/1800/1900)**. Check that your carrier still runs 2G where the gateway will be. |
| **Power** | 3.4–4.4 V able to deliver **2 A peaks**. Weak USB ports and thin cables cause `UNDER-VOLTAGE` warnings, resets and failed sends. The Modem page shows the supply voltage. |
| **Antenna** | Always connect one. Aim for RSSI ≥ 10 (≥ −93 dBm). |
| **SIM** | Mini-SIM. Disable the PIN lock, or set `SIM800C_SIM_PIN`. |
| **Serial link** | USB boards (CH340/CP2102) appear as `/dev/ttyUSB0` or `/dev/cu.usbserial-*`. TTL boards: modem TX→RX, RX→TX, GND→GND, 3.3 V logic. Some boards need `PWRKEY` held low for ~1 s to power on. |
| **Audio** | Call audio uses the module's MIC/SPK pins or a headset jack. The gateway controls signalling only. |

On Linux, the user running the runtime must be in the `dialout` group. The runtime takes an
exclusive lock on the serial device, so another program cannot use it at the same time.

## Deployment

- **Exactly one runtime per modem.** It refuses to start if another one holds its lock file
  (`tmp/pids/sim800c.lock`) or its socket.
- **Same machine / pod (default):** web processes reach the runtime through the Unix socket in
  `tmp/sockets` (mode 0600). With the Puma plugin there is nothing else to set up.
- **Runtime in its own container:** run `bin/rails sim800c:run` there and set `SIM800C_RPC_URL`
  to `tcp://0.0.0.0:7071` in the runtime and `tcp://<runtime host>:7071` in the web processes.
  Requests are authenticated with a token derived from `secret_key_base`, but are not encrypted:
  keep the port on a private network.
- **Shutdown:** the runtime stops gracefully on `INT` / `TERM` (forced after 10 s). Started by the
  Puma plugin, it also stops when Puma does, or when Puma goes away.
- **Puma plugin and phased restarts:** the plugin runs `bin/rails sim800c:run` as a separate process.
  A phased restart (`pumactl phased-restart`) does not restart it; restart Puma, or run the runtime
  as its own service, to load new code into it.
- **Health:** `GET <mount>/healthz` answers 200 while the web app runs and reports the runtime and
  modem state.

### Reaching the modem

| Modem plugged into | Settings |
|---|---|
| **The runtime's machine** | `SIM800C_MODEM_DRIVER=serial`, `SIM800C_SERIAL_PORT`. In Kubernetes, map the device into the pod (a stable `/dev/serial/by-id/...` path), pin the pod to the node and add the node's `dialout` gid as a supplemental group. |
| **Another machine** | Run the bridge there: `sim800c-bridge --port /dev/ttyUSB0 --host <lan address>` (installed with the gem). Set `SIM800C_MODEM_DRIVER=tcp`, `SIM800C_MODEM_TCP_HOST` and `SIM800C_MODEM_TCP_PORT` (default 7070). The bridge has no authentication: firewall it. |

Until the admin account exists, anyone who can reach the dashboard can create it on the setup
page. Finish setup before exposing the app, or set `SIM800C_ADMIN_PASSWORD`.

### Operations

```bash
bin/rails sim800c:ports                                   # list serial devices
bin/rails "sim800c:reset_password[admin,new-password]"    # also creates the admin if missing
```

Back up the `sim800c_*` tables with the rest of your database.

## Development

```bash
bundle install
bundle exec rake test        # unit, runtime end-to-end (simulator at 20x), RPC, HTTP API, SSE via Puma
```

The simulator reacts to special numbers:

| Destination | Behaviour |
|---|---|
| SMS to `…0000` | Fails permanently (`+CMS ERROR: 1`) |
| SMS to `…4444` | Sent, then the delivery report says *validity period expired* |
| Call to `…000` | Busy |
| Call to `…888` | Rejected by the remote party |
| Call to `…999` | Rings until no answer |
| Any other call | Answered after a few seconds |
| USSD `*123#` | Returns a balance |
| USSD `*143#` | Opens a menu: `1` balance, `2` promos |
| USSD `…999#` | Never answered (times out) |
| Any other USSD code | Not supported by the network |

`SIM800C_LOG_TRAFFIC=true` logs every AT command and response; the dashboard's **Modem → Show
serial traffic** shows the last 200 lines.

The modem stack also works without Rails: `require "sim800c/core"` gives you the reactor, AT
client, PDU codec, driver, connection manager and bridge.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| *Gateway runtime is not running* | Start it (`bin/rails sim800c:run` or `plugin :sim800c`). With separate containers, check `SIM800C_RPC_URL` on both sides. |
| *Modem did not respond to AT* | Wrong serial port, TX/RX swapped, modem not powered on (PWRKEY), or the wrong baud rate — try `SIM800C_BAUD_RATE=9600`. |
| *another program is using the serial port* | Another runtime, the bridge or a terminal program has the device open. |
| *Permission denied* opening the port | Add the user to `dialout` (Linux). On macOS use the `/dev/cu.*` device. |
| Resets, *UNDER-VOLTAGE* in the event log | The power supply cannot deliver 2 A peaks. |
| *Not registered* / *Searching* | No 2G coverage, antenna missing, or SIM not activated. |
| SMS stuck at *Sent* | The carrier does not return delivery reports. Set `SIM800C_SMS_DELIVERY_REPORTS=false`. |
| *SMSC address unknown* | Set the service centre once via the AT console: `AT+CSCA="+<smsc number>"`. |
| Dashboard not updating live | A proxy buffers `/api/v1/events`, or the web server does not support Rack hijack (then each open dashboard holds a request thread). |
| USSD *No reply from the network* | The operator did not answer within `calls.ussd_timeout`. |
