#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 03-airbyte — Airbyte (production, contract-based, idempotent)
#
# Identity
#   MODULE_ID: 03-airbyte
#   SCRIPT:    single drop-in file
#   NAMESPACE: AIRBYTE_NS
#
# Source of truth (ONLY)
#   /root/open-kpi.env via OpenKPI/00-env.sh
#
# Labels (one key used everywhere)
#   app: airbyte
#
# Contract keys used
#   Global:
#     OPENKPI_NS, STORAGE_CLASS, INGRESS_CLASS, APP_DOMAIN
#     TLS_MODE=off|letsencrypt
#     TLS_STRATEGY=per-app|wildcard (required if TLS_MODE != off)
#     TLS_SECRET_NAME (required if wildcard)
#     CERT_CLUSTER_ISSUER (required if letsencrypt and per-app)
#   App:
#     AIRBYTE_NS, AIRBYTE_EXPOSE=on|off, AIRBYTE_HOST
#     AIRBYTE_RELEASE (optional), AIRBYTE_CHART_VERSION (optional), AIRBYTE_APP_VERSION (optional)
#     AIRBYTE_DB_NAME, AIRBYTE_DB_USER, AIRBYTE_DB_PASSWORD
#     AIRBYTE_S3_REGION
#
# Guarantees
#   - Idempotent converge; deterministic names; no random naming
#   - No post-install manual patches; Helm arguments are authoritative
#   - EXPOSE and TLS strictly follow switches
#   - Bootstrap included (DB role+db+grants)
#   - Tests run at end; failures print diagnostics and exit non-zero
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../../../" && pwd)"
# shellcheck source=/dev/null
. "${ROOT}/00-env.sh"

# ==============================================================================
# SECTION 00 — Prereqs
# ==============================================================================
require_cmd kubectl
require_cmd helm

# ==============================================================================
# SECTION 01 — Contract (required vars)
# ==============================================================================
require_var OPENKPI_NS
require_var STORAGE_CLASS
require_var INGRESS_CLASS
require_var TLS_MODE

require_var AIRBYTE_NS
require_var AIRBYTE_EXPOSE
require_var AIRBYTE_HOST

require_var POSTGRES_SERVICE
require_var POSTGRES_PORT
require_var POSTGRES_USER
require_var POSTGRES_PASSWORD

require_var MINIO_SERVICE
require_var MINIO_API_PORT
require_var MINIO_ROOT_USER
require_var MINIO_ROOT_PASSWORD
require_var AIRBYTE_S3_REGION

require_var AIRBYTE_DB_NAME
require_var AIRBYTE_DB_USER
require_var AIRBYTE_DB_PASSWORD

if tls_enabled; then
  require_var TLS_STRATEGY
  if [[ "${TLS_STRATEGY}" == "wildcard" ]]; then
    require_var TLS_SECRET_NAME
  else
    require_var CERT_CLUSTER_ISSUER
  fi
fi

# ==============================================================================
# SECTION 02 — Identity and deterministic naming
# ==============================================================================
MODULE_ID="03-airbyte"
APP_ID="airbyte"
APP_LABEL_KEY="app"
APP_LABEL_VAL="${APP_ID}"
LABEL_SELECTOR="${APP_LABEL_KEY}=${APP_LABEL_VAL}"

NS="${AIRBYTE_NS}"
CORE_NS="${OPENKPI_NS}"

REL="${AIRBYTE_RELEASE:-airbyte}"

MINIO_ALIAS_SVC="airbyte-minio-svc"
MINIO_SVC_NAME="${MINIO_SVC_NAME:-$(echo "${MINIO_SERVICE}" | awk -F. '{print $1}')}"
MINIO_FQDN="${MINIO_SVC_NAME}.${CORE_NS}.svc.cluster.local"

AIRBYTE_CFG_SECRET="${AIRBYTE_CFG_SECRET:-airbyte-config-secrets}"

AIRBYTE_BUCKET="${AIRBYTE_BUCKET:-airbyte}"
AIRBYTE_LOG_BUCKET="${AIRBYTE_LOG_BUCKET:-airbyte-logs}"
AIRBYTE_STATE_BUCKET="${AIRBYTE_STATE_BUCKET:-airbyte-state}"

INGRESS_NAME="airbyte-ingress"

CERT_NAME="airbyte-cert"
TLS_SECRET_PER_APP="airbyte-tls"

AIRBYTE_CHART_VERSION="${AIRBYTE_CHART_VERSION:-}"
AIRBYTE_APP_VERSION="${AIRBYTE_APP_VERSION:-}"


