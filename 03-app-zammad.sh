#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 03-app-zammad.sh — Zammad install (production, drop-in, repeatable)
#
# Idempotent behavior:
# - Loads 00-env.sh as the single source of truth
# - Ensures namespace exists (tickets)
# - Ensures required node sysctl for Elasticsearch (vm.max_map_count)
# - Ensures tickets/zammad-secret contains ZAMMAD_DB_PASSWORD (generated if absent)
# - Bootstraps Zammad DB + role in shared OpenKPI Postgres (no DO blocks)
# - Installs/Upgrades zammad/zammad chart with:
#     - ingress class fixed (spec.ingressClassName)
#     - host fixed (guard against chart-example.local)
#     - deterministic cert-manager Certificate -> secret zammad-tls (TLS_MODE=per-host-http01)
#     - storageClass pinned for PVCs
#     - chart postgresql disabled (uses shared OpenKPI Postgres)
# - Waits for rollout and performs hard assertions on ingress host + class
#
# Requires:
# - kubectl + helm + python3 + openssl
# - 00-env.sh defines: INGRESS_CLASS, ZAMMAD_HOST, TLS_MODE, STORAGE_CLASS
# - 00-env.sh defines: OPENKPI_NS, OPENKPI_PG_SECRET (defaults ok)
# - Cluster prereqs already applied: ingress-nginx, cert-manager, ClusterIssuer
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/00-env.sh"
# shellcheck source=/dev/null
. "${HERE}/00-lib.sh"

: "${KUBECONFIG:=/root/.kube/config}"
export KUBECONFIG

APP_NS="tickets"
REL="zammad"
REPO_NAME="zammad"
REPO_URL="https://zammad.github.io/zammad-helm"
CHART="zammad/zammad"

: "${INGRESS_CLASS:?missing INGRESS_CLASS}"
: "${ZAMMAD_HOST:?missing ZAMMAD_HOST}"
: "${TLS_MODE:?missing TLS_MODE}"
: "${STORAGE_CLASS:?missing STORAGE_CLASS}"

: "${OPENKPI_NS:=open-kpi}"
: "${OPENKPI_PG_SECRET:=openkpi-postgres-secret}"

: "${ZAMMAD_DB_NAME:=zammad}"
: "${ZAMMAD_DB_USER:=zammad}"

: "${LETSENCRYPT_ISSUER:=letsencrypt-prod}"      # per-host-http01 ClusterIssuer name
: "${VM_MAX_MAP_COUNT:=262144}"

require_cmd kubectl
require_cmd helm
require_cmd python3
require_cmd openssl

ensure_ns "${APP_NS}"

log "[03C][ZAMMAD] Helm repo ensure: ${REPO_NAME} -> ${REPO_URL}"
if ! helm repo list | awk 'NR>1{print $1}' | grep -qx "${REPO_NAME}"; then
  helm repo add "${REPO_NAME}" "${REPO_URL}"
fi
helm repo update >/dev/null

TMP_DIR="$(mktemp -d)"
cleanup(){ rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

VALUES_FILE="${TMP_DIR}/values.yaml"

# ------------------------------------------------------------------------------
# 1) Node prerequisite for Elasticsearch (Zammad chart defaults to ES)
# ------------------------------------------------------------------------------
log "[03C][ZAMMAD] Ensure vm.max_map_count=${VM_MAX_MAP_COUNT} on all nodes (ES requirement)"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: openkpi-sysctl-vmmaxmapcount
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: openkpi-sysctl-vmmaxmapcount
  template:
    metadata:
      labels:
        app: openkpi-sysctl-vmmaxmapcount
    spec:
      hostPID: true
      tolerations:
      - operator: Exists
      containers:
      - name: sysctl
        image: busybox:1.36
        securityContext:
          privileged: true
        command: ["sh","-lc"]
        args:
          - |
            set -e
            sysctl -w vm.max_map_count=${VM_MAX_MAP_COUNT} || true
            sysctl vm.max_map_count || true
            sleep 3600
EOF
kubectl -n kube-system rollout status ds/openkpi-sysctl-vmmaxmapcount --timeout=3m >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 2) Ensure tickets/zammad-secret exists with DB password (single source for app)
# ------------------------------------------------------------------------------
ZPASS="$(kubectl -n "${APP_NS}" get secret zammad-secret -o jsonpath='{.data.ZAMMAD_DB_PASSWORD}' 2>/dev/null | base64 -d || true)"
if [[ -z "${ZPASS:-}" ]]; then
  log "[03C][ZAMMAD] Create tickets/zammad-secret (ZAMMAD_DB_PASSWORD)"
  ZPASS="$(openssl rand -base64 24 | tr -d '\n')"
  kubectl -n "${APP_NS}" create secret generic zammad-secret \
    --from-literal=ZAMMAD_DB_PASSWORD="${ZPASS}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi

