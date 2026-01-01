#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/../../00-env.sh"

log "[01-core] start"

require_cmd kubectl
require_cmd helm

# kubeconfig must exist (set by 00-env)
[[ -n "${OPENKPI_KUBECONFIG:-}" && -f "${OPENKPI_KUBECONFIG}" ]] || die "Missing kubeconfig. OPENKPI_KUBECONFIG=${OPENKPI_KUBECONFIG:-unset}"
kubectl_k get nodes >/dev/null 2>&1 || die "Cluster unreachable via ${OPENKPI_KUBECONFIG}"

# ------------------------------------------------------------------------------
# Disable Traefik (repeatable)
# ------------------------------------------------------------------------------
log "[01-core] disable traefik (repeatable)"
mkdir -p /var/lib/rancher/k3s/server/manifests
if [[ -f /var/lib/rancher/k3s/server/manifests/traefik.yaml ]]; then
  mv /var/lib/rancher/k3s/server/manifests/traefik.yaml /var/lib/rancher/k3s/server/manifests/traefik.yaml.disabled.$(date +%s) || true
fi
if [[ -f /var/lib/rancher/k3s/server/manifests/traefik-crd.yaml ]]; then
  mv /var/lib/rancher/k3s/server/manifests/traefik-crd.yaml /var/lib/rancher/k3s/server/manifests/traefik-crd.yaml.disabled.$(date +%s) || true
fi
kubectl_k -n kube-system delete helmchart traefik traefik-crd --ignore-not-found=true >/dev/null 2>&1 || true
kubectl_k -n kube-system delete deploy/traefik svc/traefik --ignore-not-found=true >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# Install ingress-nginx (idempotent)
# ------------------------------------------------------------------------------
log "[01-core] install/upgrade ingress-nginx"
kubectl_k get ns ingress-nginx >/dev/null 2>&1 || kubectl_k create ns ingress-nginx

helm_k repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm_k repo update >/dev/null

helm_k upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx \
  --version 4.14.1 \
  --history-max 5 \
  --atomic \
  --cleanup-on-fail \
  --set controller.ingressClassResource.name="${INGRESS_CLASS}" \
  --set controller.ingressClassResource.controllerValue="k8s.io/ingress-nginx" \
  --set controller.ingressClass="${INGRESS_CLASS}" \
  --set controller.watchIngressWithoutClass=false \
  --set controller.service.type=LoadBalancer \
  --set controller.publishService.enabled=true \
  --set controller.admissionWebhooks.enabled=true \
  --timeout 15m

kubectl_k -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s

# ------------------------------------------------------------------------------
# cert-manager bootstrap (TLS-gated, repeatable)
# - If TLS_MODE=off: skip
# - Else: ensure CRDs + controllers + ClusterIssuer exist
# ------------------------------------------------------------------------------
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.15.3}"
CERT_MANAGER_NS="cert-manager"

ensure_cert_manager() {
  tls_enabled || { log "[01-core][cert-manager] TLS_MODE=off -> skip"; return 0; }

  require_var CERT_CLUSTER_ISSUER
  require_var LE_EMAIL

  log "[01-core][cert-manager] ensure CRDs/controllers (${CERT_MANAGER_VERSION})"

  # CRD presence is the correct gate. If missing, install full release manifest (includes CRDs).
  if ! kubectl_k get crd certificates.cert-manager.io >/dev/null 2>&1; then
    log "[01-core][cert-manager] CRDs missing -> install cert-manager ${CERT_MANAGER_VERSION}"
    kubectl_k apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
  else
    log "[01-core][cert-manager] CRDs present"
  fi

  # Wait for deployments (safe even when already installed)
  kubectl_k -n "${CERT_MANAGER_NS}" rollout status deploy/cert-manager --timeout=300s
  kubectl_k -n "${CERT_MANAGER_NS}" rollout status deploy/cert-manager-webhook --timeout=300s
  kubectl_k -n "${CERT_MANAGER_NS}" rollout status deploy/cert-manager-cainjector --timeout=300s

  # Hard assert CRDs exist now
  kubectl_k get crd certificates.cert-manager.io >/dev/null
  kubectl_k get crd clusterissuers.cert-manager.io >/dev/null
  kubectl_k get crd issuers.cert-manager.io >/dev/null

  # ClusterIssuer (HTTP-01 via ingress-nginx)
  if ! kubectl_k get clusterissuer "${CERT_CLUSTER_ISSUER}" >/dev/null 2>&1; then
    log "[01-core][cert-manager] ClusterIssuer missing -> create ${CERT_CLUSTER_ISSUER}"
    cat <<YAML | kubectl_k apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${CERT_CLUSTER_ISSUER}
spec:
  acme:
    email: ${LE_EMAIL}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: ${CERT_CLUSTER_ISSUER}-account-key
    solvers:
    - http01:
        ingress:
          class: ${INGRESS_CLASS}
YAML
  else
    log "[01-core][cert-manager] ClusterIssuer exists: ${CERT_CLUSTER_ISSUER}"
  fi
}

ensure_cert_manager



apt-get update -y
apt-get install -y jq

# ------------------------------------------------------------------------------
# Tests (core)
# ------------------------------------------------------------------------------
log "[01-core] tests: ingress-nginx"
kubectl_k -n ingress-nginx get deploy ingress-nginx-controller >/dev/null
kubectl_k -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s >/dev/null

if tls_enabled; then
  log "[01-core] tests: cert-manager"
  kubectl_k get crd certificates.cert-manager.io >/dev/null
  kubectl_k -n cert-manager get deploy cert-manager cert-manager-webhook cert-manager-cainjector >/dev/null
  kubectl_k get clusterissuer "${CERT_CLUSTER_ISSUER}" >/dev/null
fi

log "[01-core] done"
