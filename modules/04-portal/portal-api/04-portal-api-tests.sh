\
#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${HERE}/../../.." && pwd)"
# shellcheck source=/dev/null
. "${ROOT}/00-env.sh"
# shellcheck source=/dev/null
. "${ROOT}/00-lib.sh"

: "${PLATFORM_NS:=platform}"
: "${PORTAL_API_SVC:=portal-api}"
: "${PORTAL_API_PORT:=8000}"
: "${PORTAL_HOST:=portal.local}"

log "[04][portal-api-tests] start"

kubectl -n "${PLATFORM_NS}" rollout status deploy/portal-api --timeout=180s

kubectl -n "${PLATFORM_NS}" run curl-api --rm -i --restart=Never --image=curlimages/curl:8.6.0 \
  --command -- sh -lc "curl -fsS http://${PORTAL_API_SVC}.${PLATFORM_NS}.svc.cluster.local:${PORTAL_API_PORT}/api/health | head"

if [[ "${TLS_MODE:-off}" != "off" ]]; then
  curl -k -fsS "https://${PORTAL_HOST}/api/health" | head
else
  curl -fsS "http://${PORTAL_HOST}/api/health" | head || true
fi

log "[04][portal-api-tests] OK"