# ------------------------------------------------------------------------------
# 3) Bootstrap DB + role in shared OpenKPI Postgres (idempotent, no DO blocks)
# ------------------------------------------------------------------------------
log "[03C][ZAMMAD] Bootstrap DB/role in shared Postgres (${OPENKPI_NS}/${OPENKPI_PG_SECRET})"
PG_SUPERUSER="$(kubectl -n "${OPENKPI_NS}" get secret "${OPENKPI_PG_SECRET}" -o jsonpath='{.data.POSTGRES_USER}' | base64 -d)"
PG_SUPERPASS="$(kubectl -n "${OPENKPI_NS}" get secret "${OPENKPI_PG_SECRET}" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"
PG_HOST="openkpi-postgres.${OPENKPI_NS}.svc.cluster.local"
PG_PORT="5432"

kubectl -n "${OPENKPI_NS}" run openkpi-psql-zammad --rm -i --restart=Never --image=postgres:16 -- \
  bash -lc "
set -euo pipefail
export PGPASSWORD='${PG_SUPERPASS}'
psql -h '${PG_HOST}' -p '${PG_PORT}' -U '${PG_SUPERUSER}' -d postgres -v ON_ERROR_STOP=1 <<SQL
SELECT 1 AS exists FROM pg_roles WHERE rolname='${ZAMMAD_DB_USER}';
SELECT 1 AS exists FROM pg_database WHERE datname='${ZAMMAD_DB_NAME}';
SQL
" >/dev/null 2>&1 || true

kubectl -n "${OPENKPI_NS}" run openkpi-psql-zammad-apply --rm -i --restart=Never --image=postgres:16 -- \
  bash -lc "
set -euo pipefail
export PGPASSWORD='${PG_SUPERPASS}'
psql -h '${PG_HOST}' -p '${PG_PORT}' -U '${PG_SUPERUSER}' -d postgres -v ON_ERROR_STOP=1 <<SQL
-- role
CREATE ROLE ${ZAMMAD_DB_USER} LOGIN PASSWORD '${ZPASS}';
-- db
CREATE DATABASE ${ZAMMAD_DB_NAME} OWNER ${ZAMMAD_DB_USER};
GRANT ALL PRIVILEGES ON DATABASE ${ZAMMAD_DB_NAME} TO ${ZAMMAD_DB_USER};
SQL
" >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 4) Render chart values (ingress + TLS + storage + external DB)
# ------------------------------------------------------------------------------
if [[ "${TLS_MODE}" == "per-host-http01" ]]; then
  cat > "${VALUES_FILE}" <<YAML
ingress:
  enabled: true
  ingressClassName: ${INGRESS_CLASS}
  hosts:
    - host: ${ZAMMAD_HOST}
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: zammad-tls
      hosts:
        - ${ZAMMAD_HOST}

# Use shared OpenKPI Postgres (disable chart dependency)
postgresql:
  enabled: false
  host: ${PG_HOST}
  port: ${PG_PORT}
  user: ${ZAMMAD_DB_USER}
  pass: ${ZPASS}
  db: ${ZAMMAD_DB_NAME}

# Persist Zammad app data (best-effort; chart keys differ across versions)
persistence:
  enabled: true
  storageClass: ${STORAGE_CLASS}

zammad:
  persistence:
    enabled: true
    storageClass: ${STORAGE_CLASS}

# Elasticsearch PVC
elasticsearch:
  enabled: true
  volumeClaimTemplate:
    storageClassName: ${STORAGE_CLASS}
