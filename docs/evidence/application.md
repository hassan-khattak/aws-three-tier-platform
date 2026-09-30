# Application verification

How the application checks are run and what they showed. Behavior being verified is defined in [the application contract](../contracts/application.md).

## Running the checks

Use Node `24.21.0` / npm `11.19.0` (see `.nvmrc`). From the repository root:

```bash
(cd api && npm ci --ignore-scripts && npm ls --omit=dev --all && npm test)
(cd web && npm ci --ignore-scripts && npm ls --omit=dev --all && npm test)
npm --prefix api run test:db   # real PostgreSQL + TLS; requires a running Docker daemon
bash scripts/check-local.sh    # everything above plus production images
```

## Installation and toolchain

Recorded 2026-09-30 on macOS ARM64 (Node 24.21.0 from the official archive, SHA256 `bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057` matched; Docker CLI 28.4.0).

| Check (each service) | Result |
| --- | --- |
| `npm ci --ignore-scripts` from lockfile | Passed; API 82 / web 173 packages (web 123 after the upstream client change below) |
| Second offline `npm ci` | Passed; lockfiles unchanged |
| `npm ls --omit=dev --all` | Exit 0 in both; optional `pg-native` intentionally absent |
| API `npm audit --omit=dev` | 0 findings |
| Web `npm audit --omit=dev` | 6 affected packages (2 low, 4 moderate); 2 low after removing Request below |

The initial audits reported API 15 affected packages (12 high) and web 33 (19 high, 6 critical). Targeted same-major updates and explicit transitive fixes removed all high/critical reports. Audit counts are snapshots, not a guarantee.

Lockfile SHA256 after the toolchain pin (web superseded below): `api/package-lock.json` `b04b2653b38ecb55e3f18da789c8804eaa2b9db664f0399d44936f842a35c082`, `web/package-lock.json` `e2943d2303f7d325478b62e7cd2c8a750b810c2c9890fdb5482846ccac62bfc3`.

## API database behavior

Recorded 2026-09-30, same host, Docker 28.4.0.

### Fixture

- [compose.test.yaml](../../compose.test.yaml): `postgres:16.15-bookworm@sha256:efedf3595f1d6f415c08568ba171029bf54052e754cc9f030e3f2412b21f3d67`, TLS on, `hostssl` SCRAM only (plaintext rejected), and a read-only non-owner role `assessment_app`. Credentials are disposable local values.
- [tests/helpers/tls-fixture.cjs](../../tests/helpers/tls-fixture.cjs) generates a per-run CA, a server certificate for `DNS:localhost`, and an unrelated CA in a private temp directory, removed afterwards.
- The script publishes the container on a free loopback port chosen per run. An ephemeral port mapping changes across `stop`/`start`, which would make the restart check test Docker rather than the API, so the script asserts the port is unchanged after restart.
- PostgreSQL 16 matches the intended managed engine major. Availability of the exact minor in the target cloud region has not been verified yet.

### Results

`npm --prefix api test`: 17 passed, 0 failed. Covers response schema and per-request UUID, sanitized 503/404, configuration validation (including production TLS enforcement and a sanitized launcher exit), one retry on transient errors only, no retry on auth/TLS/SQL errors, late acquisitions destroyed, stuck queries and client aborts discarding the connection, idle pool errors handled, and invalid results not fabricated. Web: 4 passed.

`npm --prefix api run test:db`: two consecutive clean runs, both exit 0. Second run:

| Check | Result |
| --- | --- |
| Fixture | PostgreSQL `16.15`; `pg_stat_ssl.ssl = true` |
| 20 concurrent `GET /api/status` | all 200, unique UUIDs, database time, max 46 ms; pool total 5, idle 5, waiting 0 |
| Untrusted CA | rejected (`TLS_ERROR`), no retry |
| Hostname mismatch (`127.0.0.1` vs `DNS:localhost`) | rejected (`TLS_ERROR`) |
| Wrong password | rejected (`AUTH_ERROR`) |
| Write through the app role | rejected |
| Pool exhausted (5 connections held) | `ACQUIRE_TIMEOUT` after 1001 ms, no waiters left; next read succeeds |
| Query slower than budget (`pg_sleep(3)`) | `QUERY_TIMEOUT` after 1023 ms; 0 active backends afterwards; next read succeeds |
| Database stopped | 3/3 requests 503 `DATABASE_UNAVAILABLE`, max 3 ms |
| Database restarted, API kept running | first 200 after 29 ms; 20 further concurrent requests 200; pool 5/5 idle, 0 waiting |
| Logs | no passwords or certificate paths; idle-error and 503 records present |
| Cleanup | compose project, volume and temp certificates removed |

