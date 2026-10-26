#!/usr/bin/env bash
# Make sure the app image for a tag is in ECR: skip if it is, else build it for
# Graviton (linux/arm64) and push it.
# Usage: scripts/build-push.sh <tag>
#
# The tag is the last commit that changed app/ (Makefile), so it names the code
# inside the image: a commit that only touches charts or docs reuses the image,
# and Docker is needed only when the app changed or ECR is empty (fresh deploy).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AWS_REGION="${AWS_REGION:-ca-central-1}"
TAG="${1:?usage: build-push.sh <tag>}"

REPO="$(terraform -chdir="$ROOT/infra" output -raw ecr_repository_url)"
REGISTRY="${REPO%%/*}"

# ECR tags are immutable, so an existing tag is already the right image.
if aws ecr describe-images --repository-name "${REPO#*/}" --image-ids imageTag="$TAG" >/dev/null 2>&1; then
  echo "image $TAG already in ECR"
  exit 0
fi

# Built from the working tree: uncommitted app changes would end up in an
# image named after a commit that doesn't contain them.
if ! git -C "$ROOT" diff --quiet HEAD -- app; then
  echo "app/ has uncommitted changes: commit them first (the image is tagged with the commit)" >&2
  exit 1
fi

# The token goes straight from the AWS CLI into docker's stdin; never echoed.
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
docker buildx build --platform linux/arm64 -t "$REPO:$TAG" --push "$ROOT/app"
echo "pushed $REPO:$TAG"
