#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# MODULE 03E — APP (n8n) — PRODUCTION DROP-IN (REPEATABLE)
# FILE: 03-app-n8n.sh
#
# Guarantees (idempotent):
# - Namespace: ${N8N_NS:-n8n}
# - Postgres: db + role for n8n on shared OpenKPI Postgres (in-cluster psql pod)
# - Secret: n8n/n8n-secret (db creds + n8n auth/encryption)
# - PVC: n8n/n8n-data-pvc (workflow binary data, local-path)
# - Deployment + Service + Ingress (+ optional cert-manager Certificate)
#
# Contract source of truth:
# - /root/open-kpi.env (N8N_HOST, N8N_PASS, N8N_ENCRYPTION_KEY, POSTGRES_*) :contentReference[oaicite:0]{index=0}
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Walk up to OpenKPI root (where 00-env.sh exists)
ROOT="${HERE}"
while [[ "${ROOT}" != "/" && ! -f "${ROOT}/00-env.sh" ]]; do ROOT="$(dirname "${ROOT}")"; done
[[ -f "${ROOT}/00-env.sh" ]] || { echo "[FATAL] cannot find 00-env.sh above ${HERE}"; exit 1; }

# shellcheck source=/dev/null
. "${ROOT}/00-env.sh"
# shellcheck source=/dev/null
. "${ROOT}/00-lib.sh"

require_cmd kubectl

MODULE_ID="03E"
NS="${N8N_NS:-n8n}"

# Ingress/TLS contract
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
TLS_MODE="${TLS_MODE:-off}"                       # off | per-host-http01 | letsencrypt | etc.
CLUSTER_ISSUER="${CLUSTER_ISSUER:-${CERT_CLUSTER_ISSUER:-}}"
N8N_HOST="${N8N_HOST:?missing N8N_HOST}"
URL_SCHEME="http"; [[ "${TLS_MODE}" != "off" ]] && URL_SCHEME="https"

# Shared Postgres contract
PG_SVC="${POSTGRES_SERVICE:?missing POSTGRES_SERVICE}"
PG_PORT="${POSTGRES_PORT:-5432}"
PG_ADMIN_USER="${POSTGRES_USER:?missing POSTGRES_USER}"
PG_ADMIN_PASS="${POSTGRES_PASSWORD:?missing POSTGRES_PASSWORD}"

# n8n app contract
N8N_DB_NAME="${N8N_DB_NAME:-n8n}"
N8N_DB_USER="${N8N_DB_USER:-n8n}"
N8N_DB_PASS="${N8N_DB_PASS:-${N8N_PASS:?missing N8N_PASS}}"
N8N_BASIC_AUTH_USER="${N8N_BASIC_AUTH_USER:-admin}"
N8N_BASIC_AUTH_PASS="${N8N_PASS:?missing N8N_PASS}"
N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:?missing N8N_ENCRYPTION_KEY}"
N8N_IMAGE="${N8N_IMAGE:-n8nio/n8n:1.86.0}"

APP_LABEL_KEY="app.kubernetes.io/name"
APP_LABEL_VAL="n8n"

log "[${MODULE_ID}][n8n] start (ns=${NS}, host=${N8N_HOST}, tls=${TLS_MODE})"

log "[${MODULE_ID}][n8n] ensure namespace: ${NS}"
kubectl_k apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
YAML

# ------------------------------------------------------------------------------
# 01) Bootstrap Postgres objects (Job; repeatable; fail-fast)
# ------------------------------------------------------------------------------
log "[${MODULE_ID}][n8n] bootstrap Postgres objects (db=${N8N_DB_NAME}, role=${N8N_DB_USER}) [idempotent]"

BOOT_JOB="n8n-db-bootstrap"

kubectl -n "${NS}" delete job "${BOOT_JOB}" --ignore-not-found >/dev/null 2>&1 || true

cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${BOOT_JOB}
  labels:
    ${APP_LABEL_KEY}: ${APP_LABEL_VAL}
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        ${APP_LABEL_KEY}: ${APP_LABEL_VAL}
    spec:
      restartPolicy: Never
      containers:
        - name: psql
          image: postgres:16
          env:
            - name: ADMIN_PGPASSWORD
              value: "${PG_ADMIN_PASS}"
            - name: ADMIN_USER
              value: "${PG_ADMIN_USER}"
            - name: PGHOST
              value: "${PG_SVC}"
            - name: PGPORT
              value: "${PG_PORT}"
            - name: APP_DB
              value: "${N8N_DB_NAME}"
            - name: APP_ROLE
              value: "${N8N_DB_USER}"
            - name: APP_PASS
              valueFrom:
                secretKeyRef:
                  name: n8n-secret
                  key: db-password
          command: ["bash","-lc"]
          args:
            - |
              set -euo pipefail

              export PGPASSWORD="\${ADMIN_PGPASSWORD}"

              echo "[bootstrap] wait postgres..."
              for i in {1..90}; do
                psql "host=\${PGHOST} port=\${PGPORT} user=\${ADMIN_USER} dbname=postgres sslmode=disable" -c "select 1" >/dev/null 2>&1 && break
                sleep 2
              done

              echo "[bootstrap] role exists?"
              ROLE_EXISTS="\$(psql "host=\${PGHOST} port=\${PGPORT} user=\${ADMIN_USER} dbname=postgres sslmode=disable" \
                -tAc "select 1 from pg_roles where rolname='\${APP_ROLE}'" || true)"
              ROLE_EXISTS="\${ROLE_EXISTS//[[:space:]]/}"

              if [[ "\${ROLE_EXISTS}" != "1" ]]; then
                psql "host=\${PGHOST} port=\${PGPORT} user=\${ADMIN_USER} dbname=postgres sslmode=disable" \
                  -c "CREATE ROLE \"\${APP_ROLE}\" LOGIN PASSWORD '\${APP_PASS}';"
              else
                psql "host=\${PGHOST} port=\${PGPORT} user=\${ADMIN_USER} dbname=postgres sslmode=disable" \
                  -c "ALTER ROLE \"\${APP_ROLE}\" WITH LOGIN PASSWORD '\${APP_PASS}';"
              fi

              echo "[bootstrap] db exists?"
              DB_EXISTS="\$(psql "host=\${PGHOST} port=\${PGPORT} user=\${ADMIN_USER} dbname=postgres sslmode=disable" \
                -tAc "select 1 from pg_database where datname='\${APP_DB}'" || true)"
              DB_EXISTS="\${DB_EXISTS//[[:space:]]/}"

              if [[ "\${DB_EXISTS}" != "1" ]]; then
                psql "host=\${PGHOST} port=\${PGPORT} user=\${ADMIN_USER} dbname=postgres sslmode=disable" \
                  -c "CREATE DATABASE \"\${APP_DB}\" OWNER \"\${APP_ROLE}\";"
              fi

              psql "host=\${PGHOST} port=\${PGPORT} user=\${ADMIN_USER} dbname=postgres sslmode=disable" \
                -c "ALTER DATABASE \"\${APP_DB}\" OWNER TO \"\${APP_ROLE}\";"
              psql "host=\${PGHOST} port=\${PGPORT} user=\${ADMIN_USER} dbname=postgres sslmode=disable" \
                -c "GRANT ALL PRIVILEGES ON DATABASE \"\${APP_DB}\" TO \"\${APP_ROLE}\";"

              echo "[bootstrap] verify login as app role"
              PGPASSWORD="\${APP_PASS}" psql "host=\${PGHOST} port=\${PGPORT} user=\${APP_ROLE} dbname=\${APP_DB} sslmode=disable" \
                -c "select current_user, current_database();" >/dev/null

              echo "[bootstrap] done"
YAML