YAML
else
  cat > "${VALUES_FILE}" <<YAML
ingress:
  enabled: true
  ingressClassName: ${INGRESS_CLASS}
  hosts:
    - host: ${ZAMMAD_HOST}
      paths:
        - path: /
          pathType: Prefix
  tls: []

postgresql:
  enabled: false
  host: ${PG_HOST}
  port: ${PG_PORT}
  user: ${ZAMMAD_DB_USER}
  pass: ${ZPASS}
  db: ${ZAMMAD_DB_NAME}

persistence:
  enabled: true
  storageClass: ${STORAGE_CLASS}

zammad:
  persistence:
    enabled: true
    storageClass: ${STORAGE_CLASS}

elasticsearch:
  enabled: true
  volumeClaimTemplate:
    storageClassName: ${STORAGE_CLASS}
YAML
fi

python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1])); print("values.yaml OK")' "${VALUES_FILE}" >/dev/null


# ------------------------------------------------------------------------------
# Pre-clean: if previous releases created embedded Postgres, it must be deleted
# before switching to postgresql.enabled=false (StatefulSet spec is immutable).
# ------------------------------------------------------------------------------
if kubectl -n "${APP_NS}" get sts "${REL}-postgresql" >/dev/null 2>&1; then
  log "[03C][ZAMMAD] Found legacy embedded Postgres StatefulSet; removing to allow external DB mode"
  kubectl -n "${APP_NS}" scale deploy -l "app.kubernetes.io/instance=${REL}" --replicas=0 >/dev/null 2>&1 || true
  kubectl -n "${APP_NS}" delete sts "${REL}-postgresql" --ignore-not-found
  kubectl -n "${APP_NS}" delete svc "${REL}-postgresql" --ignore-not-found
  kubectl -n "${APP_NS}" get pvc -o name | grep -E "${REL}-postgresql|data-${REL}-postgresql" | xargs -r kubectl -n "${APP_NS}" delete || true
  kubectl -n "${APP_NS}" delete pod -l app.kubernetes.io/name=postgresql,app.kubernetes.io/instance="${REL}" --ignore-not-found || true
fi


# ------------------------------------------------------------------------------
# 5) Install/upgrade chart
# ------------------------------------------------------------------------------
log "[03C][ZAMMAD] Install/upgrade: ${REL} in ns/${APP_NS}"
helm upgrade --install "${REL}" "${CHART}" \
  -n "${APP_NS}" \
  --create-namespace \
  -f "${VALUES_FILE}" \
  --wait \
  --timeout 25m

