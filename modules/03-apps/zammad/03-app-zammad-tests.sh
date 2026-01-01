#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/../../../00-env.sh"

require_cmd kubectl
NS="${TICKETS_NS}"

kubectl -n "${NS}" get deploy zammad zammad-redis >/dev/null
kubectl -n "${NS}" rollout status deploy/zammad-redis --timeout=180s
kubectl -n "${NS}" rollout status deploy/zammad --timeout=600s
kubectl -n "${NS}" get svc zammad zammad-redis >/dev/null
kubectl -n "${NS}" get pvc zammad-data-pvc >/dev/null

# smoke test
kubectl -n "${NS}" run zammad-smoke --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -fsS http://zammad/ >/dev/null

log "[03-zammad][tests] OK"