log "[${MODULE_ID}][n8n] wait db bootstrap job completion (fail-fast)"
kubectl -n "${NS}" wait --for=condition=complete "job/${BOOT_JOB}" --timeout=300s >/dev/null || {
  kubectl -n "${NS}" get pods -l job-name="${BOOT_JOB}" -o wide || true
  POD="$(kubectl -n "${NS}" get pods -l job-name="${BOOT_JOB}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${POD}" ]] && kubectl -n "${NS}" logs "${POD}" -c psql --tail=800 || true
  die "[${MODULE_ID}][n8n] db bootstrap failed"
}

POD="$(kubectl -n "${NS}" get pods -l job-name="${BOOT_JOB}" -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "${NS}" logs "${POD}" -c psql --tail=200 || true
kubectl -n "${NS}" delete job "${BOOT_JOB}" --ignore-not-found >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 02) Secrets + PVC
# ------------------------------------------------------------------------------
log "[${MODULE_ID}][n8n] apply secret + pvc"

kubectl_k -n "${NS}" apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: n8n-secret
type: Opaque
stringData:
  # DB
  db-host: "${PG_SVC}"
  db-port: "${PG_PORT}"
  db-name: "${N8N_DB_NAME}"
  db-user: "${N8N_DB_USER}"
  db-password: "${N8N_DB_PASS}"

  # App auth/encryption
  n8n-basic-user: "${N8N_BASIC_AUTH_USER}"
  n8n-basic-pass: "${N8N_BASIC_AUTH_PASS}"
  n8n-encryption-key: "${N8N_ENCRYPTION_KEY}"

  # Public URL
  n8n-host: "${N8N_HOST}"
  n8n-protocol: "${URL_SCHEME}"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: n8n-data-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: "${STORAGE_CLASS:-local-path}"
  resources:
    requests:
      storage: "${N8N_PVC_SIZE:-5Gi}"
YAML

# ------------------------------------------------------------------------------
# 03) Deployment + Service
# ------------------------------------------------------------------------------
log "[${MODULE_ID}][n8n] deploy workload"

kubectl_k -n "${NS}" apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: n8n
  labels:
    ${APP_LABEL_KEY}: ${APP_LABEL_VAL}
