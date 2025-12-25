#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# MODULE 03B — APP: n8n (Workflow Automation)
#
# File: 03-app-n8n.sh
#
# Purpose
# - Deploy n8n into Kubernetes as a first-class Open KPI application.
# - Back n8n with shared PostgreSQL (data-plane) using a dedicated database + role.
# - Expose n8n via Ingress only (no NodePorts), with optional per-host TLS.
# - Persist n8n state to a PVC (STORAGE_CLASS).
#
# Inputs (from 00-env.sh contract)
# - NS (default: open-kpi)                        Shared data-plane namespace
# - INGRESS_CLASS (traefik|nginx)                 Ingress controller class
# - TLS_MODE (off|per-host-http01)                TLS behavior
# - STORAGE_CLASS (default: local-path)           StorageClass for PVCs
# - N8N_HOST                                      Public hostname for Ingress
# - OPENKPI_PG_HOST / OPENKPI_PG_PORT (optional)  Postgres service endpoint
# - N8N_DB_PASSWORD or N8N_PASS                   Password for role n8n_user
# - N8N_ENCRYPTION_KEY (optional)                 n8n credential encryption key
#
# Kubernetes Objects Created/Managed
# - Namespace: n8n
# - Secret:    n8n/n8n-secret (DB_PASSWORD, optional N8N_ENCRYPTION_KEY)
# - PVC:       n8n/n8n-data (RWO, STORAGE_CLASS)
# - Deployment:n8n/n8n
# - Service:   n8n/n8n (ClusterIP)
# - Ingress:   n8n/n8n (host: N8N_HOST, path: /)
# - Certificate (TLS_MODE=per-host-http01): n8n/n8n-cert -> Secret n8n/n8n-tls
#
# Data-Plane Dependencies
# - Secret:    open-kpi/openkpi-postgres-secret (POSTGRES_DB/USER/PASSWORD)
# - Service:   open-kpi/openkpi-postgres (Postgres ClusterIP)
#
# Database Contract (enforced by this module)
# - Database:  n8n
# - Role:      n8n_user (LOGIN)
# - Password:  exactly matches n8n/n8n-secret:DB_PASSWORD (source of truth)
#
# Operational Guarantees
# - Idempotent: safe to re-run; no destructive changes to user data.
# - Deterministic auth: role password is forced to match n8n-secret.
# - Health: startup/readiness/liveness tuned for slow cold-starts.
# - Access: Ingress-only; internal Service is ClusterIP.
#
# Failure Modes & Diagnostics
# - Postgres bootstrap failures: emits pod logs + describe + events then exits.
# - n8n rollout failures: emits pod describe + logs + events then exits.
#
# Security Notes
# - Secrets are never inlined in manifests; stored in Kubernetes Secrets.
# - No external DB exposure; only cluster-internal Postgres service is used.
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/00-env.sh"
. "${HERE}/00-lib.sh"

: "${KUBECONFIG:=/root/.kube/config}"
export KUBECONFIG

: "${INGRESS_CLASS:?missing INGRESS_CLASS}"
: "${TLS_MODE:?missing TLS_MODE}"
: "${STORAGE_CLASS:?missing STORAGE_CLASS}"
: "${N8N_HOST:?missing N8N_HOST}"

CORE_NS="${NS:-open-kpi}"
N8N_NS="n8n"

N8N_DB="n8n"
N8N_USER="n8n_user"

N8N_DB_PASSWORD="${N8N_DB_PASSWORD:-${N8N_PASS:-}}"
[ -n "${N8N_DB_PASSWORD}" ] || fatal "Missing n8n DB password: set N8N_DB_PASSWORD (or N8N_PASS) in /root/open-kpi.env via 00-env.sh"

N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-}"

OPENKPI_PG_HOST="${OPENKPI_PG_HOST:-openkpi-postgres.${CORE_NS}.svc.cluster.local}"
OPENKPI_PG_PORT="${OPENKPI_PG_PORT:-5432}"

wait_pod_phase() {
  local ns="$1" pod="$2" want="$3" timeout="${4:-300}"
  local start now phase
  start="$(date +%s)"
  while true; do
    phase="$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
    [ "$phase" = "$want" ] && return 0
    [ "$phase" = "Failed" ] && return 1
    now="$(date +%s)"
    if [ $((now-start)) -ge "$timeout" ]; then
      return 2
    fi
    sleep 2
  done
}

log "[03B][n8n] Ensure namespaces"
ensure_ns "${CORE_NS}"
ensure_ns "${N8N_NS}"

