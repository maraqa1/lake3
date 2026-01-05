#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${HERE}/../../.." && pwd)"

# shellcheck source=/dev/null
. "${ROOT}/00-env.sh"
# shellcheck source=/dev/null
. "${ROOT}/00-lib.sh"

require_cmd kubectl curl

NS="${PLATFORM_NS:-platform}"
HOST="${PORTAL_HOST:?missing PORTAL_HOST}"

log "[04-portal-ui-tests] start"

# 1) deployment ready
kubectl -n "${NS}" rollout status deploy/portal-ui --timeout=180s >/dev/null

# 2) service exists
kubectl -n "${NS}" get svc portal-ui >/dev/null

# 3) ingress exists and has host + "/" path
# Find any ingress in NS that has rule.host == HOST and includes a "/" Prefix path
ING_LINE="$(kubectl -n "${NS}" get ingress -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.rules[*]}{.host}{"\t"}{range .http.paths[*]}{.path}{"|"}{.pathType}{"\t"}{end}{"\n"}{end}{end}' \
  | awk -v h="${HOST}" '$2==h {print $0}' || true)"

echo "${ING_LINE}" | grep -qE $'\t/\|Prefix' || {
  echo "[FAIL] ingress rule not found for host=${HOST} with path=/ (Prefix). Found:"
  kubectl -n "${NS}" get ingress -o wide
  kubectl -n "${NS}" get ingress -o yaml | sed -n '1,220p'
  exit 1
}

# 4) UI reachable and contains expected title text
HTML="$(curl -ksS "https://${HOST}/" || true)"
echo "${HTML}" | grep -q "OpenKPI" || {
  echo "[FAIL] UI html does not contain expected marker"
  echo "${HTML}" | sed -n '1,120p'
  exit 1
}

# 5) API reachable from same host (ingress split)
curl -ksS "https://${HOST}/api/health" | grep -qi "ok" || {
  echo "[FAIL] /api/health not reachable via same host"
  curl -ksS "https://${HOST}/api/health" || true
  exit 1
}

# 6) summary reachable
curl -ksS "https://${HOST}/api/summary" >/dev/null || {
  echo "[FAIL] /api/summary not reachable via same host"
  curl -ksS "https://${HOST}/api/summary" || true
  exit 1
}

log "[04-portal-ui-tests] OK"
