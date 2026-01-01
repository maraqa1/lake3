#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/../../00-env.sh"

require_cmd kubectl

kubectl get nodes >/dev/null
kubectl get sc "${STORAGE_CLASS}" >/dev/null

if [[ "${INGRESS_CLASS}" == "nginx" ]]; then
  kubectl -n ingress-nginx get deploy ingress-nginx-controller >/dev/null
fi

if tls_enabled; then
  kubectl get crd certificates.cert-manager.io >/dev/null
  kubectl get clusterissuer "${CLUSTER_ISSUER}" >/dev/null
fi

log "[01-core][tests] OK"
