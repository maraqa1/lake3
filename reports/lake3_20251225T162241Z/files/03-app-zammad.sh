#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/00-env.sh"
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

require_cmd kubectl
require_cmd helm

ensure_ns "${APP_NS}"

log "[03C][ZAMMAD] Helm repo ensure: ${REPO_NAME} -> ${REPO_URL}"
if ! helm repo list | awk '{print $1}' | grep -qx "${REPO_NAME}"; then
  helm repo add "${REPO_NAME}" "${REPO_URL}"
fi
helm repo update >/dev/null

TMP_DIR="$(mktemp -d)"
cleanup(){ rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

VALUES_FILE="${TMP_DIR}/values.yaml"
TLS_BLOCK=""
if [[ "${TLS_MODE}" == "per-host-http01" ]]; then
  TLS_BLOCK="$(cat <<YAML
  tls:
    - hosts:
        - ${ZAMMAD_HOST}
      secretName: ${REL}-tls
YAML
)"
else
  TLS_BLOCK="  tls: []"
fi

cat > "${VALUES_FILE}" <<YAML
ingress:
  enabled: true
  className: ${INGRESS_CLASS}
  host: ${ZAMMAD_HOST}
  path: /
${TLS_BLOCK}

# Persistence (best-effort across chart/dependency variants; unknown keys are harmless)
persistence:
  enabled: true
  storageClass: ${STORAGE_CLASS}

zammad:
  persistence:
    enabled: true
    storageClass: ${STORAGE_CLASS}

postgresql:
  primary:
    persistence:
      enabled: true
      storageClass: ${STORAGE_CLASS}
  persistence:
    enabled: true
    storageClass: ${STORAGE_CLASS}

elasticsearch:
  volumeClaimTemplate:
    storageClassName: ${STORAGE_CLASS}
YAML

log "[03C][ZAMMAD] Install/upgrade: ${REL} in ns/${APP_NS} (Ingress-only)"
helm upgrade --install "${REL}" "${CHART}" \
  -n "${APP_NS}" \
  --create-namespace \
  -f "${VALUES_FILE}" \
  --wait \
  --timeout 15m

log "[03C][ZAMMAD] Wait for workloads/pods readiness"
kubectl -n "${APP_NS}" wait --for=condition=available deploy -l "app.kubernetes.io/instance=${REL}" --timeout=15m 2>/dev/null || true
kubectl -n "${APP_NS}" wait --for=condition=ready pod -l "app.kubernetes.io/instance=${REL}" --timeout=15m

SCHEME="http"
if [[ "${TLS_MODE}" == "per-host-http01" ]]; then SCHEME="https"; fi
echo "[03C][ZAMMAD] READY: ${SCHEME}://${ZAMMAD_HOST}/"
