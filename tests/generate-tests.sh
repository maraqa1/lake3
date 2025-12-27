#!/usr/bin/env bash
set -euo pipefail

# generate-tests.sh
# Generates per-module test scripts under ./tests/ by applying the template.
# Run from repo root (same folder as 00-env.sh, 00-lib.sh, 01-core.sh, ...)

TEMPLATE_OUT="./tests/__template__.sh"
TESTS_DIR="./tests"

mkdir -p "${TESTS_DIR}"

# ----------------------------------------------------------------------
# 1) Write the template exactly once (edit here if you update the template)
# ----------------------------------------------------------------------
cat > "${TEMPLATE_OUT}" <<'TEMPLATE'
#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# OpenKPI Module Tests & Diagnostics (READ-ONLY)
# Target module contract:
#   Replace <MODULE_FILE_NAME> with the installer module this test validates.
# Examples:
#   02-data-plane.sh  -> tests/t02-data-plane.sh
#   03-app-airbyte.sh -> tests/t03-airbyte.sh
#   04-portal-ui.sh   -> tests/t04-portal-ui.sh
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${HERE}/../00-env.sh"
# shellcheck source=/dev/null
source "${HERE}/../00-lib.sh"

TARGET_MODULE="<MODULE_FILE_NAME>"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

need_cmds() {
  local missing=0
  for c in kubectl curl openssl base64; do
    if ! command -v "$c" >/dev/null 2>&1; then
      echo "Missing required command: $c"
      missing=1
    fi
  done
  [[ $missing -eq 0 ]] || exit 1
}

hr(){ echo "-----------------------------------------------------------------------"; }
sec(){ hr; echo "## $*"; hr; }
ts(){ date -u +"%Y-%m-%dT%H:%M:%SZ"; }

TOTAL=0
PASSED=0
FAILED=0
FAILED_REQUIRED=0

PASS(){ echo "PASS $*"; }
FAIL(){ echo "FAIL $*"; }

# run_test <TAG> <DESC> <REQUIRED:0|1> <CMD...>
run_test() {
  local tag="$1"; shift
  local desc="$1"; shift
  local required="$1"; shift
  TOTAL=$((TOTAL+1))

  if "$@"; then
    PASSED=$((PASSED+1))
    PASS "[$tag] $desc"
    return 0
  else
    FAILED=$((FAILED+1))
    [[ "$required" == "1" ]] && FAILED_REQUIRED=$((FAILED_REQUIRED+1))
    FAIL "[$tag] $desc"
    return 1
  fi
}

# run_diag <TAG> <DESC> <FUNC>
run_diag() {
  local tag="$1"; shift
  local desc="$1"; shift
  local fn="$1"; shift
  sec "Diagnostics for [$tag] $desc"
  "$fn" || true
}

# Capture failure but keep going
try_test() {
  local tag="$1"; shift
  local desc="$1"; shift
  local required="$1"; shift
  local diag_fn="$1"; shift

  if ! run_test "$tag" "$desc" "$required" "$@"; then
    run_diag "$tag" "$desc" "$diag_fn"
    return 1
  fi
  return 0
}

k(){ echo "+ $*"; "$@"; }

# ------------------------------------------------------------------------------
# Derive module intent
# ------------------------------------------------------------------------------

module_base="$(basename "$TARGET_MODULE")"
module_num="${module_base%%-*}"
module_kind="${module_base#*-}"

is_core=0
is_data_plane=0
is_app=0
is_portal_api=0
is_portal_ui=0

case "$module_base" in
  00-env.sh) is_core=1 ;;
  01-core.sh) is_core=1 ;;
  02-data-plane.sh) is_data_plane=1 ;;
  03-app-*.sh) is_app=1 ;;
  04-portal-api.sh) is_portal_api=1 ;;
  04-portal-ui.sh) is_portal_ui=1 ;;
  05-validate.sh) is_core=1 ;;
  *) : ;;
esac

# ------------------------------------------------------------------------------
# Environment expectations (best-effort)
# ------------------------------------------------------------------------------

