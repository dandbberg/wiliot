#!/usr/bin/env bash
# Build the app image for Graviton (linux/arm64) and push it to ECR.
# Usage: scripts/build-push.sh [tag]   (default: git short SHA, else a timestamp)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AWS_REGION="${AWS_REGION:-ca-central-1}"

TAG="${1:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || date -u +%Y%m%d%H%M%S)}"
REPO="$(terraform -chdir="$ROOT/infra" output -raw ecr_repository_url)"
REGISTRY="${REPO%%/*}"

# The token goes straight from the AWS CLI into docker's stdin; never echoed.
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null

docker buildx build --platform linux/arm64 -t "$REPO:$TAG" --push "$ROOT/app"
echo "$REPO:$TAG"
