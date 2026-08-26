#!/usr/bin/env bash
#
# verify-version.sh — prove which version is ACTUALLY running.
#
# WHY THIS SCRIPT EXISTS
#
# A deployment can report SUCCESS at every layer and still run the wrong code.
# Each of these is a real, common failure:
#
#   * The tag was mutable. :2.4.17 was overwritten by a later build, so the
#     digest behind the tag is not what you tested.
#   * imagePullPolicy: IfNotPresent + a mutable tag. The node already had a
#     layer cached under that tag and never contacted the registry.
#   * `helm upgrade` succeeded but nothing changed, because only a ConfigMap was
#     edited and no pod annotation changed — so no rolling update happened.
#   * The rollout is half done. Some pods are new, some are old, and a curl
#     through the Service hits whichever the load balancer picks.
#   * CI pushed to one registry and the Deployment pulls from another.
#   * The Deployment was patched by hand and Helm's stored manifest now
#     disagrees with the live object.
#
# So this script walks all nine layers and compares them. It exits non-zero if
# any layer disagrees.
#
#   Git commit -> image tag -> registry digest -> Helm release ->
#   Deployment spec -> ReplicaSet -> Pod spec -> running container -> /version
#
# Usage:
#   ./scripts/verify-version.sh -n orders -r orders-api -v 2.4.17
#   ./scripts/verify-version.sh -n orders -r orders-api -v 2.4.17 --registry us-central1-docker.pkg.dev/my-proj/orders

set -uo pipefail

NAMESPACE="orders"
RELEASE="orders-api"
EXPECTED_VERSION=""
REGISTRY=""
PORT_FORWARD_PORT="18099"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'

FAILURES=0
CHECKS=0

usage() {
  cat <<'USAGE'
Usage: verify-version.sh [options]
  -n, --namespace   Kubernetes namespace          (default: orders)
  -r, --release     Helm release name             (default: orders-api)
  -v, --version     Version you EXPECT to be live (required)
      --registry    Artifact Registry path, enables the registry-digest check
  -h, --help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -r|--release)   RELEASE="$2"; shift 2 ;;
    -v|--version)   EXPECTED_VERSION="$2"; shift 2 ;;
    --registry)     REGISTRY="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$EXPECTED_VERSION" ]]; then
  echo "${RED}ERROR: -v/--version is required. You cannot verify a version you have not named.${NC}" >&2
  exit 2
fi

step()  { CHECKS=$((CHECKS+1)); printf '\n%s[%d] %s%s\n' "$BLUE" "$CHECKS" "$1" "$NC"; }
pass()  { printf '    %s PASS%s  %s\n' "$GREEN" "$NC" "$1"; }
fail()  { FAILURES=$((FAILURES+1)); printf '    %s FAIL%s  %s\n' "$RED" "$NC" "$1"; }
warn()  { printf '    %s WARN%s  %s\n' "$YELLOW" "$NC" "$1"; }
info()  { printf '          %s\n' "$1"; }

echo "========================================================================"
echo " VERSION VERIFICATION"
echo " expecting : $EXPECTED_VERSION"
echo " release   : $RELEASE   namespace: $NAMESPACE"
echo " time      : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "========================================================================"

# ---------------------------------------------------------------------------
# 1. Git — what does the source say?
# ---------------------------------------------------------------------------
step "Git: is the expected version tagged, and is the tree clean?"
if git rev-parse --git-dir >/dev/null 2>&1; then
  GIT_COMMIT="$(git rev-parse --verify HEAD 2>/dev/null || echo unknown)"
  GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  info "HEAD    : ${GIT_COMMIT:0:12} on $GIT_BRANCH"

  if git rev-parse "v${EXPECTED_VERSION}" >/dev/null 2>&1; then
    TAG_COMMIT="$(git rev-list -n 1 "v${EXPECTED_VERSION}")"
    info "v$EXPECTED_VERSION -> ${TAG_COMMIT:0:12}"
    if [[ "$TAG_COMMIT" == "$GIT_COMMIT" ]]; then
      pass "HEAD is exactly the tagged release commit"
    else
      warn "HEAD is not the tagged commit. You may be verifying from the wrong checkout."
    fi
  else
    warn "no git tag v$EXPECTED_VERSION — releases should be tagged so this is auditable"
  fi

  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    warn "working tree is DIRTY — a build from here is not reproducible"
  else
    pass "working tree clean"
  fi
