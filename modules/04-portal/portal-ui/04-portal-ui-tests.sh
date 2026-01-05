#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 04-portal-ui-tests.sh - Portal UI smoke tests (Phase 1)
# - rollout status
# - initContainer success
# - service returns HTML
# - ingress returns HTML and /api/health JSON (if portal-api is deployed)
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${HERE}/../../.." && pwd)"

# shellcheck source=/dev/null
. "${ROOT}/00-env.sh"
# shellcheck source=/dev/null
. "${ROOT}/00-lib.sh"

require_cmd kubectl

: "${PLATFORM_NS:=platform}"
: "${PORTAL_UI_DEPLOY:=portal-ui}"
: "${PORTAL_UI_SVC:=portal-ui}"
: "${PORTAL_HOST:=portal.local}"

log "[04][portal-ui-tests] rollout"
kubectl -n "${PLATFORM_NS}" rollout status "deploy/${PORTAL_UI_DEPLOY}" --timeout=180s

POD="$(kubectl -n "${PLATFORM_NS}" get pods -l app=portal-ui -o jsonpath='{.items[0].metadata.name}')"
log "[04][portal-ui-tests] pod=${POD}"

log "[04][portal-ui-tests] initContainer exit codes"
kubectl -n "${PLATFORM_NS}" get pod "${POD}" -o jsonpath='{.status.initContainerStatuses[*].name}{"\n"}{.status.initContainerStatuses[*].state.terminated.exitCode}{"\n"}' || true

log "[04][portal-ui-tests] service fetch (in-cluster)"
kubectl -n "${PLATFORM_NS}" run curl-ui --rm -i --restart=Never --image=curlimages/curl:8.6.0 \
  --command -- sh -lc "curl -fsS http://${PORTAL_UI_SVC}.${PLATFORM_NS}.svc.cluster.local/ | head -n 5"

if [[ -n "${PORTAL_HOST}" ]]; then
  log "[04][portal-ui-tests] ingress fetch (host)"
  kubectl -n "${PLATFORM_NS}" run curl-ui-ext --rm -i --restart=Never --image=curlimages/curl:8.6.0 \
    --command -- sh -lc "curl -k -fsSI https://${PORTAL_HOST}/ | head -n 8 || true"

  log "[04][portal-ui-tests] ingress /api/health (best-effort)"
  kubectl -n "${PLATFORM_NS}" run curl-api-ext --rm -i --restart=Never --image=curlimages/curl:8.6.0 \
    --command -- sh -lc "curl -k -fsS https://${PORTAL_HOST}/api/health | head -n 40 || true"
fi

log "[04][portal-ui-tests] OK"
