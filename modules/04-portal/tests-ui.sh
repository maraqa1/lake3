#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/../../00-env.sh"

require_cmd kubectl
NS="${PLATFORM_NS}"

kubectl -n "${NS}" get deploy "${PORTAL_UI_DEPLOY:-portal-ui}" >/dev/null
kubectl -n "${NS}" rollout status deploy/"${PORTAL_UI_DEPLOY:-portal-ui}" --timeout=180s
kubectl -n "${NS}" get svc "${PORTAL_UI_SVC:-portal-ui}" >/dev/null
kubectl -n "${NS}" get ingress portal-ui-ingress >/dev/null

kubectl -n "${NS}" run portal-ui-smoke --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -fsS "http://${PORTAL_UI_SVC:-portal-ui}/" >/dev/null

log "[04-portal-ui][tests] OK"