### Limits

Measured against a single local container. Managed-database failover behavior must be measured separately on the deployed system.

## Web upstream handling

Recorded 2026-10-01, same host and toolchain.

### Dependencies

Removed `request`, `morgan`, `body-parser` and `cookie-parser`. `npm ci --offline --ignore-scripts` after deleting `node_modules`: 123 packages, `web/package-lock.json` SHA256 `9ff8a38ddf1a3a04ec58c295c312780f106a31b30d57e3cb3d413d62d1875ea3` unchanged. `npm ls --omit=dev --all` exit 0. Web audit: 2 low (`clean-css` via `jade`), raw snapshot in [web-audit.json](web-audit.json).

### Results

`npm --prefix web test`: 21 passed, 0 failed. `npm --prefix api test`: 17 passed.

| Area | Covered |
| --- | --- |
| Configuration | base URL normalization (`/api/status` appended once, optional prefix kept); rejects missing/invalid URL, non-HTTP scheme, credentials, query, fragment, trailing `/api`, bad `PORT`; launcher exits 1 with a sanitized record |
| Success | real Jade render shows API time and UUID; `Cache-Control: no-store`; `X-Request-ID`; one log record, query string not logged |
| 502 | empty array, object, `[null]`, non-JSON, wrong content type, missing/unparseable/numeric time, missing/non-UUID, oversized body (declared and chunked), 500, 404, 302 (redirect target never contacted) |
| 503 | API unreachable, API 503, no headers within the deadline, body stalled mid-stream; upstream socket closed after timeout |
| Deadline | unit budget 300 ms → failure between 280 and 600 ms; production launcher against a hung API → 503 after 5.17 s (bound 4.9–5.8 s) |
| Cancellation | caller abort and browser disconnect close the upstream socket; `request_aborted` logged |
| Error pages | 404/502/503 render the `error` template with fixed text; no internal address, port, raw error or stack |
| Static files | existing image and stylesheet served |

`npm --prefix api run test:db` with web added (PostgreSQL 16.15, TLS):

| Check | Result |
| --- | --- |
| Browser path web → API → PostgreSQL | 200 in 116 ms; page time within 10 s of now; page UUID equals the `request_id` the API logged for a successful `/api/status` DB read |
| Web page during database outage | 503 in 7 ms, API port not shown |
| Web page after database restart | 200 without restarting web or API |
| All earlier database checks | pass unchanged |
| Logs (web + API) | no fixture passwords or certificate paths |

### Limits

The internal load balancer, CDN and real network latency are not part of these local checks.

## Health, admission and shutdown

Recorded 2026-10-01, same host and toolchain.

### Unit and spawned-process tests

`npm --prefix api test`: 27 passed. `npm --prefix web test`: 26 passed.

| Area | Covered |
| --- | --- |
| Budgets | 60 s admission and 20 s shutdown asserted as defaults; timing tests use shorter injected budgets |
| Admission | listens only after the check succeeds (after 2 logged failures); exhausted budget exits 1 without listening and releases resources once, in 400 ms against a 400 ms budget; a hung check is cut off at the deadline; a signal during admission exits 0 without listening |
| Drain | in-flight request completes with `Connection: close`; new connections refused; resources closed once, after the response; repeated signal returns the same shutdown; idle keep-alive sockets do not delay exit |
| Forced exit | a request that never finishes → `shutdown_forced`, exit 1 at the budget (353 ms for 300 ms) |
| API health | liveness never queries; readiness 503/200 follows the database; draining 503 without a query |
| Web health | liveness never calls the API; readiness 503/200 follows the API; draining 503 |
| API launcher | with an unreachable database: logs `startup_waiting`, never listens, exits 0 on SIGTERM |
| Web launcher | waits while the API port is closed (no listen after 1.5 s), listens once the API answers, then serves the page; readiness 200 → 503 → 200 as the API fails and recovers with the same PID; SIGTERM during a 1.5 s upstream call → page 200, new connection refused, exit 0 after 1.69 s |
| Module drift | `web/lib/lifecycle.js` byte-identical to `api/lib/lifecycle.js` |

