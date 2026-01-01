#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/../../../00-env.sh"

require_cmd kubectl
NS="${N8N_NS}"

kubectl -n "${NS}" get deploy n8n >/dev/null
kubectl -n "${NS}" rollout status deploy/n8n --timeout=300s
kubectl -n "${NS}" get svc n8n >/dev/null

kubectl -n "${NS}" run n8n-smoke --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -fsS http://n8n:5678/ >/dev/null

log "[03-n8n][tests] OK"
