#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 02-A-minio-https.sh — MinIO HTTPS (console + S3) + tests
# Contract: /root/open-kpi.env
# - Uses MINIO_HOST as console host
# - Uses s3.<base-domain> as S3 host by default (override via MINIO_S3_HOST)
# - Explicit Certificate (single source of truth); no ingress cert annotations
# - No delete-churn; safe to rerun
# ==============================================================================

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need kubectl
need curl
need openssl
need getent
need sed

hr(){ echo "-----------------------------------------------------------------------"; }
sec(){ hr; echo "## $*"; hr; }
fatal(){ echo "FATAL: $*" >&2; exit 1; }

ENV_FILE="${OPENKPI_ENV_FILE:-/root/open-kpi.env}"
[[ -f "${ENV_FILE}" ]] || fatal "Missing contract: ${ENV_FILE}"
set -a
# shellcheck disable=SC1090
. "${ENV_FILE}"
set +a

NS="${NS:-open-kpi}"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
CLUSTER_ISSUER="${CLUSTER_ISSUER:-letsencrypt-http01}"
TLS_SECRET="${MINIO_TLS_SECRET:-minio-tls}"

MINIO_CONSOLE_HOST="${MINIO_HOST:-}"
[[ -n "${MINIO_CONSOLE_HOST}" ]] || fatal "MINIO_HOST is empty in ${ENV_FILE}"

# Derive base domain from MINIO_HOST => minio.<base> ; S3 default => s3.<base>
BASE_DOMAIN="$(echo "${MINIO_CONSOLE_HOST}" | sed -E 's/^[^.]+\.(.*)$/\1/')"
MINIO_S3_HOST="${MINIO_S3_HOST:-s3.${BASE_DOMAIN}}"

sec "Preflight: required objects"
kubectl get ns "${NS}" >/dev/null
kubectl get clusterissuer "${CLUSTER_ISSUER}" >/dev/null
kubectl -n ingress-nginx get deploy ingress-nginx-controller >/dev/null
kubectl -n "${NS}" get svc openkpi-minio >/dev/null

sec "Preflight: DNS"
for h in "${MINIO_CONSOLE_HOST}" "${MINIO_S3_HOST}"; do
  echo "Host: ${h}"
  getent ahostsv4 "${h}" | head -n 2 || fatal "DNS lookup failed for ${h}"
done

sec "Preflight: HTTP-01 reachability (port 80 must respond)"
for h in "${MINIO_CONSOLE_HOST}" "${MINIO_S3_HOST}"; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' "http://${h}/.well-known/acme-challenge/ping" || true)"
  echo "http://${h}/.well-known/acme-challenge/ping -> ${code}"
  [[ -n "${code}" && "${code}" != "000" ]] || fatal "Port 80 not reachable for ${h}"
done

sec "Apply: Ingress + Certificate (apply-only)"
TMP="$(mktemp)"
cat > "${TMP}" <<'YAML'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: minio-console
  namespace: __NS__
  labels:
    app.kubernetes.io/part-of: openkpi
    app.kubernetes.io/name: minio
spec:
  ingressClassName: __INGRESS_CLASS__
  tls:
  - hosts:
    - __MINIO_CONSOLE_HOST__
    secretName: __TLS_SECRET__
  rules:
  - host: __MINIO_CONSOLE_HOST__
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: openkpi-minio
            port:
              number: 9001
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: minio-s3
  namespace: __NS__
  labels:
    app.kubernetes.io/part-of: openkpi
    app.kubernetes.io/name: minio
spec:
  ingressClassName: __INGRESS_CLASS__
  tls:
  - hosts:
    - __MINIO_S3_HOST__
    secretName: __TLS_SECRET__
  rules:
  - host: __MINIO_S3_HOST__
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: openkpi-minio
            port:
              number: 9000
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: __TLS_SECRET__
  namespace: __NS__
  labels:
    app.kubernetes.io/part-of: openkpi
    app.kubernetes.io/name: minio
spec:
  secretName: __TLS_SECRET__
  issuerRef:
    kind: ClusterIssuer
    name: __CLUSTER_ISSUER__
  dnsNames:
  - __MINIO_CONSOLE_HOST__
  - __MINIO_S3_HOST__
YAML

sed -i \
  -e "s/__NS__/${NS}/g" \
  -e "s/__INGRESS_CLASS__/${INGRESS_CLASS}/g" \
  -e "s/__CLUSTER_ISSUER__/${CLUSTER_ISSUER}/g" \
  -e "s/__TLS_SECRET__/${TLS_SECRET}/g" \
  -e "s/__MINIO_CONSOLE_HOST__/${MINIO_CONSOLE_HOST}/g" \
  -e "s/__MINIO_S3_HOST__/${MINIO_S3_HOST}/g" \
  "${TMP}"

kubectl apply -f "${TMP}" >/dev/null
rm -f "${TMP}"

kubectl -n "${NS}" get ingress minio-console minio-s3 -o wide
kubectl -n "${NS}" get certificate "${TLS_SECRET}" -o wide

sec "Wait: certificate Ready=True (diag on failure)"
if ! kubectl -n "${NS}" wait --for=condition=Ready certificate/"${TLS_SECRET}" --timeout=600s; then
  echo "---- certificate describe"
  kubectl -n "${NS}" describe certificate "${TLS_SECRET}" || true
  echo "---- orders/challenges"
  kubectl -n "${NS}" get order,challenge -o wide || true
  echo "---- cert-manager logs"
  kubectl -n cert-manager logs deploy/cert-manager --tail=200 || true
  exit 1
fi

sec "Quick external checks"
code="$(curl -k -sS -o /dev/null -w '%{http_code}' "https://${MINIO_CONSOLE_HOST}/" || true)"
echo "console https code: ${code}"
code="$(curl -k -sS -o /dev/null -w '%{http_code}' "https://${MINIO_S3_HOST}/" || true)"
echo "s3 https code: ${code}"

sec "TLS inspection (console)"
echo | openssl s_client -connect "${MINIO_CONSOLE_HOST}:443" -servername "${MINIO_CONSOLE_HOST}" 2>/dev/null \
  | openssl x509 -noout -subject -issuer || true

hr
echo "MinIO Console: https://${MINIO_CONSOLE_HOST}/"
echo "MinIO S3:      https://${MINIO_S3_HOST}/"

