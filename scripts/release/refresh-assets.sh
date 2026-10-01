#!/usr/bin/env bash
# Refreshes changed static assets at the CDN edge by invalidating only the
# given paths, and waits (bounded) until the invalidation completes.
# Only static paths are accepted; HTML and API responses are never cached.
#
# Usage: scripts/release/refresh-assets.sh /stylesheets/style.css [/images/x.png ...]
# Env:   DISTRIBUTION_ID (default: Terraform output cloudfront_distribution_id)
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ $# -gt 0 ] || { echo "Usage: $0 <static path>..." >&2; exit 2; }
for p in "$@"; do
  [[ "$p" =~ ^/(stylesheets|images)/[A-Za-z0-9._/-]+$ ]] || { echo "Not a static asset path: $p" >&2; exit 2; }
done
id="${DISTRIBUTION_ID:-$(terraform -chdir="$root/infra/stack" output -raw cloudfront_distribution_id)}"
invalidation="$(aws cloudfront create-invalidation --distribution-id "$id" --paths "$@" --query 'Invalidation.Id' --output text)"
echo "invalidation $invalidation for $*"
start=$(date +%s)
until [ "$(aws cloudfront get-invalidation --distribution-id "$id" --id "$invalidation" --query 'Invalidation.Status' --output text 2>/dev/null)" = "Completed" ]; do
  [ $(( $(date +%s) - start )) -lt 900 ] || { echo "invalidation not completed within 15 minutes" >&2; exit 1; }
  sleep 10
done
echo "invalidation completed after $(( $(date +%s) - start ))s"
