#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# MODULE 03B — APP (Metabase) — PRODUCTION / CONTRACTIZED / REPEATABLE
# FILE: 03B-app-metabase.sh
#
# Contract:
# - Reads /root/open-kpi.env via 00-env.sh
# - Requires canonical Postgres secret: ${OPENKPI_NS}/openkpi-postgres-secret
#     keys: host port username password db
# - Bootstraps metabase role+db using in-cluster psql pod (no host psql)
# - Deploys Metabase via kubectl apply (Deployment/Service/Ingress)
# - If TLS_MODE != off: requires cert-manager + ClusterIssuer already installed; uses Certificate
# - Tests:
#   - rollout
#   - in-cluster /api/health via service DNS
#   - ingress /api/health via host
#   - if TLS: rejects nginx Fake Certificate using openssl
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
require_cmd curl
require_cmd getent
require_cmd openssl
require_cmd sed

MODULE_ID="03B"

: "${OPENKPI_NS:=open-kpi}"
: "${ANALYTICS_NS:=analytics}"
: "${INGRESS_CLASS:=nginx}"
: "${TLS_MODE:=off}"

: "${METABASE_HOST:?missing METABASE_HOST}"
: "${METABASE_TLS_SECRET:=metabase-tls}"
: "${CERT_CLUSTER_ISSUER:=letsencrypt-http01}"

: "${METABASE_IMAGE_REPO:=metabase/metabase}"
: "${METABASE_IMAGE_TAG:=v0.56.7}"

: "${METABASE_DB_NAME:=metabase}"
: "${METABASE_DB_USER:=metabase}"
: "${METABASE_DB_PASSWORD:?missing METABASE_DB_PASSWORD}"

URL_SCHEME="http"; [[ "${TLS_MODE}" != "off" ]] && URL_SCHEME="https"

cleanup() {
  kubectl -n "${OPENKPI_NS}" delete pod metabase-psql --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${ANALYTICS_NS}" delete pod metabase-curl --ignore-not-found >/dev/null 2>&1 || true
}
on_err() {
  local rc="$?"
  log "[${MODULE_ID}][metabase] ERROR exit=${rc} — diagnostics"
  kubectl get nodes -o wide || true
  kubectl -n "${ANALYTICS_NS}" get deploy,svc,ep,ingress,pods,certificate,secret -o wide || true
  kubectl -n "${ANALYTICS_NS}" get events --sort-by=.lastTimestamp | tail -n 80 || true
  kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=250 2>/dev/null \
    | egrep -i "${METABASE_HOST}|metabase|IngressClass|class|secret|tls|certificate|ignoring ingress|creating ingress" || true
  cleanup
  exit "$rc"
}
trap on_err ERR
trap cleanup EXIT

log "[${MODULE_ID}][metabase] start"
ensure_ns "${OPENKPI_NS}"
ensure_ns "${ANALYTICS_NS}"

# ------------------------------------------------------------------------------
# 01) Read canonical Postgres admin secret (NO fallback formats)
# ------------------------------------------------------------------------------

PG_SECRET="openkpi-postgres-secret"
kubectl -n "${OPENKPI_NS}" get secret "${PG_SECRET}" >/dev/null 2>&1 \
  || die "Missing ${OPENKPI_NS}/${PG_SECRET} (run 01/02 modules)."

sget() {
  local key="$1"
  kubectl -n "${OPENKPI_NS}" get secret "${PG_SECRET}" \
    -o go-template='{{ index .data "'"${key}"'" }}' 2>/dev/null \
    | base64 -d 2>/dev/null || true
}


PG_HOST="$(sget host)"
PG_PORT="$(sget port)"
PG_USER="$(sget username)"
PG_PASS="$(sget password)"
PG_ADMIN_DB="$(sget db)"

[[ -n "${PG_HOST}" && -n "${PG_PORT}" && -n "${PG_USER}" && -n "${PG_PASS}" && -n "${PG_ADMIN_DB}" ]] \
  || die "Canonical secret missing required keys: host port username password db"

log "[${MODULE_ID}][metabase] Postgres admin endpoint: ${PG_HOST}:${PG_PORT} db=${PG_ADMIN_DB} user=${PG_USER}"

