#!/usr/bin/env bash
# Local cluster: kind + Argo Workflows v4.1.6 + RustFS. Safe to run again (it only applies changes).
# Overrides: CLUSTER (default hydrowf), KIND_CONFIG (default kind-config.yaml).
set -euo pipefail
cd "$(dirname "$0")"
CLUSTER=${CLUSTER:-hydrowf}
KIND_CONFIG=${KIND_CONFIG:-kind-config.yaml}
QUICK_START=https://github.com/argoproj/argo-workflows/releases/download/v4.1.6/quick-start-minimal.yaml
QUICK_START_SHA256=2c688114d0cc00162ae433d73f7009f3226e8c761ab3f8535cc5d34ae7c8cf71

for tool in docker kind kubectl curl sha256sum; do
  command -v "$tool" >/dev/null || { echo "up.sh: $tool not found" >&2; exit 1; }
done

echo "== checking the Argo quick-start release asset"
actual=$(curl -fsSL "$QUICK_START" | sha256sum | cut -d' ' -f1)
if [ "$actual" != "$QUICK_START_SHA256" ]; then
  echo "up.sh: $QUICK_START has sha256 $actual, expected $QUICK_START_SHA256" >&2
  echo "up.sh: review the new file, then update QUICK_START_SHA256" >&2
  exit 1
fi

if kind get clusters | grep -qx "$CLUSTER"; then
  echo "== cluster $CLUSTER exists"
else
  echo "== creating cluster $CLUSTER"
  kind create cluster --name "$CLUSTER" --config "$KIND_CONFIG"
fi
ctx=(--context "kind-$CLUSTER")

echo "== Argo + RustFS"
kubectl "${ctx[@]}" create namespace argo --dry-run=client -o yaml | kubectl "${ctx[@]}" apply -f -
kubectl "${ctx[@]}" apply --server-side -k .
kubectl "${ctx[@]}" -n argo rollout status deploy/workflow-controller deploy/argo-server deploy/rustfs --timeout=300s

cat <<MSG

Ready (cluster $CLUSTER, context kind-$CLUSTER):
  Argo UI         https://localhost:2746   (self-signed certificate; no login)
  S3 API          http://localhost:9000    bucket my-bucket, admin / password
  RustFS console  http://localhost:9001
MSG
