#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 01-core.sh — Core Platform Foundation (k3s + kubeconfig + kubectl + helm + ingress + TLS)
#
# Contract:
# - Sources ./00-env.sh (single source of truth backed by /root/open-kpi.env)
# - Uses ./00-lib.sh for retry/logging helpers
#
# Production rules:
# - Idempotent: safe to rerun on same VM.
# - Fresh-install safe: survives VM rebuild because state is in Git + /root/open-kpi.env.
# - No destructive churn unless explicitly required (ingress-nginx terminating trap).
#
# Key fixes included:
# - Ingress-NGINX Helm install uses --atomic + --cleanup-on-fail + long timeout.
# - If ingress-nginx namespace is Terminating, script waits until fully gone before re-install.
# - RBAC self-heal: if controller logs show forbidden on services/leases, apply a repeatable
#   ClusterRole+Binding that grants the SA permissions it must have, then restart controller.
# - kubectl connectivity tests are portable (no deprecated --short).
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/00-env.sh"
# shellcheck source=/dev/null
. "${HERE}/00-lib.sh"

log "[01][CORE] start"

need() { command -v "$1" >/dev/null 2>&1 || fatal "Missing required command: $1"; }

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
  export KUBECONFIG="${dst}"
}

ensure_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    return 0
  fi
  log "[01][CORE] installing kubectl"
  local ver
  ver="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${ver}/bin/linux/amd64/kubectl"
  chmod +x /usr/local/bin/kubectl
  kubectl version --client >/dev/null
}

ensure_helm() {
  if command -v helm >/dev/null 2>&1; then
    return 0
  fi
  log "[01][CORE] installing helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null
  helm version >/dev/null
}

wait_kube_api() {
  log "[01][CORE] wait for apiserver /readyz"
  if retry 40 3 kubectl get --raw=/readyz >/dev/null 2>&1; then
    return 0
  fi

  warn "[01][CORE] apiserver not reachable; restarting k3s once"
  systemctl restart k3s >/dev/null 2>&1 || true
  retry 20 3 systemctl is-active --quiet k3s || fatal "k3s failed to restart"

  retry 60 3 kubectl get --raw=/readyz >/dev/null 2>&1 || {
    warn "[01][CORE] diagnostics (k3s + kubectl)"
    systemctl --no-pager -l status k3s | sed -n '1,220p' || true
    journalctl -u k3s --no-pager -n 250 || true
    kubectl version --client 2>&1 | sed -n '1,60p' || true
    kubectl config view --minify 2>/dev/null | sed -n '1,140p' || true
    ss -lntp | egrep ':(6443|80|443)\b' || true
    fatal "k3s API not reachable"
  }
}

# ------------------------------------------------------------------------------
# StorageClass default
# ------------------------------------------------------------------------------

ensure_default_storageclass() {
  log "[01][CORE] ensure default StorageClass (want: ${STORAGE_CLASS})"

  local default_sc
  default_sc="$(kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1 || true)"
  if [[ -n "${default_sc}" ]]; then
    log "[01][CORE] default StorageClass exists: ${default_sc}"
    return 0
  fi

  if kubectl get sc "${STORAGE_CLASS}" >/dev/null 2>&1; then
    log "[01][CORE] patching ${STORAGE_CLASS} as default"
    kubectl patch sc "${STORAGE_CLASS}" -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' >/dev/null
    return 0
  fi

  if [[ "${STORAGE_CLASS}" == "local-path" ]]; then
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

  warn "[01][CORE] no default StorageClass found; leaving as-is"
}

# ------------------------------------------------------------------------------
# Namespaces needed by the platform modules
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
# Ingress Controller
# ------------------------------------------------------------------------------

_wait_ns_gone_if_terminating() {
  local ns="$1"
  local phase=""
  phase="$(kubectl get ns "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${phase}" == "Terminating" ]]; then
    warn "[01][CORE] namespace ${ns} is Terminating; waiting to fully delete"
    while kubectl get ns "${ns}" >/dev/null 2>&1; do
      sleep 3
    done
    log "[01][CORE] namespace ${ns} is gone"
  fi
}

_ingress_nginx_rbac_fix_apply() {
  # Repeatable: apply-only ClusterRole/Binding for the ingress-nginx SA.
  # This is a safety net if some cluster dist/wiring results in missing rights.
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
  # Detect the failure mode you hit: forbidden get services / leases.
  # Returns 0 if broken, 1 otherwise.
  local pod
  pod="$(kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${pod}" ]] || return 1
  kubectl -n ingress-nginx logs "${pod}" --tail=250 2>/dev/null \
    | egrep -qi 'forbidden.*(services|leases)|cannot (get|update).*leases|cannot get resource "services"' \
    && return 0
  return 1
}

ensure_ingress_nginx() {
  log "[01][CORE] nginx selected: disable k3s traefik HelmCharts (if present)"
  kubectl -n kube-system delete helmchart traefik traefik-crd --ignore-not-found >/dev/null 2>&1 || true

  # If a previous run deleted the ns and it is still terminating, do not race it.
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
    --set controller.admissionWebhooks.enabled=true \
    >/dev/null

  kubectl_wait_deploy ingress-nginx ingress-nginx-controller 1200s
  kubectl get ingressclass nginx >/dev/null 2>&1 || true

  # Safety net: if RBAC is broken, fix and restart controller.
  if _ingress_nginx_rbac_broken; then
    warn "[01][CORE] ingress-nginx controller RBAC appears broken; applying fix + restart"
    _ingress_nginx_rbac_fix_apply
    kubectl -n ingress-nginx rollout restart deploy/ingress-nginx-controller >/dev/null || true
    kubectl_wait_deploy ingress-nginx ingress-nginx-controller 600s
  fi

  # Ensure the Service has an external IP in k3s LB mode (svclb)
  log "[01][CORE] ingress service status"
  kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide
}

