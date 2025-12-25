#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# MODULE 02 — DATA PLANE (Postgres + MinIO)
# FILE: 02-data-plane.sh
#
# Stable internal endpoints (in-cluster):
#   OPENKPI_PG_DSN="postgresql://${OPENKPI_PG_USER}:${OPENKPI_PG_PASSWORD}@openkpi-postgres.${NS}.svc.cluster.local:5432/${OPENKPI_PG_DB}"
#   OPENKPI_MINIO_ENDPOINT="http://openkpi-minio.${NS}.svc.cluster.local:9000"
#   OPENKPI_MINIO_CONSOLE="http://openkpi-minio.${NS}.svc.cluster.local:9001"
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/00-env.sh"
. "${HERE}/00-lib.sh"

: "${KUBECONFIG:=/root/.kube/config}"
export KUBECONFIG


require_cmd kubectl

: "${NS:=open-kpi}"
: "${STORAGE_CLASS:=local-path}"

# Expected from 00-env.sh (/root/open-kpi.env contract)
: "${OPENKPI_PG_DB:?missing OPENKPI_PG_DB}"
: "${OPENKPI_PG_USER:?missing OPENKPI_PG_USER}"
: "${OPENKPI_PG_PASSWORD:?missing OPENKPI_PG_PASSWORD}"

: "${OPENKPI_MINIO_ROOT_USER:?missing OPENKPI_MINIO_ROOT_USER}"
: "${OPENKPI_MINIO_ROOT_PASSWORD:?missing OPENKPI_MINIO_ROOT_PASSWORD}"

log "[02][DATA] Namespace=${NS} StorageClass=${STORAGE_CLASS}"

ensure_ns "${NS}"

# ------------------------------------------------------------------------------
# Secrets (create once, apply-safe)
# ------------------------------------------------------------------------------
log "[02][DATA] Apply secrets (openkpi-postgres-secret, openkpi-minio-secret)"

