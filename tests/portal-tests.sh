#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${HERE}/.." && pwd)"

if [[ -f "${ROOT}/00-env.sh" ]]; then
  # shellcheck source=/dev/null
  . "${ROOT}/00-env.sh" || true
fi
if [[ -f "${ROOT}/00-lib.sh" ]]; then
  # shellcheck source=/dev/null
  . "${ROOT}/00-lib.sh" || true
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }
need kubectl
need curl
need openssl

hr(){ echo "-----------------------------------------------------------------------"; }
sec(){ hr; echo "## $*"; hr; }

FAIL=0
fail(){ echo "FAIL: $*"; FAIL=1; }
pass(){ echo "OK:   $*"; }

PLATFORM_NS="${PLATFORM_NS:-platform}"
INGRESS_NS="${INGRESS_NS:-ingress-nginx}"
PORTAL_ING_NAME="${PORTAL_ING_NAME:-portal}"
PORTAL_API_SVC="${PORTAL_API_SVC:-portal-api}"
PORTAL_UI_SVC="${PORTAL_UI_SVC:-portal-ui}"
PORTAL_API_DEP="${PORTAL_API_DEP:-portal-api}"
PORTAL_UI_DEP="${PORTAL_UI_DEP:-portal-ui}"
PORTAL_TLS_SECRET="${PORTAL_TLS_SECRET:-portal-tls}"

PORTAL_HOST="${PORTAL_HOST:-}"
if [[ -z "${PORTAL_HOST}" ]]; then
  PORTAL_HOST="$(kubectl -n "${PLATFORM_NS}" get ingress "${PORTAL_ING_NAME}" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)"
fi

TLS_MODE="${TLS_MODE:-}"

sec "Cluster + namespaces"
kubectl get ns "${PLATFORM_NS}" >/dev/null 2>&1 && pass "namespace ${PLATFORM_NS} exists" || fail "namespace ${PLATFORM_NS} missing"
kubectl get ns "${INGRESS_NS}" >/dev/null 2>&1 && pass "namespace ${INGRESS_NS} exists" || fail "namespace ${INGRESS_NS} missing"

sec "Portal deployments ready"
if kubectl -n "${PLATFORM_NS}" get deploy "${PORTAL_API_DEP}" >/dev/null 2>&1; then
  kubectl -n "${PLATFORM_NS}" rollout status "deploy/${PORTAL_API_DEP}" --timeout=120s >/dev/null 2>&1 \
    && pass "portal-api deployment ready" || fail "portal-api deployment not ready"
else
  fail "deployment ${PLATFORM_NS}/${PORTAL_API_DEP} missing"
fi

if kubectl -n "${PLATFORM_NS}" get deploy "${PORTAL_UI_DEP}" >/dev/null 2>&1; then
  kubectl -n "${PLATFORM_NS}" rollout status "deploy/${PORTAL_UI_DEP}" --timeout=120s >/dev/null 2>&1 \
    && pass "portal-ui deployment ready" || fail "portal-ui deployment not ready"
else
  fail "deployment ${PLATFORM_NS}/${PORTAL_UI_DEP} missing"
fi

sec "Pods health (no CrashLoop/ImagePullBackOff)"
BAD_PODS="$(kubectl -n "${PLATFORM_NS}" get pods --no-headers 2>/dev/null | awk '$3 ~ /(CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError|Error)/ {print $1 ":" $3}')"
if [[ -n "${BAD_PODS}" ]]; then
  echo "${BAD_PODS}" | sed 's/^/  - /'
  fail "portal namespace has failing pods"
else
  pass "no failing pods in ${PLATFORM_NS}"
fi

sec "Services + endpoints + ports"
kubectl -n "${PLATFORM_NS}" get svc "${PORTAL_API_SVC}" >/dev/null 2>&1 && pass "service ${PORTAL_API_SVC} exists" || fail "service ${PORTAL_API_SVC} missing"
kubectl -n "${PLATFORM_NS}" get svc "${PORTAL_UI_SVC}"  >/dev/null 2>&1 && pass "service ${PORTAL_UI_SVC} exists"  || fail "service ${PORTAL_UI_SVC} missing"

