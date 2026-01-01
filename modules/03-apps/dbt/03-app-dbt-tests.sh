#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/../../../00-env.sh"

require_cmd kubectl
require_var TRANSFORM_NS

NS="${TRANSFORM_NS}"
kubectl -n "${NS}" get cronjob dbt-run >/dev/null
kubectl -n "${NS}" get secret dbt-secret >/dev/null
kubectl -n "${NS}" get configmap dbt-profiles >/dev/null

log "[03-dbt][tests] OK"