# ------------------------------------------------------------------------------
# 02) Create short-lived psql pod with env from secret (no password in CLI)
# ------------------------------------------------------------------------------

cat <<YAML | kubectl -n "${OPENKPI_NS}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: metabase-psql
  labels:
    app: metabase-psql
spec:
  restartPolicy: Never
  containers:
    - name: psql
      image: postgres:16-alpine
      imagePullPolicy: IfNotPresent
      env:
        - name: PGHOST
          valueFrom: {secretKeyRef: {name: ${PG_SECRET}, key: host}}
        - name: PGPORT
          valueFrom: {secretKeyRef: {name: ${PG_SECRET}, key: port}}
        - name: PGUSER
          valueFrom: {secretKeyRef: {name: ${PG_SECRET}, key: username}}
        - name: PGPASSWORD
          valueFrom: {secretKeyRef: {name: ${PG_SECRET}, key: password}}
        - name: PGDATABASE
          valueFrom: {secretKeyRef: {name: ${PG_SECRET}, key: db}}
      command: ["sh","-lc"]
      args: ["sleep 3600"]
YAML

kubectl -n "${OPENKPI_NS}" wait --for=condition=Ready pod/metabase-psql --timeout=180s >/dev/null

# ------------------------------------------------------------------------------
# 03) Bootstrap role+db (idempotent; no DO; safe quoting)
# ------------------------------------------------------------------------------

MB_DB="${METABASE_DB_NAME}"
MB_USER="${METABASE_DB_USER}"
MB_PASS="${METABASE_DB_PASSWORD}"
MB_PASS_SQL="${MB_PASS//\'/\'\'}"

psql_scalar() {
  local sql="$1"
  kubectl -n "${OPENKPI_NS}" exec -i metabase-psql -c psql -- sh -lc \
    "psql -v ON_ERROR_STOP=1 -q -tA" <<< "${sql}" | tr -d '[:space:]'
}
psql_exec() {
  local sql="$1"
  kubectl -n "${OPENKPI_NS}" exec -i metabase-psql -c psql -- sh -lc \
    "psql -v ON_ERROR_STOP=1 -q" <<< "${sql}"
}

log "[${MODULE_ID}][metabase] Preflight psql select 1"
psql_exec "select 1;" >/dev/null

role_exists="$(psql_scalar "SELECT 1 FROM pg_roles WHERE rolname='${MB_USER}';" || true)"
if [[ "${role_exists}" != "1" ]]; then
  log "[${MODULE_ID}][metabase] create role ${MB_USER}"
  psql_exec "CREATE ROLE ${MB_USER} LOGIN PASSWORD '${MB_PASS_SQL}';"
else
  log "[${MODULE_ID}][metabase] role exists ${MB_USER}"
fi
log "[${MODULE_ID}][metabase] enforce role password ${MB_USER}"
psql_exec "ALTER ROLE ${MB_USER} LOGIN PASSWORD '${MB_PASS_SQL}';"

db_exists="$(psql_scalar "SELECT 1 FROM pg_database WHERE datname='${MB_DB}';" || true)"
if [[ "${db_exists}" != "1" ]]; then
  log "[${MODULE_ID}][metabase] create db ${MB_DB}"
  psql_exec "CREATE DATABASE ${MB_DB} OWNER ${MB_USER};"
else
  log "[${MODULE_ID}][metabase] db exists ${MB_DB}"
fi

psql_exec "GRANT ALL PRIVILEGES ON DATABASE ${MB_DB} TO ${MB_USER};" || true
psql_exec "ALTER DATABASE ${MB_DB} OWNER TO ${MB_USER};" || true

# ------------------------------------------------------------------------------
# 04) Metabase DB secret (app DB credentials)
# ------------------------------------------------------------------------------

kubectl -n "${ANALYTICS_NS}" apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: metabase-db-secret
type: Opaque
stringData:
  MB_DB_TYPE: "postgres"
  MB_DB_HOST: "${PG_HOST}"
  MB_DB_PORT: "${PG_PORT}"
  MB_DB_DBNAME: "${MB_DB}"
  MB_DB_USER: "${MB_USER}"
  MB_DB_PASS: "${MB_PASS}"
