#!/usr/bin/env bash
# Deletes the local cluster, with everything in it: workflows, the S3 bucket, loaded images.
set -euo pipefail
CLUSTER=${CLUSTER:-hydrowf}
kind delete cluster --name "$CLUSTER"
