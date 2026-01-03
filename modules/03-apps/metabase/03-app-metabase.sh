#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# MODULE 03B — APP (Metabase) — PRODUCTION / REPEATABLE
# FILE: 03B-app-metabase.sh
# Guarantees:
# - Namespace: ${ANALYTICS_NS}
# - Postgres: metabase db + user (idempotent, via in-cluster psql pod)
# - Secret: metabase-db-secret (MB_DB_* env)
# - Deployment/Service/Ingress for Metabase
# - Tests: rollout + /api/health via ingress
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HERE}"
while [[ "${ROOT}" != "/" && ! -f "${ROOT}/00-env.sh" ]]; do ROOT="$(dirname "${ROOT}")"; done
[[ -f "${ROOT}/00-env.sh" ]] || { echo "[FATAL] cannot find 00-env.sh above ${HERE}"; exit 1; }

# shellcheck source=/dev/null
. "${ROOT}/00-env.sh"
# shellcheck source=/dev/null
. "${ROOT}/00-lib.sh"

require_cmd kubectl

MODULE_ID="03B"

: "${ANALYTICS_NS:=analytics}"
: "${INGRESS_CLASS:=nginx}"
: "${TLS_MODE:=off}"

: "${METABASE_HOST:?missing METABASE_HOST}"
: "${METABASE_TLS_SECRET:=metabase-tls}"
: "${METABASE_IMAGE_REPO:=metabase/metabase}"
: "${METABASE_IMAGE_TAG:=v0.49.16}"

: "${METABASE_DB_NAME:=metabase}"
: "${METABASE_DB_USER:=metabase_user}"
: "${METABASE_DB_PASSWORD:?missing METABASE_DB_PASSWORD}"

: "${POSTGRES_SERVICE:?missing POSTGRES_SERVICE}"
: "${POSTGRES_PORT:=5432}"
: "${POSTGRES_USER:?missing POSTGRES_USER}"
: "${POSTGRES_PASSWORD:?missing POSTGRES_PASSWORD}"

log "[${MODULE_ID}][metabase] start"
ensure_ns "${ANALYTICS_NS}"

# ------------------------------------------------------------------------------
# 01) Bootstrap Postgres objects (idempotent) using a short-lived psql client pod
#     YAML-safe: no nested heredocs inside YAML
# ------------------------------------------------------------------------------

BOOT_POD="metabase-db-bootstrap"
kubectl -n "${ANALYTICS_NS}" delete pod "${BOOT_POD}" --ignore-not-found >/dev/null 2>&1 || true

cat <<YAML | kubectl -n "${ANALYTICS_NS}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${BOOT_POD}
  labels: {app: metabase-db-bootstrap}
spec:
  restartPolicy: Never
  containers:
    - name: psql
      image: postgres:16-alpine
      env:
        - name: PGPASSWORD
          value: "${POSTGRES_PASSWORD}"
      command: ["sh","-lc"]
      args:
        - >
          set -euo pipefail;
          psql -h "${POSTGRES_SERVICE}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -v ON_ERROR_STOP=1
          -c "DO \$\$ BEGIN
                IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${METABASE_DB_USER}') THEN
                  CREATE ROLE ${METABASE_DB_USER} LOGIN PASSWORD '${METABASE_DB_PASSWORD}';
                ELSE
                  ALTER ROLE ${METABASE_DB_USER} LOGIN PASSWORD '${METABASE_DB_PASSWORD}';
                END IF;
              END \$\$;"
          -c "DO \$\$ BEGIN
                IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${METABASE_DB_NAME}') THEN
                  CREATE DATABASE ${METABASE_DB_NAME} OWNER ${METABASE_DB_USER};
                END IF;
              END \$\$;"
          -c "GRANT ALL PRIVILEGES ON DATABASE ${METABASE_DB_NAME} TO ${METABASE_DB_USER};"
YAML

kubectl -n "${ANALYTICS_NS}" wait --for=condition=Ready pod/"${BOOT_POD}" --timeout=120s >/dev/null 2>&1 || true
kubectl -n "${ANALYTICS_NS}" logs "${BOOT_POD}" -c psql --tail=200 || true
kubectl -n "${ANALYTICS_NS}" delete pod "${BOOT_POD}" --ignore-not-found >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 02) Secret for Metabase application DB (metadata store)
# ------------------------------------------------------------------------------
kubectl -n "${ANALYTICS_NS}" apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: metabase-db-secret
type: Opaque
stringData:
  MB_DB_TYPE: "postgres"
  MB_DB_HOST: "${POSTGRES_SERVICE}"
  MB_DB_PORT: "${POSTGRES_PORT}"
  MB_DB_DBNAME: "${METABASE_DB_NAME}"
  MB_DB_USER: "${METABASE_DB_USER}"
  MB_DB_PASS: "${METABASE_DB_PASSWORD}"
