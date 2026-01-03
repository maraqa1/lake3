#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

ROOT="${HERE}"
while [[ "${ROOT}" != "/" && ! -f "${ROOT}/00-env.sh" ]]; do
  ROOT="$(dirname "${ROOT}")"
done
[[ -f "${ROOT}/00-env.sh" ]] || { echo "[FATAL] cannot find 00-env.sh above ${HERE}"; exit 1; }

. "${ROOT}/00-env.sh"
. "${ROOT}/00-lib.sh" 2>/dev/null || true

fatal() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [FATAL] $*" >&2; exit 1; }

retry() {
  local attempts="$1" sleep_s="$2"; shift 2
  local i=1
  while true; do
    if "$@"; then return 0; fi
    if [[ "$i" -ge "$attempts" ]]; then return 1; fi
    i=$((i+1))
    sleep "$sleep_s"
  done
}

command -v require_cmd >/dev/null 2>&1 || require_cmd(){ command -v "$1" >/dev/null 2>&1 || fatal "Missing required command: $1"; }

require_cmd kubectl
require_cmd curl

NS="${AIRBYTE_NS:-airbyte}"
MINIO_ALIAS_SVC="${MINIO_ALIAS_SVC:-airbyte-minio-external}"
AIRBYTE_HOST="${AIRBYTE_HOST:?missing AIRBYTE_HOST}"

TLS_MODE="${TLS_MODE:-off}"
URL_SCHEME="http"
[[ "${TLS_MODE}" != "off" ]] && URL_SCHEME="https"

command -v log >/dev/null 2>&1 || log(){ echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [INFO] $*"; }

log "[03-airbyte][tests] start (ns=${NS})"

kubectl -n "${NS}" get deploy airbyte-server airbyte-worker airbyte-workload-api-server airbyte-workload-launcher >/dev/null
kubectl -n "${NS}" get cm airbyte-airbyte-env >/dev/null
kubectl -n "${NS}" get secret airbyte-airbyte-secrets >/dev/null

ep="$(kubectl -n "${NS}" get cm airbyte-airbyte-env -o jsonpath='{.data.MINIO_ENDPOINT}' 2>/dev/null || true)"
[[ "${ep}" == "http://${MINIO_ALIAS_SVC}:9000" ]] || fatal "[03-airbyte][tests] MINIO_ENDPOINT wrong: ${ep}"

if kubectl -n "${NS}" get sts airbyte-minio >/dev/null 2>&1; then
  r="$(kubectl -n "${NS}" get sts airbyte-minio -o jsonpath='{.spec.replicas}')"
  [[ "${r}" == "0" ]] || fatal "[03-airbyte][tests] sts/airbyte-minio replicas=${r} (expected 0)"
fi

kubectl -n "${NS}" rollout status deploy/airbyte-server --timeout=20m
kubectl -n "${NS}" rollout status deploy/airbyte-worker --timeout=20m

retry 18 10 bash -lc "curl -k -sS -o /dev/null -m 15 -w '%{http_code}' ${URL_SCHEME}://${AIRBYTE_HOST}/ | egrep -q '^(200|302|307|308|401|403)$'" \
  || fatal "[03-airbyte][tests] ingress not reachable: ${URL_SCHEME}://${AIRBYTE_HOST}/"

log "[03-airbyte][tests] OK"