: "${NS:=open-kpi}"
PLATFORM_NS="${PLATFORM_NS:-platform}"

INGRESS_NS="${INGRESS_NS:-ingress-nginx}"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
TLS_MODE="${TLS_MODE:-off}"

OPENKPI_NS="${NS}"
OPENKPI_PG_SVC="${OPENKPI_PG_SVC:-openkpi-postgres}"
OPENKPI_MINIO_SVC="${OPENKPI_MINIO_SVC:-openkpi-minio}"
OPENKPI_MINIO_CONSOLE_SVC="${OPENKPI_MINIO_CONSOLE_SVC:-openkpi-minio-console}"

PORTAL_HOST="${PORTAL_HOST:-${PORTAL_HOSTNAME:-}}"
AIRBYTE_HOST="${AIRBYTE_HOST:-}"
MINIO_HOST="${MINIO_HOST:-}"
METABASE_HOST="${METABASE_HOST:-}"
N8N_HOST="${N8N_HOST:-}"
ZAMMAD_HOST="${ZAMMAD_HOST:-}"

# ------------------------------------------------------------------------------
# Diagnostics blocks
# ------------------------------------------------------------------------------

diag_ns_core() {
  k kubectl get ns
  k kubectl get nodes -o wide
  k kubectl get sc || true
  k kubectl get pods -A -o wide | tail -n 80 || true
  k kubectl get events -A --sort-by=.lastTimestamp | tail -n 80 || true
}

diag_ingress_core() {
  k kubectl -n "${INGRESS_NS}" get deploy,ds,svc,pod -o wide || true
  k kubectl -n "${INGRESS_NS}" get ingressclass || true
  k kubectl -A get ingress -o wide || true
  k kubectl -n "${INGRESS_NS}" get events --sort-by=.lastTimestamp | tail -n 80 || true
  local any_pod
  any_pod="$(kubectl -n "${INGRESS_NS}" get pod -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$any_pod" ]]; then
    k kubectl -n "${INGRESS_NS}" logs "$any_pod" --tail=200 || true
  fi
}

diag_cert_tls() {
  k kubectl get pods -n cert-manager -o wide || true
  k kubectl get certificate -A -o wide || true
  k kubectl get order,challenge -A -o wide || true
  k kubectl -n cert-manager get events --sort-by=.lastTimestamp | tail -n 80 || true
}

diag_data_plane() {
  k kubectl -n "${OPENKPI_NS}" get sts,deploy,svc,pod -o wide || true
  k kubectl -n "${OPENKPI_NS}" get pvc -o wide || true
  k kubectl -n "${OPENKPI_NS}" describe sts openkpi-postgres || true
  k kubectl -n "${OPENKPI_NS}" describe sts openkpi-minio || true
  local pg_pod
  pg_pod="$(kubectl -n "${OPENKPI_NS}" get pod -l app=openkpi-postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$pg_pod" ]]; then
    k kubectl -n "${OPENKPI_NS}" logs "$pg_pod" --tail=200 || true
  fi
  local minio_pod
  minio_pod="$(kubectl -n "${OPENKPI_NS}" get pod -l app=openkpi-minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$minio_pod" ]]; then
    k kubectl -n "${OPENKPI_NS}" logs "$minio_pod" --tail=200 || true
  fi
  k kubectl -n "${OPENKPI_NS}" get events --sort-by=.lastTimestamp | tail -n 80 || true
}

diag_app_generic() {
  k kubectl get pods -A -o wide | egrep -i 'airbyte|n8n|zammad|dbt|portal|minio|openkpi|postgres' || true
  k kubectl -A get svc,ingress -o wide || true
  k kubectl -A get events --sort-by=.lastTimestamp | tail -n 100 || true
}

