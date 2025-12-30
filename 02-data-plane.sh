#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 02-data-plane.sh (OpenKPI / k3s) — REPEATABLE INSTALL (NO-RESET)
#
# Single source of truth: /root/open-kpi.env
# Uses contract keys:
#   NS (or NS_OPENKPI), STORAGE_CLASS
#   OPENKPI_PG_DB, OPENKPI_PG_USER, OPENKPI_PG_PASSWORD
#   OPENKPI_MINIO_ROOT_USER, OPENKPI_MINIO_ROOT_PASSWORD
#
# Repeatable rules:
# - Never deletes PVC/STS/SVC
# - Never overwrites existing secrets unless FORCE_SECRETS=1
# - Avoids shell expansion inside YAML (prevents "unbound variable" failures)
# - Applies Services first (prevents "service not found")
#
# Env toggles:
#   FORCE_SECRETS=1  # overwrite secrets from contract (default 0)
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Optional sourcing; script remains functional without these files.
if [[ -f "${HERE}/00-env.sh" ]]; then
  # shellcheck source=/dev/null
  . "${HERE}/00-env.sh"
fi
if [[ -f "${HERE}/00-lib.sh" ]]; then
  # shellcheck source=/dev/null
  . "${HERE}/00-lib.sh"
fi

# ------------------------------------------------------------------------------
# Local helpers (no dependency on 00-lib.sh)
# ------------------------------------------------------------------------------
hr(){ echo "-----------------------------------------------------------------------"; }
sec(){ hr; echo "## $*"; hr; }
fatal(){ echo "FATAL: $*" >&2; exit 1; }
retry(){
  local n="$1" s="$2"; shift 2
  local i=0
  until "$@"; do
    i=$((i+1))
    [[ $i -ge $n ]] && return 1
    sleep "$s"
  done
}
need(){ command -v "$1" >/dev/null 2>&1 || fatal "Missing: $1"; }

need kubectl
need sed
need mktemp

OPENKPI_ENV_FILE="${OPENKPI_ENV_FILE:-/root/open-kpi.env}"
FORCE_SECRETS="${FORCE_SECRETS:-0}"

sec "02-data-plane: load contract (${OPENKPI_ENV_FILE})"
[[ -f "${OPENKPI_ENV_FILE}" ]] || fatal "Missing contract file: ${OPENKPI_ENV_FILE}"
set -a
# shellcheck disable=SC1090
. "${OPENKPI_ENV_FILE}"
set +a

NS_OPENKPI="${OPENKPI_NS:-${NS_OPENKPI:-${NS:-open-kpi}}}"
STORAGE_CLASS="${STORAGE_CLASS:-local-path}"

: "${OPENKPI_PG_DB:?missing OPENKPI_PG_DB in contract}"
: "${OPENKPI_PG_USER:?missing OPENKPI_PG_USER in contract}"
: "${OPENKPI_PG_PASSWORD:?missing OPENKPI_PG_PASSWORD in contract}"
: "${OPENKPI_MINIO_ROOT_USER:?missing OPENKPI_MINIO_ROOT_USER in contract}"
: "${OPENKPI_MINIO_ROOT_PASSWORD:?missing OPENKPI_MINIO_ROOT_PASSWORD in contract}"

sec "02-data-plane: preflight"
kubectl get ns "${NS_OPENKPI}" >/dev/null 2>&1 || kubectl create ns "${NS_OPENKPI}" >/dev/null
kubectl get sc "${STORAGE_CLASS}" >/dev/null 2>&1 || fatal "StorageClass not found: ${STORAGE_CLASS}"

sec "02-data-plane: ensure secrets (no overwrite unless FORCE_SECRETS=1)"

apply_secret_generic() {
  local name="$1"; shift
  if kubectl -n "${NS_OPENKPI}" get secret "${name}" >/dev/null 2>&1; then
    if [[ "${FORCE_SECRETS}" == "1" ]]; then
      echo "Overwriting secret/${name} (FORCE_SECRETS=1)"
    else
      echo "Keeping existing secret/${name}"
      return 0
    fi
  else
    echo "Creating secret/${name}"
  fi

  kubectl -n "${NS_OPENKPI}" create secret generic "${name}" \
    "$@" \
    --dry-run=client -o yaml \
    | kubectl -n "${NS_OPENKPI}" apply -f - >/dev/null
}

apply_secret_generic "openkpi-postgres-secret" \
  --from-literal=POSTGRES_DB="${OPENKPI_PG_DB}" \
  --from-literal=POSTGRES_USER="${OPENKPI_PG_USER}" \
  --from-literal=POSTGRES_PASSWORD="${OPENKPI_PG_PASSWORD}" \
  --from-literal=postgres-db="${OPENKPI_PG_DB}" \
  --from-literal=postgres-user="${OPENKPI_PG_USER}" \
  --from-literal=postgres-password="${OPENKPI_PG_PASSWORD}"


apply_secret_generic "openkpi-minio-secret" \
  --from-literal=MINIO_ROOT_USER="${OPENKPI_MINIO_ROOT_USER}" \
  --from-literal=MINIO_ROOT_PASSWORD="${OPENKPI_MINIO_ROOT_PASSWORD}"

sec "02-data-plane: apply services (must exist before checks)"
kubectl -n "${NS_OPENKPI}" apply -f - <<'YAML' >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: openkpi-postgres
  labels:
    app.kubernetes.io/part-of: openkpi
    app.kubernetes.io/name: postgres
spec:
  type: ClusterIP
  selector:
    app: openkpi-postgres
  ports:
    - name: pg
      port: 5432
      targetPort: 5432
