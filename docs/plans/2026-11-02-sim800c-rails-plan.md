# sim800c-rails — implementation plan

Design: [2026-11-02-sim800c-rails-design.md](2026-11-02-sim800c-rails-design.md). Each task is
test-first: port / write the tests, see them fail, implement, see them pass. Run the whole suite
before moving to the next phase.

## Phase 1 — scaffold

1. Gemspec (`sim800c-rails`, Ruby >= 3.2, railties / activerecord / actionpack >= 7.2), Gemfile
   (sqlite3, puma, minitest), Rakefile (`rake test`), `.gitignore`, `lib/sim800c-rails.rb`,
   `lib/sim800c.rb`, `lib/sim800c/version.rb`.
2. Dummy app `test/dummy` (SQLite file DB) and `test/test_helper.rb` (migrate engine schema,
   truncate `sim800c_*` tables between tests, `wait_for` helper).

## Phase 2 — core library (no Rails)

3. `Sim800c::Emitter`, `Sim800c::Promise`, `Sim800c::Reactor` — tests: ordering, timers,
   cancellation, await / nested tasks, `call` from another thread, `defer`, errors, stop.
4. `Sim800c::PDU::GSM7`, `Sim800c::PDU` — port `pdu.test.ts`.
5. `Sim800c::AT::Errors`, `Sim800c::AT::Client` — port `at-client.test.ts` with a FakeTransport.
6. `Sim800c::Phone` — normalisers and `phones_match`.
7. `Sim800c::Modem` (driver + URC parsing, `parse_cusd`, `parse_clcc`, signal / registration).
8. `Sim800c::Transport::Base`, `::Simulator` (port), `::Tcp`, `::Serial` (PTY test for the
   `stty` configuration), `Sim800c::Bridge`.
9. `Sim800c::ModemManager`.
10. `Sim800c::Configuration` (+ validation errors like `loadConfig`).

## Phase 3 — persistence

11. Migration `db/migrate/20261102000001_create_sim800c_tables.rb` (explicit short index names,
    JSON columns, FKs).
12. Models with API serialisation (`#as_api`): `User`, `Session`, `ApiKey`, `SmsMessage`,
    `SmsFragment`, `Call`, `UssdSession`, `EventLogEntry`, `IdempotencyKey`; shared domain logic
    (SMS enqueue with idempotency, retry / cancel / retry-failed / mark-read / delete, stats, list
    filters, call and USSD history, auth: scrypt passwords, sessions, API keys, roles).

## Phase 4 — runtime

13. `Sim800c::Runtime::EventLog`, `::Webhooks`, `::SmsService`, `::CallService`,
    `::UssdService`; `Sim800c::Runtime` composition root (start / stop order, single-instance lock,
    hourly pruning).
14. Port `gateway.test.ts` (connection, SMS, calls, USSD) against the runtime + simulator.
15. Port `bridge.test.ts` and `webhook.test.ts`.

## Phase 5 — RPC

16. `Sim800c::RPC::Server` / `::Client` (token, allow-listed ops, subscribe stream, per-op
    timeouts, stale socket handling), `Sim800c::Runtime::Operations`, `Sim800c::Gateway` (web-side
    facade, `notify`, offline status). Tests: round trip, auth failure, errors, subscribe.

## Phase 6 — engine / HTTP

17. Engine (`isolate_namespace`, static middleware for `public/`, rake tasks, install
    generator), routes.
18. `Sim800c::ApiController` base: JSON body parsing (100 kB, `invalid_json`), error envelope,
    authentication (API key / session cookie + CSRF), scopes, `require_session`, rate limiting,
    validation helpers.
19. Controllers: auth, status, sms, calls, ussd, modem, admin (keys, users), simulator, events
    (SSE via `Sim800c::Web::EventHub`, hijack + streaming fallback), health, dashboard, API 404.
20. Port `api.test.ts` and `setup.test.ts` as integration tests; SSE test through a real Puma.

## Phase 7 — dashboard, packaging, docs

21. Copy `public/` (css, js, fonts); make `api.js`, `events.js`, `settings.js` and `index.html`
    mount-path aware.
22. Puma plugin `lib/puma/plugin/sim800c.rb`; `exe/sim800c-bridge`.
23. README (install, configure, run, API, webhooks, hardware, deployment, troubleshooting),
    CHANGELOG, CI workflow.
24. Final verification: full suite, `gem build`, install into a fresh Rails app, boot the runtime
    with the simulator, exercise the API and dashboard over HTTP; independent code review.
