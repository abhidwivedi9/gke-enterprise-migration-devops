#!/usr/bin/env bash
#
# local-up.sh - the entire stack on your laptop, in one command, for $0.
#
# This exists so that everything in this repo except the GCP-specific parts can
# be practised without a cloud account and without any risk of a bill.
#
# Usage: ./scripts/local-up.sh [VERSION]

set -euo pipefail

VERSION="${1:-2.4.17}"
CLUSTER="orders-lab"
NAMESPACE="orders"

GREEN=$'\033[0;32m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$BLUE" "$1" "$NC"; }

cd "$(dirname "$0")/.."

step "Checking prerequisites"
for tool in docker kind kubectl helm; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing: $tool" >&2; exit 1; }
  echo "  ok: $tool"
done
docker info >/dev/null 2>&1 || { echo "Docker daemon is not running." >&2; exit 1; }

step "Creating the kind cluster (skipped if it exists)"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "  cluster '$CLUSTER' already exists"
else
  kind create cluster --name "$CLUSTER" --config kubernetes/kind-cluster.yaml --wait 180s
fi
kubectl config use-context "kind-${CLUSTER}"

step "Installing metrics-server (required for HPA and kubectl top)"
if kubectl -n kube-system get deploy metrics-server >/dev/null 2>&1; then
  echo "  already installed"
else
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  # kind's kubelet serving certs are self-signed, so metrics-server must be told
  # not to verify them. Without this it never becomes Ready and every HPA shows
  # <unknown>. This is a kind-only workaround - never do it on GKE.
  kubectl -n kube-system patch deployment metrics-server --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
  kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s
fi

step "Building orders-api:${VERSION}"
./scripts/build.sh "$VERSION" --kind "$CLUSTER" --allow-dirty

step "Deploying with Helm"
helm upgrade --install orders-api ./helm/application \
  -f helm/application/values.yaml \
  -f helm/application/values-local.yaml \
  -n "$NAMESPACE" --create-namespace \
  --set "image.tag=${VERSION}" \
  --wait --timeout 5m

step "Verifying"
./scripts/verify-version.sh -n "$NAMESPACE" -r orders-api -v "$VERSION" || true

cat <<EOF

${GREEN}=====================================================================${NC}
${GREEN} LOCAL STACK IS UP - cost: \$0${NC}

   kubectl get pods -n $NAMESPACE
   kubectl port-forward -n $NAMESPACE svc/orders-api 8080:80
   curl localhost:8080/version

   ./scripts/health-check.sh -n $NAMESPACE
   ./scripts/load-test.sh -n $NAMESPACE
   ./failure-lab/run.sh list

 Tear it all down:
   kind delete cluster --name $CLUSTER
${GREEN}=====================================================================${NC}
EOF