diag_portal() {
  k kubectl -n "${PLATFORM_NS}" get deploy,svc,cm,ingress,pod -o wide || true
  k kubectl -n "${PLATFORM_NS}" get events --sort-by=.lastTimestamp | tail -n 80 || true
  local api_pod ui_pod
  api_pod="$(kubectl -n "${PLATFORM_NS}" get pod -l app=portal-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  ui_pod="$(kubectl -n "${PLATFORM_NS}" get pod -l app=portal-ui -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$api_pod" ]] && k kubectl -n "${PLATFORM_NS}" logs "$api_pod" --tail=200 || true
  [[ -n "$ui_pod" ]] && k kubectl -n "${PLATFORM_NS}" logs "$ui_pod" --tail=200 || true
}

# ------------------------------------------------------------------------------
# Low-level checks
# ------------------------------------------------------------------------------

ns_exists() { kubectl get ns "$1" >/dev/null 2>&1; }

deploy_ready() {
  local ns="$1" name="$2" timeout="${3:-180s}"
  kubectl -n "$ns" rollout status "deploy/$name" --timeout="$timeout" >/dev/null 2>&1
}

sts_ready() {
  local ns="$1" name="$2" timeout="${3:-240s}"
  local want ready
  want="$(kubectl -n "$ns" get sts "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")"
  ready="$(kubectl -n "$ns" get sts "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")"
  [[ -n "$want" ]] && [[ "${ready:-0}" -ge "$want" ]]
}

svc_exists() { kubectl -n "$1" get svc "$2" >/dev/null 2>&1; }

pvc_bound_any() {
  kubectl -n "$1" get pvc -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -q "Bound"
}

storageclass_default_exists() {
  kubectl get sc -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' \
    | awk -F'|' '$2=="true"{found=1} END{exit (found?0:1)}'
}

ingress_present_for_host() {
  local host="$1"
  kubectl get ingress -A -o jsonpath='{range .items[*]}{.spec.rules[0].host}{"\n"}{end}' 2>/dev/null | grep -qx "$host"
}

ingress_address_any() {
  kubectl get ingress -A -o jsonpath='{range .items[*]}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}' 2>/dev/null | grep -E -q '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

get_ingress_ip_for_host() {
  local host="$1"
  kubectl get ingress -A -o jsonpath="{range .items[?(@.spec.rules[0].host==\"${host}\")]}{.status.loadBalancer.ingress[0].ip}{end}" 2>/dev/null || true
}

curl_host_root() {
  local host="$1"
  local scheme="http"
  [[ "${TLS_MODE}" != "off" ]] && scheme="https"

  local ip
  ip="$(get_ingress_ip_for_host "$host")"
  if [[ -n "$ip" ]]; then
    curl -fsS --max-time 10 --resolve "${host}:443:${ip}" --resolve "${host}:80:${ip}" "${scheme}://${host}/" >/dev/null
  else
    curl -fsS --max-time 10 "${scheme}://${host}/" >/dev/null
  fi
}

curl_host_path_json() {
  local host="$1" path="$2"
  local scheme="http"
  [[ "${TLS_MODE}" != "off" ]] && scheme="https"

  local ip
  ip="$(get_ingress_ip_for_host "$host")"
  if [[ -n "$ip" ]]; then
    curl -fsS --max-time 10 --resolve "${host}:443:${ip}" --resolve "${host}:80:${ip}" "${scheme}://${host}${path}"
  else
    curl -fsS --max-time 10 "${scheme}://${host}${path}"
  fi
}

# ------------------------------------------------------------------------------
# Postgres tests via ephemeral client pod (allowed)
# ------------------------------------------------------------------------------

pg_secret_exists() { kubectl -n "${OPENKPI_NS}" get secret openkpi-postgres-secret >/dev/null 2>&1; }

pg_get_secret_field() {
  local field="$1"
  kubectl -n "${OPENKPI_NS}" get secret openkpi-postgres-secret -o "jsonpath={.data.${field}}" 2>/dev/null | base64 -d 2>/dev/null || true
}

pg_psql_exec() {
  local sql="$1"
  local pg_user pg_pass pg_db
  pg_user="$(pg_get_secret_field POSTGRES_USER)"
  pg_pass="$(pg_get_secret_field POSTGRES_PASSWORD)"
  pg_db="$(pg_get_secret_field POSTGRES_DB)"
  [[ -n "$pg_user" && -n "$pg_pass" ]] || return 1

  kubectl -n "${OPENKPI_NS}" run "pgtest-$$" --rm -i --restart=Never \
    --image=postgres:16-alpine \
    --env="PGPASSWORD=${pg_pass}" \
    --command -- sh -lc \
    "psql -h ${OPENKPI_PG_SVC} -U ${pg_user} -d ${pg_db:-postgres} -v ON_ERROR_STOP=1 -Atc \"$sql\"" >/dev/null
}

pg_psql_query() {
  local sql="$1"
  local pg_user pg_pass pg_db
  pg_user="$(pg_get_secret_field POSTGRES_USER)"
  pg_pass="$(pg_get_secret_field POSTGRES_PASSWORD)"
  pg_db="$(pg_get_secret_field POSTGRES_DB)"
  [[ -n "$pg_user" && -n "$pg_pass" ]] || return 1

  kubectl -n "${OPENKPI_NS}" run "pgtest-$$" --rm -i --restart=Never \
    --image=postgres:16-alpine \
    --env="PGPASSWORD=${pg_pass}" \
    --command -- sh -lc \
    "psql -h ${OPENKPI_PG_SVC} -U ${pg_user} -d ${pg_db:-postgres} -v ON_ERROR_STOP=1 -Atc \"$sql\""
}

pg_db_exists() {
  local db="$1"
  local out
  out="$(pg_psql_query "SELECT 1 FROM pg_database WHERE datname='${db}';" 2>/dev/null || true)"
  [[ "$out" == "1" ]]
}

pg_role_exists() {
  local role="$1"
  local out
  out="$(pg_psql_query "SELECT 1 FROM pg_roles WHERE rolname='${role}';" 2>/dev/null || true)"
  [[ "$out" == "1" ]]
}

pg_read_test() { pg_psql_exec "SELECT 1;" >/dev/null 2>&1; }

pg_write_rollback_test() {
  pg_psql_exec "BEGIN; CREATE TEMP TABLE _openkpi_rw_test(x int); INSERT INTO _openkpi_rw_test VALUES (1); ROLLBACK; SELECT 1;" >/dev/null 2>&1
}

pg_ro_user_cannot_write() {
  kubectl -n "${PLATFORM_NS}" get secret portal-api-pg-ro >/dev/null 2>&1 || return 1
  local u p
  u="$(kubectl -n "${PLATFORM_NS}" get secret portal-api-pg-ro -o jsonpath='{.data.PGUSER}' | base64 -d 2>/dev/null || true)"
  p="$(kubectl -n "${PLATFORM_NS}" get secret portal-api-pg-ro -o jsonpath='{.data.PGPASSWORD}' | base64 -d 2>/dev/null || true)"
  [[ -n "$u" && -n "$p" ]] || return 1

  kubectl -n "${OPENKPI_NS}" run "pgrotest-$$" --rm -i --restart=Never \
    --image=postgres:16-alpine \
    --env="PGPASSWORD=${p}" \
    --command -- sh -lc \
    "set -e; psql -h ${OPENKPI_PG_SVC} -U ${u} -d postgres -v ON_ERROR_STOP=1 -Atc \"CREATE TABLE _should_fail(x int);\" >/dev/null 2>&1" \
    && return 1 || return 0
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

need_cmds

sec "Module Test Runner"
echo "Time: $(ts)"
echo "Target module: ${TARGET_MODULE}"
echo "NS(open-kpi): ${OPENKPI_NS}"
echo "Platform NS: ${PLATFORM_NS}"
echo "Ingress NS: ${INGRESS_NS}"
echo "Ingress class: ${INGRESS_CLASS}"
echo "TLS mode: ${TLS_MODE}"
hr

try_test "T00-CORE-001" "kubectl can reach cluster" 1 diag_ns_core \
  kubectl version --short >/dev/null 2>&1

try_test "T00-CORE-002" "default StorageClass exists" 1 diag_ns_core \
  storageclass_default_exists

try_test "T00-CORE-003" "namespace ${OPENKPI_NS} exists" 1 diag_ns_core \
  ns_exists "${OPENKPI_NS}"

if [[ $is_core -eq 1 || "$module_base" == "01-core.sh" ]]; then
  try_test "T01-ING-001" "ingress namespace ${INGRESS_NS} exists" 1 diag_ingress_core \
    ns_exists "${INGRESS_NS}"

  try_test "T01-ING-002" "ingress controller has ready pods" 1 diag_ingress_core \
    bash -lc "kubectl -n \"${INGRESS_NS}\" get pods -o jsonpath='{.items[*].status.containerStatuses[0].ready}' 2>/dev/null | tr ' ' '\n' | grep -q true"

  try_test "T01-ING-003" "cluster has at least one ingress with an assigned address" 0 diag_ingress_core \
    ingress_address_any

  if [[ "${TLS_MODE}" != "off" ]]; then
    try_test "T01-TLS-001" "cert-manager namespace exists (TLS enabled)" 1 diag_cert_tls \
      ns_exists "cert-manager"

    try_test "T01-TLS-002" "cert-manager pods ready" 1 diag_cert_tls \
      bash -lc "kubectl -n cert-manager get pods -o jsonpath='{.items[*].status.containerStatuses[0].ready}' 2>/dev/null | tr ' ' '\n' | grep -q true"
  fi
fi

if [[ $is_data_plane -eq 1 ]]; then
  try_test "T02-DP-001" "Postgres StatefulSet openkpi-postgres ready" 1 diag_data_plane \
    sts_ready "${OPENKPI_NS}" "openkpi-postgres" "240s"

  try_test "T02-DP-002" "MinIO StatefulSet openkpi-minio ready" 1 diag_data_plane \
    sts_ready "${OPENKPI_NS}" "openkpi-minio" "240s"

  try_test "T02-DP-003" "Postgres service ${OPENKPI_PG_SVC} exists" 1 diag_data_plane \
    svc_exists "${OPENKPI_NS}" "${OPENKPI_PG_SVC}"

  try_test "T02-DP-004" "MinIO service ${OPENKPI_MINIO_SVC} exists" 1 diag_data_plane \
    svc_exists "${OPENKPI_NS}" "${OPENKPI_MINIO_SVC}"

  try_test "T02-DP-005" "At least one PVC is Bound in ${OPENKPI_NS}" 1 diag_data_plane \
    pvc_bound_any "${OPENKPI_NS}"

  try_test "T02-PG-001" "Postgres secret openkpi-postgres-secret exists" 1 diag_data_plane \
    pg_secret_exists

  try_test "T02-PG-002" "Postgres reachable via ClusterIP (SELECT 1)" 1 diag_data_plane \
    pg_read_test

  try_test "T02-PG-003" "Postgres write test using rollback succeeds" 1 diag_data_plane \
    pg_write_rollback_test
fi

if [[ $is_app -eq 1 ]]; then
  app_name="${module_base#03-app-}"
  app_name="${app_name%.sh}"

  case "$app_name" in
    airbyte) app_ns="airbyte" ;;
    n8n) app_ns="n8n" ;;
    zammad) app_ns="tickets" ;;
    dbt) app_ns="transform" ;;
    minio|postgres) app_ns="${OPENKPI_NS}" ;;
    *) app_ns="$app_name" ;;
  esac

  try_test "T03-APP-001" "namespace ${app_ns} exists" 1 diag_app_generic \
    ns_exists "${app_ns}"

  try_test "T03-APP-002" "pods in ${app_ns} have at least one Ready container" 1 diag_app_generic \
    bash -lc "kubectl -n \"${app_ns}\" get pods -o jsonpath='{.items[*].status.containerStatuses[0].ready}' 2>/dev/null | tr ' ' '\n' | grep -q true"

  case "$app_name" in
    airbyte) host="${AIRBYTE_HOST}" ;;
    n8n) host="${N8N_HOST}" ;;
    zammad) host="${ZAMMAD_HOST}" ;;
    *) host="" ;;
  esac

  if [[ -n "${host}" ]]; then
    try_test "T03-ING-001" "Ingress exists for ${host}" 1 diag_app_generic \
      ingress_present_for_host "${host}"

    try_test "T03-HTTP-001" "HTTP(S) reachable at ${host}/" 1 diag_app_generic \
      curl_host_root "${host}"
  fi

  if [[ "$app_name" == "dbt" || "$app_name" == "n8n" ]]; then
    try_test "T03-PG-001" "Shared Postgres reachable (SELECT 1)" 1 diag_app_generic \
      pg_read_test

    try_test "T03-PG-002" "Write rollback works on shared Postgres" 1 diag_app_generic \
      pg_write_rollback_test

    if [[ "$app_name" == "dbt" ]]; then
      try_test "T03-PG-101" "db 'analytics' exists" 0 diag_app_generic \
        pg_db_exists "analytics"
      try_test "T03-PG-102" "role 'dbt_user' exists" 0 diag_app_generic \
        pg_role_exists "dbt_user"
    fi
    if [[ "$app_name" == "n8n" ]]; then
      try_test "T03-PG-111" "role 'n8n' exists (common)" 0 diag_app_generic \
        pg_role_exists "n8n"
    fi
  fi
