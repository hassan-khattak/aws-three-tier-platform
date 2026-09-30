# Application contract

What the web and API services require from their environment and what they guarantee to callers. Verification results are in [the application evidence](../evidence/application.md).

## Toolchain

| Item | Pin / behavior |
| --- | --- |
| Node | `24.21.0`, recorded in `.nvmrc` and both `engines.node` fields |
| npm | `11.19.0`, recorded in both `engines.npm` and `packageManager` fields |
| Installation | Per-service lockfile v3, `npm ci --ignore-scripts`; `.npmrc` enforces matching engines and exact saves |
| Tests | Node's built-in test runner; `npm test` in each service |
| Production architecture | Linux AMD64 (container execution not yet verified; local checks ran on macOS ARM64) |
| Framework | Express 4; Jade templates retained |
| Database client | `pg` 8, pure JavaScript path; optional `pg-native` is intentionally not installed |

The [official Node release archive](https://nodejs.org/en/download/archive/v24.21.0) and [release metadata](https://nodejs.org/dist/index.json) identify the selected Node/npm pair. Archives are checked against the official SHA256 list before use.

### Container base

The official tag `node:24.21.0-bookworm-slim` includes Linux AMD64:

- Multi-platform index: `sha256:0e0ff40c39bc087845bfb27465a0df4ea419520094bc35842ff83dd8cbe6f9b6`.
- Linux AMD64 manifest: `sha256:5cbc7caba8c2c0f0bca675d1b61b9f2857e1cf1853c6164ee9dd409501a936e7`.
- Intended base reference: `node:24.21.0-bookworm-slim@sha256:5cbc7caba8c2c0f0bca675d1b61b9f2857e1cf1853c6164ee9dd409501a936e7` with an explicit Linux AMD64 build target.

Images must verify the container's actual Node/npm versions; do not substitute the local ARM64 architecture.

## API configuration

Validated at startup. Invalid or missing values exit 1 with a single JSON `startup_failed` record naming only the offending field, never its value.

| Variable | Rule |
| --- | --- |
| `PORT` | integer 0–65535, default 3000 |
| `DB`, `DBUSER`, `DBPASS` | required, non-empty, no control characters |
| `DBHOST` | required hostname/IP, no whitespace or slashes |
| `DBPORT` | integer 1–65535, default 5432 |
| `DB_SSL` | `true` (default) or `false`; `false` rejected when `NODE_ENV=production` |
| `DB_CA_FILE` | required when `DB_SSL=true`; readable PEM with at least one parseable certificate |
| `NODE_TLS_REJECT_UNAUTHORIZED=0` | rejected |

See [api/.env.example](../../api/.env.example). Database TLS uses `rejectUnauthorized`, TLS ≥ 1.2, and checks the server certificate against the configured `DBHOST`.

## API database behavior

- One `pg` pool per process: max 5 connections, idle timeout 30 s.
- Per request: total 3 s; connection acquisition ≤ 1 s; query ≤ 1 s (client timeout and `statement_timeout`).
- One retry only for connection-class errors, inside the same 3 s. No retry for authentication, TLS, SQL, timeout or invalid-result failures.
- A failed, late or aborted checkout is destroyed rather than returned to the pool. A client disconnect aborts the in-flight read.
- The status query is read-only (`SELECT now()`); the time is never cached or fabricated.

## API HTTP responses

| Case | Response |
| --- | --- |
| `GET /api/status` success | 200 `[{"time":"<ISO from SELECT now()>","request_uuid":"<UUID>"}]` |
| Database unavailable/timeout | 503 `{"error":{"code":"DATABASE_UNAVAILABLE"},"request_uuid":"<UUID>"}` |
| Unknown route | 404 `{"error":{"code":"NOT_FOUND"},"request_uuid":"<UUID>"}` |
| Malformed URI | 400 `BAD_REQUEST` |
| Anything else | 500 `INTERNAL_ERROR` |

Every response carries `X-Request-ID` (equal to `request_uuid`) and `Cache-Control: no-store`. No error messages or stack traces are returned in any environment.

## Logging

One JSON line per request on stdout: `timestamp`, `service`, `level`, `request_id`, route pattern (or `unmatched`), `status`, `duration_ms`, plus a fixed `reason` code on failure. Query strings, raw errors, credentials and file paths are never logged.

## Web configuration

| Variable | Rule |
| --- | --- |
| `PORT` | integer 0–65535, default 3000 |
| `API_HOST` | required `http`/`https` base URL of the API (e.g. the internal load balancer). No credentials, query or fragment, and no trailing `/api`: the web tier appends `/api/status` exactly once. An optional path prefix is kept. |

Invalid values exit 1 with a sanitized `startup_failed` record, as for the API. See [web/.env.example](../../web/.env.example).

## Web upstream behavior

- One `GET <API_HOST>/api/status` per page view using the runtime's built-in `fetch`. Redirects are not followed.
- A single 5 s deadline covers connect, headers and body. A browser disconnect aborts the upstream request. The body is capped at 64 KiB.
- The response must be 200, `application/json`, a non-empty array whose first element has a parseable `time` string and a UUID `request_uuid`. Nothing is read from the body before that validation passes.

| Case | Web response |
| --- | --- |
| Valid API response | 200 page showing `time` and `request_uuid` (existing Jade view) |
| API unreachable, timed out, or answered 502/503/504 | 503 "Service Unavailable" page |
| Any other status, redirect, wrong content type, invalid JSON/schema/time/UUID, oversized body | 502 "Bad Gateway" page |
| Unknown route | 404 "Not Found" page; the API is not called |

Error pages use the `error` template with only a fixed message and status: no upstream address, raw error or stack trace in any environment. Dynamic responses carry `Cache-Control: no-store` and `X-Request-ID`. Static files under `public/` are served with `Cache-Control: public, max-age=300`, so the CDN caches them for 5 minutes; changed assets are refreshed with `scripts/release/refresh-assets.sh`. Web logs follow the same JSON format as the API with `service: "web"`.

## Health, admission and shutdown (both services)

| Endpoint | Behavior |
| --- | --- |
| `GET /health/live` | 200 `{"status":"ok"}` whenever the process serves HTTP. Never touches a dependency, so a shared database or API outage does not make every task fail its health check and restart. |
| `GET /health/ready` | API: one bounded database read (3 s budget). Web: one bounded `/api/status` call (5 s budget). 200 `{"status":"ready"}`, or 503 `{"status":"unavailable"}`; 503 `{"status":"draining"}` during shutdown without calling the dependency. |

Web readiness deliberately calls `/api/status` rather than the API's `/health/ready`: on the shared load balancer only `/api` and `/api/*` reach the API, so `/health/ready` would route back to web.

**Admission.** A launcher opens its port only after one successful dependency check: API → database, web → API. Checks repeat every 1 s. If none succeeds within 60 s (attempts in progress are cut off at the deadline), the process logs `startup_failed` / `DEPENDENCY_UNAVAILABLE`, releases resources and exits 1. There is no startup cycle: the API never depends on web. After admission, losing a dependency only affects readiness and request responses; the process keeps running and recovers without a restart.

**Shutdown.** On SIGTERM or SIGINT (repeated signals are ignored): readiness turns 503, the listening socket closes so new connections are refused, idle keep-alive connections close, and requests already in progress complete with `Connection: close`. Then the API closes its database pool once, and the process exits 0. If draining takes longer than 20 s, the process logs `shutdown_forced` and exits 1. A signal during admission exits 0 without listening. Container stop timeouts should be at least 30 s.

Lifecycle log events: `startup_waiting` (with a fixed `reason`), `server_listening`, `startup_failed`, `shutdown_started`, `shutdown_complete`, `shutdown_forced`.

`api/lib/lifecycle.js` and `web/lib/lifecycle.js` are identical copies (each service is built from its own directory); a web test fails if they diverge.

## Container images

| Item | Value |
| --- | --- |
| Base | `node:24.21.0-bookworm-slim@sha256:5cbc7caba8c2c0f0bca675d1b61b9f2857e1cf1853c6164ee9dd409501a936e7` (Linux AMD64 manifest), overridable with build arg `NODE_IMAGE` |
| Build | `docker buildx build --platform linux/amd64 -t <name> api` (or `web`); each service directory is its own build context |
| Dependencies | `npm ci --omit=dev --ignore-scripts` in a separate stage; npm cache removed |
| Contents | only `package.json`, `node_modules`, `app.js`, `bin/`, `lib/` and, for web, `routes/`, `views/`, `public/`; for the API, `certs/`. `.dockerignore` allow-lists these, so `.env`, tests, Git data and docs never enter the context |
| Runtime user | `node` (uid 1000); application files are root-owned and not writable by it |
| Start | `ENTRYPOINT ["node", "bin/www"]`; Node is PID 1 with its own signal handlers, no shell. `STOPSIGNAL SIGTERM` |
| Filesystem | runs with a read-only root filesystem; no writable path is needed |
| Image environment | `NODE_ENV=production`, `PORT=3000`; API also `DB_CA_FILE=/app/certs/rds-global-bundle.pem`. No credentials or endpoints are baked in |
| Size | about 82 MB (API) and 84 MB (web) |

**Database CA.** `api/certs/rds-global-bundle.pem` is the Amazon RDS global trust bundle from `https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem`, downloaded 2026-10-01 over HTTPS: 111 root certificates including the six `us-east-1` roots, SHA256 `fe45bbebf92ad3e27a583bbb2ddd1553c521ed4d49af5514dc0a40372ea5395c`. Verification stays on; to trust another CA, mount it and set `DB_CA_FILE`.

**Deployment settings the images expect:** container port 3000; health checks on `/health/live` (ongoing) and `/health/ready` (release verification); stop timeout ≥ 30 s; read-only root filesystem enabled; DB credentials and `API_HOST` supplied at runtime.

## Local checks

One command builds both images and runs every local check against disposable resources:

```bash
bash scripts/check-local.sh
```

It needs Node matching `.nvmrc` and a running Docker daemon with buildx. Steps: clean install, dependency tree and unit tests for each service; both image builds; the PostgreSQL/TLS integration (`tests/system/database/integration.cjs`); then the production images under `compose.test.yaml --profile images` at 0.25 vCPU / 512 MiB (`tests/system/containers/integration.cjs`). Each script removes its compose project, volume and temporary certificates on success, failure or interrupt, and the shell script's exit trap removes any project left by an interrupted run. Exit status is 0 only if every check passes.

## Dependency decisions and remaining findings

- Added `debug` as a direct API launcher dependency instead of relying on Express's transitive copy.
- Updated Express within major 4, the PostgreSQL client within major 8, and web middleware within their existing major versions to address audit findings. Direct versions and all transitives are locked.
- Removed unused `node-uuid`, Redis clients and the unused favicon dependency/import.
- Replaced Request with the runtime's built-in `fetch`. Removed `morgan` (replaced by structured JSON logs) and the unused `body-parser`/`cookie-parser` middleware; the web tier reads no request bodies or cookies.
- Retained Jade 1.11.0. Explicit same-major overrides select `constantinople` 3.1.2 and `uglify-js` 2.8.29.

Install scripts are disabled. The only installed package with an install script is transitive `core-js`; all checks pass without it.

Current audits: API **0** findings; web **2 affected packages**, both low (`clean-css` and `jade`, which depends on it). `npm audit --omit=dev --json` for web correctly exits 1. Raw results: [API](../evidence/api-audit.json), [web](../evidence/web-audit.json).

| Remaining finding | Current use / boundary | Follow-up |
| --- | --- | --- |
| `clean-css`, via `jade` (low) | Only committed Jade files and an external stylesheet; no CSS minification filter or user-supplied templates. | Keep template/filter inputs trusted. The automated fix is a Jade downgrade and was not applied. |

The earlier Request findings (SSRF, `qs`, `tough-cookie`, `uuid`) no longer apply: the package is removed from the tree.

These reachability notes are static inspection of this application, not a claim that the packages are safe. An automated Jade downgrade suggestion was not applied blindly.

Advisories: [constantinople](https://github.com/advisories/GHSA-4vmm-mhcq-4x9j), [UglifyJS](https://github.com/advisories/GHSA-34r7-q49f-h37c), [Request](https://github.com/advisories/GHSA-p8p7-x288-28g6), [clean-css](https://github.com/advisories/GHSA-wxhq-pm8v-cw75).
