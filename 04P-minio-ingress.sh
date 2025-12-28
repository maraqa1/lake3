#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# patches/04P-minio-ingress.sh — create OpenKPI MinIO Console ingress (repeatable)
# - Creates Ingress in open-kpi namespace named "minio"
# - Host: ${MINIO_HOST} (default: minio.<base-domain from PORTAL_HOST>)
# - Routes to Service openkpi-minio, port 9001 if present, else 9000
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/00-env.sh"
# shellcheck source=/dev/null
. "${HERE}/00-lib.sh"

require_cmd kubectl

OPENKPI_NS="${NS:-open-kpi}"
: "${INGRESS_CLASS:=nginx}"
: "${TLS_MODE:=per-host-http01}"
: "${PORTAL_HOST:=portal.lake3.opendatalake.com}"
: "${PORTAL_TLS_SECRET:=portal-tls}"
: "${CLUSTER_ISSUER:=letsencrypt-http01}"

# derive base domain from PORTAL_HOST: portal.lake3.opendatalake.com -> lake3.opendatalake.com
BASE_DOMAIN="${PORTAL_HOST#*.}"
: "${MINIO_HOST:=minio.${BASE_DOMAIN}}"

ensure_ns "${OPENKPI_NS}"

# detect service + port (prefer 9001 console if exposed)
SVC="openkpi-minio"
kubectl -n "${OPENKPI_NS}" get svc "${SVC}" >/dev/null 2>&1 || fatal "Missing service ${OPENKPI_NS}/${SVC}"

PORT="9001"
if ! kubectl -n "${OPENKPI_NS}" get svc "${SVC}" -o jsonpath='{.spec.ports[?(@.port==9001)].port}' 2>/dev/null | grep -q 9001; then
  PORT="9000"
fi

# TLS cert (re-uses your cluster issuer + a dedicated secret for minio)
MINIO_TLS_SECRET="${MINIO_TLS_SECRET:-minio-tls}"

if [[ "${TLS_MODE}" == "per-host-http01" ]]; then
  kubectl -n "${OPENKPI_NS}" apply -f - <<YAML
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: minio-cert
  namespace: ${OPENKPI_NS}
spec:
  secretName: ${MINIO_TLS_SECRET}
  issuerRef:
    kind: ClusterIssuer
    name: ${CLUSTER_ISSUER}
  dnsNames:
    - ${MINIO_HOST}
YAML
  kubectl -n "${OPENKPI_NS}" wait --for=condition=Ready certificate/minio-cert --timeout=600s || true
fi

TLS_BLOCK=""
if [[ "${TLS_MODE}" == "per-host-http01" ]]; then
  TLS_BLOCK="$(cat <<EOF
  tls:
  - hosts:
    - ${MINIO_HOST}
    secretName: ${MINIO_TLS_SECRET}
EOF
)"
fi

kubectl -n "${OPENKPI_NS}" apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: minio
  namespace: ${OPENKPI_NS}
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-body-size: "100m"
spec:
  ingressClassName: ${INGRESS_CLASS}
${TLS_BLOCK}
  rules:
  - host: ${MINIO_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${SVC}
            port:
              number: ${PORT}
YAML

echo "[04P][MINIO-INGRESS] Ready: https://${MINIO_HOST}/ (service=${SVC} port=${PORT})"
