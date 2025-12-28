#!/usr/bin/env bash
set -euo pipefail

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
: "${LETSENCRYPT_ISSUER:=letsencrypt-prod}"   # set in 00-env.sh if different

require_cmd kubectl
require_cmd helm

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
# Chart-compatible ingress values:
# ingress.hosts is an array of objects and template expects `.host`
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

# Persistence (best-effort; harmless if some keys are ignored by chart deps)
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

elasticsearch:
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

# Persistence (best-effort; harmless if some keys are ignored by chart deps)
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

elasticsearch:
  volumeClaimTemplate:
    storageClassName: ${STORAGE_CLASS}
YAML
fi

# Validate YAML early (fail-fast)
python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1])); print("values.yaml OK")' "${VALUES_FILE}" >/dev/null

log "[03C][ZAMMAD] Install/upgrade: ${REL} in ns/${APP_NS}"
helm upgrade --install "${REL}" "${CHART}" \
  -n "${APP_NS}" \
  --create-namespace \
  -f "${VALUES_FILE}" \
  --wait \
  --timeout 20m

# ------------------------------------------------------------------------------
# Deterministic TLS: create Certificate -> secret zammad-tls (no reliance on shim)
# ------------------------------------------------------------------------------
if [[ "${TLS_MODE}" == "per-host-http01" ]]; then
  log "[03C][ZAMMAD] Ensure cert-manager Certificate -> secret zammad-tls"
  cat <<EOF | kubectl apply -f -
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

  kubectl -n "${APP_NS}" wait --for=condition=Ready certificate/zammad-tls --timeout=15m
  kubectl -n "${APP_NS}" get secret zammad-tls >/dev/null
fi

log "[03C][ZAMMAD] Wait for pods readiness"
kubectl -n "${APP_NS}" wait --for=condition=available deploy -l "app.kubernetes.io/instance=${REL}" --timeout=20m 2>/dev/null || true
kubectl -n "${APP_NS}" wait --for=condition=ready pod -l "app.kubernetes.io/instance=${REL}" --timeout=20m

# Hard check: ingress host must match (prevents silent reversion to chart-example.local)
ACTUAL_HOST="$(kubectl -n "${APP_NS}" get ingress "${REL}" -o jsonpath='{.spec.rules[0].host}')"
[[ "${ACTUAL_HOST}" == "${ZAMMAD_HOST}" ]] || fatal "[03C][ZAMMAD] Ingress host mismatch: ${ACTUAL_HOST} != ${ZAMMAD_HOST}"

SCHEME="http"
if [[ "${TLS_MODE}" == "per-host-http01" ]]; then SCHEME="https"; fi
echo "[03C][ZAMMAD] READY: ${SCHEME}://${ZAMMAD_HOST}/"