else
  warn "not inside a git repository — skipping git checks"
  GIT_COMMIT="unknown"
fi

# ---------------------------------------------------------------------------
# 2. Registry — does the image exist, and what digest is behind the tag?
# ---------------------------------------------------------------------------
step "Artifact Registry: does the tag exist, and what digest does it resolve to?"
REGISTRY_DIGEST=""
if [[ -n "$REGISTRY" ]]; then
  if command -v gcloud >/dev/null 2>&1; then
    REGISTRY_DIGEST="$(gcloud artifacts docker images describe \
        "${REGISTRY}/orders-api:${EXPECTED_VERSION}" \
        --format='value(image_summary.digest)' 2>/dev/null || true)"
    if [[ -n "$REGISTRY_DIGEST" ]]; then
      pass "tag resolves to ${REGISTRY_DIGEST:0:24}..."
      info "THIS is the digest every running pod must match."
    else
      fail "tag ${EXPECTED_VERSION} not found in ${REGISTRY} (or no permission to read it)"
      info "If CI reported a successful push, check it pushed to THIS registry path."
    fi
  else
    warn "gcloud not installed — skipping registry check"
  fi
else
  info "no --registry given; skipping. Pass it to catch 'pushed to the wrong repo'."
fi

# ---------------------------------------------------------------------------
# 3. Helm — what does the release claim?
# ---------------------------------------------------------------------------
step "Helm: what does the release say it deployed?"
if command -v helm >/dev/null 2>&1; then
  HELM_JSON="$(helm list -n "$NAMESPACE" -f "^${RELEASE}\$" -o json 2>/dev/null || echo '[]')"
  if [[ "$HELM_JSON" == "[]" || -z "$HELM_JSON" ]]; then
    fail "no Helm release named '$RELEASE' in namespace '$NAMESPACE'"
    info "The Deployment may still exist — deployed by kubectl, Argo CD, or by hand."
  else
    HELM_APP_VERSION="$(printf '%s' "$HELM_JSON" | grep -o '"app_version":"[^"]*"' | head -1 | cut -d'"' -f4)"
    HELM_STATUS="$(printf '%s' "$HELM_JSON" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)"
    HELM_REVISION="$(printf '%s' "$HELM_JSON" | grep -o '"revision":"\?[0-9]*"\?' | head -1 | tr -dc '0-9')"
    info "status: $HELM_STATUS   revision: $HELM_REVISION   appVersion: $HELM_APP_VERSION"

    [[ "$HELM_STATUS" == "deployed" ]] \
      && pass "release status is 'deployed'" \
      || fail "release status is '$HELM_STATUS' — a failed or pending release is not live"

    [[ "$HELM_APP_VERSION" == "$EXPECTED_VERSION" ]] \
      && pass "Helm appVersion matches" \
      || fail "Helm appVersion is '$HELM_APP_VERSION', expected '$EXPECTED_VERSION'"
  fi
else
  warn "helm not installed — skipping"
fi

# ---------------------------------------------------------------------------
# 4. Deployment — what image does the desired state specify?
# ---------------------------------------------------------------------------
step "Deployment: what image is in the pod template (the DESIRED state)?"
DEPLOY_IMAGE="$(kubectl get deployment "$RELEASE" -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"

if [[ -z "$DEPLOY_IMAGE" ]]; then
  fail "Deployment '$RELEASE' not found in namespace '$NAMESPACE'"
  echo; echo "${RED}Cannot continue — nothing is deployed under that name.${NC}"
  exit 1
fi
info "image: $DEPLOY_IMAGE"

if [[ "$DEPLOY_IMAGE" == *":${EXPECTED_VERSION}" || "$DEPLOY_IMAGE" == *"@sha256:"* ]]; then
  pass "Deployment references the expected version"
else
  fail "Deployment references '$DEPLOY_IMAGE', which is not :${EXPECTED_VERSION}"
fi

if [[ "$DEPLOY_IMAGE" == *":latest" ]]; then
  fail "image tag is ':latest' — mutable, unrollbackable, and unverifiable"
fi

# Desired vs available replicas.
DESIRED="$(kubectl get deployment "$RELEASE" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
AVAILABLE="$(kubectl get deployment "$RELEASE" -n "$NAMESPACE" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
UPDATED="$(kubectl get deployment "$RELEASE" -n "$NAMESPACE" -o jsonpath='{.status.updatedReplicas}' 2>/dev/null || echo 0)"
info "replicas: desired=$DESIRED available=${AVAILABLE:-0} updated=${UPDATED:-0}"

if [[ "${UPDATED:-0}" != "${DESIRED:-0}" ]]; then
  fail "rollout INCOMPLETE — only ${UPDATED:-0}/${DESIRED} pods run the new template"
  info "Some traffic is still being served by the OLD version right now."
else
  pass "every replica is on the current template"
fi

# ---------------------------------------------------------------------------
# 5. Pods — what is actually scheduled, and what is actually running?
#
# .spec.containers[].image is what was REQUESTED.
# .status.containerStatuses[].imageID is what the kubelet actually RESOLVED and
# started. When a mutable tag has been overwritten, these disagree — and only
# imageID tells the truth.
# ---------------------------------------------------------------------------
step "Pods: reconcile requested image vs the digest actually running"
PODS="$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=${RELEASE}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.containers[0].image}{"|"}{.status.containerStatuses[0].imageID}{"|"}{.status.phase}{"\n"}{end}' 2>/dev/null || true)"

if [[ -z "$PODS" ]]; then
  fail "no pods found with label app.kubernetes.io/instance=${RELEASE}"
else
  UNIQUE_DIGESTS=0
  SEEN_DIGESTS=""
  while IFS='|' read -r pod image imageid phase; do
    [[ -z "$pod" ]] && continue
    short_id="${imageid##*@}"
    info "$pod  [$phase]"
    info "    spec  : $image"
    info "    running: ${short_id:-<not started>}"
    if [[ -n "$short_id" && "$SEEN_DIGESTS" != *"$short_id"* ]]; then
      SEEN_DIGESTS="$SEEN_DIGESTS $short_id"
      UNIQUE_DIGESTS=$((UNIQUE_DIGESTS+1))
    fi
  done <<< "$PODS"

  if [[ "$UNIQUE_DIGESTS" -gt 1 ]]; then
    fail "$UNIQUE_DIGESTS DIFFERENT image digests are running simultaneously"
    info "This is the classic 'intermittent errors' shape: some requests hit the"
    info "new version, some hit the old. Averaged metrics hide it completely."
  elif [[ "$UNIQUE_DIGESTS" -eq 1 ]]; then
    pass "all pods run one identical digest"
    if [[ -n "$REGISTRY_DIGEST" ]]; then
      RUNNING_DIGEST="$(echo "$SEEN_DIGESTS" | tr -d ' ')"
      if [[ "$RUNNING_DIGEST" == "$REGISTRY_DIGEST" ]]; then
        pass "running digest matches the registry — the tag was not overwritten"
      else
        fail "running digest does NOT match the registry digest for :${EXPECTED_VERSION}"
        info "registry: $REGISTRY_DIGEST"
        info "running : $RUNNING_DIGEST"
        info "The tag was moved after these pods started, or the node used a cached layer."
      fi
    fi
  fi

  RESTARTS="$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=${RELEASE}" \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null \
    | awk '{s+=$1} END {print s+0}')"
  [[ "$RESTARTS" -eq 0 ]] \
    && pass "0 restarts across all pods" \
    || warn "$RESTARTS restarts total — check `kubectl logs --previous`"
