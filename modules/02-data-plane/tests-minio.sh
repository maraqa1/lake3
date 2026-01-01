#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/../../00-env.sh"

require_cmd kubectl
require_var OPENKPI_NS
require_var MINIO_API_PORT

NS="${OPENKPI_NS}"
kubectl -n "${NS}" get pvc openkpi-minio-pvc >/dev/null
kubectl -n "${NS}" get svc openkpi-minio openkpi-minio-console >/dev/null
kubectl -n "${NS}" get sts openkpi-minio >/dev/null
kubectl -n "${NS}" rollout status sts/openkpi-minio --timeout=240s

# In-cluster HTTP readiness via a short-lived pod
kubectl -n "${NS}" run minio-smoke --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -fsS "http://openkpi-minio:${MINIO_API_PORT}/minio/health/ready" >/dev/null

log "[02-minio][tests] OK"
