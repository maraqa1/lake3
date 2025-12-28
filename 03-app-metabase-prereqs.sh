#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 03-app-metabase-prereqs.sh — Metabase prerequisites (check + install if missing)
#
# Installs only what Metabase needs:
# - k3s (if missing)
# - default StorageClass (local-path) (if missing / not default)
# - ingress-nginx (if missing)
# - cert-manager (if missing)
# - ClusterIssuer letsencrypt-http01 (if missing)
# - canonical secret open-kpi/openkpi-postgres-secret (if missing) from /root/open-kpi.env
#
# DOES NOT install Postgres. It only verifies Postgres endpoint is reachable.
# ==============================================================================

need(){ command -v "$1" >/dev/null 2>&1 || { echo "FATAL: missing command: $1" >&2; exit 1; }; }
log(){ echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }
fatal(){ echo "FATAL: $*" >&2; exit 1; }
retry(){ local n="$1" s="$2"; shift 2; for i in $(seq 1 "$n"); do "$@" && return 0 || true; sleep "$s"; done; return 1; }

need curl
need kubectl

# ---- load env contract ----
if [[ -f /root/open-kpi.env ]]; then
  set -a
  # shellcheck source=/dev/null
  . /root/open-kpi.env
  set +a
else
  fatal "missing /root/open-kpi.env"
fi

OPENKPI_NS="${NS:-${OPENKPI_NS:-open-kpi}}"
INGRESS_NS="ingress-nginx"
CERT_NS="cert-manager"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
STORAGE_CLASS="${STORAGE_CLASS:-local-path}"
TLS_MODE="${TLS_MODE:-per-host-http01}"
ACME_EMAIL="${ACME_EMAIL:-}"

CERT_ISSUER="${CERT_CLUSTER_ISSUER:-letsencrypt-http01}"
KUBE_DNS_IP="${KUBE_DNS_IP:-10.43.0.10}"

# ------------------------------------------------------------------------------
# 1) k3s present + kube reachable
# ------------------------------------------------------------------------------
if ! command -v k3s >/dev/null 2>&1; then
  log "[PREREQ] Installing k3s"
  curl -sfL https://get.k3s.io | sh - >/dev/null
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
retry 30 2 kubectl version --short >/dev/null 2>&1 || fatal "kubernetes API not ready"

# ------------------------------------------------------------------------------
# 2) default StorageClass exists (local-path) and is default
# ------------------------------------------------------------------------------
ensure_local_path_default_sc() {
  local default_sc
  default_sc="$(kubectl get sc -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' \
    | awk '$2=="true"{print $1; exit}')"

  if kubectl get sc "${STORAGE_CLASS}" >/dev/null 2>&1; then
    :
  else
    log "[PREREQ] Installing local-path-provisioner (StorageClass ${STORAGE_CLASS})"
    # k3s usually installs it; if missing, apply upstream manifest
    kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml >/dev/null
    retry 60 2 kubectl get sc local-path >/dev/null 2>&1 || fatal "local-path StorageClass not created"
  fi

  if [[ "${default_sc:-}" != "${STORAGE_CLASS}" ]]; then
    log "[PREREQ] Setting default StorageClass=${STORAGE_CLASS} (was ${default_sc:-none})"
    # remove default from others (best effort)
    kubectl get sc -o name | while read -r sc; do
      kubectl patch "${sc}" -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null 2>&1 || true
    done
    kubectl patch sc "${STORAGE_CLASS}" -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' >/dev/null
  fi

  kubectl get sc | sed 's/^/[PREREQ] /'
}
ensure_local_path_default_sc

# ------------------------------------------------------------------------------
# 3) ingress-nginx installed and ready
# ------------------------------------------------------------------------------
install_ingress_nginx_if_missing() {
  if kubectl get ns "${INGRESS_NS}" >/dev/null 2>&1; then
    :
  else
    log "[PREREQ] Installing ingress-nginx"
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml >/dev/null
  fi

  retry 120 2 kubectl -n "${INGRESS_NS}" get deploy ingress-nginx-controller >/dev/null 2>&1 \
    || fatal "ingress-nginx controller deployment missing"

  retry 120 2 kubectl -n "${INGRESS_NS}" rollout status deploy/ingress-nginx-controller --timeout=5m >/dev/null 2>&1 \
    || fatal "ingress-nginx controller not ready"
}
install_ingress_nginx_if_missing