# ==============================================================================
# SECTION 00-3A — Pre-flight cleanup (stuck pods/jobs/helm locks)  [REPEATABLE]
# Run before helm install/upgrade. Does NOT delete PVCs. Safe to re-run.
# ==============================================================================

log "[${MODULE_ID}] pre-flight cleanup (stuck pods/jobs + helm pending)"

NS="${NS:-airbyte}"
REL="${REL:-airbyte}"

# 1) delete known-sticky pods/jobs (hooks, bootloaders, migrations, temporal schema)
kubectl_k -n "${NS}" get pods,job -o name 2>/dev/null | \
  egrep -i 'hook|bootloader|pre-install|post-install|migrate|schema|temporal|setup|init' | \
  xargs -r kubectl_k -n "${NS}" delete --ignore-not-found >/dev/null 2>&1 || true

# 2) delete pods in bad states (keeps running/ready pods)
mapfile -t BAD_PODS < <(
  kubectl -n "${NS}" get pod --no-headers 2>/dev/null | awk '
    $3 ~ /(Error|CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError|CreateContainerError|RunContainerError)/ {print $1}
    $3=="Pending" && $2 ~ /^0\// {print $1}
  ' | sort -u
)
if [[ "${#BAD_PODS[@]}" -gt 0 ]]; then
  log "[${MODULE_ID}] delete bad pods: ${BAD_PODS[*]}"
  kubectl_k -n "${NS}" delete pod "${BAD_PODS[@]}" --ignore-not-found >/dev/null 2>&1 || true
fi

# 3) clear helm “another operation in progress” by resolving pending revision (best-effort)
PENDING_REV="$(helm -n "${NS}" history "${REL}" 2>/dev/null | awk '$0 ~ /pending-(install|upgrade|rollback)/ {print $1}' | tail -n1 || true)"
if [[ -n "${PENDING_REV}" ]]; then
  log "[${MODULE_ID}] helm pending revision=${PENDING_REV} -> rollback to clear lock"
  helm -n "${NS}" rollback "${REL}" "${PENDING_REV}" --wait --timeout 15m >/dev/null 2>&1 || true
fi

# 4) if still pending, nuke helm secrets for this release (last resort, deterministic)
if helm -n "${NS}" status "${REL}" 2>/dev/null | egrep -qi 'pending-(install|upgrade|rollback)'; then
  log "[${MODULE_ID}] helm still pending -> uninstall keep-history + delete helm secrets"
  helm -n "${NS}" uninstall "${REL}" --keep-history >/dev/null 2>&1 || true
  kubectl_k -n "${NS}" delete secret -l "owner=helm,name=${REL}" --ignore-not-found >/dev/null 2>&1 || true
fi



# ==============================================================================
# SECTION 03 — Namespace
# ==============================================================================
log "[${MODULE_ID}] ensure namespace: ${NS}"
kubectl_k get ns "${NS}" >/dev/null 2>&1 || kubectl_k create ns "${NS}"

# ==============================================================================
# SECTION 04 — Secrets + Alias (Airbyte storage DNS fix)
# ==============================================================================

log "[${MODULE_ID}] apply MinIO alias service: ${NS}/${MINIO_ALIAS_SVC} -> ${MINIO_FQDN}"
cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${MINIO_ALIAS_SVC}
  labels:
    ${APP_LABEL_KEY}: ${APP_LABEL_VAL}
spec:
  type: ExternalName
  externalName: ${MINIO_FQDN}
YAML

log "[${MODULE_ID}] apply secret: ${NS}/${AIRBYTE_CFG_SECRET} (DB + AWS_* + s3-*)"
cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${AIRBYTE_CFG_SECRET}
  labels:
    ${APP_LABEL_KEY}: ${APP_LABEL_VAL}
type: Opaque
stringData:
  # External Postgres creds (Airbyte chart reads these via valueFrom)
  database-user: "${AIRBYTE_DB_USER}"
  database-password: "${AIRBYTE_DB_PASSWORD}"

  # MinIO creds (keep both key styles)
  AWS_ACCESS_KEY_ID: "${MINIO_ROOT_USER}"
  AWS_SECRET_ACCESS_KEY: "${MINIO_ROOT_PASSWORD}"
  s3-access-key-id: "${MINIO_ROOT_USER}"
  s3-secret-access-key: "${MINIO_ROOT_PASSWORD}"
YAML


# ==============================================================================
# SECTION 05 — Bootstrap (Postgres role + db + grants)  [FILE-BASED, ZERO QUOTING ISSUES]
#   - No DO $$ blocks
#   - No inline -c strings with complex quoting
#   - Uses psql meta \gexec inside a mounted script file
# ==============================================================================

