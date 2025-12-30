##!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 01-core.sh — Core Platform Foundation (k3s + kubeconfig + kubectl + helm + ingress + TLS)
#
# Production-grade objectives:
# - Deterministic: always targets THIS VM’s k3s cluster.
# - Idempotent: safe to rerun.
# - Hard gates: fails fast if core prereqs are not satisfied.
# - TLS enforced when TLS_MODE=per-host-http01:
#   * cert-manager CRDs installed explicitly (no reliance on Helm CRD hooks)
#   * cert-manager controllers installed and ready
#   * ClusterIssuer exists and Ready
#
# Key hardening fixes vs current version:
# - Sanitizes env values (strip inline comments + trim) to prevent silent skips.
# - Never uses `kubectl api-resources` as a health gate (aggregated discovery can fail).
# - Enforces ingress-nginx external address (HTTP-01 will fail without it).
# - Enforces KUBECONFIG=/etc/rancher/k3s/k3s.yaml to avoid “wrong cluster” drift.
# - Adds deterministic diagnostics on failures.
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/00-env.sh"
# shellcheck source=/dev/null
. "${HERE}/00-lib.sh"

log "[01][CORE] start"

need() { command -v "$1" >/dev/null 2>&1 || fatal "Missing required command: $1"; }

# ------------------------------------------------------------------------------
# Env sanitization (prevents TLS_MODE skip due to inline comments/whitespace)
# ------------------------------------------------------------------------------
_strip() { printf "%s" "${1%%#*}" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'; }
TLS_MODE="$(_strip "${TLS_MODE:-}")"
INGRESS_CLASS="$(_strip "${INGRESS_CLASS:-}")"
STORAGE_CLASS="$(_strip "${STORAGE_CLASS:-}")"
ACME_EMAIL="$(_strip "${ACME_EMAIL:-}")"
CERT_CLUSTER_ISSUER="$(_strip "${CERT_CLUSTER_ISSUER:-}")"
CLUSTER_ISSUER="$(_strip "${CLUSTER_ISSUER:-}")"
OPENKPI_NS="$(_strip "${OPENKPI_NS:-open-kpi}")"
ACME_EMAIL="$(_strip "${ACME_EMAIL:-}")"

# Canonical issuer policy (CERT_CLUSTER_ISSUER canonical)
if [[ -z "${CERT_CLUSTER_ISSUER}" && -n "${CLUSTER_ISSUER}" ]]; then CERT_CLUSTER_ISSUER="${CLUSTER_ISSUER}"; fi
if [[ -z "${CLUSTER_ISSUER}" && -n "${CERT_CLUSTER_ISSUER}" ]]; then CLUSTER_ISSUER="${CERT_CLUSTER_ISSUER}"; fi

# ------------------------------------------------------------------------------
# k3s
# ------------------------------------------------------------------------------
ensure_k3s_running() {
  if command -v k3s >/dev/null 2>&1 && systemctl is-active --quiet k3s; then
    log "[01][CORE] k3s already installed and active"
  else
    if systemctl list-unit-files 2>/dev/null | grep -q '^k3s\.service'; then
      log "[01][CORE] k3s unit exists; starting"
      systemctl enable --now k3s >/dev/null 2>&1 || true
    else
      log "[01][CORE] installing k3s (server)"
      export INSTALL_K3S_EXEC="${INSTALL_K3S_EXEC:-server --write-kubeconfig-mode 644}"
      export K3S_KUBECONFIG_MODE="${K3S_KUBECONFIG_MODE:-644}"
      curl -sfL https://get.k3s.io | sh - >/dev/null
      systemctl enable --now k3s >/dev/null 2>&1 || true
    fi
  fi

  retry 40 2 systemctl is-active --quiet k3s || fatal "k3s service not active"
  retry 60 2 test -f /etc/rancher/k3s/k3s.yaml || fatal "k3s kubeconfig not created"
}

ensure_root_kubeconfig() {
  local src="/etc/rancher/k3s/k3s.yaml"
  local dst="/root/.kube/config"
  [[ -f "${src}" ]] || fatal "k3s kubeconfig not found at ${src}"
  install -d -m 700 /root/.kube
  if [[ ! -f "${dst}" ]] || ! cmp -s "${src}" "${dst}"; then
    cp -f "${src}" "${dst}"
    chmod 600 "${dst}"
  fi

  # Hard pin: avoid drift to any other cluster context.
  export KUBECONFIG="${src}"
}

ensure_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then return 0; fi
  log "[01][CORE] installing kubectl"
  local ver
  ver="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${ver}/bin/linux/amd64/kubectl"
  chmod +x /usr/local/bin/kubectl
  kubectl version --client >/dev/null
}