# ------------------------------------------------------------------------------
# 6) TLS fix (repeatable): force existing issuer + spec.ingressClassName + clean solver noise
#    Root cause seen in your logs:
#      - Certificate points to ClusterIssuer letsencrypt-prod (missing) while cluster has letsencrypt-http01
# ------------------------------------------------------------------------------
if [[ "${TLS_MODE:-}" == "per-host-http01" ]]; then
  : "${LETSENCRYPT_ISSUER:=letsencrypt-http01}"
  : "${INGRESS_CLASS:=nginx}"

  # Use the namespace already in use by the script (APP_NS), do not overwrite it.
  ING_NAME="${REL}"               # chart creates ingress with release name
  CERT_NAME="${REL}-tls"          # keep consistent naming; change if you want fixed "zammad-tls"
  TLS_SECRET="${REL}-tls"

  # If you already have fixed names elsewhere, uncomment these:
  # CERT_NAME="zammad-tls"
  # TLS_SECRET="zammad-tls"

  # Derive host from the actual ingress (source of truth)
  ZAMMAD_HOST="$(kubectl -n "${APP_NS}" get ingress "${ING_NAME}" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)"

  log "[03C][ZAMMAD][TLS] enforce issuer=${LETSENCRYPT_ISSUER}, ingressClassName=${INGRESS_CLASS}, host=${ZAMMAD_HOST}"

  # A) Enforce spec.ingressClassName (not deprecated annotation)
  kubectl -n "${APP_NS}" patch ingress "${ING_NAME}" --type=merge \
    -p "{\"spec\":{\"ingressClassName\":\"${INGRESS_CLASS}\"}}" >/dev/null 2>&1 || true

  # B) Remove ingress-shim annotations to prevent cert-manager creating extra solver ingresses
  kubectl -n "${APP_NS}" annotate ingress "${ING_NAME}" \
    kubernetes.io/ingress.class- \
    cert-manager.io/cluster-issuer- \
    cert-manager.io/issuer- \
    cert-manager.io/common-name- \
    acme.cert-manager.io/http01-edit-in-place- \
    >/dev/null 2>&1 || true

  # C) If an existing Certificate references a missing/wrong issuer, delete it + artifacts
  old_issuer="$(kubectl -n "${APP_NS}" get certificate "${CERT_NAME}" -o jsonpath='{.spec.issuerRef.name}' 2>/dev/null || true)"
  if [[ -n "${old_issuer}" && "${old_issuer}" != "${LETSENCRYPT_ISSUER}" ]]; then
    log "[03C][ZAMMAD][TLS] deleting stale certificate/${CERT_NAME} (issuer ${old_issuer} -> ${LETSENCRYPT_ISSUER})"
    kubectl -n "${APP_NS}" delete certificate "${CERT_NAME}" --ignore-not-found >/dev/null 2>&1 || true
    kubectl -n "${APP_NS}" delete certificaterequest -l cert-manager.io/certificate-name="${CERT_NAME}" --ignore-not-found >/dev/null 2>&1 || true
    kubectl -n "${APP_NS}" delete order,challenge --all --ignore-not-found >/dev/null 2>&1 || true
    kubectl -n "${APP_NS}" delete secret "${TLS_SECRET}" --ignore-not-found >/dev/null 2>&1 || true
  fi

  # D) Create/ensure deterministic Certificate (single source of truth)
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${CERT_NAME}
  namespace: ${APP_NS}
spec:
  secretName: ${TLS_SECRET}
  issuerRef:
    kind: ClusterIssuer
    name: ${LETSENCRYPT_ISSUER}
  dnsNames:
    - ${ZAMMAD_HOST}
EOF

  # E) Ensure Ingress TLS block references the secret and the host
  kubectl -n "${APP_NS}" patch ingress "${ING_NAME}" --type=merge \
    -p "{\"spec\":{\"tls\":[{\"hosts\":[\"${ZAMMAD_HOST}\"],\"secretName\":\"${TLS_SECRET}\"}]}}" >/dev/null 2>&1 || true

  # F) Delete solver ingresses in this namespace for this host (repeatable, safe)
  mapfile -t solver_ings < <(
    kubectl -n "${APP_NS}" get ingress -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.rules[*]}{.host}{" "}{end}{"\n"}{end}' \
      | awk -v h="${ZAMMAD_HOST}" -v keep="${ING_NAME}" '$0 ~ h && $1 != keep {print $1}' \
      | sort -u
  )
  if [[ "${#solver_ings[@]}" -gt 0 ]]; then
    for ing in "${solver_ings[@]}"; do
      if [[ "${ing}" == cm-acme-http-solver-* || "${ing}" == *acme* || "${ing}" == *solver* ]]; then
        kubectl -n "${APP_NS}" delete ingress "${ing}" --ignore-not-found >/dev/null 2>&1 || true
      fi
    done
  fi

  # G) Wait for cert Ready + secret exists
  kubectl -n "${APP_NS}" wait --for=condition=Ready "certificate/${CERT_NAME}" --timeout=20m
  kubectl -n "${APP_NS}" get secret "${TLS_SECRET}" >/dev/null
fi


# ------------------------------------------------------------------------------
# 6) Deterministic TLS (Certificate is source of truth; no ingress-shim reliance)
# ------------------------------------------------------------------------------
if [[ "${TLS_MODE}" == "per-host-http01" ]]; then
  log "[03C][ZAMMAD] Ensure cert-manager Certificate -> secret zammad-tls"
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: zammad-tls
  namespace: ${APP_NS}
spec:
  secretName: zammad-tls
  issuerRef:
    kind: ClusterIssuer
    name: ${LETSENCRYPT_ISSUER}
  dnsNames:
    - ${ZAMMAD_HOST}
