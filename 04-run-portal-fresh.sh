#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "${HERE}/00-env.sh" ]] && . "${HERE}/00-env.sh" || true

need(){ command -v "$1" >/dev/null 2>&1 || { echo "[FATAL] missing: $1" >&2; exit 1; }; }
need kubectl
need curl

log(){ echo "[04RUN][PORTAL] $*"; }
warn(){ echo "[04RUN][PORTAL][WARN] $*" >&2; }

PLATFORM_NS="${PLATFORM_NS:-platform}"
UI_DEPLOY="${PORTAL_UI_DEPLOY:-portal-ui}"
UI_SVC="${PORTAL_UI_SVC:-portal-ui}"
UI_CM="${PORTAL_UI_CM:-portal-ui-static}"
API_DEPLOY="${PORTAL_API_DEPLOY:-portal-api}"
API_SVC="${PORTAL_API_SVC:-portal-api}"
INGRESS_NAME="${PORTAL_INGRESS_NAME:-portal}"
CERT_NAME="${PORTAL_CERT_NAME:-portal-cert}"

PORTAL_HOST="${PORTAL_HOST:-}"
TLS_MODE="${TLS_MODE:-per-host-http01}"
SCHEME="http"
[[ "${TLS_MODE}" == "per-host-http01" ]] && SCHEME="https"

cleanup_portal(){
  log "Portal-only cleanup in namespace=${PLATFORM_NS}"

  kubectl -n "${PLATFORM_NS}" delete ingress "${INGRESS_NAME}" --ignore-not-found
  kubectl -n "${PLATFORM_NS}" delete certificate "${CERT_NAME}" --ignore-not-found

  kubectl -n "${PLATFORM_NS}" delete deploy "${UI_DEPLOY}" --ignore-not-found
  kubectl -n "${PLATFORM_NS}" delete svc "${UI_SVC}" --ignore-not-found
  kubectl -n "${PLATFORM_NS}" delete cm  "${UI_CM}" --ignore-not-found

  kubectl -n "${PLATFORM_NS}" delete deploy "${API_DEPLOY}" --ignore-not-found
  kubectl -n "${PLATFORM_NS}" delete svc "${API_SVC}" --ignore-not-found
  kubectl -n "${PLATFORM_NS}" delete cm  portal-api-code --ignore-not-found
  kubectl -n "${PLATFORM_NS}" delete secret portal-api-secrets --ignore-not-found

  log "Wait old portal pods to terminate"
  for _ in $(seq 1 60); do
    if kubectl -n "${PLATFORM_NS}" get pods -l app="${UI_DEPLOY}" 2>/dev/null | awk 'NR>1{exit 1}'; then :; else
      sleep 2
      continue
    fi
    if kubectl -n "${PLATFORM_NS}" get pods -l app="${API_DEPLOY}" 2>/dev/null | awk 'NR>1{exit 1}'; then :; else
      sleep 2
      continue
    fi
    break
  done
  log "Cleanup done"
}

run_api(){
  log "Run API installer: ${HERE}/04-portal-api-v2.sh"
  "${HERE}/04-portal-api-v2.sh"
  log "Wait API rollout"
  kubectl -n "${PLATFORM_NS}" rollout status deploy "${API_DEPLOY}" --timeout=240s

  if [[ -n "${PORTAL_HOST}" ]]; then
    log "TEST: API health via ingress"
    curl -sk "${SCHEME}://${PORTAL_HOST}/api/health" | head -c 200 || true
    echo
  fi
}

run_api_patch_appstate(){
  local p="${HERE}/04X-api-appstate.patch.sh"
  [[ -f "${p}" ]] || { warn "Skip API app-state patch (missing ${p})"; return 0; }

  log "Run API app-state patch: ${p}"
  set +e
  "${p}"
  local rc=$?
  set -e
  [[ $rc -eq 0 ]] || warn "API patch returned non-zero (continuing)"

  log "Wait API rollout after patch"
  kubectl -n "${PLATFORM_NS}" rollout status deploy "${API_DEPLOY}" --timeout=240s
}

run_ui(){
  log "Run UI installer: ${HERE}/04-portal-ui-v1.sh"
  "${HERE}/04-portal-ui-v1.sh" || true

  # UI installer can time out while pod crashloops; patch fixes that; do not stop here.
  log "UI status (pre-patch)"
  kubectl -n "${PLATFORM_NS}" get deploy "${UI_DEPLOY}" -o wide || true
  kubectl -n "${PLATFORM_NS}" get pods -l app="${UI_DEPLOY}" -o wide || true
}

run_ui_patch_nginxconf(){
  local p="${HERE}/04X-ui-nginxconf-context-fix.patch.sh"
  log "Run UI nginx.conf context patch: ${p}"
  "${p}"
}

post_tests(){
  [[ -n "${PORTAL_HOST}" ]] || return 0

  log "TEST: Portal UI"
  curl -skI "${SCHEME}://${PORTAL_HOST}/" | tr -d '\r' | egrep -i 'HTTP/|content-type:' || true

  log "TEST: Portal Summary"
  curl -sk "${SCHEME}://${PORTAL_HOST}/api/summary?v=1" | head -c 400 || true
  echo
}

cleanup_portal
run_api
run_api_patch_appstate
run_ui
run_ui_patch_nginxconf
post_tests

log "URL: ${SCHEME}://${PORTAL_HOST}/"
log "API: ${SCHEME}://${PORTAL_HOST}/api/health"
log "SUM: ${SCHEME}://${PORTAL_HOST}/api/summary?v=1"
