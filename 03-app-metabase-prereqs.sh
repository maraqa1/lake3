#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 03-app-metabase-prereqs.sh — Metabase prerequisites (self-sufficient + repeatable)
#
# Guarantees, idempotently:
#  - kubeconfig detection + Kubernetes API reachable
#  - default StorageClass exists + is default (local-path by default)
#  - ingress-nginx installed + ready
#  - cert-manager installed + ready (pinned version)
#  - ClusterIssuer exists (letsencrypt-http01 by default)
#  - Namespace exists (open-kpi by default)
#  - Canonical Postgres secret exists (openkpi-postgres-secret) with:
#       host, port, username, password, db
#    derived from /root/open-kpi.env (authoritative), not from any prior secret shape
#  - Verifies Postgres TCP reachable using a labeled diagnostic pod, with logs on failure
#
# NOTES:
#  - Does NOT install Postgres. Only checks reachability.
#  - Avoids kubectl version --short (not supported by some kubectl builds).
# ==============================================================================

need(){ command -v "$1" >/dev/null 2>&1 || { echo "FATAL: missing command: $1" >&2; exit 1; }; }
ts(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
log(){ echo "$(ts) $*"; }
fatal(){ echo "$(ts) FATAL: $*" >&2; exit 1; }
retry(){ local n="$1" s="$2"; shift 2; for _ in $(seq 1 "$n"); do "$@" && return 0 || true; sleep "$s"; done; return 1; }

need base64
need curl
need kubectl

STEP_START=0
step(){ STEP_START="$(date +%s)"; log "==> $*"; }
step_ok(){ local end; end="$(date +%s)"; log "<== OK ($((end-STEP_START))s)"; }

kube_ok() {
  kubectl version --client >/dev/null 2>&1 || return 1
  kubectl get --raw=/readyz >/dev/null 2>&1 && return 0
  kubectl get nodes >/dev/null 2>&1 && return 0
  return 1
}

dump_kube_context() {
  log "---- DIAG: kubectl context ----"
  kubectl config current-context 2>/dev/null || true
  log "---- DIAG: nodes ----"
  kubectl get nodes -o wide || true
  log "---- DIAG: namespaces ----"
  kubectl get ns || true
}

dump_rollout_diag() {
  local ns="$1" name="$2"
  log "---- DIAG: rollout status ${ns}/${name} ----"
  kubectl -n "$ns" rollout status "deploy/${name}" --timeout=10s || true
  log "---- DIAG: deploy describe ${ns}/${name} ----"
  kubectl -n "$ns" describe "deploy/${name}" | sed -n '1,240p' || true
  log "---- DIAG: pods ${ns} (last 40) ----"
  kubectl -n "$ns" get pods -o wide --sort-by=.metadata.creationTimestamp | tail -n 40 || true
  log "---- DIAG: events ${ns} (last 120) ----"
  kubectl -n "$ns" get events --sort-by=.lastTimestamp | tail -n 120 || true
}

on_err() {
  local rc="$?"
  log "ERROR (exit code ${rc}). Dumping diagnostics."
  dump_kube_context
  kubectl get sc -o wide || true
  kubectl get ingress -A || true
  kubectl get certificate -A || true
  kubectl get clusterissuer -A || true
  kubectl get pods -A | awk 'NR==1 || $4!="Running" && $4!="Completed" {print}' || true
  exit "$rc"
}
trap on_err ERR

# ------------------------------------------------------------------------------
# 0) Load env contract
# ------------------------------------------------------------------------------
step "Load /root/open-kpi.env"
if [[ -f /root/open-kpi.env ]]; then
  set -a
  # shellcheck source=/dev/null
  . /root/open-kpi.env
  set +a
else
  fatal "missing /root/open-kpi.env"
fi
step_ok

# Contract defaults
OPENKPI_NS="${NS:-${OPENKPI_NS:-open-kpi}}"
INGRESS_NS="${INGRESS_NS:-ingress-nginx}"
CERT_NS="${CERT_NS:-cert-manager}"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
STORAGE_CLASS="${STORAGE_CLASS:-local-path}"
ACME_EMAIL="${ACME_EMAIL:-}"
CERT_ISSUER="${CERT_CLUSTER_ISSUER:-letsencrypt-http01}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.15.3}"

# Authoritative Postgres endpoint and creds (from env)
# Prefer OPENKPI_* if present; otherwise fall back to DBT_* where appropriate.
PG_HOST="${OPENKPI_PG_HOST:-${DBT_DB_HOST:-openkpi-postgres.open-kpi.svc.cluster.local}}"
PG_PORT="${OPENKPI_PG_PORT:-${DBT_DB_PORT:-5432}}"
PG_DB="${OPENKPI_PG_DB:-${DBT_DB_NAME:-openkpi}}"
PG_USER="${OPENKPI_PG_USER:-}"
PG_PASSWORD="${OPENKPI_PG_PASSWORD:-}"

[[ -n "${PG_HOST}" ]] || fatal "Postgres host missing: set OPENKPI_PG_HOST or DBT_DB_HOST in /root/open-kpi.env"
[[ -n "${PG_PORT}" ]] || fatal "Postgres port missing: set OPENKPI_PG_PORT or DBT_DB_PORT in /root/open-kpi.env"
[[ -n "${PG_DB}"   ]] || fatal "Postgres db missing: set OPENKPI_PG_DB or DBT_DB_NAME in /root/open-kpi.env"
[[ -n "${PG_USER}" ]] || fatal "Postgres user missing: set OPENKPI_PG_USER in /root/open-kpi.env"
[[ -n "${PG_PASSWORD}" ]] || fatal "Postgres password missing: set OPENKPI_PG_PASSWORD in /root/open-kpi.env"

# ------------------------------------------------------------------------------
# 1) Kubernetes reachable (robust kubeconfig detection)
# ------------------------------------------------------------------------------
step "Detect kubeconfig + verify Kubernetes API reachable"

detect_kubeconfig() {
  local candidates=()

  if [[ -n "${KUBECONFIG:-}" ]]; then candidates+=("${KUBECONFIG}"); fi
  candidates+=(
    "/etc/rancher/k3s/k3s.yaml"
    "/root/.kube/config"
    "${HOME}/.kube/config"
  )

  for f in "${candidates[@]}"; do
    [[ -f "$f" ]] || continue
    export KUBECONFIG="$f"
    if kube_ok; then
      echo "$f"
      return 0
    fi
  done

  if command -v k3s >/dev/null 2>&1; then
    local tmp="/tmp/k3s.kubeconfig.$(date +%s).yaml"
    k3s kubectl config view --raw > "${tmp}" 2>/dev/null || true
    if [[ -s "${tmp}" ]]; then
      export KUBECONFIG="${tmp}"
      if kube_ok; then
        echo "${tmp}"
        return 0
      fi
    fi
  fi

  return 1
}

KCFG="$(detect_kubeconfig)" || {
  log "Kubeconfig detection failed. Diagnostics:"
  log " - env KUBECONFIG=${KUBECONFIG:-<empty>}"
  log " - tried: /etc/rancher/k3s/k3s.yaml /root/.kube/config ${HOME}/.kube/config"
  log " - kubectl client:"
  kubectl version --client || true
  log " - API /readyz:"
  kubectl get --raw=/readyz || true
  log " - nodes:"
  kubectl get nodes -o wide || true
  fatal "Kubernetes cluster exists but is not reachable from this shell. Fix kubeconfig / permissions, then rerun."
}

log "[PREREQ] Using KUBECONFIG=${KCFG}"
kubectl get nodes -o wide | sed 's/^/[PREREQ] /'
step_ok

# ------------------------------------------------------------------------------
# 2) default StorageClass exists and is default
# ------------------------------------------------------------------------------
ensure_local_path_default_sc() {
  local default_sc
  default_sc="$(kubectl get sc -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' \
    | awk '$2=="true"{print $1; exit}')"

  log "[PREREQ] Current default StorageClass: ${default_sc:-none}"

  if kubectl get sc "${STORAGE_CLASS}" >/dev/null 2>&1; then
    log "[PREREQ] StorageClass exists: ${STORAGE_CLASS}"
  else
    log "[PREREQ] Installing local-path-provisioner (StorageClass ${STORAGE_CLASS})"
    kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml >/dev/null
    retry 60 2 kubectl get sc "${STORAGE_CLASS}" >/dev/null 2>&1 || fatal "${STORAGE_CLASS} StorageClass not created"
  fi

  if [[ "${default_sc:-}" != "${STORAGE_CLASS}" ]]; then
    log "[PREREQ] Setting default StorageClass=${STORAGE_CLASS} (was ${default_sc:-none})"
    if [[ -n "${default_sc:-}" ]]; then
      kubectl patch sc "${default_sc}" -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null 2>&1 || true
    fi
    kubectl patch sc "${STORAGE_CLASS}" -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' >/dev/null
  fi

  kubectl get sc | sed 's/^/[PREREQ] /'
}

step "Ensure default StorageClass=${STORAGE_CLASS}"
ensure_local_path_default_sc
step_ok

# ------------------------------------------------------------------------------
# 3) ingress-nginx installed and ready
# ------------------------------------------------------------------------------
install_ingress_nginx_if_missing() {
  if kubectl get ns "${INGRESS_NS}" >/dev/null 2>&1; then
    log "[PREREQ] Namespace exists: ${INGRESS_NS}"
  else
    log "[PREREQ] Installing ingress-nginx"
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml >/dev/null
  fi

  retry 120 2 kubectl -n "${INGRESS_NS}" get deploy ingress-nginx-controller >/dev/null 2>&1 \
    || fatal "ingress-nginx controller deployment missing"

  log "[PREREQ] Waiting for ingress-nginx-controller rollout"
  if ! kubectl -n "${INGRESS_NS}" rollout status deploy/ingress-nginx-controller --timeout=5m; then
    dump_rollout_diag "${INGRESS_NS}" "ingress-nginx-controller"
    fatal "ingress-nginx controller not ready"
  fi

  kubectl -n "${INGRESS_NS}" get pods -o wide | sed 's/^/[PREREQ] /'
}

step "Ensure ingress-nginx installed + ready"
install_ingress_nginx_if_missing
step_ok

# ------------------------------------------------------------------------------
# 4) cert-manager installed and ready (pinned)
# ------------------------------------------------------------------------------
install_cert_manager_if_missing() {
  if kubectl get ns "${CERT_NS}" >/dev/null 2>&1; then
    log "[PREREQ] Namespace exists: ${CERT_NS}"
  else
    log "[PREREQ] Installing cert-manager ${CERT_MANAGER_VERSION}"
    kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" >/dev/null
  fi

  retry 180 2 kubectl -n "${CERT_NS}" get deploy cert-manager >/dev/null 2>&1 || fatal "cert-manager deployment missing"

  for d in cert-manager cert-manager-webhook cert-manager-cainjector; do
    log "[PREREQ] Waiting rollout: ${CERT_NS}/${d}"
    if ! kubectl -n "${CERT_NS}" rollout status "deploy/${d}" --timeout=5m; then
      dump_rollout_diag "${CERT_NS}" "${d}"
      fatal "cert-manager component not ready: ${d}"
    fi
  done

  kubectl -n "${CERT_NS}" get pods -o wide | sed 's/^/[PREREQ] /'
}

step "Ensure cert-manager installed + ready"
install_cert_manager_if_missing
step_ok

# ------------------------------------------------------------------------------
# 5) ClusterIssuer exists; create if missing
# ------------------------------------------------------------------------------
ensure_clusterissuer() {
  if kubectl get clusterissuer "${CERT_ISSUER}" >/dev/null 2>&1; then
    log "[PREREQ] ClusterIssuer exists: ${CERT_ISSUER}"
    kubectl get clusterissuer "${CERT_ISSUER}" -o wide || true
    return 0
  fi

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
  kubectl get clusterissuer "${CERT_ISSUER}" -o wide || true
}

step "Ensure ClusterIssuer=${CERT_ISSUER}"
ensure_clusterissuer
step_ok

# ------------------------------------------------------------------------------
# 6) Ensure open-kpi namespace exists
# ------------------------------------------------------------------------------
step "Ensure namespace exists: ${OPENKPI_NS}"
kubectl get ns "${OPENKPI_NS}" >/dev/null 2>&1 || kubectl create ns "${OPENKPI_NS}" >/dev/null
kubectl get ns "${OPENKPI_NS}" -o wide | sed 's/^/[PREREQ] /'
step_ok

# ------------------------------------------------------------------------------
# 7) Ensure canonical Postgres secret exists with expected keys (host/port/username/password/db)
# ------------------------------------------------------------------------------
ensure_openkpi_postgres_secret() {
  local name="openkpi-postgres-secret"

  # Always enforce canonical shape (idempotent apply). This makes the prereq self-sufficient.
  log "[PREREQ] Applying canonical secret: ${OPENKPI_NS}/${name} (host=${PG_HOST} port=${PG_PORT} db=${PG_DB} user=${PG_USER})"
  kubectl -n "${OPENKPI_NS}" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ${name}
  namespace: ${OPENKPI_NS}
type: Opaque
stringData:
  host: "${PG_HOST}"
  port: "${PG_PORT}"
  username: "${PG_USER}"
  password: "${PG_PASSWORD}"
  db: "${PG_DB}"
YAML

  # Show a safe summary (no secrets printed)
  log "[PREREQ] Secret present: ${OPENKPI_NS}/${name}"
  kubectl -n "${OPENKPI_NS}" get secret "${name}" -o jsonpath='{.metadata.name}{" keys="}{range $k,$v := .data}{$k}{" "}{end}{"\n"}' \
    | sed 's/^/[PREREQ] /' || true
}

step "Ensure Postgres secret exists (canonical shape)"
ensure_openkpi_postgres_secret
step_ok

# ------------------------------------------------------------------------------
# 8) Verify Postgres endpoint reachable (visible logs)
# ------------------------------------------------------------------------------
verify_postgres_reachable() {
  local pod="pg-tcp-test"

  log "[PREREQ] Verifying Postgres TCP reachable: ${PG_HOST}:${PG_PORT}"

  kubectl -n "${OPENKPI_NS}" delete pod "${pod}" --ignore-not-found >/dev/null 2>&1 || true

  kubectl -n "${OPENKPI_NS}" run "${pod}" --restart=Never --image=alpine:3.20 \
    --labels="app=openkpi-diag,component=metabase-prereqs" \
    --command -- sh -lc "
      set -e
      echo 'DNS:'; cat /etc/resolv.conf || true
      echo 'Resolve host:'; nslookup '${PG_HOST}' || true
      echo 'Install nc:'; apk add --no-cache busybox-extras >/dev/null
      echo 'TCP check:'; nc -vz -w 3 '${PG_HOST}' '${PG_PORT}'
      echo 'OK'
    " >/dev/null 2>&1 || {
      log "[PREREQ] TCP test failed. Pod logs + describe follow."
      kubectl -n "${OPENKPI_NS}" get pod "${pod}" -o wide || true
      kubectl -n "${OPENKPI_NS}" logs pod/"${pod}" --tail=300 || true
      kubectl -n "${OPENKPI_NS}" describe pod/"${pod}" | sed -n '1,260p' || true
      kubectl -n "${OPENKPI_NS}" delete pod "${pod}" --ignore-not-found >/dev/null 2>&1 || true
      fatal "Postgres not reachable at ${PG_HOST}:${PG_PORT}. Fix 02-data-plane.sh / CoreDNS / service endpoints."
    }

  kubectl -n "${OPENKPI_NS}" logs pod/"${pod}" --tail=200 || true
  kubectl -n "${OPENKPI_NS}" delete pod "${pod}" --ignore-not-found >/dev/null 2>&1 || true
}

step "Verify Postgres TCP reachable"
verify_postgres_reachable
step_ok

log "[PREREQ] OK: Metabase prerequisites satisfied"
echo "NEXT: cd ~/OpenKPI && ./03-app-metabase.sh"

