#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 03-app-metabase.sh — Metabase install (production, drop-in, repeatable)
#
# What this script does (idempotent):
# - Loads /root/open-kpi.env as the single source of truth
# - Ensures namespaces exist: OPENKPI_NS (platform) and NS_MB (metabase)
# - Reads platform Postgres superuser creds from OPENKPI_NS/openkpi-postgres-secret
# - Creates/updates NS_MB/metabase-db-secret (Metabase app DB password)
# - Bootstraps Metabase DB role+db+grants in shared Postgres (NO DO blocks)
# - Ensures cert-manager Certificate in NS_MB for HOST_MB -> metabase-tls (if TLS_MODE != off)
# - Helm install/upgrade metabase chart with ingress class bound correctly (permanent fix)
# - Waits for rollout + verifies nginx is actively serving the host
# - Verifies external HTTPS cert is NOT the nginx "Fake Certificate"
#
# Requirements:
# - kubectl + helm installed
# - ingress-nginx + cert-manager + ClusterIssuer already installed (use prereqs script)
# - /root/open-kpi.env defines METABASE_HOST and METABASE_DB_PASSWORD (and ACME_EMAIL if issuer creation happens elsewhere)
#
# Notes:
# - Ingress class binding fix:
#     ingressClassName + kubernetes.io/ingress.class annotation are BOTH set.
#     Without this, ingress-nginx may ignore the ingress and serve the fake cert.
# ==============================================================================