ensure_ingress() {
  case "${INGRESS_CLASS}" in
    traefik)
      log "[01][CORE] validate traefik (k3s default)"
      ensure_ns kube-system
      kubectl -n kube-system get deploy traefik >/dev/null 2>&1 || fatal "INGRESS_CLASS=traefik but kube-system/traefik not found"
      kubectl_wait_deploy kube-system traefik 600s
      kubectl get ingressclass traefik >/dev/null 2>&1 || true
      ;;
    nginx)
      ensure_ingress_nginx
      ;;
    *)
      fatal "Unsupported INGRESS_CLASS=${INGRESS_CLASS} (expected traefik|nginx)"
      ;;
  esac
}

# ------------------------------------------------------------------------------
# TLS (cert-manager + ClusterIssuer)
# ------------------------------------------------------------------------------

ensure_tls() {
  if [[ "${TLS_MODE}" != "per-host-http01" ]]; then
    log "[01][CORE] TLS_MODE=${TLS_MODE}; skipping cert-manager/issuer"
    return 0
  fi

  [[ -n "${ACME_EMAIL:-}" ]] || fatal "TLS_MODE=per-host-http01 requires ACME_EMAIL"
  [[ -n "${CERT_CLUSTER_ISSUER:-}" ]] || fatal "TLS_MODE=per-host-http01 requires CERT_CLUSTER_ISSUER"

  log "[01][CORE] ensure cert-manager via Helm"
  ensure_ns cert-manager

  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true

  helm upgrade --install cert-manager jetstack/cert-manager \
    -n cert-manager \
    --set installCRDs=true \
    --atomic \
    --cleanup-on-fail \
    --wait \
    --timeout 20m >/dev/null

  kubectl_wait_deploy cert-manager cert-manager 1200s
  kubectl_wait_deploy cert-manager cert-manager-webhook 1200s
  kubectl_wait_deploy cert-manager cert-manager-cainjector 1200s

  log "[01][CORE] apply ClusterIssuer (${CERT_CLUSTER_ISSUER})"
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

  retry 20 3 kubectl get clusterissuer "${CERT_CLUSTER_ISSUER}" >/dev/null 2>&1 || fatal "ClusterIssuer ${CERT_CLUSTER_ISSUER} not created"
}

# ------------------------------------------------------------------------------
# Tests
# ------------------------------------------------------------------------------

run_tests() {
  log "[01][CORE][TEST] begin"

  log "[01][CORE][TEST][T01] kubectl connectivity"
  kubectl version --client >/dev/null 2>&1 || fatal "[T01] kubectl client not working"
  kubectl cluster-info >/dev/null 2>&1 || fatal "[T01] kubectl cluster-info failed"
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
  case "${INGRESS_CLASS}" in
    traefik)
      kubectl -n kube-system get deploy traefik >/dev/null 2>&1 || fatal "[T05] traefik deployment missing"
      kubectl_wait_deploy kube-system traefik 600s || fatal "[T05] traefik not ready"
      ;;
    nginx)
      kubectl -n ingress-nginx get deploy ingress-nginx-controller >/dev/null 2>&1 || fatal "[T05] ingress-nginx-controller missing"
      kubectl_wait_deploy ingress-nginx ingress-nginx-controller 1200s || fatal "[T05] ingress-nginx-controller not ready"
      kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide
      ;;
  esac

  log "[01][CORE][TEST][T06] TLS stack checks (TLS_MODE=${TLS_MODE})"
  if [[ "${TLS_MODE}" == "per-host-http01" ]]; then
    kubectl -n cert-manager get deploy cert-manager >/dev/null 2>&1 || fatal "[T06] cert-manager missing"
    kubectl -n cert-manager get deploy cert-manager-webhook >/dev/null 2>&1 || fatal "[T06] cert-manager-webhook missing"
    kubectl -n cert-manager get deploy cert-manager-cainjector >/dev/null 2>&1 || fatal "[T06] cert-manager-cainjector missing"
    kubectl_wait_deploy cert-manager cert-manager 1200s || fatal "[T06] cert-manager not ready"
    kubectl_wait_deploy cert-manager cert-manager-webhook 1200s || fatal "[T06] cert-manager-webhook not ready"
    kubectl_wait_deploy cert-manager cert-manager-cainjector 1200s || fatal "[T06] cert-manager-cainjector not ready"
    kubectl get clusterissuer "${CERT_CLUSTER_ISSUER}" >/dev/null 2>&1 || fatal "[T06] ClusterIssuer ${CERT_CLUSTER_ISSUER} missing"
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
retry 10 2 kubectl get nodes >/dev/null 2>&1 || fatal "kubectl cannot reach cluster after kubeconfig setup"

ensure_platform_namespaces
ensure_default_storageclass
ensure_ingress
ensure_tls

run_tests

log "[01][CORE] done"