Node keeps a busy keep-alive socket open for the 5 s keep-alive timeout after `server.close()` unless the response carries `Connection: close`; this was reproduced on Node 24.21.0 and is why the lifecycle marks in-flight responses when draining starts.

### Real database (`npm --prefix api run test:db`)

Two consecutive runs, both exit 0, with identical results:

| Check | Result |
| --- | --- |
| API launcher | listens after the database check; `/health/live` and `/health/ready` 200 |
| Web launcher against that API | listens after the API check; both health endpoints 200 |
| Database stopped | both services: ready 503, live 200 |
| New API launcher started during the outage | logs `startup_waiting`, not listening after 1.5 s |
| Database restarted | both running services ready 200 without restart; the waiting API is admitted and ready |
| SIGTERM to all three launchers | exit 0 in 4–5 ms each, `shutdown_complete` logged, no passwords or certificate paths in output |
| All earlier checks | pass unchanged |

### Limits

Drain timing was measured with local connections only. Load balancer deregistration delay and container stop timeouts are deployment settings and must be verified on the deployed service.

## Production images

Recorded 2026-10-01 on macOS ARM64 with Docker Desktop 28.4.0 (buildx 0.28.0, Compose 2.39.2). Linux AMD64 images run under Rosetta emulation on this host.

`bash scripts/check-local.sh`: exit 0 in 66 s. API 27 and web 26 unit tests pass; the database integration passes unchanged (host clock 984 ms ahead of the database clock, reported rather than asserted).

| Check | Result |
| --- | --- |
| Image identity | `assessment-api:local` `sha256:8e4e36ef1134310fa3a09cef74bdb8bb111ec726df7c61184fc406eee40b8894`, `assessment-web:local` `sha256:5420aa65921ca1652fad500478b3dc9a16e1e412151426c71be5ffece8d52a0c` (IDs change on rebuild) |
| Shape | `linux/amd64`, user `node`, entrypoint `["node","bin/www"]`, no `Cmd`, `STOPSIGNAL SIGTERM`; Node v24.21.0 / npm 11.19.0 inside |
| Contents | API 9 files, web 14 files outside `node_modules`; no tests, `.env`, `.npmrc`, Dockerfile or README; no fixture passwords or private keys found; no credential or `API_HOST` variables in the image config |
| Runtime hardening | read-only root filesystem; a fresh read-only container of each image cannot write to `/app`, `/tmp` or `/home/node`; exactly one `node bin/www` process, no shell; 0.25 vCPU / 512 MiB limits applied |
| Startup | compose `up --wait` with readiness health checks: 23.6 s for DB → API → web (emulated) |
| Browser path | web page 200 with a database-fresh time over TLS; `/api/status` 200; stylesheet 200; both health endpoints 200 |
| Capacity at planned size | 200 page views at concurrency 20: 0 failures, 50 req/s, p50 301 ms, p95 902 ms, max 2.0 s. Memory after load: API 66 MiB, web 121 MiB of 512 MiB. Web was CPU-bound at its 0.25 vCPU cap (25% of one CPU); API near 0% |
| Database outage | web 503 in 147 ms; API ready 503, both live 200; page recovers after restart; neither container restarted |
| Logs | 429 JSON records; request records with ID/route/duration; no secrets or stack traces |
| Graceful stop | `docker compose stop -t 30`: web exit 0 in 441 ms with an in-flight page returning 200; API exit 0 in 273 ms; `shutdown_complete` logged |
| Cleanup | compose projects, volumes and temp certificates removed |
| Interrupted run | SIGINT during the container phase: script exits 1 within 1 s; no compose projects, containers or temp certificates left |

Two emulation effects were found and accounted for. First, `docker exec` into a read-only container fails under Rosetta because it needs a writable temp file, so the checks use `docker top` and a fresh `docker run --read-only` probe instead. Second, the Docker VM clock can drift from the host between resyncs; one run saw a DB time more than 10 s from host time, so freshness is checked against the database clock.

### Limits

Capacity figures come from emulated AMD64 on a laptop and are a lower bound for Fargate, not a production load test. At 0.25 vCPU the web tier is the CPU bottleneck; memory has large headroom. Load balancer, CDN and managed-database behavior are not part of these checks.