YAML

# ------------------------------------------------------------------------------
# 05) TLS Certificate (if enabled)
# ------------------------------------------------------------------------------

if [[ "${TLS_MODE}" != "off" ]]; then
  kubectl -n "${ANALYTICS_NS}" apply -f - <<YAML
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: metabase-tls
spec:
  secretName: ${METABASE_TLS_SECRET}
  issuerRef:
    kind: ClusterIssuer
    name: ${CERT_CLUSTER_ISSUER}
  dnsNames:
    - ${METABASE_HOST}
YAML
fi

# ------------------------------------------------------------------------------
# 06) Deployment + Service + Ingress (class bound in BOTH fields)
# ------------------------------------------------------------------------------

ING_TLS_BLOCK=""
if [[ "${TLS_MODE}" != "off" ]]; then
  ING_TLS_BLOCK="$(cat <<EOF
  tls:
    - hosts:
        - ${METABASE_HOST}
      secretName: ${METABASE_TLS_SECRET}
EOF
)"
fi

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

          startupProbe:
            httpGet: {path: /api/health, port: 3000}
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 60

          readinessProbe:
            httpGet: {path: /api/health, port: 3000}
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 12

          livenessProbe:
            httpGet: {path: /api/health, port: 3000}
            initialDelaySeconds: 120
            periodSeconds: 20
            timeoutSeconds: 3
            failureThreshold: 6

---
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
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: metabase-ingress
  labels: {app: metabase}
  annotations:
    kubernetes.io/ingress.class: "${INGRESS_CLASS}"
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
spec:
  ingressClassName: ${INGRESS_CLASS}
${ING_TLS_BLOCK}
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

# ------------------------------------------------------------------------------
# 07) Tests (deterministic)
# ------------------------------------------------------------------------------

log "[${MODULE_ID}][metabase] rollout"
kubectl -n "${ANALYTICS_NS}" rollout status deploy/metabase --timeout=10m

log "[${MODULE_ID}][metabase] in-cluster service reachability (retry)"
# Use an ephemeral pod so we don't depend on host curl, and we retry until Metabase is actually serving.
kubectl -n "${ANALYTICS_NS}" run -i --rm --restart=Never metabase-curl \
  --image="curlimages/curl:8.10.1" \
  --command -- sh -lc '
set -euo pipefail
URL="http://metabase.'"${ANALYTICS_NS}"'.svc.cluster.local:3000/api/health"
i=0
while [ $i -lt 60 ]; do
  # -f fail on non-2xx, -sS quiet but show errors, -L follow redirects, short timeouts
  if curl -fsSL -m 3 "$URL" >/dev/null 2>&1; then
    exit 0
  fi
  i=$((i+1))
  sleep 2
done
echo "metabase in-cluster health never became ready"
exit 1
' >/dev/null

log "[${MODULE_ID}][metabase] DNS + ingress health"
getent ahosts "${METABASE_HOST}" >/dev/null 2>&1 || die "DNS does not resolve: ${METABASE_HOST}"

HTTP_CODE="$(curl -k -sS -L -o /dev/null -m 20 -w '%{http_code}' "${URL_SCHEME}://${METABASE_HOST}/api/health" || true)"
[[ "${HTTP_CODE}" == "200" ]] || die "Ingress health failed: http_code=${HTTP_CODE}"

if [[ "${TLS_MODE}" != "off" ]]; then
  log "[${MODULE_ID}][metabase] TLS proof (not nginx Fake Certificate)"
  ok=0
  for _ in 1 2 3 4 5 6; do
    out="$(openssl s_client -connect "${METABASE_HOST}:443" -servername "${METABASE_HOST}" </dev/null 2>/dev/null \
      | openssl x509 -noout -subject -issuer 2>/dev/null || true)"
    echo "${out}"
    if ! echo "${out}" | grep -q "Kubernetes Ingress Controller Fake Certificate"; then
      ok=1; break
    fi
    sleep 5
  done
  [[ "${ok}" -eq 1 ]] || die "Still serving nginx Fake Certificate on ${METABASE_HOST}"
fi

log "[${MODULE_ID}][metabase] OK: ${URL_SCHEME}://${METABASE_HOST}/"