# ------------------------------------------------------------------------------
# 4) cert-manager installed and ready
# ------------------------------------------------------------------------------
install_cert_manager_if_missing() {
  if kubectl get ns "${CERT_NS}" >/dev/null 2>&1; then
    :
  else
    log "[PREREQ] Installing cert-manager (CRDs + controller)"
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml >/dev/null
  fi

  retry 120 2 kubectl -n "${CERT_NS}" get deploy cert-manager >/dev/null 2>&1 || fatal "cert-manager deployment missing"
  retry 120 2 kubectl -n "${CERT_NS}" rollout status deploy/cert-manager --timeout=5m >/dev/null 2>&1 || fatal "cert-manager not ready"
  retry 120 2 kubectl -n "${CERT_NS}" rollout status deploy/cert-manager-webhook --timeout=5m >/dev/null 2>&1 || fatal "cert-manager webhook not ready"
}
install_cert_manager_if_missing

# ------------------------------------------------------------------------------
# 5) ClusterIssuer (letsencrypt-http01) exists; create if missing
# ------------------------------------------------------------------------------
ensure_clusterissuer() {
  kubectl get clusterissuer "${CERT_ISSUER}" >/dev/null 2>&1 && return 0

  [[ -n "${ACME_EMAIL}" ]] || fatal "ACME_EMAIL is empty in /root/open-kpi.env (required to create ClusterIssuer)"

  log "[PREREQ] Creating ClusterIssuer ${CERT_ISSUER}"
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${CERT_ISSUER}
spec:
  acme:
    email: ${ACME_EMAIL}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: ${CERT_ISSUER}-account-key
    solvers:
    - http01:
        ingress:
          class: ${INGRESS_CLASS}
YAML

  retry 30 2 kubectl get clusterissuer "${CERT_ISSUER}" >/dev/null 2>&1 || fatal "ClusterIssuer not created"
}
ensure_clusterissuer

# ------------------------------------------------------------------------------
# 6) Ensure open-kpi namespace exists
# ------------------------------------------------------------------------------
kubectl get ns "${OPENKPI_NS}" >/dev/null 2>&1 || kubectl create ns "${OPENKPI_NS}" >/dev/null

# ------------------------------------------------------------------------------
# 7) Ensure canonical Postgres secret exists (from /root/open-kpi.env)
# ------------------------------------------------------------------------------
ensure_openkpi_postgres_secret() {
  if kubectl -n "${OPENKPI_NS}" get secret openkpi-postgres-secret >/dev/null 2>&1; then
    log "[PREREQ] openkpi-postgres-secret exists"
    return 0
  fi

  [[ -n "${OPENKPI_PG_USER:-}" ]] || fatal "OPENKPI_PG_USER missing in /root/open-kpi.env"
  [[ -n "${OPENKPI_PG_PASSWORD:-}" ]] || fatal "OPENKPI_PG_PASSWORD missing in /root/open-kpi.env"

  local host port
  host="${DBT_DB_HOST:-openkpi-postgres.open-kpi.svc.cluster.local}"
  port="${DBT_DB_PORT:-5432}"

  log "[PREREQ] Creating ${OPENKPI_NS}/openkpi-postgres-secret"
  kubectl -n "${OPENKPI_NS}" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: openkpi-postgres-secret
  namespace: ${OPENKPI_NS}
type: Opaque
stringData:
  host: "${host}"
  port: "${port}"
  username: "${OPENKPI_PG_USER}"
  password: "${OPENKPI_PG_PASSWORD}"
YAML
}
ensure_openkpi_postgres_secret

# ------------------------------------------------------------------------------
# 8) Verify Postgres endpoint is reachable (does not install Postgres)
# ------------------------------------------------------------------------------
verify_postgres_reachable() {
  local pg_host pg_port
  pg_host="$(kubectl -n "${OPENKPI_NS}" get secret openkpi-postgres-secret -o jsonpath='{.data.host}' | base64 -d)"
  pg_port="$(kubectl -n "${OPENKPI_NS}" get secret openkpi-postgres-secret -o jsonpath='{.data.port}' | base64 -d)"

  log "[PREREQ] Verifying Postgres TCP reachable: ${pg_host}:${pg_port}"
  kubectl -n "${OPENKPI_NS}" run pg-tcp-test --rm -i --restart=Never --image=alpine:3.20 -- \
    sh -lc "apk add --no-cache busybox-extras >/dev/null 2>&1; nc -z -w 3 '${pg_host}' '${pg_port}'" \
    >/dev/null 2>&1 || fatal "Postgres not reachable at ${pg_host}:${pg_port}. Install/repair 02-data-plane.sh first."
}
verify_postgres_reachable

log "[PREREQ] OK: Metabase prerequisites satisfied"
echo "NEXT: cd ~/OpenKPI && ./03-app-metabase.sh"