ensure_helm() {
  if command -v helm >/dev/null 2>&1; then return 0; fi
  log "[01][CORE] installing helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null
  helm version >/dev/null
}

wait_kube_api() {
  log "[01][CORE] wait for apiserver /readyz"
  if retry 40 3 kubectl get --raw=/readyz >/dev/null 2>&1; then return 0; fi

  warn "[01][CORE] apiserver not reachable; restarting k3s once"
  systemctl restart k3s >/dev/null 2>&1 || true
  retry 20 3 systemctl is-active --quiet k3s || fatal "k3s failed to restart"

  retry 60 3 kubectl get --raw=/readyz >/dev/null 2>&1 || {
    warn "[01][CORE] diagnostics (k3s + kubectl)"
    systemctl --no-pager -l status k3s | sed -n '1,220p' || true
    journalctl -u k3s --no-pager -n 250 || true
    kubectl version --client 2>&1 | sed -n '1,80p' || true
    kubectl config view --minify 2>/dev/null | sed -n '1,160p' || true
    ss -lntp | egrep ':(6443|80|443)\b' || true
    fatal "k3s API not reachable"
  }
}

# ------------------------------------------------------------------------------
# StorageClass default
# ------------------------------------------------------------------------------
ensure_default_storageclass() {
  log "[01][CORE] ensure default StorageClass (want: ${STORAGE_CLASS:-local-path})"

  local default_sc
  default_sc="$(kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1 || true)"
  if [[ -n "${default_sc}" ]]; then
    log "[01][CORE] default StorageClass exists: ${default_sc}"
    return 0
  fi

  local sc="${STORAGE_CLASS:-local-path}"
  if kubectl get sc "${sc}" >/dev/null 2>&1; then
    log "[01][CORE] patching ${sc} as default"
    kubectl patch sc "${sc}" -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' >/dev/null
    return 0
  fi

  if [[ "${sc}" == "local-path" ]]; then
    log "[01][CORE] creating StorageClass local-path and setting as default"
    cat <<'YAML' | kubectl apply -f - >/dev/null
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
YAML
    return 0
  fi

  fatal "No default StorageClass found and STORAGE_CLASS=${sc} does not exist"
}

# ------------------------------------------------------------------------------
# Namespaces needed by platform modules
# ------------------------------------------------------------------------------
ensure_platform_namespaces() {
  log "[01][CORE] ensure namespaces"
  ensure_ns "${OPENKPI_NS}"
  ensure_ns airbyte
  ensure_ns n8n
  ensure_ns tickets
  ensure_ns platform
  ensure_ns transform
}

# ------------------------------------------------------------------------------
# Ingress Controller (nginx)
# ------------------------------------------------------------------------------
_wait_ns_gone_if_terminating() {
  local ns="$1"
  local phase
  phase="$(kubectl get ns "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${phase}" == "Terminating" ]]; then
    warn "[01][CORE] namespace ${ns} is Terminating; waiting to fully delete"
    while kubectl get ns "${ns}" >/dev/null 2>&1; do sleep 3; done
    log "[01][CORE] namespace ${ns} is gone"
  fi
}

_ingress_nginx_rbac_fix_apply() {
  kubectl apply -f - <<'YAML' >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: openkpi-ingress-nginx-fix
rules:
- apiGroups: [""]
  resources: ["services","endpoints","pods","nodes","namespaces","configmaps","secrets"]
  verbs: ["get","list","watch"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create","patch","update"]
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses","ingresses/status","ingressclasses"]
  verbs: ["get","list","watch","update","patch"]
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["get","list","watch","create","update","patch"]
- apiGroups: ["discovery.k8s.io"]
  resources: ["endpointslices"]
  verbs: ["get","list","watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: openkpi-ingress-nginx-fix
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: openkpi-ingress-nginx-fix
subjects:
- kind: ServiceAccount
  name: ingress-nginx
  namespace: ingress-nginx
YAML
}

_ingress_nginx_rbac_broken() {
  local pod
  pod="$(kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${pod}" ]] || return 1
  kubectl -n ingress-nginx logs "${pod}" --tail=250 2>/dev/null \
    | egrep -qi 'forbidden.*(services|leases)|cannot (get|update).*leases|cannot get resource "services"' \
    && return 0
  return 1
}

