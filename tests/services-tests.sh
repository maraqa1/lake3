#!/usr/bin/env bash
set -euo pipefail

fail(){ echo "FAIL: $*"; exit 1; }
warn(){ echo "WARN: $*"; }
pass(){ echo "OK:   $*"; }
hr(){ echo "-----------------------------------------------------------------------"; }
sec(){ hr; echo "## $*"; hr; }

need(){ command -v "$1" >/dev/null 2>&1 || fail "Missing: $1"; }
need kubectl
need curl
need openssl

NS_PLATFORM="${PLATFORM_NS:-platform}"
NS_OPENKPI="${NS:-open-kpi}"
NS_AIRBYTE="${AIRBYTE_NS:-airbyte}"
NS_TICKETS="${TICKETS_NS:-tickets}"
NS_N8N="${N8N_NS:-n8n}"
NS_TRANSFORM="${DBT_NS:-transform}"
PORTAL_ING="${PORTAL_ING_NAME:-portal}"

# Resolve hosts from ingresses (source of truth)
portal_host="$(kubectl -n "$NS_PLATFORM" get ingress "$PORTAL_ING" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)"
airbyte_host="$(kubectl -n "$NS_AIRBYTE" get ingress airbyte -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)"
zammad_host="$(kubectl -n "$NS_TICKETS" get ingress zammad -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)"
n8n_host="$(kubectl -n "$NS_N8N" get ingress n8n -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)"

sec "Namespaces"
for n in "$NS_PLATFORM" "$NS_OPENKPI" "$NS_AIRBYTE" "$NS_TICKETS" "$NS_N8N" "$NS_TRANSFORM" "ingress-nginx"; do
  kubectl get ns "$n" >/dev/null 2>&1 || fail "namespace missing: $n"
  pass "namespace $n exists"
done

sec "Ingress/TLS: platform/portal"
kubectl -n "$NS_PLATFORM" get ingress "$PORTAL_ING" >/dev/null 2>&1 || fail "missing ingress: $NS_PLATFORM/$PORTAL_ING"
[[ -n "$portal_host" ]] || fail "cannot resolve portal host from ingress"
pass "portal host: $portal_host"
kubectl -n "$NS_PLATFORM" get certificate portal-tls >/dev/null 2>&1 && {
  kubectl -n "$NS_PLATFORM" wait --for=condition=Ready certificate/portal-tls --timeout=180s >/dev/null 2>&1 || fail "portal cert not Ready"
  pass "certificate platform/portal-tls Ready=True"
} || warn "no portal certificate object (TLS may be off)"

sec "Portal services + endpoints"
kubectl -n "$NS_PLATFORM" get svc portal-ui portal-api >/dev/null 2>&1 || fail "missing portal services"
kubectl -n "$NS_PLATFORM" get endpoints portal-ui >/dev/null 2>&1 || fail "portal-ui has no endpoints"
kubectl -n "$NS_PLATFORM" get endpoints portal-api >/dev/null 2>&1 || fail "portal-api has no endpoints"
pass "portal-ui endpoints present"
pass "portal-api endpoints present"

sec "In-cluster: portal-ui -> portal-api"
kubectl -n "$NS_PLATFORM" run -i --rm curltmp --restart=Never --image=curlimages/curl:8.5.0 -- \
  sh -lc 'curl -fsS -m 8 http://portal-ui/api/health >/dev/null' \
  >/dev/null 2>&1 || fail "portal-ui does not proxy /api"
pass "portal-ui proxies /api"

sec "External: portal"
code="$(curl -sS -m 12 -o /dev/null -w '%{http_code}' "https://${portal_host}/" || true)"
[[ "$code" == "200" ]] || fail "portal UI not 200 (code=$code): https://${portal_host}/"
pass "portal UI 200: https://${portal_host}/"

code="$(curl -sS -m 12 -o /dev/null -w '%{http_code}' "https://${portal_host}/api/health" || true)"
[[ "$code" == "200" ]] || fail "portal API not 200 (code=$code): https://${portal_host}/api/health"
pass "portal API 200: https://${portal_host}/api/health"

sec "OpenKPI core: Postgres + MinIO services"
kubectl -n "$NS_OPENKPI" get svc openkpi-postgres openkpi-minio >/dev/null 2>&1 || fail "missing openkpi-postgres/minio services"
pass "openkpi-postgres/minio services exist"

sec "Airbyte external"
if [[ -n "$airbyte_host" ]]; then
  code="$(curl -sS -m 12 -o /dev/null -w '%{http_code}' "https://${airbyte_host}/" || true)"
  [[ "$code" == "200" ]] || fail "airbyte not 200 (code=$code): https://${airbyte_host}/"
  pass "airbyte 200: https://${airbyte_host}/"
else
  warn "airbyte ingress not found"
fi

sec "Zammad external"

: "${ZAMMAD_HOST:?missing ZAMMAD_HOST (set in /root/open-kpi.env to zammad.lake3.opendatalake.com)}"

code="$(curl -k -sS -o /dev/null -m 15 -w '%{http_code}' "https://${ZAMMAD_HOST}/" || true)"
if [[ "$code" == "200" || "$code" == "302" ]]; then
  pass "zammad reachable (code=${code}): https://${ZAMMAD_HOST}/"
else
  fail "zammad not reachable (code=${code}): https://${ZAMMAD_HOST}/"
  echo "Ingress host currently:"
  kubectl -n "${NS_TICKETS}" get ingress zammad -o jsonpath='{.spec.rules[0].host}{"\n"}' || true
  echo "Cert served (SNI):"
  echo | openssl s_client -connect "${ZAMMAD_HOST}:443" -servername "${ZAMMAD_HOST}" 2>/dev/null \
    | openssl x509 -noout -subject -issuer || true
fi


sec "n8n external"
if [[ -n "$n8n_host" ]]; then
  code="$(curl -sS -m 12 -o /dev/null -w '%{http_code}' "https://${n8n_host}/" || true)"
  [[ "$code" == "200" ]] || fail "n8n not 200 (code=$code): https://${n8n_host}/"
  pass "n8n 200: https://${n8n_host}/"
else
  warn "n8n ingress not found (namespace may be empty)"
fi

hr
echo "Portal:  https://${portal_host}/"
echo "Airbyte: https://${airbyte_host:-<none>}/"
echo "Zammad:  https://${zammad_host:-<none>}/"
echo "n8n:     https://${n8n_host:-<none>}/"
echo "Result:  PASS"