kubectl -n "${NS}" create secret generic openkpi-postgres-secret \
  --from-literal=POSTGRES_DB="${OPENKPI_PG_DB}" \
  --from-literal=POSTGRES_USER="${OPENKPI_PG_USER}" \
  --from-literal=POSTGRES_PASSWORD="${OPENKPI_PG_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "${NS}" create secret generic openkpi-minio-secret \
  --from-literal=MINIO_ROOT_USER="${OPENKPI_MINIO_ROOT_USER}" \
  --from-literal=MINIO_ROOT_PASSWORD="${OPENKPI_MINIO_ROOT_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ------------------------------------------------------------------------------
# Postgres (StatefulSet + PVC + ClusterIP Service)
# - Non-root runtime user
# - Init container fixes PVC permissions (root) then main runs as non-root
# ------------------------------------------------------------------------------
log "[02][DATA] Apply Postgres (StatefulSet + Service + PVC template)"

apply_yaml "
apiVersion: v1
kind: Service
metadata:
  name: openkpi-postgres
  namespace: ${NS}
  labels:
    app: openkpi-postgres
spec:
  type: ClusterIP
  selector:
    app: openkpi-postgres
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: openkpi-postgres
  namespace: ${NS}
  labels:
    app: openkpi-postgres
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
    spec:
      securityContext: {}
      initContainers:
        - name: init-permissions
          image: postgres:16
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - -c
            - |
              set -e
              mkdir -p /var/lib/postgresql/data
              chown -R 999:999 /var/lib/postgresql/data
              chmod 700 /var/lib/postgresql/data
          securityContext:
            runAsUser: 0
            runAsGroup: 0
            allowPrivilegeEscalation: false
          volumeMounts:
            - name: pgdata
              mountPath: /var/lib/postgresql/data
      containers:
        - name: postgres
          image: postgres:16
          imagePullPolicy: IfNotPresent
          ports:
            - name: postgres
              containerPort: 5432
          envFrom:
            - secretRef:
                name: openkpi-postgres-secret
          env:
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          livenessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - pg_isready -U \"\${POSTGRES_USER}\" -d \"\${POSTGRES_DB}\" -h 127.0.0.1 -p 5432
            initialDelaySeconds: 25
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6
          readinessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - pg_isready -U \"\${POSTGRES_USER}\" -d \"\${POSTGRES_DB}\" -h 127.0.0.1 -p 5432
            initialDelaySeconds: 10
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 12
          securityContext:
            runAsNonRoot: true
            runAsUser: 999
            runAsGroup: 999
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
          volumeMounts:
            - name: pgdata
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata:
        name: pgdata
        labels:
          app: openkpi-postgres
      spec:
        accessModes: [\"ReadWriteOnce\"]
        storageClassName: ${STORAGE_CLASS}
        resources:
          requests:
            storage: 20Gi
"

# ------------------------------------------------------------------------------
# MinIO (StatefulSet + PVC + ClusterIP Service)
# - Non-root UID 1000 with fsGroup 1000
# ------------------------------------------------------------------------------
log "[02][DATA] Apply MinIO (StatefulSet + Service + PVC template)"

apply_yaml "
apiVersion: v1
kind: Service
metadata:
  name: openkpi-minio
  namespace: ${NS}
  labels:
    app: openkpi-minio
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
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: openkpi-minio
  namespace: ${NS}
  labels:
    app: openkpi-minio
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
    spec:
      securityContext:
        fsGroup: 1000
      containers:
        - name: minio
          image: minio/minio:RELEASE.2025-07-23T15-54-02Z
          imagePullPolicy: IfNotPresent
          args:
            - server
            - /data
            - --console-address
            - \":9001\"
          ports:
            - name: s3
              containerPort: 9000
            - name: console
              containerPort: 9001
          envFrom:
            - secretRef:
                name: openkpi-minio-secret
          env:
            - name: MINIO_BROWSER_REDIRECT_URL
              value: \"\"
          livenessProbe:
            httpGet:
              path: /minio/health/live
              port: 9000
            initialDelaySeconds: 25
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6
          readinessProbe:
            httpGet:
              path: /minio/health/ready
              port: 9000
            initialDelaySeconds: 10
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 12
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            runAsGroup: 1000
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
          volumeMounts:
            - name: miniostorage
              mountPath: /data
  volumeClaimTemplates:
    - metadata:
        name: miniostorage
        labels:
          app: openkpi-minio
      spec:
        accessModes: [\"ReadWriteOnce\"]
        storageClassName: ${STORAGE_CLASS}
        resources:
          requests:
            storage: 50Gi
"

# ------------------------------------------------------------------------------
# Wait for readiness
# ------------------------------------------------------------------------------
log "[02][DATA] Wait for Postgres readiness"
kubectl_wait_sts "${NS}" "openkpi-postgres" "600s"

log "[02][DATA] Wait for MinIO readiness"
kubectl_wait_sts "${NS}" "openkpi-minio" "600s"

# ------------------------------------------------------------------------------
# Output quick status + endpoints
# ------------------------------------------------------------------------------
log "[02][DATA] Status"
kubectl -n "${NS}" get svc openkpi-postgres openkpi-minio -o wide
kubectl -n "${NS}" get sts openkpi-postgres openkpi-minio -o wide
kubectl -n "${NS}" get pods -l app=openkpi-postgres -o wide
kubectl -n "${NS}" get pods -l app=openkpi-minio -o wide

log "[02][DATA] In-cluster endpoints"
echo "OPENKPI_PG_DSN=postgresql://${OPENKPI_PG_USER}:${OPENKPI_PG_PASSWORD}@openkpi-postgres.${NS}.svc.cluster.local:5432/${OPENKPI_PG_DB}"
echo "OPENKPI_MINIO_ENDPOINT=http://openkpi-minio.${NS}.svc.cluster.local:9000"
echo "OPENKPI_MINIO_CONSOLE=http://openkpi-minio.${NS}.svc.cluster.local:9001"
