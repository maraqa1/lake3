#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${HERE}/../../.." && pwd)"

# shellcheck source=/dev/null
. "${ROOT}/00-env.sh"
# shellcheck source=/dev/null
. "${ROOT}/00-lib.sh"

require_cmd kubectl jq curl

# Local URL scheme fallback (don’t rely on 00-env exporting URL_SCHEME)
URL_SCHEME_LOCAL="http"
if [[ "${TLS_MODE:-off}" != "off" && "${TLS_MODE:-off}" != "disabled" && "${TLS_MODE:-off}" != "false" && "${TLS_MODE:-off}" != "0" ]]; then
  URL_SCHEME_LOCAL="https"
fi

NS="${PLATFORM_NS:-platform}"
APP_NAME="portal-api"
SVC="${PORTAL_API_SVC:-portal-api}"
PORT="8000"

BASE_EXTERNAL="${URL_SCHEME_LOCAL}://${PORTAL_HOST}"
BASE_INTERNAL="http://${SVC}.${NS}.svc.cluster.local:${PORT}"

REQ_SERVICES_CSV="kubernetes,postgres,minio,ingress_tls,airbyte,dbt,n8n,zammad,metabase"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
fail() { echo "$(ts) [TEST][FAIL] $*" >&2; exit 1; }
ok() { echo "$(ts) [TEST][OK] $*"; }

assert_top_shape() {
  local json="$1"
  echo "${json}" | jq -e 'has("generated_at") and has("platform_status") and has("operational") and has("links") and has("services") and has("k8s") and has("postgres") and has("assets") and has("proof")' >/dev/null \
    || fail "missing required top-level keys"
  echo "${json}" | jq -e '.operational|has("x") and has("y")' >/dev/null || fail "operational.x/y missing"
  echo "${json}" | jq -e '.links|has("portal") and has("airbyte") and has("minio") and has("metabase") and has("dbt_docs") and has("dbt_lineage") and has("n8n") and has("zammad")' >/dev/null \
    || fail "links contract missing keys"
  echo "${json}" | jq -e '.services|type=="array" and length>0' >/dev/null || fail "services[] missing/empty"

  local names dup
  names="$(echo "${json}" | jq -r '.services[].name' | sort)"
  dup="$(echo "${names}" | uniq -d || true)"
  [[ -z "${dup}" ]] || fail "duplicate service entries: ${dup}"

  local r
  IFS=',' read -r -a req <<< "${REQ_SERVICES_CSV}"
  for r in "${req[@]}"; do
    echo "${names}" | grep -qx "${r}" || fail "missing service entry: ${r}"
  done
}

assert_service_shape() {
  local json="$1"
  echo "${json}" | jq -e '
    .services[] |
    has("name") and has("status") and has("reason") and has("last_checked") and has("links") and has("evidence") and
    (.links|has("ui") and has("api")) and
    (.evidence|has("type") and has("details"))
  ' >/dev/null || fail "one or more service objects missing required keys"
}

probe_url() {
  local url="$1"
  curl -fsS --connect-timeout 3 --max-time 20 "${url}"
}

incluster_probe() {
  local path="$1"
  kubectl -n "${NS}" run "portal-api-test-$$" --rm -i --restart=Never \
    --image=alpine:3.20 --command -- sh -lc "
      apk add --no-cache curl jq >/dev/null
      curl -fsS --connect-timeout 3 --max-time 20 '${BASE_INTERNAL}${path}'
    "
}

backup_secret() {
  local name="$1" out="$2"
  kubectl -n "${NS}" get secret "${name}" -o yaml > "${out}"
}

restore_secret() {
  local in="$1"
  kubectl apply -f "${in}" >/dev/null
  kubectl -n "${NS}" rollout status "deploy/${APP_NAME}" --timeout=180s
}

delete_secret_key() {
  local name="$1" key="$2"
  kubectl -n "${NS}" get secret "${name}" >/dev/null 2>&1 || return 0
  kubectl -n "${NS}" patch secret "${name}" --type=json -p "[{\"op\":\"remove\",\"path\":\"/data/${key}\"}]" >/dev/null 2>&1 || true
  kubectl -n "${NS}" rollout status "deploy/${APP_NAME}" --timeout=180s
}

assert_degraded() {
  local json="$1" svc="$2" reason_re="$3"
  echo "${json}" | jq -e --arg s "${svc}" '.services[] | select(.name==$s) | (.status=="DEGRADED" or .status=="INFO" or .status=="DOWN")' >/dev/null \
    || fail "${svc} expected DEGRADED/INFO/DOWN but was OPERATIONAL"
  echo "${json}" | jq -e --arg s "${svc}" --arg r "${reason_re}" '.services[] | select(.name==$s) | (.reason|tostring|test($r))' >/dev/null \
    || fail "${svc} expected reason matching '${reason_re}'"
}

echo "$(ts) [TEST] start"

HEALTH_JSON="$(incluster_probe "/api/health")" || { kubectl -n "${NS}" get pods -l app="${APP_NAME}" -o wide || true; fail "in-cluster /api/health failed"; }
echo "${HEALTH_JSON}" | jq -e 'has("status") and has("generated_at")' >/dev/null || fail "/api/health shape invalid"
ok "in-cluster /api/health"

SUMMARY_JSON="$(incluster_probe "/api/summary")" || fail "in-cluster /api/summary failed"
assert_top_shape "${SUMMARY_JSON}"
assert_service_shape "${SUMMARY_JSON}"
ok "in-cluster /api/summary contract"

EXT_SUMMARY="$(probe_url "${BASE_EXTERNAL}/api/summary")" || fail "external /api/summary failed (${BASE_EXTERNAL})"
assert_top_shape "${EXT_SUMMARY}"
assert_service_shape "${EXT_SUMMARY}"
ok "external /api/summary contract"

SECRET_NAME="portal-api-secret-optional"
TMPDIR="$(mktemp -d)"
BACKUP_YAML="${TMPDIR}/secret-backup.yaml"
backup_secret "${SECRET_NAME}" "${BACKUP_YAML}" || true

delete_secret_key "${SECRET_NAME}" "ZAMMAD_API_TOKEN"
D1="$(probe_url "${BASE_EXTERNAL}/api/summary")" || fail "external /api/summary failed after zammad token removal"
assert_degraded "${D1}" "zammad" "token|API token|not configured"
ok "zammad degradation verified"

delete_secret_key "${SECRET_NAME}" "N8N_API_KEY"
delete_secret_key "${SECRET_NAME}" "N8N_BASIC_USER"
delete_secret_key "${SECRET_NAME}" "N8N_BASIC_PASS"
D2="$(probe_url "${BASE_EXTERNAL}/api/summary")" || fail "external /api/summary failed after n8n auth removal"
assert_degraded "${D2}" "n8n" "auth|API auth|not configured"
ok "n8n degradation verified"

if [[ -s "${BACKUP_YAML}" ]]; then
  restore_secret "${BACKUP_YAML}"
fi

ok "all tests passed"