log "[03B][n8n] Read Postgres superuser credentials from ${CORE_NS}/openkpi-postgres-secret"
PG_DB="$(kubectl -n "${CORE_NS}" get secret openkpi-postgres-secret -o jsonpath='{.data.POSTGRES_DB}' 2>/dev/null | base64 -d || true)"
PG_USER="$(kubectl -n "${CORE_NS}" get secret openkpi-postgres-secret -o jsonpath='{.data.POSTGRES_USER}' 2>/dev/null | base64 -d || true)"
PG_PASS="$(kubectl -n "${CORE_NS}" get secret openkpi-postgres-secret -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d || true)"

[ -n "${PG_DB}" ] || fatal "Missing POSTGRES_DB in ${CORE_NS}/openkpi-postgres-secret"
[ -n "${PG_USER}" ] || fatal "Missing POSTGRES_USER in ${CORE_NS}/openkpi-postgres-secret"
[ -n "${PG_PASS}" ] || fatal "Missing POSTGRES_PASSWORD in ${CORE_NS}/openkpi-postgres-secret"

log "[03B][n8n] Create/ensure n8n secret in namespace ${N8N_NS}"
kubectl -n "${N8N_NS}" create secret generic n8n-secret \
  --from-literal=DB_PASSWORD="${N8N_DB_PASSWORD}" \
  ${N8N_ENCRYPTION_KEY:+--from-literal=N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY}"} \
  --dry-run=client -o yaml | kubectl apply -f -

N8N_PASS_IN_SECRET="$(kubectl -n "${N8N_NS}" get secret n8n-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d)"
[ -n "${N8N_PASS_IN_SECRET}" ] || fatal "Failed to read DB_PASSWORD from ${N8N_NS}/n8n-secret"

log "[03B][n8n] Ensure dedicated DB and role exist in shared Postgres (idempotent)"
kubectl -n "${CORE_NS}" delete pod openkpi-psql-tmp --ignore-not-found >/dev/null 2>&1 || true

kubectl -n "${CORE_NS}" run openkpi-psql-tmp \
  --image=postgres:16-alpine \
  --restart=Never \
  --env="PGHOST=${OPENKPI_PG_HOST}" \
  --env="PGPORT=${OPENKPI_PG_PORT}" \
  --env="PGUSER=${PG_USER}" \
  --env="PGPASSWORD=${PG_PASS}" \
  --command -- sh -lc "
set -eu
psql -v ON_ERROR_STOP=1 -d '${PG_DB}' -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${N8N_USER}'\" | grep -q 1 \
  || psql -v ON_ERROR_STOP=1 -d '${PG_DB}' -c \"CREATE ROLE \\\"${N8N_USER}\\\" LOGIN;\"
psql -v ON_ERROR_STOP=1 -d '${PG_DB}' -c \"ALTER ROLE \\\"${N8N_USER}\\\" WITH LOGIN PASSWORD '${N8N_PASS_IN_SECRET}';\"

psql -v ON_ERROR_STOP=1 -d '${PG_DB}' -tAc \"SELECT 1 FROM pg_database WHERE datname='${N8N_DB}'\" | grep -q 1 \
  || psql -v ON_ERROR_STOP=1 -d '${PG_DB}' -c \"CREATE DATABASE \\\"${N8N_DB}\\\" OWNER \\\"${N8N_USER}\\\";\"

psql -v ON_ERROR_STOP=1 -d '${PG_DB}' -c \"ALTER DATABASE \\\"${N8N_DB}\\\" OWNER TO \\\"${N8N_USER}\\\";\"
psql -v ON_ERROR_STOP=1 -d '${PG_DB}' -c \"GRANT ALL PRIVILEGES ON DATABASE \\\"${N8N_DB}\\\" TO \\\"${N8N_USER}\\\";\"
" >/dev/null

set +e
wait_pod_phase "${CORE_NS}" openkpi-psql-tmp Succeeded 120
rc=$?
set -e

if [ $rc -ne 0 ]; then
  warn "[03B][n8n] Postgres bootstrap pod did not reach phase Succeeded; dumping diagnostics"
  kubectl -n "${CORE_NS}" get pod openkpi-psql-tmp -o wide || true
  kubectl -n "${CORE_NS}" describe pod openkpi-psql-tmp | sed -n '1,260p' || true
  kubectl -n "${CORE_NS}" get events --sort-by=.lastTimestamp | tail -n 80 || true
  kubectl -n "${CORE_NS}" logs openkpi-psql-tmp --all-containers --tail=200 || true
  fatal "Failed to ensure Postgres DB/role for n8n"
fi

kubectl -n "${CORE_NS}" logs openkpi-psql-tmp --all-containers --tail=200 >/dev/null 2>&1 || true
kubectl -n "${CORE_NS}" delete pod openkpi-psql-tmp --ignore-not-found >/dev/null 2>&1 || true

