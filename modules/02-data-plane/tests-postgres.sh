#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/../../00-env.sh"

require_cmd kubectl
require_var OPENKPI_NS
require_var POSTGRES_USER
require_var POSTGRES_DB

NS="${OPENKPI_NS}"

kubectl -n "${NS}" get pvc openkpi-postgres-pvc >/dev/null
kubectl -n "${NS}" get svc openkpi-postgres >/dev/null
kubectl -n "${NS}" get sts openkpi-postgres >/dev/null
kubectl -n "${NS}" rollout status sts/openkpi-postgres --timeout=240s

POD="$(kubectl -n "${NS}" get pod -l app=openkpi-postgres -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "${NS}" exec "${POD}" -- psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c "select 1;" >/dev/null

log "[02-postgres][tests] OK"