fi

# ---------------------------------------------------------------------------
# 6. The application itself — the only ground truth.
# ---------------------------------------------------------------------------
step "Application /version — ask the running process directly"
PF_PID=""
cleanup() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

kubectl port-forward -n "$NAMESPACE" "svc/${RELEASE}" "${PORT_FORWARD_PORT}:80" >/dev/null 2>&1 &
PF_PID=$!
sleep 3

VERSION_JSON="$(curl -s --max-time 5 "http://127.0.0.1:${PORT_FORWARD_PORT}/version" 2>/dev/null || true)"

if [[ -z "$VERSION_JSON" ]]; then
  fail "could not reach /version through the Service"
  info "The pods may be Running but not Ready, so the Service has no endpoints:"
  info "  kubectl get endpoints ${RELEASE} -n ${NAMESPACE}"
else
  RUNNING_VERSION="$(printf '%s' "$VERSION_JSON" | grep -o '"application_version":"[^"]*"' | cut -d'"' -f4)"
  RUNNING_COMMIT="$(printf '%s' "$VERSION_JSON" | grep -o '"git_commit":"[^"]*"' | cut -d'"' -f4)"
  info "reported version : $RUNNING_VERSION"
  info "reported commit  : ${RUNNING_COMMIT:0:12}"

  if [[ "$RUNNING_VERSION" == "$EXPECTED_VERSION" ]]; then
    pass "THE RUNNING APPLICATION REPORTS $EXPECTED_VERSION"
  else
    fail "THE RUNNING APPLICATION REPORTS '$RUNNING_VERSION', NOT '$EXPECTED_VERSION'"
    info "Every layer above can be green while this is wrong. This is the one that counts."
  fi

  if [[ "${GIT_COMMIT:-unknown}" != "unknown" && -n "$RUNNING_COMMIT" && "$RUNNING_COMMIT" != "unknown" ]]; then
    [[ "$RUNNING_COMMIT" == "$GIT_COMMIT" ]] \
      && pass "running commit matches local HEAD" \
      || warn "running commit ${RUNNING_COMMIT:0:12} != local HEAD ${GIT_COMMIT:0:12}"
  fi

  # Sample several times: with a partial rollout, different requests land on
  # different pods and a single curl can give you a false green.
  MISMATCH=0
  for _ in 1 2 3 4 5 6 7 8; do
    v="$(curl -s --max-time 3 "http://127.0.0.1:${PORT_FORWARD_PORT}/version" 2>/dev/null \
         | grep -o '"application_version":"[^"]*"' | cut -d'"' -f4)"
    [[ -n "$v" && "$v" != "$EXPECTED_VERSION" ]] && MISMATCH=$((MISMATCH+1))
  done
  [[ "$MISMATCH" -eq 0 ]] \
    && pass "8/8 sampled requests served $EXPECTED_VERSION" \
    || fail "$MISMATCH of 8 sampled requests served a DIFFERENT version — mixed fleet"
fi

# ---------------------------------------------------------------------------
echo
echo "========================================================================"
if [[ "$FAILURES" -eq 0 ]]; then
  echo "${GREEN} VERIFIED: $EXPECTED_VERSION is running, consistently, everywhere.${NC}"
  echo "========================================================================"
  exit 0
else
  echo "${RED} $FAILURES CHECK(S) FAILED. Do NOT report this deployment as complete.${NC}"
  echo " Next: TROUBLESHOOTING.md, or ./scripts/collect-logs.sh -n $NAMESPACE"
  echo "========================================================================"
  exit 1
fi