log "[03B][n8n] Deploy PVC + Deployment + Service + Ingress"
TLS_YAML=""
CERT_YAML=""
if [ "${TLS_MODE}" = "per-host-http01" ]; then
  TLS_YAML="$(cat <<EOF
  tls:
  - hosts:
    - ${N8N_HOST}
    secretName: n8n-tls
EOF
)"
  CERT_YAML="$(cat <<EOF
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: n8n-cert
  namespace: ${N8N_NS}
spec:
  secretName: n8n-tls
  issuerRef:
    kind: ClusterIssuer
    name: letsencrypt-http01
  dnsNames:
  - ${N8N_HOST}
EOF
)"
fi

apply_yaml "$(cat <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: n8n-data
  namespace: ${N8N_NS}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: n8n
  namespace: ${N8N_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: n8n
  template:
    metadata:
      labels:
        app: n8n
    spec:
      securityContext:
        fsGroup: 1000
      containers:
      - name: n8n
        image: n8nio/n8n:latest
        imagePullPolicy: IfNotPresent
        ports:
        - name: http
          containerPort: 5678
        env:
        - name: DB_TYPE
          value: postgresdb
        - name: DB_POSTGRESDB_HOST
          value: ${OPENKPI_PG_HOST}
        - name: DB_POSTGRESDB_PORT
          value: "${OPENKPI_PG_PORT}"
        - name: DB_POSTGRESDB_DATABASE
          value: ${N8N_DB}
        - name: DB_POSTGRESDB_USER
          value: ${N8N_USER}
        - name: DB_POSTGRESDB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: n8n-secret
              key: DB_PASSWORD
        - name: N8N_HOST
          value: ${N8N_HOST}
        - name: N8N_PORT
          value: "5678"
        - name: N8N_LISTEN_ADDRESS
          value: "0.0.0.0"
        - name: N8N_PROTOCOL
          value: $([ "${TLS_MODE}" = "per-host-http01" ] && echo "https" || echo "http")
        - name: WEBHOOK_URL
          value: $([ "${TLS_MODE}" = "per-host-http01" ] && echo "https://${N8N_HOST}/" || echo "http://${N8N_HOST}/")
        - name: N8N_LOG_LEVEL
          value: "info"
$(if kubectl -n "${N8N_NS}" get secret n8n-secret -o jsonpath='{.data.N8N_ENCRYPTION_KEY}' >/dev/null 2>&1; then cat <<'EOK'
        - name: N8N_ENCRYPTION_KEY
          valueFrom:
            secretKeyRef:
              name: n8n-secret
              key: N8N_ENCRYPTION_KEY
EOK
fi)
        volumeMounts:
        - name: n8n-data
          mountPath: /home/node/.n8n
        startupProbe:
          tcpSocket:
            port: 5678
          periodSeconds: 5
          timeoutSeconds: 2
          failureThreshold: 120
        readinessProbe:
          tcpSocket:
            port: 5678
          periodSeconds: 10
          timeoutSeconds: 2
          failureThreshold: 12
        livenessProbe:
          tcpSocket:
            port: 5678
          periodSeconds: 20
          timeoutSeconds: 2
          failureThreshold: 6
      volumes:
      - name: n8n-data
        persistentVolumeClaim:
          claimName: n8n-data
---
apiVersion: v1
kind: Service
metadata:
  name: n8n
  namespace: ${N8N_NS}
spec:
  type: ClusterIP
  selector:
    app: n8n
  ports:
  - name: http
    port: 80
    targetPort: 5678
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: n8n
  namespace: ${N8N_NS}
  annotations:
    kubernetes.io/ingress.class: ${INGRESS_CLASS}
    $( [ "${TLS_MODE}" = "per-host-http01" ] && echo "cert-manager.io/cluster-issuer: letsencrypt-http01" || true )
spec:
  ingressClassName: ${INGRESS_CLASS}
${TLS_YAML}
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
${CERT_YAML}
EOF
)"

log "[03B][n8n] Wait for readiness"
set +e
kubectl -n "${N8N_NS}" rollout status deploy/n8n --timeout=900s
rc=$?
set -e
if [ $rc -ne 0 ]; then
  warn "[03B][n8n] Rollout failed; dumping diagnostics"
  kubectl -n "${N8N_NS}" get pod -o wide || true
  kubectl -n "${N8N_NS}" describe pod -l app=n8n | sed -n '1,260p' || true
  kubectl -n "${N8N_NS}" logs -l app=n8n --all-containers --tail=300 || true
  kubectl -n "${N8N_NS}" get events --sort-by=.lastTimestamp | tail -n 120 || true
  fatal "n8n rollout did not become ready"
fi

URL="http://${N8N_HOST}/"
[ "${TLS_MODE}" = "per-host-http01" ] && URL="https://${N8N_HOST}/"
log "[03B][n8n] Ready: ${URL}"
