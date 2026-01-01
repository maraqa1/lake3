#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 02-A-minio-https.sh — OpenKPI Module 02-A: MinIO Ingress (HTTP/TLS toggle)
#
# Production guarantees:
# - Idempotent kubectl apply only
# - TLS gate via tls_enabled()
# - When TLS enabled:
#   - Creates/updates Certificate (minio-cert -> secret MINIO_TLS_SECRET)
#   - Waits for Certificate Ready + secret + nginx serving non-fake cert
# - Ingress routes:
#   - https://<MINIO_HOST>/console/  -> console svc (rewritten)
#   - https://<MINIO_HOST>/          -> api svc
# - Prevents redirect to :9001 by:
#   - nginx rewrite under /console/
#   - X-Forwarded-* headers
# ==============================================================================
#
# IMPORTANT:
# - No sed templating. No "$2" bash expansion bugs:
#   - rewrite-target uses "/\$2" in YAML so nginx receives "/$2"
# - Snippet variables are escaped (\$scheme, \$host, \$server_port)
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/../../00-env.sh"

log "[02-A][minio-https] start"

# ------------------------------------------------------------------------------
# Requirements
# ------------------------------------------------------------------------------
require_cmd kubectl
require_cmd curl
require_cmd grep
require_cmd openssl

require_var OPENKPI_NS
require_var INGRESS_CLASS
require_var TLS_MODE
require_var MINIO_HOST

NS="${OPENKPI_NS}"

API_SVC="${MINIO_API_SVC:-openkpi-minio}"
CONSOLE_SVC="${MINIO_CONSOLE_SVC:-openkpi-minio-console}"

MINIO_API_PORT="${MINIO_API_PORT:-9000}"
MINIO_CONSOLE_PORT="${MINIO_CONSOLE_PORT:-9001}"

MINIO_TLS_SECRET="${MINIO_TLS_SECRET:-minio-tls}"

# ------------------------------------------------------------------------------
# Prechecks
# ------------------------------------------------------------------------------
kubectl_k -n "${NS}" get svc "${API_SVC}" >/dev/null
kubectl_k -n "${NS}" get svc "${CONSOLE_SVC}" >/dev/null

# ------------------------------------------------------------------------------
# TLS: Certificate
# ------------------------------------------------------------------------------
TLS_BLOCK=""
if tls_enabled; then
  require_var CERT_CLUSTER_ISSUER

  cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: minio-cert
spec:
  secretName: ${MINIO_TLS_SECRET}
  issuerRef:
    kind: ClusterIssuer
    name: ${CERT_CLUSTER_ISSUER}
  dnsNames:
    - ${MINIO_HOST}
YAML

  TLS_BLOCK="$(cat <<EOF
  tls:
    - hosts:
        - ${MINIO_HOST}
      secretName: ${MINIO_TLS_SECRET}
EOF
)"
fi

# ------------------------------------------------------------------------------
# Ingress (rewrite /console/ -> /)
# ------------------------------------------------------------------------------
cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: minio-ingress
  annotations:
    kubernetes.io/ingress.class: "${INGRESS_CLASS}"
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: "/\$2"
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_set_header X-Forwarded-Host  \$host;
      proxy_set_header X-Forwarded-Port  \$server_port;
spec:
  ingressClassName: "${INGRESS_CLASS}"
${TLS_BLOCK}
  rules:
    - host: ${MINIO_HOST}
      http:
        paths:
          - path: /console(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: ${CONSOLE_SVC}
                port:
                  number: ${MINIO_CONSOLE_PORT}
          - path: (/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: ${API_SVC}
                port:
                  number: ${MINIO_API_PORT}
YAML

# ------------------------------------------------------------------------------
# Tests (HTTP/HTTPS aware)
# ------------------------------------------------------------------------------
LB_IP="${INGRESS_LB_IP:-$(kubectl_k -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)}"
[[ -n "${LB_IP}" ]] || die "Unable to detect ingress LB IP (set INGRESS_LB_IP or ensure ingress-nginx service has external IP)"

_diag_tls() {
  log "[02-A][minio-https][DIAG] objects/events"
  kubectl_k -n "${NS}" get ingress minio-ingress -o yaml || true
  kubectl_k -n "${NS}" get certificate minio-cert -o yaml || true
  kubectl_k -n "${NS}" get secret "${MINIO_TLS_SECRET}" -o wide || true
  kubectl_k -n "${NS}" get certificaterequest,order,challenge -o wide || true
  kubectl_k -n "${NS}" get events --sort-by=.lastTimestamp | tail -n 120 || true
}

_wait_cert_ready() {
  log "[02-A][minio-https] wait Certificate Ready: ${NS}/minio-cert"
  kubectl_k -n "${NS}" wait --for=condition=Ready "certificate/minio-cert" --timeout=600s || { _diag_tls; die "minio-cert not Ready"; }

  log "[02-A][minio-https] wait TLS secret present: ${NS}/${MINIO_TLS_SECRET}"
  for _ in {1..60}; do
    kubectl_k -n "${NS}" get secret "${MINIO_TLS_SECRET}" >/dev/null 2>&1 && break
    sleep 2
  done
  kubectl_k -n "${NS}" get secret "${MINIO_TLS_SECRET}" >/dev/null 2>&1 || { _diag_tls; die "TLS secret missing: ${NS}/${MINIO_TLS_SECRET}"; }
}

_is_fake_cert() {
  echo | openssl s_client -servername "${MINIO_HOST}" -connect "${MINIO_HOST}:443" 2>/dev/null \
    | openssl x509 -noout -issuer -subject 2>/dev/null | grep -qi "Fake Certificate"
}

_wait_nginx_serves_real_cert() {
  log "[02-A][minio-https] wait nginx to serve real cert for ${MINIO_HOST}"
  for _ in {1..60}; do
    _is_fake_cert && { sleep 3; continue; }
    return 0
  done
  log "[02-A][minio-https][DIAG] nginx still serving fake cert"
  echo | openssl s_client -servername "${MINIO_HOST}" -connect "${MINIO_HOST}:443" 2>/dev/null \
    | openssl x509 -noout -issuer -subject -dates || true
  _diag_tls
  die "nginx still serving fake/self-signed cert"
}

if tls_enabled; then
  _wait_cert_ready
  _wait_nginx_serves_real_cert

  # Reachability checks (403 is valid for unauthenticated)
  curl -sS -o /dev/null -D - "https://${MINIO_HOST}/" \
    | head -n 1 | grep -Eq 'HTTP/.* (200|301|302|401|403|405)'

  curl -sS -o /dev/null -D - "https://${MINIO_HOST}/console/" \
    | head -n 1 | grep -Eq 'HTTP/.* (200|301|302|401|403)'

  # Console must not redirect to :9001 (port leak)
  curl -sS -o /dev/null -D - "https://${MINIO_HOST}/console/" \
    | tr -d '\r' | grep -Eqi '^location: https://minio\.lake4\.opendatalake\.com:9001/' && die "console redirect to :9001 detected"
else
  curl -sS -o /dev/null -D - -H "Host: ${MINIO_HOST}" "http://${LB_IP}/" \
    | head -n 1 | grep -Eq 'HTTP/.* (200|301|302|401|403|405)'

  curl -sS -o /dev/null -D - -H "Host: ${MINIO_HOST}" "http://${LB_IP}/console/" \
    | head -n 1 | grep -Eq 'HTTP/.* (200|301|302|401|403)'
fi

log "[02-A][minio-https] done"
