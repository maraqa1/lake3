#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/../../00-env.sh"

require_cmd kubectl
require_var PLATFORM_NS
require_var PORTAL_API_SVC

NS="${PLATFORM_NS}"

kubectl -n "${NS}" get deploy portal-api >/dev/null
kubectl -n "${NS}" rollout status deploy/portal-api --timeout=180s
kubectl -n "${NS}" get svc "${PORTAL_API_SVC}" >/dev/null
kubectl -n "${NS}" get ingress portal-api-ingress >/dev/null

kubectl -n "${NS}" run portal-api-smoke --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -fsS "http://${PORTAL_API_SVC}/" >/dev/null

log "[04-portal-api][tests] OK"