API_TP="$(kubectl -n "${PLATFORM_NS}" get svc "${PORTAL_API_SVC}" -o jsonpath='{.spec.ports[0].targetPort}' 2>/dev/null || true)"
API_PORT="$(kubectl -n "${PLATFORM_NS}" get svc "${PORTAL_API_SVC}" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
if [[ "${API_PORT}" == "80" && ( "${API_TP}" == "8080" || "${API_TP}" == "http" ) ]]; then
  pass "portal-api service maps port 80 -> targetPort ${API_TP}"
else
  fail "portal-api service port mapping wrong (port=${API_PORT}, targetPort=${API_TP}); expected port=80 targetPort=8080"
fi

if kubectl -n "${PLATFORM_NS}" get endpoints "${PORTAL_API_SVC}" >/dev/null 2>&1; then
  EP_PORT="$(kubectl -n "${PLATFORM_NS}" get endpoints "${PORTAL_API_SVC}" -o jsonpath='{.subsets[0].ports[0].port}' 2>/dev/null || true)"
  [[ "${EP_PORT}" == "8080" ]] && pass "portal-api endpoints present on port 8080" || fail "portal-api endpoints wrong port (got ${EP_PORT}, expected 8080)"
else
  fail "endpoints ${PORTAL_API_SVC} missing"
fi

sec "Portal ingress + host"
kubectl -n "${PLATFORM_NS}" get ingress "${PORTAL_ING_NAME}" >/dev/null 2>&1 && pass "ingress ${PORTAL_ING_NAME} exists" || fail "ingress ${PORTAL_ING_NAME} missing"
[[ -n "${PORTAL_HOST}" ]] && pass "portal host resolved: ${PORTAL_HOST}" || fail "portal host not set and could not derive from ingress"

ING_BACKEND_SVC="$(kubectl -n "${PLATFORM_NS}" get ingress "${PORTAL_ING_NAME}" -o jsonpath='{.spec.rules[0].http.paths[0].backend.service.name}' 2>/dev/null || true)"
[[ "${ING_BACKEND_SVC}" == "${PORTAL_UI_SVC}" ]] && pass "ingress routes to ${PORTAL_UI_SVC}" || fail "ingress backend is '${ING_BACKEND_SVC}', expected '${PORTAL_UI_SVC}'"

sec "TLS (if enabled)"
if [[ "${TLS_MODE}" == "per-host-http01" ]]; then
  kubectl -n "${PLATFORM_NS}" get secret "${PORTAL_TLS_SECRET}" >/dev/null 2>&1 && pass "TLS secret ${PORTAL_TLS_SECRET} exists" || fail "TLS secret ${PORTAL_TLS_SECRET} missing"
  if kubectl -n "${PLATFORM_NS}" get certificate "${PORTAL_TLS_SECRET}" >/dev/null 2>&1; then
    READY="$(kubectl -n "${PLATFORM_NS}" get certificate "${PORTAL_TLS_SECRET}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [[ "${READY}" == "True" ]] && pass "certificate ${PORTAL_TLS_SECRET} Ready=True" || fail "certificate ${PORTAL_TLS_SECRET} not Ready"
  fi
else
  pass "TLS_MODE not enforced (current: '${TLS_MODE:-unset}')"
fi

sec "In-cluster API reachability"
API_HEALTH="$(kubectl -n "${PLATFORM_NS}" run -i --rm curltmp --image=curlimages/curl:8.5.0 --restart=Never \
  -- sh -lc "curl -sS -m 8 http://${PORTAL_API_SVC}/api/health" 2>/dev/null || true)"
echo "${API_HEALTH}" | grep -q '"ok":true' && pass "portal-api /api/health OK" || { echo "${API_HEALTH}" | sed 's/^/  /'; fail "portal-api /api/health failed"; }

API_SUMMARY="$(kubectl -n "${PLATFORM_NS}" run -i --rm curltmp --image=curlimages/curl:8.5.0 --restart=Never \
  -- sh -lc "curl -sS -m 8 http://${PORTAL_API_SVC}/api/summary" 2>/dev/null || true)"
if echo "${API_SUMMARY}" | grep -q '"k8s"' && echo "${API_SUMMARY}" | grep -q '"catalog"' && echo "${API_SUMMARY}" | grep -q '"ingestion"'; then
  pass "portal-api /api/summary returns expected JSON keys"