---
apiVersion: v1
kind: Service
metadata:
  name: openkpi-minio
  labels:
    app.kubernetes.io/part-of: openkpi
    app.kubernetes.io/name: minio
spec:
  type: ClusterIP
  selector:
    app: openkpi-minio
  ports:
    - name: s3
      port: 9000
      targetPort: 9000
    - name: console
      port: 9001
      targetPort: 9001
YAML

sec "02-data-plane: apply statefulsets (PVC-backed; no shell expansion)"

TMP_YAML="$(mktemp)"
cat > "${TMP_YAML}" <<'YAML'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: openkpi-postgres
  labels:
    app: openkpi-postgres
    app.kubernetes.io/part-of: openkpi
    app.kubernetes.io/name: postgres
spec:
  serviceName: openkpi-postgres
  replicas: 1
  selector:
    matchLabels:
      app: openkpi-postgres
  template:
    metadata:
      labels:
        app: openkpi-postgres
        app.kubernetes.io/part-of: openkpi
        app.kubernetes.io/name: postgres
    spec:
      securityContext:
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
      initContainers:
      - name: init-perms
        image: busybox:1.36.1
        command: ["sh","-lc"]
        args:
          - |
            set -e
            mkdir -p /var/lib/postgresql/data
            chown -R 999:999 /var/lib/postgresql/data
        securityContext:
          runAsUser: 0
        volumeMounts:
        - name: pgdata
          mountPath: /var/lib/postgresql/data
      containers:
      - name: postgres
        image: postgres:16
        ports:
        - containerPort: 5432
          name: pg
        env:
        - name: POSTGRES_DB
          valueFrom:
            secretKeyRef:
              name: openkpi-postgres-secret
              key: POSTGRES_DB
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef:
              name: openkpi-postgres-secret
              key: POSTGRES_USER
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: openkpi-postgres-secret
              key: POSTGRES_PASSWORD
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        readinessProbe:
          exec:
            command: ["sh","-lc","pg_isready -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\" -h 127.0.0.1"]
          initialDelaySeconds: 10
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 12
        livenessProbe:
          exec:
            command: ["sh","-lc","pg_isready -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\" -h 127.0.0.1"]
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 3
          failureThreshold: 12
        volumeMounts:
        - name: pgdata
          mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
  - metadata:
      name: pgdata
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: __STORAGE_CLASS__
      resources:
        requests:
          storage: 20Gi
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: openkpi-minio
  labels:
    app: openkpi-minio
    app.kubernetes.io/part-of: openkpi
    app.kubernetes.io/name: minio
spec:
  serviceName: openkpi-minio
  replicas: 1
  selector:
    matchLabels:
      app: openkpi-minio
  template:
    metadata:
      labels:
        app: openkpi-minio
        app.kubernetes.io/part-of: openkpi
        app.kubernetes.io/name: minio
    spec:
      securityContext:
        fsGroup: 1000
      containers:
      - name: minio
        image: minio/minio:RELEASE.2025-07-23T15-54-02Z-cpuv1
        args: ["server","/data","--console-address",":9001"]
        ports:
        - containerPort: 9000
          name: s3
        - containerPort: 9001
          name: console
        env:
        - name: MINIO_ROOT_USER
          valueFrom:
            secretKeyRef:
              name: openkpi-minio-secret
              key: MINIO_ROOT_USER
        - name: MINIO_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: openkpi-minio-secret
              key: MINIO_ROOT_PASSWORD
        - name: MINIO_REGION_NAME
          value: "us-east-1"
        securityContext:
          runAsUser: 1000
          runAsGroup: 1000
        readinessProbe:
          httpGet:
            path: /minio/health/ready
            port: 9000
          initialDelaySeconds: 10
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 24
        livenessProbe:
          httpGet:
            path: /minio/health/live
            port: 9000
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 3
          failureThreshold: 12
        volumeMounts:
        - name: miniodata
          mountPath: /data
  volumeClaimTemplates:
  - metadata:
      name: miniodata
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: __STORAGE_CLASS__
      resources:
        requests:
          storage: 50Gi
YAML

sed -i "s/__STORAGE_CLASS__/${STORAGE_CLASS}/g" "${TMP_YAML}"
kubectl -n "${NS_OPENKPI}" apply -f "${TMP_YAML}" >/dev/null
rm -f "${TMP_YAML}"

sec "02-data-plane: wait"
retry 30 2 kubectl -n "${NS_OPENKPI}" get svc openkpi-postgres >/dev/null || fatal "svc/openkpi-postgres missing"
retry 30 2 kubectl -n "${NS_OPENKPI}" get svc openkpi-minio >/dev/null || fatal "svc/openkpi-minio missing"

kubectl -n "${NS_OPENKPI}" rollout status statefulset/openkpi-postgres --timeout=300s
kubectl -n "${NS_OPENKPI}" rollout status statefulset/openkpi-minio --timeout=300s

sec "02-data-plane: sanity dump"
kubectl -n "${NS_OPENKPI}" get pods,svc,sts,pvc -o wide
kubectl -n "${NS_OPENKPI}" get endpoints openkpi-postgres openkpi-minio -o wide

sec "02-data-plane: internal endpoints"
echo "OPENKPI_PG_DSN=postgresql://${OPENKPI_PG_USER}:<PASSWORD>@openkpi-postgres.${NS_OPENKPI}.svc.cluster.local:5432/${OPENKPI_PG_DB}"
echo "OPENKPI_MINIO_ENDPOINT=http://openkpi-minio.${NS_OPENKPI}.svc.cluster.local:9000"
echo "OPENKPI_MINIO_CONSOLE=http://openkpi-minio.${NS_OPENKPI}.svc.cluster.local:9001"
echo "CONTRACT_FILE=${OPENKPI_ENV_FILE}"
