#!/usr/bin/env bash
#
# build.sh — build the container image with a verifiable build identity.
#
# The point of this script is that NOTHING about the built image is ambiguous.
# The version, the commit, the branch and the build time are baked in as
# --build-arg values, so `curl /version` on a running pod can always be traced
# back to an exact commit.
#
# Usage:
#   ./scripts/build.sh 2.4.17
#   ./scripts/build.sh 2.4.17 --push --registry us-central1-docker.pkg.dev/my-proj/orders
#   ./scripts/build.sh 2.4.17 --kind orders-lab      # side-load into a kind cluster

set -euo pipefail

VERSION="${1:-}"
shift || true

REGISTRY=""
PUSH=false
KIND_CLUSTER=""
IMAGE_NAME="orders-api"
ALLOW_DIRTY=false

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'

if [[ -z "$VERSION" ]]; then
  cat <<'USAGE'
Usage: build.sh VERSION [options]
  --registry PATH   Artifact Registry path, e.g. REGION-docker.pkg.dev/PROJECT/REPO
  --push            Push after building (requires --registry)
  --kind CLUSTER    Side-load the image into a kind cluster instead of pushing
  --allow-dirty     Build even with uncommitted changes (NOT reproducible)
USAGE
  exit 2
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry) REGISTRY="$2"; shift 2 ;;
    --push) PUSH=true; shift ;;
    --kind) KIND_CLUSTER="$2"; shift 2 ;;
    --allow-dirty) ALLOW_DIRTY=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Refuse to tag a build "latest". A mutable tag cannot be rolled back to and
# cannot be verified after the fact.
# ---------------------------------------------------------------------------
if [[ "$VERSION" == "latest" ]]; then
  echo "${RED}Refusing to build 'latest'. Use a real version, e.g. 2.4.17.${NC}" >&2
  exit 2
fi

cd "$(dirname "$0")/.."

# ---------------------------------------------------------------------------
# Capture build identity from git.
# ---------------------------------------------------------------------------
GIT_COMMIT="$(git rev-parse --verify HEAD 2>/dev/null || echo unknown)"
GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
BUILD_TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  if [[ "$ALLOW_DIRTY" == true ]]; then
    echo "${YELLOW}WARNING: building from a DIRTY tree. GIT_COMMIT will not describe the image.${NC}"
    GIT_COMMIT="${GIT_COMMIT}-dirty"
  else
    echo "${RED}Working tree has uncommitted changes.${NC}" >&2
    echo "A build from a dirty tree cannot be reproduced or audited." >&2
    echo "Commit your work, or pass --allow-dirty if this is a local experiment." >&2
    exit 1
  fi
fi

if [[ -n "$REGISTRY" ]]; then
  FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${VERSION}"
else
  FULL_IMAGE="${IMAGE_NAME}:${VERSION}"
fi

echo "========================================================================"
echo " BUILD"
echo "   image     : $FULL_IMAGE"
echo "   version   : $VERSION"
echo "   commit    : ${GIT_COMMIT:0:12}"
echo "   branch    : $GIT_BRANCH"
echo "   timestamp : $BUILD_TIMESTAMP"
echo "========================================================================"

# ---------------------------------------------------------------------------
# Build. Context is the repo root, Dockerfile lives in app/.
# ---------------------------------------------------------------------------
docker build \
  -f app/Dockerfile \
  --build-arg "APP_VERSION=${VERSION}" \
  --build-arg "GIT_COMMIT=${GIT_COMMIT}" \
  --build-arg "GIT_BRANCH=${GIT_BRANCH}" \
  --build-arg "BUILD_TIMESTAMP=${BUILD_TIMESTAMP}" \
  --build-arg "IMAGE_TAG=${VERSION}" \
  -t "$FULL_IMAGE" \
  .

echo "${GREEN}Build complete.${NC}"

# ---------------------------------------------------------------------------
# Prove the identity actually landed in the image, before it goes anywhere.
# Checking this here means a broken build is caught in seconds rather than
# during a production version check.
# ---------------------------------------------------------------------------
echo
echo "--- verifying build identity inside the image ---"
BAKED_VERSION="$(docker inspect "$FULL_IMAGE" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^APP_VERSION=' | cut -d= -f2)"
BAKED_COMMIT="$(docker inspect "$FULL_IMAGE" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^GIT_COMMIT=' | cut -d= -f2)"

echo "  APP_VERSION baked in : $BAKED_VERSION"
echo "  GIT_COMMIT  baked in : ${BAKED_COMMIT:0:12}"

if [[ "$BAKED_VERSION" != "$VERSION" ]]; then
  echo "${RED}FAILED: image reports '$BAKED_VERSION' but we asked for '$VERSION'.${NC}" >&2
  exit 1
fi
echo "${GREEN}  identity confirmed${NC}"

# Also confirm the image does not run as root — cheap check, catches a
# Dockerfile regression before it reaches a cluster with a restrictive PSS.
IMAGE_USER="$(docker inspect "$FULL_IMAGE" --format '{{.Config.User}}')"
if [[ -z "$IMAGE_USER" || "$IMAGE_USER" == "root" || "$IMAGE_USER" == "0" ]]; then
  echo "${RED}FAILED: image would run as root.${NC}" >&2
  exit 1
fi
echo "${GREEN}  runs as UID $IMAGE_USER (non-root)${NC}"

# ---------------------------------------------------------------------------
# Distribute.
# ---------------------------------------------------------------------------
if [[ -n "$KIND_CLUSTER" ]]; then
  echo
  echo "--- side-loading into kind cluster '$KIND_CLUSTER' ---"
  # kind nodes have their own container runtime and cannot see images in your
  # local Docker daemon. Skipping this step is the #1 cause of ErrImageNeverPull
  # / ImagePullBackOff on a local cluster.
  kind load docker-image "$FULL_IMAGE" --name "$KIND_CLUSTER"
  echo "${GREEN}loaded${NC}"
fi

if [[ "$PUSH" == true ]]; then
  if [[ -z "$REGISTRY" ]]; then
    echo "${RED}--push requires --registry${NC}" >&2
    exit 2
  fi
  echo
  echo "--- pushing ---"
  docker push "$FULL_IMAGE"

  # Print the digest. This is the value to pin in values.yaml for a fully
  # deterministic deploy, and the value verify-version.sh compares against.
  DIGEST="$(docker inspect "$FULL_IMAGE" --format '{{index .RepoDigests 0}}' 2>/dev/null || true)"
  echo "${GREEN}pushed${NC}"
  [[ -n "$DIGEST" ]] && echo "  digest: $DIGEST"
  echo
  echo "  Deploy this exact artifact with:"
  echo "    --set image.digest=${DIGEST##*@}"
fi

echo
echo "Next: ./scripts/deploy.sh $VERSION"