else
  echo "${API_SUMMARY}" | head -c 600 | sed 's/^/  /'
  fail "portal-api /api/summary missing expected keys"
fi

sec "UI reachability (in-cluster)"
UI_ROOT="$(kubectl -n "${PLATFORM_NS}" run -i --rm curltmp --image=curlimages/curl:8.5.0 --restart=Never \
  -- sh -lc "curl -sS -m 8 http://${PORTAL_UI_SVC}/ | head -c 120" 2>/dev/null || true)"
[[ -n "${UI_ROOT}" ]] && pass "portal-ui serves /" || fail "portal-ui did not return content on /"

UI_HEALTHZ="$(kubectl -n "${PLATFORM_NS}" run -i --rm curltmp --image=curlimages/curl:8.5.0 --restart=Never \
  -- sh -lc "curl -sS -m 8 http://${PORTAL_UI_SVC}/healthz" 2>/dev/null || true)"
[[ -n "${UI_HEALTHZ}" ]] && pass "portal-ui /healthz responds" || fail "portal-ui /healthz failed"

sec "UI -> API proxy check (expects nginx.conf to proxy /api/)"
UI_API_HEALTH="$(kubectl -n "${PLATFORM_NS}" run -i --rm curltmp --image=curlimages/curl:8.5.0 --restart=Never \
  -- sh -lc "curl -sS -m 8 http://${PORTAL_UI_SVC}/api/health" 2>/dev/null || true)"
echo "${UI_API_HEALTH}" | grep -q '"ok":true' && pass "portal-ui proxies /api/health" || { echo "${UI_API_HEALTH}" | sed 's/^/  /'; fail "portal-ui does not proxy /api/*"; }

sec "Secrets contract (portal-api-secrets)"
kubectl -n "${PLATFORM_NS}" get secret portal-api-secrets >/dev/null 2>&1 && pass "secret portal-api-secrets exists" || fail "secret portal-api-secrets missing"
REQ_KEYS=(OPENKPI_PG_USER OPENKPI_PG_PASSWORD OPENKPI_PG_DB OPENKPI_MINIO_ACCESS_KEY OPENKPI_MINIO_SECRET_KEY)
for k in "${REQ_KEYS[@]}"; do
  v="$(kubectl -n "${PLATFORM_NS}" get secret portal-api-secrets -o jsonpath="{.data.${k}}" 2>/dev/null || true)"
  [[ -n "${v}" ]] && pass "portal-api-secrets has ${k}" || fail "portal-api-secrets missing ${k}"
done

sec "Airbyte discovery (optional)"
if kubectl get ns airbyte >/dev/null 2>&1; then
  AB_SERVER="$(kubectl -n airbyte get svc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -E 'server' | head -n1 || true)"
  [[ -n "${AB_SERVER}" ]] && pass "airbyte server service exists: ${AB_SERVER}" || fail "airbyte namespace exists but no service matching /server/ found"
else
  pass "airbyte namespace not present (tolerated)"
fi

sec "External URL smoke (best effort)"
if [[ -n "${PORTAL_HOST}" ]]; then
  SCHEME="http"; [[ "${TLS_MODE}" == "per-host-http01" ]] && SCHEME="https"
  CODE="$(curl -k -sS -m 8 -o /dev/null -w '%{http_code}' "${SCHEME}://${PORTAL_HOST}/" || true)"
  if [[ "${CODE}" == "200" || "${CODE}" == "301" || "${CODE}" == "302" ]]; then
    pass "external portal URL responds (${CODE}): ${SCHEME}://${PORTAL_HOST}/"
  else
    echo "  http_code=${CODE} url=${SCHEME}://${PORTAL_HOST}/"
    fail "external portal URL not reachable/healthy"
  fi
else
  fail "PORTAL_HOST unresolved; cannot run external URL smoke"
fi

sec "Summary"
echo "Portal Host: ${PORTAL_HOST:-<unset>}"
echo "API Service: ${PLATFORM_NS}/${PORTAL_API_SVC}"
echo "UI Service:  ${PLATFORM_NS}/${PORTAL_UI_SVC}"
echo "TLS_MODE:    ${TLS_MODE:-unset}"
echo "Result:      $([[ "${FAIL}" -eq 0 ]] && echo PASS || echo FAIL)"
exit "${FAIL}"
