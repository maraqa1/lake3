#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Airbyte ↔ OpenKPI MinIO Storage Wiring (REPEATABLE PATCH)
# Fixes: Airbyte connector-sidecar writeWorkloadOutput -> HTTP 500 due to wrong S3 creds
# Root cause pattern: workload pods inherit wrong AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
# (e.g., "minio"/"minio123") instead of OpenKPI MinIO root creds.
#
# What this patch enforces:
# 1) A stable MinIO alias Service name Airbyte pods can use: airbyte-minio-svc
# 2) A single, authoritative secret containing BOTH key styles used by Airbyte components
# 3) Explicit storage env vars on core deployments + rollout restart
# 4) Proof checks (DNS + MinIO health + env presence)
# ============================================================================

# Airbyte namespace (Airbyte Helm release namespace)
AB_NS="${AB_NS:-airbyte}"

# OpenKPI MinIO namespace + service (where your shared MinIO runs)
OPENKPI_NS="${OPENKPI_NS:-open-kpi}"
OPENKPI_MINIO_SVC="${OPENKPI_MINIO_SVC:-openkpi-minio}" # service name in open-kpi ns

# Alias service name (created in airbyte namespace)
ALIAS_SVC="${ALIAS_SVC:-airbyte-minio-svc}"

# Region (must match your MinIO region + airbyte-s3-config)
S3_REGION="${S3_REGION:-us-east-1}"

# MinIO endpoint via alias service in the Airbyte namespace
MINIO_ENDPOINT="http://${ALIAS_SVC}:9000"

log(){ echo "[AIRBYTE][MINIO-FIX] $*"; }
need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }

need kubectl
need base64

log "1) Create/refresh alias service ${AB_NS}/${ALIAS_SVC} -> ${OPENKPI_MINIO_SVC}.${OPENKPI_NS}.svc.cluster.local"
kubectl -n "${AB_NS}" delete svc "${ALIAS_SVC}" --ignore-not-found >/dev/null 2>&1 || true
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: ${ALIAS_SVC}
  namespace: ${AB_NS}
spec:
  type: ExternalName
  externalName: ${OPENKPI_MINIO_SVC}.${OPENKPI_NS}.svc.cluster.local
YAML

log "2) Read OpenKPI MinIO creds (source of truth: ${OPENKPI_NS}/openkpi-minio-secret)"
MINIO_USER="$(kubectl -n "${OPENKPI_NS}" get secret openkpi-minio-secret -o jsonpath='{.data.MINIO_ROOT_USER}' | base64 -d)"
MINIO_PASS="$(kubectl -n "${OPENKPI_NS}" get secret openkpi-minio-secret -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d)"
: "${MINIO_USER:?missing MINIO_USER}"
: "${MINIO_PASS:?missing MINIO_PASS}"

log "3) Create/refresh Airbyte secret ${AB_NS}/airbyte-config-secrets with BOTH key styles"
kubectl -n "${AB_NS}" create secret generic airbyte-config-secrets \
  --from-literal=s3-access-key-id="${MINIO_USER}" \
  --from-literal=s3-secret-access-key="${MINIO_PASS}" \
  --from-literal=MINIO_ACCESS_KEY_ID="${MINIO_USER}" \
  --from-literal=MINIO_SECRET_ACCESS_KEY="${MINIO_PASS}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "4) Force storage wiring on core Airbyte deployments (overwrite)"
for DEP in airbyte-server airbyte-worker airbyte-workload-api-server airbyte-workload-launcher; do
  kubectl -n "${AB_NS}" set env "deploy/${DEP}" \
    STORAGE_TYPE=MINIO \
    MINIO_ENDPOINT="${MINIO_ENDPOINT}" \
    S3_ENDPOINT="${MINIO_ENDPOINT}" \
    AWS_REGION="${S3_REGION}" \
    AWS_DEFAULT_REGION="${S3_REGION}" \
    S3_PATH_STYLE_ACCESS=true \
    --overwrite >/dev/null
done

log "5) Rollout restart core Airbyte deployments"
kubectl -n "${AB_NS}" rollout restart deploy/airbyte-server >/dev/null
kubectl -n "${AB_NS}" rollout restart deploy/airbyte-worker >/dev/null
kubectl -n "${AB_NS}" rollout restart deploy/airbyte-workload-api-server >/dev/null
kubectl -n "${AB_NS}" rollout restart deploy/airbyte-workload-launcher >/dev/null

log "6) Wait for readiness"
kubectl -n "${AB_NS}" rollout status deploy/airbyte-server --timeout=300s >/dev/null
kubectl -n "${AB_NS}" rollout status deploy/airbyte-worker --timeout=300s >/dev/null

log "7) Proof: alias DNS + MinIO health through alias"
SUF="$(date +%s)-$RANDOM"
kubectl -n "${AB_NS}" run -i --rm --restart=Never "dns-proof-${SUF}" \
  --image=busybox:1.36 --command -- sh -eu -c \
  "nslookup ${ALIAS_SVC}.${AB_NS}.svc.cluster.local >/dev/null; echo OK" >/dev/null
kubectl -n "${AB_NS}" run -i --rm --restart=Never "minio-health-${SUF}" \
  --image=curlimages/curl:8.10.1 --command -- sh -eu -c \
  "curl -fsSI ${MINIO_ENDPOINT}/minio/health/live | head -n 8; echo OK" | sed -n '1,10p'

log "8) Proof: env present on server/worker"
kubectl -n "${AB_NS}" exec deploy/airbyte-server -- printenv | egrep -i 'STORAGE_TYPE|MINIO_ENDPOINT|S3_ENDPOINT|AWS_REGION|AWS_DEFAULT_REGION|S3_PATH_STYLE_ACCESS' | sort
kubectl -n "${AB_NS}" exec deploy/airbyte-worker -- printenv | egrep -i 'STORAGE_TYPE|MINIO_ENDPOINT|S3_ENDPOINT|AWS_REGION|AWS_DEFAULT_REGION|S3_PATH_STYLE_ACCESS' | sort

log "DONE"
