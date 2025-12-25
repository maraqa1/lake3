#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 05-validate.sh — End-to-end platform validation
# - Validates core infra + shared data plane + optional apps + portal
# - Exits non-zero on first failure
# - Prints a single URL summary block at the end
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/00-env.sh"
. "${HERE}/00-lib.sh"

require_cmd kubectl

# -------------------------
# helpers
# -------------------------
http_probe() {
  # usage: http_probe <url> <timeout_seconds>
  local url="$1"
  local timeout="${2:-10}"

  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time "$timeout" "$url" >/dev/null
    return 0
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -q -T "$timeout" -O /dev/null "$url"
    return 0
  fi

  fatal "Missing curl/wget for HTTP validation"
}

http_probe_json() {
  # usage: http_probe_json <url> <timeout_seconds>
  local url="$1"
  local timeout="${2:-10}"

  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time "$timeout" "$url" | grep -qE '^\s*[{[]'
    return 0
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -q -T "$timeout" -O - "$url" | grep -qE '^\s*[{[]'
    return 0
  fi

  fatal "Missing curl/wget for HTTP JSON validation"
}

ns_exists() {
  local ns="$1"
  kubectl get ns "$ns" >/dev/null 2>&1
}

has_resource() {
  # usage: has_resource <kind> <name> <ns>
  local kind="$1" name="$2" ns="$3"
  kubectl -n "$ns" get "$kind" "$name" >/dev/null 2>&1
}