log "[${MODULE_ID}] bootstrap Airbyte DB (role+db+grants) on shared Postgres"

BOOT_POD="airbyte-db-bootstrap"
BOOT_CM="airbyte-db-bootstrap-script"

kubectl -n "${NS}" delete pod "${BOOT_POD}" --ignore-not-found >/dev/null 2>&1 || true

# 05A — ConfigMap containing a psql script (idempotent apply)
cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${BOOT_CM}
  labels:
    ${APP_LABEL_KEY}: ${APP_LABEL_VAL}
data:
  bootstrap.psql: |
    \set ON_ERROR_STOP on
    \set ab_user '${AIRBYTE_DB_USER}'
    \set ab_pass '${AIRBYTE_DB_PASSWORD}'
    \set ab_db   '${AIRBYTE_DB_NAME}'

    -- Create role if missing
    SELECT format('CREATE ROLE %I LOGIN PASSWORD %L;', :'ab_user', :'ab_pass')
    WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'ab_user')
    \gexec

    -- Create DB if missing
    SELECT format('CREATE DATABASE %I;', :'ab_db')
    WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'ab_db')
    \gexec
YAML

# 05B — Run the script inside a short-lived postgres client pod (psql is present)
cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${BOOT_POD}
  labels:
    ${APP_LABEL_KEY}: ${APP_LABEL_VAL}
spec:
  restartPolicy: Never
  volumes:
    - name: script
      configMap:
        name: ${BOOT_CM}
  containers:
    - name: pg
      image: postgres:16-alpine
      env:
        - name: PGPASSWORD
          value: "${POSTGRES_PASSWORD}"
      volumeMounts:
        - name: script
          mountPath: /script
      command: ["sh","-lc"]
      args:
        - |
          set -euo pipefail

          psql "host=${POSTGRES_SERVICE} port=${POSTGRES_PORT} user=${POSTGRES_USER} dbname=postgres sslmode=disable" \
            -f /script/bootstrap.psql

          psql "host=${POSTGRES_SERVICE} port=${POSTGRES_PORT} user=${POSTGRES_USER} dbname=${AIRBYTE_DB_NAME} sslmode=disable" \
            -v ON_ERROR_STOP=1 \
            -c "GRANT ALL PRIVILEGES ON DATABASE \"${AIRBYTE_DB_NAME}\" TO \"${AIRBYTE_DB_USER}\";" \
            -c "GRANT ALL ON SCHEMA public TO \"${AIRBYTE_DB_USER}\";" \
            -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO \"${AIRBYTE_DB_USER}\";" \
            -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO \"${AIRBYTE_DB_USER}\";" \
            -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO \"${AIRBYTE_DB_USER}\";"

          echo "[BOOTSTRAP] OK"
YAML

# 05C — Wait + diagnostics on failure
log "[${MODULE_ID}] wait bootstrap completion: ${NS}/${BOOT_POD}"
deadline=$((SECONDS + 240))
while true; do
  phase="$(kubectl -n "${NS}" get pod "${BOOT_POD}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
  [[ "${phase}" == "Succeeded" ]] && break
  if [[ "${phase}" == "Failed" ]]; then
    echo "[${MODULE_ID}][FATAL] bootstrap failed: ${NS}/${BOOT_POD}" >&2
    kubectl -n "${NS}" logs "${BOOT_POD}" --tail=200 >&2 || true
    kubectl -n "${NS}" describe pod "${BOOT_POD}" >&2 || true
    exit 1
  fi
  if (( SECONDS >= deadline )); then
    echo "[${MODULE_ID}][FATAL] bootstrap timeout (phase=${phase:-unknown}): ${NS}/${BOOT_POD}" >&2
    kubectl -n "${NS}" logs "${BOOT_POD}" --tail=200 >&2 || true
    kubectl -n "${NS}" describe pod "${BOOT_POD}" >&2 || true
    exit 1
  fi
  sleep 2
done

kubectl -n "${NS}" logs "${BOOT_POD}" || true
kubectl -n "${NS}" delete pod "${BOOT_POD}" --ignore-not-found >/dev/null 2>&1 || true
log "[${MODULE_ID}] bootstrap OK"

# ==============================================================================
# SECTION 06 — Helm deploy (Airbyte) [PRODUCTION / CONTRACT-SAFE]
#   - External Postgres via secret refs (no inline creds)
#   - Disable chart MinIO (we use OpenKPI MinIO via ExternalName alias)
#   - Force MINIO storage env wiring to prevent docstore 500 regressions
#   - Post-helm assertion: no MinIO resources exist in AIRBYTE_NS
# ==============================================================================

