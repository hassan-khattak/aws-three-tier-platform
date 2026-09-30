#!/usr/bin/env bash
# Builds both production images and runs every local check: unit tests,
# PostgreSQL/TLS integration, lifecycle and container checks. All test
# resources are disposable and removed on success, failure or interrupt.
#
# Requires: Node matching .nvmrc on PATH, a running Docker daemon with buildx.
# Usage: bash scripts/check-local.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

cleanup() {
  local status=$?
  # The test scripts remove their own compose projects; this catches any
  # left behind by an interrupted run.
  local projects
  projects="$(docker compose ls --all --format json 2>/dev/null \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{for(const p of JSON.parse(s||"[]"))if(/^assessment-(db|images)-/.test(p.Name))console.log(p.Name)})' || true)"
  for project in $projects; do
    echo "Removing leftover test project $project" >&2
    docker compose --project-name "$project" -f compose.test.yaml --profile images down --volumes --remove-orphans --timeout 5 >/dev/null 2>&1 || true
  done
  exit "$status"
}
trap cleanup EXIT

step() { printf '\n==> %s\n' "$*"; }

expected="v$(tr -d '[:space:]' < .nvmrc)"
if [ "$(node --version)" != "$expected" ]; then
  echo "Node $expected is required (found $(node --version)); see .nvmrc." >&2
  exit 1
fi
docker info >/dev/null 2>&1 || { echo "Docker daemon is not running." >&2; exit 1; }

for service in api web; do
  step "$service: clean install and unit tests"
  (cd "$service" && npm ci --ignore-scripts --no-audit --no-fund && npm ls --omit=dev --all >/dev/null && npm test)
done

for service in api web; do
  step "$service: build linux/amd64 image"
  docker buildx build --platform linux/amd64 --load -t "assessment-${service}:local" "$service"
done

step "PostgreSQL/TLS, web -> API -> DB and lifecycle integration"
node tests/system/database/integration.cjs

step "Production images: shape, hardening, browser path, capacity, outage, stop"
node tests/system/containers/integration.cjs

step "All local checks passed"