fi

if [[ $is_portal_api -eq 1 ]]; then
  try_test "T04-NS-001" "namespace ${PLATFORM_NS} exists" 1 diag_portal \
    ns_exists "${PLATFORM_NS}"

  try_test "T04-API-001" "portal-api deployment ready" 1 diag_portal \
    deploy_ready "${PLATFORM_NS}" "portal-api" "180s"

  try_test "T04-API-002" "portal-api service exists" 1 diag_portal \
    svc_exists "${PLATFORM_NS}" "portal-api"

  try_test "T04-PG-001" "Shared Postgres reachable (SELECT 1)" 1 diag_portal \
    pg_read_test

  try_test "T04-PG-002" "Read-only user cannot write (if RO secret exists)" 0 diag_portal \
    pg_ro_user_cannot_write

  if [[ -n "${PORTAL_HOST}" ]]; then
    try_test "T04-ING-001" "Ingress exists for ${PORTAL_HOST}" 1 diag_portal \
      ingress_present_for_host "${PORTAL_HOST}"

    try_test "T04-HTTP-001" "Portal root reachable at ${PORTAL_HOST}/" 1 diag_portal \
      curl_host_root "${PORTAL_HOST}"

    try_test "T04-API-101" "/api/summary returns JSON" 1 diag_portal \
      bash -lc "curl_host_path_json \"${PORTAL_HOST}\" \"/api/summary\" | head -c 1 | grep -Eq '\\{|\\['"

    try_test "T04-API-102" "/api/summary non-empty payload" 1 diag_portal \
      bash -lc "[[ \$(curl_host_path_json \"${PORTAL_HOST}\" \"/api/summary\" | wc -c) -ge 20 ]]"
  fi
