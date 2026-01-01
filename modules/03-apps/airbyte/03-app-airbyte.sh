#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/../../../00-env.sh"

log "[03-airbyte] start"

require_cmd kubectl
require_cmd helm

require_var AIRBYTE_NS
require_var OPENKPI_NS

require_var MINIO_ROOT_USER
require_var MINIO_ROOT_PASSWORD
require_var MINIO_API_PORT
require_var AIRBYTE_S3_REGION

# Namespace
kubectl get ns "${AIRBYTE_NS}" >/dev/null 2>&1 || kubectl create ns "${AIRBYTE_NS}"

# ExternalName alias inside airbyte ns -> OpenKPI MinIO service (permanent fix)
cat <<YAML | kubectl -n "${AIRBYTE_NS}" apply -f -
apiVersion: v1
kind: Service
metadata:
  name: airbyte-minio-svc
spec:
  type: ExternalName
  externalName: openkpi-minio.${OPENKPI_NS}.svc.cluster.local
YAML

# Airbyte config secret: keep BOTH key styles (Airbyte components read different names)
cat <<YAML | kubectl -n "${AIRBYTE_NS}" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: airbyte-config-secrets
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "${MINIO_ROOT_USER}"
  AWS_SECRET_ACCESS_KEY: "${MINIO_ROOT_PASSWORD}"
  s3-access-key-id: "${MINIO_ROOT_USER}"
  s3-secret-access-key: "${MINIO_ROOT_PASSWORD}"
YAML

# Install Airbyte via Helm (baseline; internal DB is OK for now)
helm repo add airbyte https://airbytehq.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

# Pin a stable-ish chart line; adjust later when you freeze versions
AIRBYTE_RELEASE="airbyte"
helm upgrade --install "${AIRBYTE_RELEASE}" airbyte/airbyte \
  -n "${AIRBYTE_NS}" \
  --history-max 5 \
  --timeout 15m

# Wait rollouts for main components that must carry MinIO env
for d in airbyte-server airbyte-worker airbyte-webapp airbyte-workload-api-server airbyte-workload-launcher; do
  kubectl -n "${AIRBYTE_NS}" rollout status deploy/"$d" --timeout=600s || true
done

# Patch env onto the components that touch docstore/storage (permanent fix)
# Keep last occurrence per name implicitly by applying this patch once after Helm.
for d in airbyte-server airbyte-worker airbyte-workload-api-server airbyte-workload-launcher; do
  kubectl -n "${AIRBYTE_NS}" set env deploy/"$d" \
    STORAGE_TYPE=MINIO \
    MINIO_ENDPOINT="http://airbyte-minio-svc:${MINIO_API_PORT}" \
    S3_ENDPOINT="http://airbyte-minio-svc:${MINIO_API_PORT}" \
    AWS_REGION="${AIRBYTE_S3_REGION}" \
    AWS_DEFAULT_REGION="${AIRBYTE_S3_REGION}" \
    S3_PATH_STYLE_ACCESS="true" >/dev/null
done

# Restart to apply patched env
kubectl -n "${AIRBYTE_NS}" rollout restart deploy/airbyte-server deploy/airbyte-worker deploy/airbyte-workload-api-server deploy/airbyte-workload-launcher >/dev/null

# Wait again
kubectl -n "${AIRBYTE_NS}" rollout status deploy/airbyte-server --timeout=600s
kubectl -n "${AIRBYTE_NS}" rollout status deploy/airbyte-worker --timeout=600s
kubectl -n "${AIRBYTE_NS}" rollout status deploy/airbyte-workload-api-server --timeout=600s
kubectl -n "${AIRBYTE_NS}" rollout status deploy/airbyte-workload-launcher --timeout=600s
kubectl -n "${AIRBYTE_NS}" rollout status deploy/airbyte-webapp --timeout=600s || true

log "[03-airbyte] done"