spec:
  replicas: 1
  selector:
    matchLabels:
      ${APP_LABEL_KEY}: ${APP_LABEL_VAL}
  template:
    metadata:
      labels:
        ${APP_LABEL_KEY}: ${APP_LABEL_VAL}
    spec:
      securityContext:
        fsGroup: 1000
      containers:
        - name: n8n
          image: ${N8N_IMAGE}
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 5678
          env:
            # Core
            - name: N8N_HOST
              valueFrom: { secretKeyRef: { name: n8n-secret, key: n8n-host } }
            - name: N8N_PROTOCOL
              valueFrom: { secretKeyRef: { name: n8n-secret, key: n8n-protocol } }
            - name: N8N_PORT
              value: "5678"
            - name: WEBHOOK_URL
              value: "${URL_SCHEME}://${N8N_HOST}/"

            # Basic auth
            - name: N8N_BASIC_AUTH_ACTIVE
              value: "true"
            - name: N8N_BASIC_AUTH_USER
              valueFrom: { secretKeyRef: { name: n8n-secret, key: n8n-basic-user } }
            - name: N8N_BASIC_AUTH_PASSWORD
              valueFrom: { secretKeyRef: { name: n8n-secret, key: n8n-basic-pass } }

            # Encryption
            - name: N8N_ENCRYPTION_KEY
              valueFrom: { secretKeyRef: { name: n8n-secret, key: n8n-encryption-key } }

            # DB (Postgres)
            - name: DB_TYPE
              value: "postgresdb"
            - name: DB_POSTGRESDB_HOST
              valueFrom: { secretKeyRef: { name: n8n-secret, key: db-host } }
            - name: DB_POSTGRESDB_PORT
              valueFrom: { secretKeyRef: { name: n8n-secret, key: db-port } }
            - name: DB_POSTGRESDB_DATABASE
              valueFrom: { secretKeyRef: { name: n8n-secret, key: db-name } }
            - name: DB_POSTGRESDB_USER
              valueFrom: { secretKeyRef: { name: n8n-secret, key: db-user } }
            - name: DB_POSTGRESDB_PASSWORD
              valueFrom: { secretKeyRef: { name: n8n-secret, key: db-password } }

            # Hardening + deterministic behavior
            - name: N8N_DIAGNOSTICS_ENABLED
              value: "false"
            - name: N8N_PERSONALIZATION_ENABLED
              value: "false"
            - name: N8N_VERSION_NOTIFICATIONS_ENABLED
              value: "false"

            # Binary data (keep on PVC)
            - name: N8N_BINARY_DATA_MODE
              value: "filesystem"
            - name: N8N_BINARY_DATA_STORAGE_PATH
              value: "/home/node/.n8n/binaryData"

          volumeMounts:
            - name: data
              mountPath: /home/node/.n8n
          readinessProbe:
            httpGet: { path: /healthz, port: http }
            initialDelaySeconds: 20
            periodSeconds: 10
            timeoutSeconds: 3
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            initialDelaySeconds: 60
            periodSeconds: 20
            timeoutSeconds: 3
          resources:
            requests:
              cpu: "100m"
              memory: "256Mi"
            limits:
              cpu: "1000m"
              memory: "1Gi"
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: n8n-data-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: n8n
spec:
  selector:
    ${APP_LABEL_KEY}: ${APP_LABEL_VAL}
  ports:
    - name: http
      port: 80
      targetPort: 5678
YAML

# ------------------------------------------------------------------------------
# 04) Ingress (+ cert-manager per-host Certificate if TLS enabled)
# ------------------------------------------------------------------------------
log "[${MODULE_ID}][n8n] apply ingress"

kubectl_k -n "${NS}" apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: n8n-ingress
  annotations:
    kubernetes.io/ingress.class: "${INGRESS_CLASS}"
spec:
  ingressClassName: "${INGRESS_CLASS}"
  rules:
    - host: ${N8N_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: n8n
                port:
                  number: 80
YAML

if [[ "${TLS_MODE}" != "off" ]]; then
  : "${CLUSTER_ISSUER:?missing CLUSTER_ISSUER/CERT_CLUSTER_ISSUER for TLS}"
  log "[${MODULE_ID}][n8n] TLS enabled: create Certificate + bind ingress tls"
  kubectl_k -n "${NS}" apply -f - <<YAML
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: n8n-cert
spec:
  secretName: n8n-tls
  issuerRef:
    kind: ClusterIssuer
    name: ${CLUSTER_ISSUER}
  dnsNames:
    - ${N8N_HOST}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: n8n-ingress
  annotations:
    kubernetes.io/ingress.class: "${INGRESS_CLASS}"
spec:
  ingressClassName: "${INGRESS_CLASS}"
  tls:
    - hosts: [${N8N_HOST}]
      secretName: n8n-tls
  rules:
    - host: ${N8N_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: n8n
                port:
                  number: 80
YAML
fi

# ------------------------------------------------------------------------------
# 05) Rollout verification + deterministic diagnostics
# ------------------------------------------------------------------------------
log "[${MODULE_ID}][n8n] rollout"
kubectl -n "${NS}" rollout status deploy/n8n --timeout=180s || {
  kubectl -n "${NS}" get pods -o wide || true
  kubectl -n "${NS}" describe deploy/n8n | sed -n '1,240p' || true
  kubectl -n "${NS}" logs deploy/n8n --tail=300 || true
  exit 1
}

log "[${MODULE_ID}][n8n] OK: ${URL_SCHEME}://${N8N_HOST}/"
