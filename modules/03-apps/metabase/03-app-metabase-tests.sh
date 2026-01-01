#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/../../../00-env.sh"

require_cmd kubectl
NS="${ANALYTICS_NS}"

kubectl -n "${NS}" get deploy metabase >/dev/null
kubectl -n "${NS}" rollout status deploy/metabase --timeout=300s
kubectl -n "${NS}" get svc metabase >/dev/null

# Smoke test in-cluster
kubectl -n "${NS}" run metabase-smoke --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -fsS http://metabase:3000/api/health >/dev/null

log "[03-metabase][tests] OK"