fi

if [[ $is_portal_ui -eq 1 ]]; then
  try_test "T04-NS-011" "namespace ${PLATFORM_NS} exists" 1 diag_portal \
    ns_exists "${PLATFORM_NS}"

  try_test "T04-UI-001" "portal-ui deployment ready" 1 diag_portal \
    deploy_ready "${PLATFORM_NS}" "portal-ui" "180s"

  try_test "T04-UI-002" "portal-ui service exists" 1 diag_portal \
    svc_exists "${PLATFORM_NS}" "portal-ui"

  try_test "T04-UI-003" "portal-api service exists (UI dependency)" 0 diag_portal \
    svc_exists "${PLATFORM_NS}" "portal-api"

  if [[ -n "${PORTAL_HOST}" ]]; then
    try_test "T04-ING-011" "Ingress exists for ${PORTAL_HOST}" 1 diag_portal \
      ingress_present_for_host "${PORTAL_HOST}"

    try_test "T04-HTTP-011" "Portal UI reachable at ${PORTAL_HOST}/" 1 diag_portal \
      curl_host_root "${PORTAL_HOST}"

    try_test "T04-UI-101" "Portal UI serves HTML" 1 diag_portal \
      bash -lc "curl_host_path_json \"${PORTAL_HOST}\" \"/\" | tr -d '\\n' | grep -qi '<html'"

    try_test "T04-API-111" "/api/summary returns JSON (for UI data)" 0 diag_portal \
      bash -lc "curl_host_path_json \"${PORTAL_HOST}\" \"/api/summary\" | head -c 1 | grep -Eq '\\{|\\['"
  fi