YAML

# ------------------------------------------------------------------------------
# 03) Deployment + Service
# ------------------------------------------------------------------------------
cat <<YAML | kubectl -n "${ANALYTICS_NS}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: metabase
  labels: {app: metabase}
spec:
  replicas: 1
  selector:
    matchLabels: {app: metabase}
  template:
    metadata:
      labels: {app: metabase}
    spec:
      containers:
        - name: metabase
          image: ${METABASE_IMAGE_REPO}:${METABASE_IMAGE_TAG}
          imagePullPolicy: IfNotPresent
          ports:
            - {containerPort: 3000}
          envFrom:
            - secretRef: {name: metabase-db-secret}
          readinessProbe:
            httpGet: {path: /api/health, port: 3000}
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 12
          livenessProbe:
            httpGet: {path: /api/health, port: 3000}
            initialDelaySeconds: 60
            periodSeconds: 20
            timeoutSeconds: 3
            failureThreshold: 6
YAML

kubectl -n "${ANALYTICS_NS}" apply -f - <<YAML
apiVersion: v1
kind: Service
metadata:
  name: metabase
  labels: {app: metabase}
spec:
  selector: {app: metabase}
  ports:
    - name: http
      port: 3000
      targetPort: 3000
YAML

# ------------------------------------------------------------------------------
# 04) Ingress (TLS follows TLS_MODE)
# ------------------------------------------------------------------------------
if [[ "${TLS_MODE}" == "off" ]]; then
  kubectl -n "${ANALYTICS_NS}" apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: metabase-ingress
  labels: {app: metabase}
