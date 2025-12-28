#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 03-app-metabase.sh — OpenKPI Metabase installer (repeatable)
#
# Contract:
# - Sources /root/open-kpi.env (single source of truth)
# - Expects canonical Postgres secret: open-kpi/openkpi-postgres-secret
#   keys: host, port, username, password
# - Creates analytics/metabase-db-secret (Metabase app DB creds; stable)
# - Creates Postgres DB+role for Metabase (idempotent)
# - Installs Metabase via Helm, pinned to metabase/metabase:v0.56.x
# - Creates cert-manager Certificate -> analytics/metabase-tls when TLS_MODE != off
#
# Required tools: kubectl, helm, openssl
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ---- source env (authoritative) ----
if [[ -f /root/open-kpi.env ]]; then
  set -a
  # shellcheck source=/dev/null
  . /root/open-kpi.env
  set +a
elif [[ -f "${HERE}/open-kpi.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "${HERE}/open-kpi.env"
  set +a
elif [[ -f "${HERE}/00-env.sh" ]]; then
  # legacy compatibility
  # shellcheck source=/dev/null
  . "${HERE}/00-env.sh"
else
  echo "FATAL: missing /root/open-kpi.env (or ./open-kpi.env / ./00-env.sh)" >&2
  exit 1
fi

# ---- best-effort shared lib ----
if [[ -f "${HERE}/00-lib.sh" ]]; then
  # shellcheck source=/dev/null
  . "${HERE}/00-lib.sh" || true
fi

# ---- fallback helpers ----
log(){ echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }
fatal(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || fatal "Missing required command: $1"; }
sec(){ echo "-----------------------------------------------------------------------"; echo "## $*"; echo "-----------------------------------------------------------------------"; }

need kubectl
need helm
need openssl

# ---- settings (from env, with safe defaults) ----
OPENKPI_NS="${NS:-${OPENKPI_NS:-open-kpi}}"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
TLS_MODE="${TLS_MODE:-off}"
CERT_ISSUER="${CERT_CLUSTER_ISSUER:-letsencrypt-http01}"

NS_MB="${METABASE_NAMESPACE:-analytics}"
REL_MB="${METABASE_RELEASE:-metabase}"
HOST_MB="${METABASE_HOST:-metabase.${APP_DOMAIN:-${DOMAIN_BASE:-example.local}}}"

IMG_REPO="${METABASE_IMAGE_REPO:-metabase/metabase}"
IMG_TAG="${METABASE_IMAGE_TAG:-v0.56.x}"

MB_DB="${METABASE_DB_NAME:-metabase}"
MB_USER="${METABASE_DB_USER:-metabase}"
MB_PASS="${METABASE_DB_PASSWORD:-}"

URL_SCHEME="http"
[[ "${TLS_MODE}" != "off" ]] && URL_SCHEME="https"

# ---- guard: enforce real Metabase DB password ----
if [[ -z "${MB_PASS}" || "${MB_PASS}" == "CHANGE_ME_STRONG" ]]; then
  fatal "METABASE_DB_PASSWORD is not set (or still CHANGE_ME_STRONG) in /root/open-kpi.env"
fi

# ---- ensure namespaces ----
log "[03D][METABASE] Ensure namespaces: ${NS_MB} (metabase), ${OPENKPI_NS} (platform)"
kubectl get ns "${NS_MB}" >/dev/null 2>&1 || kubectl create ns "${NS_MB}" >/dev/null
kubectl get ns "${OPENKPI_NS}" >/dev/null 2>&1 || fatal "Namespace ${OPENKPI_NS} missing"

# ---- read canonical postgres secret expected by platform modules ----
PG_SECRET="openkpi-postgres-secret"
log "[03D][METABASE] Reading Postgres creds from ${OPENKPI_NS}/${PG_SECRET}"
PG_HOST="$(kubectl -n "${OPENKPI_NS}" get secret "${PG_SECRET}" -o jsonpath='{.data.host}' 2>/dev/null | base64 -d || true)"
PG_PORT="$(kubectl -n "${OPENKPI_NS}" get secret "${PG_SECRET}" -o jsonpath='{.data.port}' 2>/dev/null | base64 -d || true)"
PG_SUPERUSER="$(kubectl -n "${OPENKPI_NS}" get secret "${PG_SECRET}" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d || true)"
PG_SUPERPASS="$(kubectl -n "${OPENKPI_NS}" get secret "${PG_SECRET}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"

if [[ -z "${PG_HOST}" || -z "${PG_PORT}" || -z "${PG_SUPERUSER}" || -z "${PG_SUPERPASS}" ]]; then
  fatal "Could not read host/port/username/password from ${OPENKPI_NS}/${PG_SECRET}"
fi

# ---- create/reuse metabase db secret (stable) ----
log "[03D][METABASE] Ensuring ${NS_MB}/metabase-db-secret"
kubectl -n "${NS_MB}" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: metabase-db-secret
  namespace: ${NS_MB}
type: Opaque
stringData:
  MB_DB_NAME: "${MB_DB}"
  MB_DB_USER: "${MB_USER}"
  MB_DB_PASS: "${MB_PASS}"
YAML

# ---- bootstrap dedicated DB + role in shared Postgres (idempotent) ----
BOOT_POD="openkpi-psql-metabase-tmp"
log "[03D][METABASE] Bootstrapping DB objects (role/db/grants) via postgres:16"
kubectl -n "${NS_MB}" delete pod "${BOOT_POD}" --ignore-not-found >/dev/null 2>&1 || true

kubectl -n "${NS_MB}" run "${BOOT_POD}" --rm -i --restart=Never --image=postgres:16 -- \
  bash -lc "
set -euo pipefail
export PGPASSWORD='${PG_SUPERPASS}'

# role
psql -h '${PG_HOST}' -p '${PG_PORT}' -U '${PG_SUPERUSER}' -d postgres -v ON_ERROR_STOP=1 -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${MB_USER}'\" | grep -q 1 || \
  psql -h '${PG_HOST}' -p '${PG_PORT}' -U '${PG_SUPERUSER}' -d postgres -v ON_ERROR_STOP=1 -c \"CREATE ROLE \\\"${MB_USER}\\\" LOGIN PASSWORD '${MB_PASS}';\"

# db
psql -h '${PG_HOST}' -p '${PG_PORT}' -U '${PG_SUPERUSER}' -d postgres -v ON_ERROR_STOP=1 -tAc \"SELECT 1 FROM pg_database WHERE datname='${MB_DB}'\" | grep -q 1 || \
  psql -h '${PG_HOST}' -p '${PG_PORT}' -U '${PG_SUPERUSER}' -d postgres -v ON_ERROR_STOP=1 -c \"CREATE DATABASE \\\"${MB_DB}\\\" OWNER \\\"${MB_USER}\\\";\"

# grant (repeatable)
psql -h '${PG_HOST}' -p '${PG_PORT}' -U '${PG_SUPERUSER}' -d postgres -v ON_ERROR_STOP=1 -c \"GRANT ALL PRIVILEGES ON DATABASE \\\"${MB_DB}\\\" TO \\\"${MB_USER}\\\";\"
" || fatal "[03D][METABASE] Postgres bootstrap failed"

# ---- TLS certificate (cert-manager) ----
if [[ "${TLS_MODE}" != "off" ]]; then
  log "[03D][METABASE] Ensuring cert-manager Certificate (issuer=${CERT_ISSUER}, secret=metabase-tls)"
  cat <<YAML | kubectl apply -f - >/dev/null
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

# ---- Helm install/upgrade ----
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
  ingressClassName: ${INGRESS_CLASS}
  annotations:
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

# ---- readiness ----
log "[03D][METABASE] Readiness"
kubectl -n "${NS_MB}" rollout status deploy/"${REL_MB}" --timeout=10m

if [[ "${TLS_MODE}" != "off" ]]; then
  log "[03D][METABASE] Waiting for certificate Ready (best effort)"
  kubectl -n "${NS_MB}" wait --for=condition=Ready certificate/metabase-tls --timeout=10m >/dev/null 2>&1 || true
fi

sec "[03D][METABASE] URLs"
echo "Metabase: ${URL_SCHEME}://${HOST_MB}/"

kubectl -n "${NS_MB}" get deploy,svc,ingress,certificate 2>/dev/null | sed 's/^/[03D][METABASE] /' || true