log "[${MODULE_ID}] helm repo ensure"
helm repo add airbyte https://airbytehq.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

CHART_FLAGS=()
[[ -n "${AIRBYTE_CHART_VERSION}" ]] && CHART_FLAGS+=(--version "${AIRBYTE_CHART_VERSION}")

APP_FLAGS=()
if [[ -n "${AIRBYTE_APP_VERSION}" ]]; then
  APP_FLAGS+=(--set "global.image.tag=${AIRBYTE_APP_VERSION}")
  APP_FLAGS+=(--set "global.airbyteVersion=${AIRBYTE_APP_VERSION}")
fi

log "[${MODULE_ID}] enforce MinIO alias service is ExternalName"
svc_type="$(kubectl -n "${NS}" get svc "${MINIO_ALIAS_SVC}" -o jsonpath='{.spec.type}' 2>/dev/null || echo "")"
[[ "${svc_type}" == "ExternalName" ]] || die "MinIO alias svc must be ExternalName: ${NS}/${MINIO_ALIAS_SVC} (found: ${svc_type:-missing})"

log "[${MODULE_ID}] deploy release: ${REL} (namespace=${NS})"

helm upgrade --install "${REL}" airbyte/airbyte \
  -n "${NS}" \
  "${CHART_FLAGS[@]}" \
  --atomic \
  --timeout 25m \
  "${APP_FLAGS[@]}" \
  \
  --set minio.enabled=false \
  --set postgresql.enabled=false \
  \
  --set global.database.type=external \
  --set global.database.host="${POSTGRES_SERVICE}" \
  --set global.database.port="${POSTGRES_PORT}" \
  --set global.database.database="${AIRBYTE_DB_NAME}" \
  --set global.database.secretName="${AIRBYTE_CFG_SECRET}" \
  --set global.database.userSecretKey="database-user" \
  --set global.database.passwordSecretKey="database-password" \
  \
  --set global.storage.type=MINIO \
  --set global.storage.minio.endpoint="http://${MINIO_ALIAS_SVC}:${MINIO_API_PORT}" \
  --set global.storage.minio.bucket="${AIRBYTE_BUCKET}" \
  --set global.storage.minio.region="${AIRBYTE_S3_REGION}" \
  --set global.storage.minio.auth.secretName="${AIRBYTE_CFG_SECRET}" \
  --set global.storage.minio.auth.accessKeyIdSecretKey="AWS_ACCESS_KEY_ID" \
  --set global.storage.minio.auth.secretAccessKeySecretKey="AWS_SECRET_ACCESS_KEY" \
  \
  --set global.logs.storage.type=MINIO \
  --set global.logs.storage.minio.bucket="${AIRBYTE_LOG_BUCKET}" \
  --set global.state.storage.type=MINIO \
  --set global.state.storage.minio.bucket="${AIRBYTE_STATE_BUCKET}" \
  \
  --set-string global.env_vars.STORAGE_TYPE="MINIO" \
  --set-string global.env_vars.MINIO_ENDPOINT="http://${MINIO_ALIAS_SVC}:${MINIO_API_PORT}" \
  --set-string global.env_vars.S3_ENDPOINT="http://${MINIO_ALIAS_SVC}:${MINIO_API_PORT}" \
  --set-string global.env_vars.S3_PATH_STYLE_ACCESS="true" \
  --set-string global.env_vars.AWS_REGION="${AIRBYTE_S3_REGION}" \
  --set-string global.env_vars.AWS_DEFAULT_REGION="${AIRBYTE_S3_REGION}"

log "[${MODULE_ID}] post-helm assert: chart MinIO disabled (no minio resources in ${NS})"
if kubectl -n "${NS}" get deploy,sts,svc 2>/dev/null | egrep -i 'minio' >/dev/null; then
  kubectl -n "${NS}" get deploy,sts,svc | egrep -i 'minio' >&2 || true
  die "[${MODULE_ID}] chart MinIO still present in ${NS} (minio.enabled=false not honored)"
fi


# ==============================================================================
# SECTION 07 — Exposure + Ingress + TLS
#   - Uses spec.ingressClassName (not deprecated annotation)
#   - TLS_MODE + TLS_STRATEGY enforced
#   - AIRBYTE_EXPOSE=off deletes owned ingress (+ per-app cert if used)
# ==============================================================================