spec:
  ingressClassName: ${INGRESS_CLASS}
  rules:
    - host: ${METABASE_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: metabase
                port:
                  number: 3000
YAML
else
  kubectl -n "${ANALYTICS_NS}" apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: metabase-ingress
  labels: {app: metabase}
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
    - hosts: [${METABASE_HOST}]
      secretName: ${METABASE_TLS_SECRET}
  rules:
    - host: ${METABASE_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: metabase
                port:
                  number: 3000
YAML
fi

# ------------------------------------------------------------------------------
# 05) Tests + bounded diagnostics
# ------------------------------------------------------------------------------
if ! kubectl -n "${ANALYTICS_NS}" rollout status deploy/metabase --timeout=300s; then
  POD="$(kubectl -n "${ANALYTICS_NS}" get pods -l app=metabase -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  kubectl -n "${ANALYTICS_NS}" get pods -l app=metabase -o wide || true
  [[ -n "${POD}" ]] && kubectl -n "${ANALYTICS_NS}" describe pod "${POD}" | sed -n '1,260p' || true
  [[ -n "${POD}" ]] && kubectl -n "${ANALYTICS_NS}" logs "${POD}" --tail=400 || true
  exit 1
fi

URL_SCHEME="http"; [[ "${TLS_MODE}" != "off" ]] && URL_SCHEME="https"
curl -fsS -m 10 "${URL_SCHEME}://${METABASE_HOST}/api/health" >/dev/null || {
  kubectl -n "${ANALYTICS_NS}" get ingress,svc,pods -o wide || true
  exit 1
}

log "[${MODULE_ID}][metabase] OK (${URL_SCHEME}://${METABASE_HOST})"

# ------------------------------------------------------------------------------
# CONTRACT TESTS (K8s ? Service ? Ingress ? API)
# ------------------------------------------------------------------------------


NS_APP="${ANALYTICS_NS}"
APP_LABEL="metabase"
SVC_NAME="metabase"
INGRESS_NAME="metabase-ingress"
HOST_FQDN="${METABASE_HOST}"
SVC_PORT="3000"
HEALTH_PATH="/api/health"




URL_SCHEME="http"; [[ "${TLS_MODE:-off}" != "off" ]] && URL_SCHEME="https"

fail_diag() {
  local ns="$1" app_label="$2" svc="$3" ingress="$4" host="$5" port="$6"
  echo "---- DIAG: namespace=${ns} app=${app_label} ----" >&2
  kubectl -n "${ns}" get deploy,sts,svc,ep,ingress,pods -o wide || true
  kubectl -n "${ns}" get events --sort-by=.lastTimestamp | tail -n 40 || true
  local pod
  pod="$(kubectl -n "${ns}" get pods -l "app=${app_label}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${pod}" ]]; then
    kubectl -n "${ns}" describe pod "${pod}" | sed -n '1,260p' || true
    kubectl -n "${ns}" logs "${pod}" --all-containers --tail=600 || true
  fi
  if [[ -n "${ingress}" ]]; then
    kubectl -n "${ns}" describe ingress "${ingress}" | sed -n '1,220p' || true
  fi
  echo "---- DIAG END ----" >&2
}

# Inputs per module (set these before running tests)
#   NS_APP, APP_LABEL, SVC_NAME, INGRESS_NAME, HOST_FQDN, SVC_PORT, HEALTH_PATH

: "${NS_APP:?missing NS_APP}"
: "${APP_LABEL:?missing APP_LABEL}"
: "${SVC_NAME:?missing SVC_NAME}"
: "${HOST_FQDN:?missing HOST_FQDN}"
: "${SVC_PORT:?missing SVC_PORT}"
: "${HEALTH_PATH:?missing HEALTH_PATH}"
: "${INGRESS_NAME:=}"

echo "[TEST] k8s objects exist"
kubectl -n "${NS_APP}" get svc "${SVC_NAME}" >/dev/null || { fail_diag "${NS_APP}" "${APP_LABEL}" "${SVC_NAME}" "${INGRESS_NAME}" "${HOST_FQDN}" "${SVC_PORT}"; exit 1; }
kubectl -n "${NS_APP}" get deploy -l "app=${APP_LABEL}" >/dev/null || { fail_diag "${NS_APP}" "${APP_LABEL}" "${SVC_NAME}" "${INGRESS_NAME}" "${HOST_FQDN}" "${SVC_PORT}"; exit 1; }

echo "[TEST] rollout ready"
if ! kubectl -n "${NS_APP}" rollout status deploy -l "app=${APP_LABEL}" --timeout=300s; then
  fail_diag "${NS_APP}" "${APP_LABEL}" "${SVC_NAME}" "${INGRESS_NAME}" "${HOST_FQDN}" "${SVC_PORT}"
  exit 1
fi

echo "[TEST] service endpoints ready"
kubectl -n "${NS_APP}" get endpoints "${SVC_NAME}" -o jsonpath='{.subsets[0].addresses[0].ip}' >/dev/null 2>&1 || {
  fail_diag "${NS_APP}" "${APP_LABEL}" "${SVC_NAME}" "${INGRESS_NAME}" "${HOST_FQDN}" "${SVC_PORT}"
  exit 1
}

echo "[TEST] in-cluster service reachability"
kubectl -n "${NS_APP}" delete pod "${APP_LABEL}-curl" --ignore-not-found >/dev/null 2>&1 || true
cat <<YAML | kubectl -n "${NS_APP}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${APP_LABEL}-curl
spec:
  restartPolicy: Never
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: ["sh","-lc"]
      args:
        - |
          set -euo pipefail
          curl -fsS -m 10 "http://${SVC_NAME}.${NS_APP}.svc.cluster.local:${SVC_PORT}${HEALTH_PATH}" >/dev/null
YAML
if ! kubectl -n "${NS_APP}" wait --for=condition=Ready pod/"${APP_LABEL}-curl" --timeout=60s >/dev/null 2>&1; then
  # even if pod doesn't become Ready, get logs (curlimages may exit fast)
  true
fi
if ! kubectl -n "${NS_APP}" logs "${APP_LABEL}-curl" -c curl --tail=50 >/dev/null 2>&1; then
  fail_diag "${NS_APP}" "${APP_LABEL}" "${SVC_NAME}" "${INGRESS_NAME}" "${HOST_FQDN}" "${SVC_PORT}"
  exit 1
fi
kubectl -n "${NS_APP}" delete pod "${APP_LABEL}-curl" --ignore-not-found >/dev/null 2>&1 || true

echo "[TEST] ingress reachability"
# 1) DNS resolution (host must resolve)
getent ahosts "${HOST_FQDN}" >/dev/null 2>&1 || {
  echo "[TEST][FAIL] DNS does not resolve: ${HOST_FQDN}" >&2
  fail_diag "${NS_APP}" "${APP_LABEL}" "${SVC_NAME}" "${INGRESS_NAME}" "${HOST_FQDN}" "${SVC_PORT}"
  exit 1
}

# 2) HTTP status + latency (via ingress)
HTTP_CODE="$(curl -k -sS -o /dev/null -m 15 -w '%{http_code}' "${URL_SCHEME}://${HOST_FQDN}${HEALTH_PATH}" || true)"
if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "[TEST][FAIL] ingress returned http_code=${HTTP_CODE} for ${URL_SCHEME}://${HOST_FQDN}${HEALTH_PATH}" >&2
  fail_diag "${NS_APP}" "${APP_LABEL}" "${SVC_NAME}" "${INGRESS_NAME}" "${HOST_FQDN}" "${SVC_PORT}"
  exit 1
fi

echo "[TEST] OK: contract + accessibility (${URL_SCHEME}://${HOST_FQDN}${HEALTH_PATH})"

