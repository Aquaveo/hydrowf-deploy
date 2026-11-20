#!/usr/bin/env bash
# The read-only S3 user hydrowf-ogc issues read keys from (GET /ogc/jobs/{id}/credentials): RustFS user
# hydrowf-reader with policy hydrowf-read (s3-reader-policy.json: GetObject and ListBucket on my-bucket,
# nothing else). Its keys are kept in the Secret hydrowf-s3-reader (namespace argo), made once; the
# script prints none. Safe to run again: it sets the policy, the user and its secret to what they should be.
#
# Needs the S3 API on localhost:9000 (kubectl --context kind-hydrowf -n argo port-forward svc/minio 9000)
# and Docker: the user is made with minio-py's admin client in a container (RustFS speaks MinIO's admin API).
#
# Then run hydrowf-ogc with HYDROWF_S3_READER_ACCESS_KEY / HYDROWF_S3_READER_SECRET_KEY from that Secret.
set -euo pipefail
cd "$(dirname "$0")"
ctx=(--context "kind-${CLUSTER:-hydrowf}" -n argo)
S3=${S3:-localhost:9000}
MINIO_PY="minio==7.2.20"

secret() {                     # <secret> <key>: its value, or exit (never an empty key)
  local value
  value=$(kubectl "${ctx[@]}" get secret "$1" -o "jsonpath={.data.$2}") && [ -n "$value" ] \
    || { echo "s3-reader.sh: secret $1 has no $2" >&2; exit 1; }
  printf '%s' "$value" | base64 -d
}

if ! kubectl "${ctx[@]}" get secret hydrowf-s3-reader >/dev/null 2>&1; then
  # from stdin: the new key is never on a command line
  printf 'accesskey=hydrowf-reader\nsecretkey=%s\n' "$(python3 -c 'import secrets; print(secrets.token_urlsafe(30))')" \
    | kubectl "${ctx[@]}" create secret generic hydrowf-s3-reader --from-env-file=/dev/stdin >/dev/null
  echo "== Secret hydrowf-s3-reader: created"
fi

# Read every key first (a failure stops here), then hand them to the container by name only: docker run
# -e NAME takes the value from this environment, so no key is on a command line.
ADMIN_K=$(secret my-minio-cred accesskey); ADMIN_S=$(secret my-minio-cred secretkey)
READER_K=$(secret hydrowf-s3-reader accesskey); READER_S=$(secret hydrowf-s3-reader secretkey)
export S3 ADMIN_K ADMIN_S READER_K READER_S

echo "== policy hydrowf-read and user hydrowf-reader on $S3"
docker run --rm --network host -v "$PWD/s3-reader-policy.json:/policy.json:ro" \
  -e S3 -e ADMIN_K -e ADMIN_S -e READER_K -e READER_S \
  python:3.12-slim sh -c "pip install -q --disable-pip-version-check --root-user-action=ignore '$MINIO_PY' >/dev/null && python -I -c '
import json, os
from minio.credentials import StaticProvider
from minio.minioadmin import MinioAdmin
admin = MinioAdmin(endpoint=os.environ[\"S3\"], secure=False,
                   credentials=StaticProvider(os.environ[\"ADMIN_K\"], os.environ[\"ADMIN_S\"]))
admin.policy_add(\"hydrowf-read\", \"/policy.json\")
admin.user_add(os.environ[\"READER_K\"], os.environ[\"READER_S\"])
try:
    admin.attach_policy([\"hydrowf-read\"], user=os.environ[\"READER_K\"])
except Exception as err:  # RustFS answers in a cipher minio-py 7.2 cannot read; MinIO refuses a policy already
    print(\"   attach:\", type(err).__name__, \"(checked below)\")   # attached. Either way user_info decides:
info = json.loads(admin.user_info(os.environ[\"READER_K\"]))
assert info.get(\"policyName\") == \"hydrowf-read\" and info.get(\"status\") == \"enabled\", info
print(\"   user\", os.environ[\"READER_K\"], \"enabled, policy\", info[\"policyName\"])
'"