_wait_ingress_external_address() {
  local addr=""
  for i in {1..60}; do
    addr="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    [[ -n "${addr}" ]] && break
    sleep 2
  done
  [[ -n "${addr}" ]] || fatal "ingress-nginx-controller has no external address; HTTP-01 will fail"
  log "[01][CORE] ingress external address: ${addr}"
}

ensure_ingress_nginx() {
  log "[01][CORE] nginx selected: disable k3s traefik HelmCharts (if present)"
  kubectl -n kube-system delete helmchart traefik traefik-crd --ignore-not-found >/dev/null 2>&1 || true

  _wait_ns_gone_if_terminating ingress-nginx
  ensure_ns ingress-nginx

  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true

  log "[01][CORE] install/upgrade ingress-nginx (atomic)"
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    -n ingress-nginx \
    --version 4.14.1 \
    --history-max 5 \
    --atomic \
    --cleanup-on-fail \
    --wait \
    --timeout 20m \
    --set controller.ingressClassResource.name=nginx \
    --set controller.ingressClassResource.controllerValue="k8s.io/ingress-nginx" \
    --set controller.ingressClass=nginx \
    --set controller.watchIngressWithoutClass=false \
    --set controller.service.type=LoadBalancer \
    --set controller.publishService.enabled=true \
    --set controller.admissionWebhooks.enabled=true

  kubectl_wait_deploy ingress-nginx ingress-nginx-controller 1200s
  kubectl get ingressclass nginx >/dev/null 2>&1 || true

  if _ingress_nginx_rbac_broken; then
    warn "[01][CORE] ingress-nginx RBAC broken; applying fix + restart"
    _ingress_nginx_rbac_fix_apply
    kubectl -n ingress-nginx rollout restart deploy/ingress-nginx-controller >/dev/null || true
    kubectl_wait_deploy ingress-nginx ingress-nginx-controller 600s
  fi

  log "[01][CORE] ingress service status"
  kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide

  _wait_ingress_external_address
}

ensure_ingress() {
  case "${INGRESS_CLASS:-nginx}" in
    nginx) ensure_ingress_nginx ;;
    traefik)
      log "[01][CORE] validate traefik (k3s default)"
      ensure_ns kube-system
      kubectl -n kube-system get deploy traefik >/dev/null 2>&1 || fatal "INGRESS_CLASS=traefik but kube-system/traefik not found"
      kubectl_wait_deploy kube-system traefik 600s
      kubectl get ingressclass traefik >/dev/null 2>&1 || true
      ;;
    *) fatal "Unsupported INGRESS_CLASS=${INGRESS_CLASS} (expected traefik|nginx)" ;;
  esac
}

# ------------------------------------------------------------------------------
# TLS (cert-manager + ClusterIssuer) — production hardened
# ------------------------------------------------------------------------------
ensure_tls() {
  if [[ "${TLS_MODE:-off}" != "per-host-http01" ]]; then
    log "[01][CORE] TLS_MODE=${TLS_MODE:-off}; skipping cert-manager/issuer"
    return 0
  fi

  [[ -n "${ACME_EMAIL}" ]] || fatal "TLS_MODE=per-host-http01 requires ACME_EMAIL"
  [[ -n "${CERT_CLUSTER_ISSUER}" ]] || fatal "TLS_MODE=per-host-http01 requires CERT_CLUSTER_ISSUER"
  [[ "${INGRESS_CLASS:-nginx}" == "nginx" || "${INGRESS_CLASS}" == "traefik" ]] || fatal "TLS requires valid INGRESS_CLASS"

  ensure_ns cert-manager

  log "[01][CORE] ensure cert-manager CRDs (hard requirement)"
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.3/cert-manager.crds.yaml >/dev/null

  log "[01][CORE] verify CRD clusterissuers.cert-manager.io is registered"
  retry 40 2 kubectl get crd clusterissuers.cert-manager.io >/dev/null 2>&1 \
    || fatal "cert-manager CRDs not registered (clusterissuers.cert-manager.io missing)"

  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true

  log "[01][CORE] install/upgrade cert-manager (chart)"
  helm upgrade --install cert-manager jetstack/cert-manager \
    -n cert-manager \
    --version v1.16.3 \
    --set installCRDs=false \
    --atomic \
    --cleanup-on-fail \
    --wait \
    --timeout 20m

  kubectl_wait_deploy cert-manager cert-manager 1200s
  kubectl_wait_deploy cert-manager cert-manager-webhook 1200s
  kubectl_wait_deploy cert-manager cert-manager-cainjector 1200s

  log "[01][CORE] ensure ClusterIssuer (${CERT_CLUSTER_ISSUER})"
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${CERT_CLUSTER_ISSUER}
spec:
  acme:
    email: ${ACME_EMAIL}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: ${CERT_CLUSTER_ISSUER}-account-key
    solvers:
    - http01:
        ingress:
          class: ${INGRESS_CLASS}
YAML

  retry 40 2 kubectl get clusterissuer "${CERT_CLUSTER_ISSUER}" >/dev/null 2>&1 \
    || fatal "ClusterIssuer ${CERT_CLUSTER_ISSUER} not created"

  # Readiness check (do not assume)
  retry 60 2 kubectl get clusterissuer "${CERT_CLUSTER_ISSUER}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q '^True$' \
    || fatal "ClusterIssuer ${CERT_CLUSTER_ISSUER} not Ready=True"
}