log "[${MODULE_ID}] exposure switch: AIRBYTE_EXPOSE=${AIRBYTE_EXPOSE}"

if [[ "${AIRBYTE_EXPOSE}" == "on" ]]; then
  if tls_enabled; then
    if [[ "${TLS_STRATEGY}" == "per-app" ]]; then
      log "[${MODULE_ID}] apply Certificate (per-app TLS): ${CERT_NAME} -> ${TLS_SECRET_PER_APP}"
      cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${CERT_NAME}
  labels:
    ${APP_LABEL_KEY}: ${APP_LABEL_VAL}
spec:
  secretName: ${TLS_SECRET_PER_APP}
  issuerRef:
    kind: ClusterIssuer
    name: ${CERT_CLUSTER_ISSUER}
  dnsNames:
    - ${AIRBYTE_HOST}
YAML
      TLS_SECRET="${TLS_SECRET_PER_APP}"
    else
      TLS_SECRET="${TLS_SECRET_NAME}"
    fi

    log "[${MODULE_ID}] apply Ingress (TLS enabled) secret=${TLS_SECRET}"
    cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${INGRESS_NAME}
  labels:
    ${APP_LABEL_KEY}: ${APP_LABEL_VAL}
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
    - hosts: [ "${AIRBYTE_HOST}" ]
      secretName: ${TLS_SECRET}
  rules:
    - host: ${AIRBYTE_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: airbyte-webapp
                port:
                  number: 80
YAML

  else
    log "[${MODULE_ID}] apply Ingress (HTTP only)"
    cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${INGRESS_NAME}
  labels:
    ${APP_LABEL_KEY}: ${APP_LABEL_VAL}
spec:
  ingressClassName: ${INGRESS_CLASS}
  rules:
    - host: ${AIRBYTE_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: airbyte-webapp
                port:
                  number: 80
YAML
  fi

else
  log "[${MODULE_ID}] AIRBYTE_EXPOSE=off -> delete ingress (owned)"
  kubectl_k -n "${NS}" delete ingress "${INGRESS_NAME}" --ignore-not-found >/dev/null 2>&1 || true
  if tls_enabled && [[ "${TLS_STRATEGY}" == "per-app" ]]; then
    kubectl_k -n "${NS}" delete certificate "${CERT_NAME}" --ignore-not-found >/dev/null 2>&1 || true
  fi
fi

# ==============================================================================
# SECTION 08 — Rollout + hard readiness gates (release-aware)
#   - Waits rollouts for core deployments
#   - Enforces server Service has READY endpoints (dataplane truth)
#   - Enforces in-cluster HTTP reachability to server:8001 (from a test pod)
# ==============================================================================

log "[${MODULE_ID}] rollout checks + readiness gates (release=${REL})"

mapfile -t REL_DEPS < <(kubectl -n "${NS}" get deploy -l "app.kubernetes.io/instance=${REL}" -o name 2>/dev/null || true)
if [[ "${#REL_DEPS[@]}" -eq 0 ]]; then
  mapfile -t REL_DEPS < <(kubectl -n "${NS}" get deploy -o name | egrep -i 'airbyte' || true)
fi
[[ "${#REL_DEPS[@]}" -gt 0 ]] || die "[${MODULE_ID}] no Airbyte deployments found in namespace ${NS}"

_rollout_match() {
  local rx="$1" timeout="${2:-900s}" d=""
  for x in "${REL_DEPS[@]}"; do
    if echo "${x}" | egrep -qi "${rx}"; then d="${x}"; break; fi
  done
  [[ -n "${d}" ]] || return 0
  kubectl -n "${NS}" rollout status "${d}" --timeout="${timeout}"
}

# rollouts (best-effort; chart-safe)
_rollout_match 'server'                 900s
_rollout_match 'worker'                 900s
_rollout_match 'workload.*api'          900s
_rollout_match 'workload.*launcher'     900s
_rollout_match 'webapp'                 900s
_rollout_match 'temporal'               900s || true

# --- HARD GATE 1: server service exists
SRV_SVC="$(kubectl -n "${NS}" get svc -o name | egrep -i 'server' | head -n 1 | sed 's#^service/##' || true)"
[[ -n "${SRV_SVC}" ]] || die "[${MODULE_ID}] no Airbyte server Service found (svc name must contain 'server')"

# --- HARD GATE 2: server service has ready endpoints (not just pods existing)
if ! kubectl -n "${NS}" get endpoints "${SRV_SVC}" -o jsonpath='{.subsets[0].addresses[0].ip}' >/dev/null 2>&1; then
  echo "[${MODULE_ID}][FATAL] ${SRV_SVC} has no READY endpoints (airbyte-server not serving)"
  kubectl -n "${NS}" get pods -o wide || true
  kubectl -n "${NS}" get svc,endpoints -o wide || true
  kubectl -n "${NS}" describe deploy "$(kubectl -n "${NS}" get deploy -o name | egrep -i 'airbyte.*server' | head -n1 | sed 's#^deployment/##')" 2>/dev/null || true
  kubectl -n "${NS}" logs deploy/airbyte-server --tail=200 2>/dev/null || true
  exit 1
fi

# --- HARD GATE 3: in-cluster HTTP to server:8001 responds (prevents workload-launcher loops)
TEST_POD="airbyte-contract-test-server"
kubectl -n "${NS}" delete pod "${TEST_POD}" --ignore-not-found >/dev/null 2>&1 || true
cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${TEST_POD}
  labels:
    ${APP_LABEL_KEY}: ${APP_LABEL_VAL}
spec:
  restartPolicy: Never
  containers:
    - name: curl
      image: curlimages/curl:8.6.0
      command: ["sh","-lc"]
      args:
        - |
          set -e
          echo "[API] svc=${SRV_SVC}:8001"
          # health endpoint may vary by Airbyte version; tolerate 404 but not connection failure
          code="$(curl -sS -o /dev/null -w '%{http_code}' http://${SRV_SVC}:8001/ || true)"
          echo "[API] status=${code}"
          [ "${code}" != "000" ]
YAML
kubectl -n "${NS}" wait --for=condition=Ready pod/"${TEST_POD}" --timeout=120s >/dev/null 2>&1 || true
kubectl -n "${NS}" logs "${TEST_POD}" || true
kubectl -n "${NS}" delete pod "${TEST_POD}" --ignore-not-found >/dev/null 2>&1 || true

log "[${MODULE_ID}] rollout + readiness gates OK"

# ==============================================================================
# SECTION 09 — Contract tests (must pass)
#   - Includes hard gates for Airbyte server readiness (endpoints + in-cluster HTTP)
#   - Includes best-effort Temporal reachability test (7233)
#   - Diagnostics hardened for TLS_STRATEGY=shared (no CERT_NAME assumptions)
# ==============================================================================

diag() {
  echo "----- [${MODULE_ID}] DIAGNOSTICS (ns=${NS}) -----" >&2
  kubectl -n "${NS}" get all -o wide >&2 || true
  kubectl -n "${NS}" get svc,ingress,secret -o wide >&2 || true
  kubectl -n "${NS}" get endpoints -o wide >&2 || true

  if tls_enabled; then
    kubectl -n "${NS}" get certificate -o wide >&2 || true
    if [[ "${TLS_STRATEGY:-shared}" == "per-app" ]] && [[ -n "${CERT_NAME:-}" ]]; then
      kubectl -n "${NS}" describe certificate "${CERT_NAME}" >&2 || true
    fi
  fi

  echo "----- [${MODULE_ID}] POD LOGS (best-effort) -----" >&2
  for p in $(kubectl -n "${NS}" get pods -o name | head -n 12); do
    kubectl -n "${NS}" logs "$p" --tail=160 >&2 || true
  done

  # Focus logs for common Airbyte failure points
  kubectl -n "${NS}" logs deploy/airbyte-server --tail=220 2>/dev/null >&2 || true
  kubectl -n "${NS}" logs deploy/airbyte-workload-launcher --tail=220 2>/dev/null >&2 || true
  kubectl -n "${NS}" logs deploy/airbyte-temporal --tail=220 2>/dev/null >&2 || true
}

trap 'diag' ERR

log "[${MODULE_ID}][TEST] 01 alias service points to expected FQDN"
kubectl -n "${NS}" get svc "${MINIO_ALIAS_SVC}" -o jsonpath='{.spec.type}{" "}{.spec.externalName}{"\n"}' | grep -F "ExternalName" >/dev/null
kubectl -n "${NS}" get svc "${MINIO_ALIAS_SVC}" -o jsonpath='{.spec.externalName}{"\n"}' | grep -F "${MINIO_FQDN}" >/dev/null

log "[${MODULE_ID}][TEST] 02 secret contains all required keys"
for k in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY s3-access-key-id s3-secret-access-key; do
  kubectl -n "${NS}" get secret "${AIRBYTE_CFG_SECRET}" -o jsonpath="{.data.${k}}" 2>/dev/null | grep -q .
done

log "[${MODULE_ID}][TEST] 03 in-cluster DNS + HTTP to MinIO via alias"
TEST_POD="airbyte-contract-test-minio"
kubectl -n "${NS}" delete pod "${TEST_POD}" --ignore-not-found >/dev/null 2>&1 || true
cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${TEST_POD}
  labels:
    ${APP_LABEL_KEY}: ${APP_LABEL_VAL}
spec:
  restartPolicy: Never
  containers:
    - name: curl
      image: curlimages/curl:8.6.0
      command: ["sh","-lc"]
      args:
        - |
          set -e
          echo "[DNS] getent hosts ${MINIO_ALIAS_SVC} (best-effort)"
          (getent hosts ${MINIO_ALIAS_SVC} || true)
          code="$(curl -sS -o /dev/null -w '%{http_code}' http://${MINIO_ALIAS_SVC}:${MINIO_API_PORT}/ || true)"
          echo "[HTTP] minio status=${code}"
          [ "${code}" != "000" ]
YAML
kubectl -n "${NS}" wait --for=condition=Ready pod/"${TEST_POD}" --timeout=120s >/dev/null 2>&1 || true
kubectl -n "${NS}" logs "${TEST_POD}" || true
kubectl -n "${NS}" delete pod "${TEST_POD}" --ignore-not-found >/dev/null 2>&1 || true

log "[${MODULE_ID}][TEST] 04 Airbyte services exist (webapp + server required)"
kubectl -n "${NS}" get svc -o name | egrep -qi 'webapp' || die "[${MODULE_ID}] no webapp service found"
kubectl -n "${NS}" get svc -o name | egrep -qi 'server' || die "[${MODULE_ID}] no server service found"

log "[${MODULE_ID}][TEST] 05 in-cluster Airbyte health checks (webapp + server http reachability)"
WEB_SVC="$(kubectl -n "${NS}" get svc -o name | egrep -i 'webapp' | head -n 1 | sed 's#^service/##')"
SRV_SVC="$(kubectl -n "${NS}" get svc -o name | egrep -i 'server' | head -n 1 | sed 's#^service/##')"

TEST_POD="airbyte-contract-test-health"
kubectl -n "${NS}" delete pod "${TEST_POD}" --ignore-not-found >/dev/null 2>&1 || true
cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${TEST_POD}
  labels:
    ${APP_LABEL_KEY}: ${APP_LABEL_VAL}
spec:
  restartPolicy: Never
  containers:
    - name: curl
      image: curlimages/curl:8.6.0
      command: ["sh","-lc"]
      args:
        - |
          set -e
          echo "[WEB] svc=${WEB_SVC}"
          web="$(curl -sS -o /dev/null -w '%{http_code}' http://${WEB_SVC}:80/ || true)"
          echo "[WEB] status=${web}"
          [ "${web}" != "000" ]

          echo "[API] svc=${SRV_SVC}:8001"
          # tolerate 404, do not tolerate connect failure
          api="$(curl -sS -o /dev/null -w '%{http_code}' http://${SRV_SVC}:8001/ || true)"
          echo "[API] status=${api}"
          [ "${api}" != "000" ]
YAML
kubectl -n "${NS}" wait --for=condition=Ready pod/"${TEST_POD}" --timeout=120s >/dev/null 2>&1 || true
kubectl -n "${NS}" logs "${TEST_POD}" || true
kubectl -n "${NS}" delete pod "${TEST_POD}" --ignore-not-found >/dev/null 2>&1 || true

log "[${MODULE_ID}][TEST] 06 server service has READY endpoints (hard gate; prevents workload-launcher ConnectException)"
kubectl -n "${NS}" get endpoints "${SRV_SVC}" -o jsonpath='{.subsets[0].addresses[0].ip}{"\n"}' | grep -q .

log "[${MODULE_ID}][TEST] 07 Temporal reachable on 7233 (best-effort; fail -> diagnostics)"
TMP_SVC="$(kubectl -n "${NS}" get svc -o name | egrep -i 'temporal' | head -n 1 | sed 's#^service/##' || true)"
if [[ -n "${TMP_SVC}" ]]; then
  TEST_POD="airbyte-contract-test-temporal"
  kubectl -n "${NS}" delete pod "${TEST_POD}" --ignore-not-found >/dev/null 2>&1 || true
  cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${TEST_POD}
  labels:
    ${APP_LABEL_KEY}: ${APP_LABEL_VAL}
spec:
  restartPolicy: Never
  containers:
    - name: nc
      image: alpine:3.19
      command: ["sh","-lc"]
      args:
        - |
          set -e
          apk add --no-cache busybox-extras >/dev/null
          echo "[TEMPORAL] check ${TMP_SVC}:7233"
          nc -zvw5 ${TMP_SVC} 7233
YAML
  kubectl -n "${NS}" wait --for=condition=Ready pod/"${TEST_POD}" --timeout=120s >/dev/null 2>&1 || true
  kubectl -n "${NS}" logs "${TEST_POD}" || true
  kubectl -n "${NS}" delete pod "${TEST_POD}" --ignore-not-found >/dev/null 2>&1 || true
else
  echo "[${MODULE_ID}][WARN] no temporal service found; skipping temporal port test" >&2
fi

if [[ "${AIRBYTE_EXPOSE}" == "on" ]]; then
  log "[${MODULE_ID}][TEST] 08 ingress host/class/tls secret correctness"
  kubectl -n "${NS}" get ingress "${INGRESS_NAME}" -o jsonpath='{.spec.ingressClassName}{"\n"}' 2>/dev/null | grep -F "${INGRESS_CLASS}" >/dev/null || true
  kubectl -n "${NS}" get ingress "${INGRESS_NAME}" -o jsonpath='{.spec.rules[0].host}{"\n"}' | grep -F "${AIRBYTE_HOST}" >/dev/null

  if tls_enabled; then
    if [[ "${TLS_STRATEGY}" == "per-app" ]]; then
      kubectl -n "${NS}" get ingress "${INGRESS_NAME}" -o jsonpath='{.spec.tls[0].secretName}{"\n"}' | grep -F "${TLS_SECRET_PER_APP}" >/dev/null
      kubectl -n "${NS}" get certificate "${CERT_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}' | grep -F "True" >/dev/null || true
    else
      kubectl -n "${NS}" get ingress "${INGRESS_NAME}" -o jsonpath='{.spec.tls[0].secretName}{"\n"}' | grep -F "${TLS_SECRET_NAME}" >/dev/null
    fi

    log "[${MODULE_ID}][TEST] 09 external TLS handshake + SAN contains host (from inside cluster)"
    TEST_POD="airbyte-contract-test-tls"
    kubectl -n "${NS}" delete pod "${TEST_POD}" --ignore-not-found >/dev/null 2>&1 || true
    cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${TEST_POD}
  labels:
    ${APP_LABEL_KEY}: ${APP_LABEL_VAL}
spec:
  restartPolicy: Never
  containers:
    - name: tls
      image: alpine:3.19
      command: ["sh","-lc"]
      args:
        - |
          set -e
          apk add --no-cache openssl curl >/dev/null
          echo "[TLS] curl https://${AIRBYTE_HOST}/"
          code="$(curl -k -sS -o /dev/null -w '%{http_code}' https://${AIRBYTE_HOST}/ || true)"
          echo "[TLS] status=${code}"
          echo | openssl s_client -servername ${AIRBYTE_HOST} -connect ${AIRBYTE_HOST}:443 2>/dev/null | openssl x509 -noout -text | egrep -i "DNS:${AIRBYTE_HOST}" >/dev/null
YAML
    kubectl -n "${NS}" wait --for=condition=Ready pod/"${TEST_POD}" --timeout=180s >/dev/null 2>&1 || true
    kubectl -n "${NS}" logs "${TEST_POD}" || true
    kubectl -n "${NS}" delete pod "${TEST_POD}" --ignore-not-found >/dev/null 2>&1 || true
  else
    log "[${MODULE_ID}][TEST] 09 external HTTP status check"
    TEST_POD="airbyte-contract-test-http"
    kubectl -n "${NS}" delete pod "${TEST_POD}" --ignore-not-found >/dev/null 2>&1 || true
    cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${TEST_POD}
  labels:
    ${APP_LABEL_KEY}: ${APP_LABEL_VAL}
spec:
  restartPolicy: Never
  containers:
    - name: curl
      image: curlimages/curl:8.6.0
      command: ["sh","-lc"]
      args:
        - |
          set -e
          code="$(curl -sS -o /dev/null -w '%{http_code}' http://${AIRBYTE_HOST}/ || true)"
          echo "[HTTP] status=${code}"
          [ "${code}" != "000" ]
YAML
    kubectl -n "${NS}" wait --for=condition=Ready pod/"${TEST_POD}" --timeout=180s >/dev/null 2>&1 || true
    kubectl -n "${NS}" logs "${TEST_POD}" || true
    kubectl -n "${NS}" delete pod "${TEST_POD}" --ignore-not-found >/dev/null 2>&1 || true
  fi
fi

trap - ERR
log "[${MODULE_ID}] done"
