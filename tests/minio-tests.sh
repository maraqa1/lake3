#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# tests/minio-tests.sh
# Validates:
# - Ingress objects exist
# - Certificate Ready
# - External HTTPS reachability (console + S3)
# - In-cluster health endpoints
# - In-cluster mc auth (list buckets)
# ==============================================================================

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need kubectl
need curl
need openssl

hr(){ echo "-----------------------------------------------------------------------"; }
sec(){ hr; echo "## $*"; hr; }

FAIL=0
fail(){ echo "FAIL: $*"; FAIL=1; }
pass(){ echo "OK:   $*"; }

NS="${NS:-open-kpi}"
TLS_SECRET="${TLS_SECRET:-minio-tls}"
MINIO_CONSOLE_HOST="${MINIO_CONSOLE_HOST:-minio.lake3.opendatalake.com}"
MINIO_S3_HOST="${MINIO_S3_HOST:-s3.lake3.opendatalake.com}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.5.0}"
MC_IMAGE="${MC_IMAGE:-minio/mc:RELEASE.2025-08-13T08-35-41Z}"

sec "Objects exist"
kubectl -n "${NS}" get ingress minio-console >/dev/null && pass "ingress ${NS}/minio-console exists" || fail "missing ingress ${NS}/minio-console"
kubectl -n "${NS}" get ingress minio-s3 >/dev/null && pass "ingress ${NS}/minio-s3 exists" || fail "missing ingress ${NS}/minio-s3"
kubectl -n "${NS}" get certificate "${TLS_SECRET}" >/dev/null && pass "certificate ${NS}/${TLS_SECRET} exists" || fail "missing certificate ${NS}/${TLS_SECRET}"
kubectl -n "${NS}" get secret "${TLS_SECRET}" >/dev/null && pass "tls secret ${NS}/${TLS_SECRET} exists" || fail "missing tls secret ${NS}/${TLS_SECRET}"

sec "Certificate Ready"
READY="$(kubectl -n "${NS}" get certificate "${TLS_SECRET}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
[[ "${READY}" == "True" ]] && pass "certificate Ready=True" || fail "certificate not Ready (status=${READY:-empty})"

sec "In-cluster health (no ingress)"
kubectl -n "${NS}" run -i --rm curltmp --image="${CURL_IMAGE}" --restart=Never -- \
  sh -lc "curl -fsS http://openkpi-minio.${NS}.svc.cluster.local:9000/minio/health/ready >/dev/null" \
  >/dev/null 2>&1 && pass "minio ready endpoint OK (cluster)" || fail "minio ready endpoint FAIL (cluster)"

sec "External HTTPS: console"
code="$(curl -k -sS -o /dev/null -w '%{http_code}' "https://${MINIO_CONSOLE_HOST}/" || true)"
[[ "${code}" == "200" ]] && pass "console responds 200: https://${MINIO_CONSOLE_HOST}/" || fail "console not 200 (code=${code}): https://${MINIO_CONSOLE_HOST}/"

sec "External HTTPS: S3 (expected non-200 is acceptable)"
# S3 root commonly returns 400/403 depending on host/path; both indicate reachability.
code="$(curl -k -sS -o /dev/null -w '%{http_code}' "https://${MINIO_S3_HOST}/" || true)"
if [[ "${code}" == "400" || "${code}" == "403" || "${code}" == "405" ]]; then
  pass "S3 endpoint reachable (code=${code}): https://${MINIO_S3_HOST}/"
else
  fail "S3 endpoint unexpected code=${code}: https://${MINIO_S3_HOST}/"
fi

sec "TLS inspection (console host)"
# Verify handshake and show issuer subject quickly (best-effort)
echo | openssl s_client -connect "${MINIO_CONSOLE_HOST}:443" -servername "${MINIO_CONSOLE_HOST}" 2>/dev/null \
  | openssl x509 -noout -subject -issuer >/dev/null 2>&1 \
  && pass "TLS handshake OK for ${MINIO_CONSOLE_HOST}:443" || fail "TLS handshake FAIL for ${MINIO_CONSOLE_HOST}:443"

sec "MinIO auth via mc (in-cluster)"
USER="$(kubectl -n "${NS}" get secret openkpi-minio-secret -o jsonpath='{.data.MINIO_ROOT_USER}' | base64 -d 2>/dev/null || true)"
PASSWD="$(kubectl -n "${NS}" get secret openkpi-minio-secret -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d 2>/dev/null || true)"
[[ -n "${USER}" ]] && [[ -n "${PASSWD}" ]] && pass "minio creds read from secret" || fail "cannot read minio creds from openkpi-minio-secret"

kubectl -n "${NS}" run mccheck --restart=Never --rm -i --image="${MC_IMAGE}" \
  --env "MINIO_USER=${USER}" --env "MINIO_PASS=${PASSWD}" \
  --command -- sh -lc '
    set -e
    mc alias set openkpi http://openkpi-minio:9000 "$MINIO_USER" "$MINIO_PASS" >/dev/null
    mc ls openkpi >/dev/null
  ' >/dev/null 2>&1 && pass "mc auth OK + ls buckets" || fail "mc auth/ls FAIL (image tag may be wrong or creds invalid)"

hr
echo "MinIO Console: https://${MINIO_CONSOLE_HOST}/"
echo "MinIO S3:      https://${MINIO_S3_HOST}/"
echo "Result:        $([[ "${FAIL}" == "0" ]] && echo PASS || echo FAIL)"
exit "${FAIL}"
