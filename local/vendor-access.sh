#!/usr/bin/env bash
# What hydrowf-ogc's step-key vendor needs when it runs in Docker beside kind (hydrowf-ogc docs/ogc.md, "Steps
# that read in place"): the token of the service account hydrowf-ogc (hydrowf-ogc.yaml: create TokenReviews, get
# pods in argo, nothing else) and the cluster's CA, written to files in $OUT (default ~/.config/hydrowf/kind-<cluster>,
# mode 600), plus the settings to run it with. Prints no token. Safe to run again (it rewrites both files).
set -euo pipefail
CLUSTER=${CLUSTER:-hydrowf}
ctx=(--context "kind-$CLUSTER")
OUT=${OUT:-$HOME/.config/hydrowf/kind-$CLUSTER}

token=""
for try in $(seq 30); do     # Kubernetes fills the Secret's token shortly after it is made
  if [ "$try" -lt 30 ]; then
    token=$(kubectl "${ctx[@]}" -n argo get secret hydrowf-ogc-token -o 'jsonpath={.data.token}' 2>/dev/null || true)
  else                       # the last try shows kubectl's own error (wrong context, no cluster, no Secret)
    token=$(kubectl "${ctx[@]}" -n argo get secret hydrowf-ogc-token -o 'jsonpath={.data.token}' || true)
  fi
  [ -n "$token" ] && break
  sleep 1
done
[ -n "$token" ] || { echo "vendor-access.sh: Secret argo/hydrowf-ogc-token has no token (run up.sh first)" >&2; exit 1; }

# step pods reach a server on this machine at the kind network's IPv4 gateway
gateway=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' | tr ' ' '\n' \
  | grep -m1 -E '^[0-9.]+$' || true)
[ -n "$gateway" ] || { echo "vendor-access.sh: the Docker network kind has no IPv4 gateway" >&2; exit 1; }

umask 077
mkdir -p "$OUT"
chmod 700 "$OUT"             # umask doesn't change a folder or file that is already there
printf '%s' "$token" | base64 -d > "$OUT/token"
kubectl "${ctx[@]}" config view --raw --minify -o 'jsonpath={.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > "$OUT/ca.crt"
chmod 600 "$OUT/token" "$OUT/ca.crt"
[ -s "$OUT/ca.crt" ] || { echo "vendor-access.sh: no CA for kind-$CLUSTER in the kubeconfig" >&2; exit 1; }
api=$(kubectl "${ctx[@]}" config view --minify -o 'jsonpath={.clusters[0].cluster.server}')

cat <<MSG
== token and CA in $OUT

Run hydrowf-ogc (network host, as you, so it can read them) with, besides its usual settings:
  --user "\$(id -u)" -v $OUT:/run/hydrowf-k8s:ro
  -e HYDROWF_K8S_API=$api
  -e HYDROWF_K8S_TOKEN_FILE=/run/hydrowf-k8s/token
  -e HYDROWF_K8S_CA_FILE=/run/hydrowf-k8s/ca.crt

and in its manager config, beside credentials.role_arn:
  credentials:
    steps:
      vendor_url: http://$gateway:8001/step-keys
      init_image: curlimages/curl@sha256:c1fe1679c34d9784c1b0d1e5f62ac0a79fca01fb6377cdd33e90473c6f9f9a69   # 8.11.1
      s3_endpoint: http://minio.argo.svc.cluster.local:9000
MSG
