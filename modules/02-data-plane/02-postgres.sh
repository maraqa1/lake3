#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 02-postgres.sh — OpenKPI Module 02 (Core Data Plane): Postgres
#
# Contract / Design:
# - Single source of truth: /root/open-kpi.env loaded by 00-env.sh
# - Idempotent: safe to run repeatedly (kubectl apply only; no rotations)
# - Namespace: OPENKPI_NS
# - Storage: one pre-created PVC (external PVC model) using STORAGE_CLASS
# - Security: Postgres runs as non-root (uid/gid 999); initContainer fixes perms
# - Readiness: probes ensure Pod Ready == Postgres accepting TCP connections
# - Tests: deterministic end-to-end checks at the end
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/../../00-env.sh"

log "[02-postgres] start"

# ------------------------------------------------------------------------------
# [SECTION][helpers] kubectl wrapper fallback
# ------------------------------------------------------------------------------
if ! command -v kubectl_k >/dev/null 2>&1; then
  kubectl_k(){ kubectl "$@"; }
fi

# ------------------------------------------------------------------------------
# [SECTION][contract] Requirements
# ------------------------------------------------------------------------------
require_cmd kubectl
require_cmd grep

require_var OPENKPI_NS
require_var STORAGE_CLASS

# Credentials must come from env contract (do not generate/rotate here)
require_var POSTGRES_DB
require_var POSTGRES_USER
require_var POSTGRES_PASSWORD

NS="${OPENKPI_NS}"

# Canonical resource names (stable, referenced by other modules)
PG_SECRET="openkpi-postgres-secret"
PG_PVC="openkpi-postgres-pvc"
PG_SVC="openkpi-postgres"
PG_STS="openkpi-postgres"

# Tunables (safe defaults; override via env if needed)
PG_IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
PG_STORAGE_SIZE="${POSTGRES_STORAGE_SIZE:-30Gi}"
PG_MAX_CONNECTIONS="${POSTGRES_MAX_CONNECTIONS:-200}"

# ------------------------------------------------------------------------------
# [SECTION][namespace] Ensure namespace exists
# ------------------------------------------------------------------------------
kubectl_k get ns "${NS}" >/dev/null 2>&1 || kubectl_k create ns "${NS}"

# ------------------------------------------------------------------------------
# [SECTION][secret] Postgres credentials (idempotent apply)
# ------------------------------------------------------------------------------
cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${PG_SECRET}
type: Opaque
stringData:
  POSTGRES_DB: "${POSTGRES_DB}"
  POSTGRES_USER: "${POSTGRES_USER}"
  POSTGRES_PASSWORD: "${POSTGRES_PASSWORD}"
YAML

# ------------------------------------------------------------------------------
# [SECTION][pvc] PersistentVolumeClaim (external PVC model)
# ------------------------------------------------------------------------------
cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PG_PVC}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: ${PG_STORAGE_SIZE}
YAML

# ------------------------------------------------------------------------------
# [SECTION][service] ClusterIP service for in-cluster clients
# ------------------------------------------------------------------------------
cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${PG_SVC}
spec:
  type: ClusterIP
  selector:
    app: ${PG_STS}
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
YAML

# ------------------------------------------------------------------------------
# [SECTION][statefulset] StatefulSet using pre-created PVC + perms-safe init
# ------------------------------------------------------------------------------
cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ${PG_STS}
spec:
  serviceName: ${PG_SVC}
  replicas: 1
  selector:
    matchLabels:
      app: ${PG_STS}
  template:
    metadata:
      labels:
        app: ${PG_STS}
    spec:
      securityContext:
        fsGroup: 999
        fsGroupChangePolicy: "OnRootMismatch"
      initContainers:
        - name: fix-perms
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              set -e
              mkdir -p /var/lib/postgresql/data/pgdata
              chown -R 999:999 /var/lib/postgresql/data
          securityContext:
            runAsUser: 0
          volumeMounts:
            - name: pgdata
              mountPath: /var/lib/postgresql/data
      containers:
        - name: postgres
          image: ${PG_IMAGE}
          imagePullPolicy: IfNotPresent
          securityContext:
            runAsUser: 999
            runAsGroup: 999
            allowPrivilegeEscalation: false
          ports:
            - name: postgres
              containerPort: 5432
          envFrom:
            - secretRef:
                name: ${PG_SECRET}
          env:
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          args:
            - "-c"
            - "max_connections=${PG_MAX_CONNECTIONS}"
          startupProbe:
            exec:
              command: ["sh","-lc","pg_isready -h 127.0.0.1 -p 5432 -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\""]
            failureThreshold: 60
            periodSeconds: 2
            timeoutSeconds: 2
          readinessProbe:
            exec:
              command: ["sh","-lc","pg_isready -h 127.0.0.1 -p 5432 -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\""]
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 6
          livenessProbe:
            exec:
              command: ["sh","-lc","pg_isready -h 127.0.0.1 -p 5432 -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\""]
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 6
          volumeMounts:
            - name: pgdata
              mountPath: /var/lib/postgresql/data
      volumes:
        - name: pgdata
          persistentVolumeClaim:
            claimName: ${PG_PVC}
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Retain
    whenScaled: Retain
  updateStrategy:
    type: RollingUpdate
  podManagementPolicy: OrderedReady
YAML

# ------------------------------------------------------------------------------
# [SECTION][rollout] Wait for StatefulSet
# ------------------------------------------------------------------------------
kubectl_k -n "${NS}" rollout status statefulset/${PG_STS} --timeout=300s

# ------------------------------------------------------------------------------
# [SECTION][tests] Deterministic validation (PVC + Ready + TCP query)
# ------------------------------------------------------------------------------
kubectl_k -n "${NS}" get pvc "${PG_PVC}" -o jsonpath='{.status.phase}{"\n"}' | grep -q '^Bound$'
kubectl_k -n "${NS}" wait --for=condition=Ready pod -l app="${PG_STS}" --timeout=180s

POD="$(kubectl_k -n "${NS}" get pod -l app="${PG_STS}" -o jsonpath='{.items[0].metadata.name}')"

if ! kubectl_k -n "${NS}" exec "${POD}" -- sh -lc 'pg_isready -h 127.0.0.1 -p 5432 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'; then
  echo "[FATAL] Postgres not accepting TCP connections; printing logs" >&2
  kubectl_k -n "${NS}" logs "${POD}" -c postgres --tail=200 >&2 || true
  exit 2
fi

kubectl_k -n "${NS}" exec "${POD}" -- sh -lc 'psql -h 127.0.0.1 -p 5432 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select 1;"'

log "[02-postgres] done"