EOF
  kubectl -n "${APP_NS}" wait --for=condition=Ready certificate/zammad-tls --timeout=15m >/dev/null
  kubectl -n "${APP_NS}" get secret zammad-tls >/dev/null
fi

# ------------------------------------------------------------------------------
# 7) Hard assertions: ingress host + class
# ------------------------------------------------------------------------------
ACTUAL_HOST="$(kubectl -n "${APP_NS}" get ingress "${REL}" -o jsonpath='{.spec.rules[0].host}')"
[[ "${ACTUAL_HOST}" == "${ZAMMAD_HOST}" ]] || fatal "[03C][ZAMMAD] Ingress host mismatch: ${ACTUAL_HOST} != ${ZAMMAD_HOST}"

ACTUAL_CLASS="$(kubectl -n "${APP_NS}" get ingress "${REL}" -o jsonpath='{.spec.ingressClassName}')"
[[ "${ACTUAL_CLASS}" == "${INGRESS_CLASS}" ]] || fatal "[03C][ZAMMAD] Ingress class mismatch: ${ACTUAL_CLASS} != ${INGRESS_CLASS}"

log "[03C][ZAMMAD] Wait for pods readiness"
kubectl -n "${APP_NS}" wait --for=condition=available deploy -l "app.kubernetes.io/instance=${REL}" --timeout=20m 2>/dev/null || true
kubectl -n "${APP_NS}" wait --for=condition=ready pod -l "app.kubernetes.io/instance=${REL}" --timeout=20m

SCHEME="http"
[[ "${TLS_MODE}" == "per-host-http01" ]] && SCHEME="https"
echo "[03C][ZAMMAD] READY: ${SCHEME}://${ZAMMAD_HOST}/"

# ------------------------------------------------------------------------------
# 8) HTTPS verification (hard fail on fake/self-signed certs)
# ------------------------------------------------------------------------------

log "[03C][ZAMMAD] HTTPS verification start"

if [[ "${TLS_MODE}" == "per-host-http01" ]]; then
  require_cmd curl
  require_cmd openssl

  # 8.1 Certificate must be Ready
  kubectl -n "${APP_NS}" wait --for=condition=Ready certificate/zammad-tls --timeout=10m

  # 8.2 TLS secret must exist and be kubernetes.io/tls
  SECRET_TYPE="$(kubectl -n "${APP_NS}" get secret zammad-tls -o jsonpath='{.type}')"
  [[ "${SECRET_TYPE}" == "kubernetes.io/tls" ]] || \
    fatal "zammad-tls secret type invalid: ${SECRET_TYPE}"

  # 8.3 Ingress must reference the TLS secret and correct host
  TLS_REF="$(kubectl -n "${APP_NS}" get ingress zammad -o jsonpath='{.spec.tls[0].secretName}')"
  [[ "${TLS_REF}" == "zammad-tls" ]] || \
    fatal "Ingress TLS secret mismatch: ${TLS_REF}"

  HOST_REF="$(kubectl -n "${APP_NS}" get ingress zammad -o jsonpath='{.spec.rules[0].host}')"
  [[ "${HOST_REF}" == "${ZAMMAD_HOST}" ]] || \
    fatal "Ingress host mismatch: ${HOST_REF}"

  # 8.4 HTTPS handshake must succeed (no fake cert)
  CERT_ISSUER="$(echo | openssl s_client -connect "${ZAMMAD_HOST}:443" -servername "${ZAMMAD_HOST}" 2>/dev/null \
    | openssl x509 -noout -issuer | sed 's/^issuer= //')"

  echo "[03C][ZAMMAD] TLS issuer: ${CERT_ISSUER}"

  echo "${CERT_ISSUER}" | grep -qi "Let's Encrypt" || \
    fatal "Non-Let's Encrypt certificate detected (fake or self-signed)"

  # 8.5 HTTPS endpoint must respond
  curl -fsSI "https://${ZAMMAD_HOST}/" >/dev/null || \
    fatal "HTTPS endpoint not reachable"

  log "[03C][ZAMMAD] HTTPS verification PASSED"
else
  log "[03C][ZAMMAD] TLS_MODE=${TLS_MODE} — HTTPS verification skipped"
fi