need(){ command -v "$1" >/dev/null 2>&1 || { echo "FATAL: missing command: $1" >&2; exit 1; }; }
ts(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
log(){ echo "$(ts) $*"; }
fatal(){ echo "FATAL: $*" >&2; exit 1; }
retry(){ local n="$1" s="$2"; shift 2; for _ in $(seq 1 "$n"); do "$@" && return 0 || true; sleep "$s"; done; return 1; }
sec(){ echo "-----------------------------------------------------------------------"; echo "## $*"; echo "-----------------------------------------------------------------------"; }

need kubectl
need helm
need base64
need openssl

# ---- load env contract ----
[[ -f /root/open-kpi.env ]] || fatal "missing /root/open-kpi.env"
set -a
# shellcheck source=/dev/null
. /root/open-kpi.env
set +a

# ---- config (NO hard-coded domains) ----
OPENKPI_NS="${NS:-${OPENKPI_NS:-open-kpi}}"

NS_MB="${METABASE_NAMESPACE:-analytics}"
REL_MB="${METABASE_RELEASE:-metabase}"
HOST_MB="${METABASE_HOST:?METABASE_HOST missing in /root/open-kpi.env}"

IMG_REPO="${METABASE_IMAGE_REPO:-metabase/metabase}"
IMG_TAG="${METABASE_IMAGE_TAG:-v0.56.7}"

INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
CERT_ISSUER="${CERT_CLUSTER_ISSUER:-letsencrypt-http01}"
TLS_MODE="${TLS_MODE:-per-host-http01}"

MB_DB="${METABASE_DB_NAME:-metabase}"
MB_USER="${METABASE_DB_USER:-metabase}"
MB_PASS="${METABASE_DB_PASSWORD:?METABASE_DB_PASSWORD missing in /root/open-kpi.env}"

PG_SECRET="openkpi-postgres-secret"

URL_SCHEME="https"
if [[ "${TLS_MODE}" == "off" ]]; then URL_SCHEME="http"; fi

# ---- trap diagnostics on error ----
on_err() {
  local rc="$?"
  log "[03D][METABASE] ERROR exit=${rc}. Diagnostics:"
  kubectl get nodes -o wide || true
  kubectl get ns || true
  kubectl -n "${NS_MB}" get all,ingress,certificate,secret 2>/dev/null || true
  kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=200 2>/dev/null | egrep -i "${HOST_MB}|metabase|IngressClass|class|secret|tls|certificate" || true
  exit "$rc"
}
trap on_err ERR

# ------------------------------------------------------------------------------
# 0) namespaces
# ------------------------------------------------------------------------------
log "[03D][METABASE] Ensure namespaces: ${NS_MB} (metabase), ${OPENKPI_NS} (platform)"
kubectl get ns "${OPENKPI_NS}" >/dev/null 2>&1 || kubectl create ns "${OPENKPI_NS}" >/dev/null
kubectl get ns "${NS_MB}" >/dev/null 2>&1 || kubectl create ns "${NS_MB}" >/dev/null

# ------------------------------------------------------------------------------
# 1) read platform Postgres admin creds (supports BOTH secret formats)
# ------------------------------------------------------------------------------

log "[03D][METABASE] Reading Postgres admin creds from ${OPENKPI_NS}/${PG_SECRET}"
kubectl -n "${OPENKPI_NS}" get secret "${PG_SECRET}" >/dev/null 2>&1 || fatal "missing ${OPENKPI_NS}/${PG_SECRET} (run 02-data-plane.sh)"

# Helper: read a key if it exists, else empty
sget() {
  local key="$1"
  kubectl -n "${OPENKPI_NS}" get secret "${PG_SECRET}" -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true
}

# Detect keyset
KEYS="$(kubectl -n "${OPENKPI_NS}" get secret "${PG_SECRET}" -o jsonpath='{range $k,$v := .data}{printf "%s\n" $k}{end}' 2>/dev/null || true)"

# Preferred (canonical) format: host/port/username/password (and optional database)
PG_HOST="$(sget host)"
PG_PORT="$(sget port)"
PG_USER="$(sget username)"
PG_PASS="$(sget password)"
PG_ADMIN_DB="$(sget database)"

# Fallback (chart) format: POSTGRES_*
if [[ -z "${PG_USER}" || -z "${PG_PASS}" ]]; then
  PG_USER="$(sget POSTGRES_USER)"
  PG_PASS="$(sget POSTGRES_PASSWORD)"
  PG_ADMIN_DB="$(sget POSTGRES_DB)"
fi

# Host/port fallback from env contract if secret doesn't carry them
PG_HOST="${PG_HOST:-${DBT_DB_HOST:-openkpi-postgres.${OPENKPI_NS}.svc.cluster.local}}"
PG_PORT="${PG_PORT:-${DBT_DB_PORT:-5432}}"
PG_ADMIN_DB="${PG_ADMIN_DB:-postgres}"

# Hard guardrails
[[ -n "${PG_USER}" ]] || { echo "${KEYS}" | sed 's/^/[03D][METABASE] secret key: /' >&2; fatal "Postgres admin username not found in ${OPENKPI_NS}/${PG_SECRET}"; }
[[ -n "${PG_PASS}" ]] || { echo "${KEYS}" | sed 's/^/[03D][METABASE] secret key: /' >&2; fatal "Postgres admin password not found in ${OPENKPI_NS}/${PG_SECRET}"; }
if [[ "${PG_USER}" == "root" ]]; then
  echo "${KEYS}" | sed 's/^/[03D][METABASE] secret key: /' >&2
  fatal "Refusing to use PG_USER=root. Fix ${OPENKPI_NS}/${PG_SECRET} to carry the real Postgres admin user."
fi

log "[03D][METABASE] Postgres admin endpoint: ${PG_HOST}:${PG_PORT} db=${PG_ADMIN_DB} user=${PG_USER}"

# Preflight: prove creds work before doing any bootstrap
TMP_POD="openkpi-psql-metabase-tmp"
kubectl -n "${OPENKPI_NS}" delete pod "${TMP_POD}" --ignore-not-found >/dev/null 2>&1 || true
kubectl -n "${OPENKPI_NS}" run "${TMP_POD}" --restart=Never --image=postgres:16 \
  --labels="app=openkpi-diag,component=metabase-bootstrap" \
  --command -- sleep 3600 >/dev/null

kubectl -n "${OPENKPI_NS}" wait --for=condition=Ready "pod/${TMP_POD}" --timeout=180s >/dev/null \
  || { kubectl -n "${OPENKPI_NS}" describe pod "${TMP_POD}" | sed -n '1,260p' >&2 || true; fatal "psql temp pod not Ready"; }

log "[03D][METABASE] Preflight psql select 1"
kubectl -n "${OPENKPI_NS}" exec -i "${TMP_POD}" -- bash -lc \
  "export PGPASSWORD='${PG_PASS}'; psql -h '${PG_HOST}' -p '${PG_PORT}' -U '${PG_USER}' -d '${PG_ADMIN_DB}' -v ON_ERROR_STOP=1 -c 'select 1;'" >/dev/null \
  || { echo "${KEYS}" | sed 's/^/[03D][METABASE] secret key: /' >&2; fatal "Postgres admin creds invalid (authentication failed)"; }

# ------------------------------------------------------------------------------
# 2) ensure metabase-db-secret in metabase namespace
# ------------------------------------------------------------------------------
log "[03D][METABASE] Ensuring ${NS_MB}/metabase-db-secret"
kubectl -n "${NS_MB}" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: metabase-db-secret
  namespace: ${NS_MB}
type: Opaque
stringData:
  MB_DB_PASS: "${MB_PASS}"
YAML

# ------------------------------------------------------------------------------
# 3) bootstrap DB objects (NO DO blocks, NO \gexec; idempotent; safe quoting)
# ------------------------------------------------------------------------------

log "[03D][METABASE] Bootstrapping DB objects (role/db/grants) (no DO; no \\gexec)"

# Run psql inside the temp pod, SQL via stdin (prevents word-splitting bugs)
psql_admin_sql() {
  local sql="$1"
  kubectl -n "${OPENKPI_NS}" exec -i "${TMP_POD}" -- bash -lc "
    set -euo pipefail
    export PGPASSWORD='${PG_PASS}'
    psql -h '${PG_HOST}' -p '${PG_PORT}' -U '${PG_USER}' -d '${PG_ADMIN_DB}' -v ON_ERROR_STOP=1 -q
  " <<< "${sql}"
}

psql_admin_scalar() {
  local sql="$1"
  kubectl -n "${OPENKPI_NS}" exec -i "${TMP_POD}" -- bash -lc "
    set -euo pipefail
    export PGPASSWORD='${PG_PASS}'
    psql -h '${PG_HOST}' -p '${PG_PORT}' -U '${PG_USER}' -d '${PG_ADMIN_DB}' -v ON_ERROR_STOP=1 -q -tA
  " <<< "${sql}" | tr -d '[:space:]'
}

role_exists() {
  [[ "$(psql_admin_scalar "SELECT 1 FROM pg_roles WHERE rolname='${MB_USER}';")" == "1" ]]
}

db_exists() {
  [[ "$(psql_admin_scalar "SELECT 1 FROM pg_database WHERE datname='${MB_DB}';")" == "1" ]]
}

# Escape single quotes for SQL string literal
MB_PASS_SQL="${MB_PASS//\'/\'\'}"

# 1) role
if role_exists; then
  log "[03D][METABASE] Role exists: ${MB_USER}"
else
  log "[03D][METABASE] Creating role: ${MB_USER}"
  psql_admin_sql "CREATE ROLE ${MB_USER} LOGIN PASSWORD '${MB_PASS_SQL}';"
fi

# 2) database
if db_exists; then
  log "[03D][METABASE] DB exists: ${MB_DB}"
else
  log "[03D][METABASE] Creating database: ${MB_DB}"
  psql_admin_sql "CREATE DATABASE ${MB_DB} OWNER ${MB_USER};"
fi

# 3) grants/ownership (safe on rerun)
log "[03D][METABASE] Ensuring grants/ownership for ${MB_DB}"
psql_admin_sql "GRANT CONNECT ON DATABASE ${MB_DB} TO ${MB_USER};" || true
psql_admin_sql "ALTER DATABASE ${MB_DB} OWNER TO ${MB_USER};" || true

# ------------------------------------------------------------------------------
# 4) cert-manager Certificate (if TLS on)
# ------------------------------------------------------------------------------
if [[ "${TLS_MODE}" != "off" ]]; then
  log "[03D][METABASE] Ensuring cert-manager Certificate (issuer=${CERT_ISSUER}, secret=metabase-tls)"
  kubectl -n "${NS_MB}" apply -f - >/dev/null <<YAML
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: metabase-tls
  namespace: ${NS_MB}
spec:
  secretName: metabase-tls
  issuerRef:
    kind: ClusterIssuer
    name: ${CERT_ISSUER}
  dnsNames:
    - ${HOST_MB}
YAML
fi

# ------------------------------------------------------------------------------
# 5) helm install/upgrade with PERMANENT ingress class fix (no post-patch)
# ------------------------------------------------------------------------------
REPO_NAME="pmint93"
REPO_URL="https://pmint93.github.io/helm-charts"
CHART="${REPO_NAME}/metabase"

log "[03D][METABASE] Helm repo add/update"
helm repo add "${REPO_NAME}" "${REPO_URL}" >/dev/null 2>&1 || true
helm repo update >/dev/null

VALUES="$(mktemp)"
cat > "${VALUES}" <<YAML
replicaCount: 1

image:
  repository: ${IMG_REPO}
  tag: ${IMG_TAG}

service:
  type: ClusterIP
  port: 3000

ingress:
  enabled: true
  # Critical: make ingress-nginx accept this ingress (otherwise fake cert is served)
  ingressClassName: ${INGRESS_CLASS}
  annotations:
    kubernetes.io/ingress.class: "${INGRESS_CLASS}"
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
  hosts:
    - ${HOST_MB}
  path: /
  pathType: Prefix
YAML

if [[ "${TLS_MODE}" != "off" ]]; then
  cat >> "${VALUES}" <<YAML
  tls:
    - secretName: metabase-tls
      hosts:
        - ${HOST_MB}
YAML
else
  cat >> "${VALUES}" <<'YAML'
  tls: []
YAML
fi

cat >> "${VALUES}" <<YAML

env:
  MB_DB_TYPE: postgres
  MB_DB_HOST: "${PG_HOST}"
  MB_DB_PORT: "${PG_PORT}"
  MB_DB_DBNAME: "${MB_DB}"
  MB_DB_USER: "${MB_USER}"
  MB_DB_PASS:
    valueFrom:
      secretKeyRef:
        name: metabase-db-secret
        key: MB_DB_PASS

extraEnv:
  - name: MB_SITE_URL
    value: "${URL_SCHEME}://${HOST_MB}"

resources: {}
nodeSelector: {}
tolerations: []
affinity: {}
YAML

log "[03D][METABASE] Installing/upgrading ${REL_MB} in ${NS_MB} (${IMG_REPO}:${IMG_TAG})"
helm upgrade --install "${REL_MB}" "${CHART}" -n "${NS_MB}" -f "${VALUES}" --wait --timeout 10m
rm -f "${VALUES}" || true

# ------------------------------------------------------------------------------
# 6) readiness + certificate ready (best-effort)
# ------------------------------------------------------------------------------
log "[03D][METABASE] Readiness"
kubectl -n "${NS_MB}" rollout status deploy/"${REL_MB}" --timeout=10m

if [[ "${TLS_MODE}" != "off" ]]; then
  log "[03D][METABASE] Waiting for certificate Ready (best effort)"
  kubectl -n "${NS_MB}" wait --for=condition=Ready certificate/metabase-tls --timeout=10m >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------------------------
# 7) prove ingress is class-bound and nginx has accepted it
# ------------------------------------------------------------------------------
sec "[03D][METABASE] Ingress class binding proof"
kubectl -n "${NS_MB}" get ingress "${REL_MB}" -o jsonpath='{.spec.ingressClassName}{" | "}{.metadata.annotations.kubernetes\.io/ingress\.class}{"\n"}' || true
kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=200 2>/dev/null | egrep -i "${HOST_MB}|${REL_MB}|IngressClass|class|creating ingress|ignoring ingress" || true

# ------------------------------------------------------------------------------
# 8) external HTTPS proof (must not be fake cert)
# ------------------------------------------------------------------------------
if [[ "${TLS_MODE}" != "off" ]]; then
  sec "[03D][METABASE] External TLS proof (openssl)"
  # retry a few times to allow controller sync
  ok=0
  for _ in 1 2 3 4 5 6; do
    out="$(openssl s_client -connect "${HOST_MB}:443" -servername "${HOST_MB}" </dev/null 2>/dev/null \
      | openssl x509 -noout -subject -issuer -ext subjectAltName 2>/dev/null || true)"
    echo "${out}"
    if ! echo "${out}" | grep -q "Kubernetes Ingress Controller Fake Certificate"; then
      ok=1
      break
    fi
    sleep 5
  done
  [[ "${ok}" -eq 1 ]] || fatal "Still serving nginx Fake Certificate on ${HOST_MB}. Ingress not active on controller or 443 not routed."
fi

# ------------------------------------------------------------------------------
# summary
# ------------------------------------------------------------------------------
sec "[03D][METABASE] URLs"
echo "Metabase: ${URL_SCHEME}://${HOST_MB}/"
kubectl -n "${NS_MB}" get deploy,svc,ingress,certificate 2>/dev/null | sed 's/^/[03D][METABASE] /' || true