# ------------------------------------------------------------------------------
# Tests
# ------------------------------------------------------------------------------
run_tests() {
  log "[01][CORE][TEST] begin"

  log "[01][CORE][TEST][T01] kubectl connectivity"
  kubectl version --client >/dev/null 2>&1 || fatal "[T01] kubectl client not working"
  kubectl get --raw=/readyz >/dev/null 2>&1 || fatal "[T01] apiserver /readyz failed"

  log "[01][CORE][TEST][T02] node Ready"
  kubectl get nodes -o wide
  kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -qE ' True$' \
    || fatal "[T02] no Ready node detected"

  log "[01][CORE][TEST][T03] namespaces exist"
  for ns in "${OPENKPI_NS}" airbyte n8n tickets platform transform; do
    kubectl get ns "${ns}" >/dev/null 2>&1 || fatal "[T03] missing namespace: ${ns}"
  done

  log "[01][CORE][TEST][T04] default StorageClass exists"
  local dsc
  dsc="$(kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1 || true)"
  [[ -n "${dsc}" ]] || fatal "[T04] default StorageClass is missing"
  log "[01][CORE][TEST] default StorageClass = ${dsc}"

  log "[01][CORE][TEST][T05] ingress controller ready (${INGRESS_CLASS})"
  if [[ "${INGRESS_CLASS}" == "nginx" ]]; then
    kubectl -n ingress-nginx get deploy ingress-nginx-controller >/dev/null 2>&1 || fatal "[T05] ingress-nginx-controller missing"
    kubectl_wait_deploy ingress-nginx ingress-nginx-controller 1200s || fatal "[T05] ingress-nginx not ready"
    kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide
    # external address gate
    local addr=""
    addr="$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    [[ -n "${addr}" ]] || fatal "[T05] ingress-nginx has no external address"
  fi

  log "[01][CORE][TEST][T06] TLS stack checks (TLS_MODE=${TLS_MODE:-off})"
  if [[ "${TLS_MODE:-off}" == "per-host-http01" ]]; then
    kubectl get crd clusterissuers.cert-manager.io >/dev/null 2>&1 || fatal "[T06] missing cert-manager CRDs"
    kubectl -n cert-manager get deploy cert-manager cert-manager-webhook cert-manager-cainjector >/dev/null 2>&1 || fatal "[T06] cert-manager deployments missing"
    kubectl get clusterissuer "${CERT_CLUSTER_ISSUER}" >/dev/null 2>&1 || fatal "[T06] ClusterIssuer missing"
    local ready
    ready="$(kubectl get clusterissuer "${CERT_CLUSTER_ISSUER}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [[ "${ready}" == "True" ]] || fatal "[T06] ClusterIssuer not Ready=True"
  fi

  log "[01][CORE][TEST] PASS"
}

# ------------------------------------------------------------------------------
# Run
# ------------------------------------------------------------------------------
need curl
need sed

ensure_k3s_running
ensure_root_kubeconfig
ensure_kubectl
ensure_helm

need kubectl
need helm

wait_kube_api
retry 10 2 kubectl get nodes >/dev/null 2>&1 || fatal "kubectl cannot reach THIS VM k3s cluster"

ensure_platform_namespaces
ensure_default_storageclass
ensure_ingress
ensure_tls

run_tests

log "[01][CORE] done"
