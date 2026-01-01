#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/../../../00-env.sh"

require_cmd kubectl

NS="${AIRBYTE_NS}"

kubectl -n "${NS}" get deploy airbyte-server airbyte-worker airbyte-webapp airbyte-workload-api-server airbyte-workload-launcher >/dev/null
kubectl -n "${NS}" get svc airbyte-minio-svc >/dev/null
kubectl -n "${NS}" get secret airbyte-config-secrets >/dev/null

# Confirm env is present on the docstore-critical deployments
for d in airbyte-server airbyte-worker airbyte-workload-api-server airbyte-workload-launcher; do
  kubectl -n "${NS}" get deploy "$d" -o jsonpath='{.spec.template.spec.containers[0].env}' | grep -q 'STORAGE_TYPE' || exit 1
done

kubectl -n "${NS}" rollout status deploy/airbyte-server --timeout=600s
kubectl -n "${NS}" rollout status deploy/airbyte-worker --timeout=600s

log "[03-airbyte][tests] OK"