wait_svc_endpoints() {
  # usage: wait_svc_endpoints <ns> <svc> <timeout_seconds>
  local ns="$1" svc="$2" timeout="${3:-120}"
  local end=$((SECONDS + timeout))
  while (( SECONDS < end )); do
    local addrs
    addrs="$(kubectl -n "$ns" get endpoints "$svc" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
    if [[ -n "${addrs// /}" ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

ingress_controller_ready() {
  # validates chosen ingress controller is present and has ready pods
  local cls="${INGRESS_CLASS:-traefik}"

  if [[ "$cls" == "traefik" ]]; then
    # k3s default traefik
    kubectl -n kube-system get deploy traefik >/dev/null 2>&1 || return 1
    kubectl -n kube-system wait --for=condition=Available deploy/traefik --timeout=180s >/dev/null
    return 0
  fi

  if [[ "$cls" == "nginx" ]]; then
    # ingress-nginx helm install typically in ingress-nginx ns
    kubectl -n ingress-nginx get deploy ingress-nginx-controller >/dev/null 2>&1 || return 1
    kubectl -n ingress-nginx wait --for=condition=Available deploy/ingress-nginx-controller --timeout=180s >/dev/null
    return 0
  fi

  return 1
}

default_storageclass_exists() {
  local sc
  sc="$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  [[ -n "${sc// /}" ]]
}

# -------------------------
# start validation
# -------------------------
log "[05][VALIDATE] Starting platform checks"

# 1) Default StorageClass
log "[05][VALIDATE] Check default StorageClass exists"
default_storageclass_exists || fatal "No default StorageClass found (expected ${STORAGE_CLASS:-local-path} as default)"

# 2) Ingress controller readiness
log "[05][VALIDATE] Check ingress controller ready (INGRESS_CLASS=${INGRESS_CLASS:-traefik})"
ingress_controller_ready || fatal "Ingress controller not ready for INGRESS_CLASS=${INGRESS_CLASS:-traefik}"

# 3) Namespaces expected
: "${NS:=open-kpi}"
OPENKPI_NS="${NS}"

# 4) Postgres + MinIO ready (shared data plane)
log "[05][VALIDATE] Check Postgres + MinIO readiness (namespace: ${OPENKPI_NS})"

ns_exists "${OPENKPI_NS}" || fatal "Namespace missing: ${OPENKPI_NS}"

# Postgres service + endpoints
has_resource svc openkpi-postgres "${OPENKPI_NS}" || fatal "Postgres service missing: ${OPENKPI_NS}/openkpi-postgres"
wait_svc_endpoints "${OPENKPI_NS}" openkpi-postgres 180 || fatal "Postgres endpoints not ready: ${OPENKPI_NS}/openkpi-postgres"

# If StatefulSet exists, wait it; otherwise best-effort pod readiness in ns
if has_resource sts openkpi-postgres "${OPENKPI_NS}"; then
  kubectl_wait_sts "${OPENKPI_NS}" openkpi-postgres 300s
else
  # tolerate different sts naming; require at least one ready pod labeled app=openkpi-postgres or name match
  local_ready="$(kubectl -n "${OPENKPI_NS}" get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -E 'openkpi-postgres' | grep -E ' true$' || true)"
  [[ -n "${local_ready}" ]] || fatal "Postgres pods not ready in ${OPENKPI_NS} (expected name contains openkpi-postgres)"
fi

# MinIO service + endpoints
has_resource svc openkpi-minio "${OPENKPI_NS}" || fatal "MinIO service missing: ${OPENKPI_NS}/openkpi-minio"
wait_svc_endpoints "${OPENKPI_NS}" openkpi-minio 180 || fatal "MinIO endpoints not ready: ${OPENKPI_NS}/openkpi-minio"

if has_resource sts openkpi-minio "${OPENKPI_NS}"; then
  kubectl_wait_sts "${OPENKPI_NS}" openkpi-minio 300s
else
  local_ready="$(kubectl -n "${OPENKPI_NS}" get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -E 'openkpi-minio' | grep -E ' true$' || true)"
  [[ -n "${local_ready}" ]] || fatal "MinIO pods not ready in ${OPENKPI_NS} (expected name contains openkpi-minio)"
fi

# 5) Optional apps readiness
# Airbyte
if ns_exists airbyte; then
  log "[05][VALIDATE] Check Airbyte readiness (optional)"
  # accept either deployment or sts naming patterns
  if kubectl -n airbyte get deploy >/dev/null 2>&1; then
    # prefer known helm controller/server deployment names; otherwise require all deployments available
    if kubectl -n airbyte get deploy airbyte-webapp >/dev/null 2>&1; then
      kubectl_wait_deploy airbyte airbyte-webapp 600s
    else
      # wait all deployments in namespace
      while read -r d; do
        [[ -z "$d" ]] && continue
        kubectl -n airbyte wait --for=condition=Available "deploy/${d}" --timeout=600s >/dev/null || fatal "Airbyte deploy not ready: airbyte/${d}"
      done < <(kubectl -n airbyte get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    fi
  fi
else
  log "[05][VALIDATE] Airbyte namespace not present; skipping"
fi

# n8n
if ns_exists n8n; then
  log "[05][VALIDATE] Check n8n readiness (optional)"
  if kubectl -n n8n get deploy n8n >/dev/null 2>&1; then
    kubectl_wait_deploy n8n n8n 600s
  else
    # if deployed via helm chart with different name, require at least one ready pod
    ready_pods="$(kubectl -n n8n get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -E ' true$' || true)"
    [[ -n "${ready_pods}" ]] || fatal "n8n namespace exists but no ready pods found"
  fi
else
  log "[05][VALIDATE] n8n namespace not present; skipping"
fi

# Zammad
if ns_exists tickets; then
  log "[05][VALIDATE] Check Zammad readiness (optional)"
  # chart commonly creates deployment zammad; tolerate other names
  if kubectl -n tickets get deploy zammad >/dev/null 2>&1; then
    kubectl_wait_deploy tickets zammad 900s
  else
    ready_pods="$(kubectl -n tickets get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -E ' true$' || true)"
    [[ -n "${ready_pods}" ]] || fatal "tickets namespace exists but no ready pods found (zammad)"
  fi
else
  log "[05][VALIDATE] tickets namespace not present; skipping"
fi

# 6) Portal checks
: "${PORTAL_HOST:?missing PORTAL_HOST}"
PORTAL_BASE="http://${PORTAL_HOST}"
PORTAL_API_URL="${PORTAL_BASE}/api/summary"

log "[05][VALIDATE] Check Portal API returns JSON (optional but required if platform namespace exists)"
ns_exists platform || fatal "Namespace missing: platform (portal required)"

# Ensure at least one portal-api pod exists and is ready (best-effort naming)
portal_api_ready="$(kubectl -n platform get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -E 'portal-api|portal' | grep -E ' true$' || true)"
[[ -n "${portal_api_ready}" ]] || fatal "Portal API pods not ready in namespace platform"

# Portal UI pod readiness (nginx) best-effort
portal_ui_ready="$(kubectl -n platform get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -E 'portal-ui|portal' | grep -E ' true$' || true)"
[[ -n "${portal_ui_ready}" ]] || fatal "Portal UI pods not ready in namespace platform"

# Ingress presence for portal UI
if ! kubectl -n platform get ingress >/dev/null 2>&1; then
  fatal "Portal ingress resources missing in namespace platform"
fi

# HTTP probes (requires DNS/host routing to work from this machine)
log "[05][VALIDATE] HTTP probe Portal API: ${PORTAL_API_URL}"
retry 10 3 http_probe_json "${PORTAL_API_URL}" 10 || fatal "Portal API not reachable or not JSON: ${PORTAL_API_URL}"

log "[05][VALIDATE] HTTP probe Portal UI: ${PORTAL_BASE}/"
retry 10 3 http_probe "${PORTAL_BASE}/" 10 || fatal "Portal UI not reachable: ${PORTAL_BASE}/"

# 7) Print URL summary (single block)
PROTO="http"
if [[ "${TLS_MODE:-off}" == "per-host-http01" ]]; then
  PROTO="https"
fi

: "${AIRBYTE_HOST:=}"
: "${MINIO_HOST:=}"
: "${N8N_HOST:=}"
: "${ZAMMAD_HOST:=}"
: "${POSTGRES_HOST:=}"

AIRBYTE_URL=""
MINIO_URL=""
MINIO_CONSOLE_URL=""
N8N_URL=""
ZAMMAD_URL=""
POSTGRES_URL=""
PORTAL_URL="${PROTO}://${PORTAL_HOST}"

[[ -n "${AIRBYTE_HOST}" ]] && AIRBYTE_URL="${PROTO}://${AIRBYTE_HOST}"
[[ -n "${MINIO_HOST}" ]] && MINIO_URL="${PROTO}://${MINIO_HOST}" && MINIO_CONSOLE_URL="${PROTO}://${MINIO_HOST}"
[[ -n "${N8N_HOST}" ]] && N8N_URL="${PROTO}://${N8N_HOST}"
[[ -n "${ZAMMAD_HOST}" ]] && ZAMMAD_URL="${PROTO}://${ZAMMAD_HOST}"
[[ -n "${POSTGRES_HOST}" ]] && POSTGRES_URL="${PROTO}://${POSTGRES_HOST}"

cat <<EOF

============================================================
OPEN KPI PLATFORM — VALIDATION PASSED
============================================================
Portal:
  ${PORTAL_URL}

Apps (if installed):
  Airbyte:  ${AIRBYTE_URL:-<not set>}
  MinIO:    ${MINIO_URL:-<not set>}
  n8n:      ${N8N_URL:-<not set>}
  Zammad:   ${ZAMMAD_URL:-<not set>}

Notes:
  - Portal API endpoint validated: ${PORTAL_URL}/api/summary
  - Postgres/MinIO validated via Kubernetes readiness and endpoints
  - Ingress class: ${INGRESS_CLASS:-traefik}
  - TLS mode: ${TLS_MODE:-off}
============================================================

EOF
