# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-11-02

Initial release: the features of sms-gateway 1.2.0 (plus *Retry all failed messages*) as a Ruby
gem with a mountable Rails engine.

### Added

- SMS: a persistent queue with priorities, retries with backoff for transient errors, delivery
  reports, multipart messages, Unicode and emoji, `Idempotency-Key` for safe retries, a
  real-time inbox with multipart reassembly, retry / cancel / retry-all / bulk delete.
- Voice calls: dial, answer, reject, hang up, DTMF, live progress and history.
- USSD: codes and operator menus, with history.
- Modem monitoring with automatic reconnect, watchdog and re-initialisation after reboots; event
  log; AT console for admins.
- REST API with the same paths, payloads and errors as sms-gateway, Server-Sent Events, signed
  webhooks.
- Dashboard accounts (admin / operator / viewer) with first-time setup, scoped API keys, CSRF
  protection and rate limiting.
- The web dashboard, served under the engine's mount path.
- A runtime process that owns the modem (`bin/rails sim800c:run` or `plugin :sim800c` for Puma),
  reached by web processes over an authenticated Unix or TCP socket.
- Serial, TCP (`sim800c-bridge`) and built-in simulator drivers.
- `sim800c:install` generator, `sim800c:ports` and `sim800c:reset_password` tasks.

[Unreleased]: https://github.com/denmarkmeralpis/sim800c-rails/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/denmarkmeralpis/sim800c-rails/releases/tag/v0.1.0