fi

if [[ $is_core -eq 0 && $is_data_plane -eq 0 && $is_app -eq 0 && $is_portal_api -eq 0 && $is_portal_ui -eq 0 ]]; then
  try_test "T99-GEN-001" "module type recognized (informational)" 0 diag_ns_core \
    bash -lc "echo \"Unknown module: ${module_base}\" >/dev/null; exit 1"
fi

sec "Summary"
echo "Target module: ${TARGET_MODULE}"
echo "Total tests:   ${TOTAL}"
echo "Passed:        ${PASSED}"
echo "Failed:        ${FAILED}"
echo "Failed req'd:  ${FAILED_REQUIRED}"
echo "Exit code:     $([[ ${FAILED_REQUIRED} -eq 0 ]] && echo 0 || echo 1)"
hr

if [[ ${FAILED_REQUIRED} -eq 0 ]]; then
  exit 0
else
  exit 1
fi
TEMPLATE

chmod 0755 "${TEMPLATE_OUT}"

# ----------------------------------------------------------------------
# 2) Mapping: module -> tests filename
# ----------------------------------------------------------------------
derive_test_name() {
  local mod="$1"
  case "$mod" in
    00-env.sh) echo "t00-env.sh" ;;
    00-lib.sh) echo "t00-lib.sh" ;;
    01-core.sh) echo "t01-core.sh" ;;
    02-data-plane.sh) echo "t02-data-plane.sh" ;;
    03-app-airbyte.sh) echo "t03-airbyte.sh" ;;
    03-app-n8n.sh) echo "t03-n8n.sh" ;;
    03-app-zammad.sh) echo "t03-zammad.sh" ;;
    03-app-dbt.sh) echo "t03-dbt.sh" ;;
    04-portal-api.sh) echo "t04-portal-api.sh" ;;
    04-portal-ui.sh) echo "t04-portal-ui.sh" ;;
    05-validate.sh) echo "t05-validate.sh" ;;
    *)
      # generic: keep number + basename
      local base
      base="$(basename "$mod")"
      local n="${base%%-*}"
      echo "t${n}-${base}"
      ;;
  esac
}

MODULES=(
  "00-env.sh"
  "00-lib.sh"
  "01-core.sh"
  "02-data-plane.sh"
  "03-app-airbyte.sh"
  "03-app-n8n.sh"
  "03-app-zammad.sh"
  "03-app-dbt.sh"
  "04-portal-api.sh"
  "04-portal-ui.sh"
  "05-validate.sh"
)

# ----------------------------------------------------------------------
# 3) Generate test scripts
# ----------------------------------------------------------------------
for m in "${MODULES[@]}"; do
  if [[ ! -f "./${m}" ]]; then
    echo "SKIP missing module: ./${m}"
    continue
  fi

  tname="$(derive_test_name "$m")"
  out="${TESTS_DIR}/${tname}"

  sed "s|TARGET_MODULE=\"<MODULE_FILE_NAME>\"|TARGET_MODULE=\"${m}\"|g" "${TEMPLATE_OUT}" > "${out}"
  chmod 0755 "${out}"
  echo "OK  generated: ${out}"
done

# Optional: remove the template file after generation
rm -f "${TEMPLATE_OUT}"

echo "DONE"
