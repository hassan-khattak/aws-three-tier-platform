#!/usr/bin/env bash
# Builds linux/amd64 images for web and/or api from a clean commit, pushes
# them to ECR with the commit as an immutable tag, and records the pushed
# digests in deploy/images.json (deployments reference digests, never tags).
#
# Usage: scripts/release/build-push.sh [web] [api]     (default: both)
# Requires: AWS credentials for the account, Docker with buildx, terraform
#           outputs of infra/stack (repository URLs).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
services=("$@")
[ ${#services[@]} -gt 0 ] || services=(web api)

region="${AWS_REGION:-us-east-1}"
for service in "${services[@]}"; do
  case "$service" in web|api) ;; *) echo "Unknown service: $service" >&2; exit 2 ;; esac
  if [ -n "$(git status --porcelain -- "$service")" ]; then
    echo "$service/ has uncommitted changes; images are built from committed code only." >&2
    exit 1
  fi
done

tag="$(git rev-parse --short=12 HEAD)"
outputs="$(terraform -chdir=infra/stack output -json)"
registry="$(printf '%s' "$outputs" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).api_repository_url.value.split("/")[0]))')"

aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "$registry" >/dev/null

for service in "${services[@]}"; do
  repository="$(printf '%s' "$outputs" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s)[process.argv[1]+"_repository_url"].value))' "$service")"
  if aws ecr describe-images --region "$region" --repository-name "${repository#*/}" --image-ids imageTag="$tag" >/dev/null 2>&1; then
    echo "$service: $tag already pushed; reusing it (tags are immutable)."
  else
    echo "$service: building and pushing $repository:$tag"
    docker buildx build --platform linux/amd64 --provenance=false --push -t "$repository:$tag" "$service"
  fi
  digest="$(aws ecr describe-images --region "$region" --repository-name "${repository#*/}" --image-ids imageTag="$tag" --query 'imageDetails[0].imageDigest' --output text)"
  node -e '
    const fs = require("fs"); const [file, service, image, commit] = process.argv.slice(1);
    const data = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : {};
    data[service] = { image, commit };
    fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n");
  ' deploy/images.json "$service" "$repository@$digest" "$tag"
  echo "$service: $repository@$digest"
done
