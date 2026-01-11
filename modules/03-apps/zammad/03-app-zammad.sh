#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HERE}"
while [[ "${ROOT}" != "/" && ! -f "${ROOT}/00-env.sh" ]]; do ROOT="$(dirname "${ROOT}")"; done
[[ -f "${ROOT}/00-env.sh" ]] || { echo "[FATAL] cannot find 00-env.sh above ${HERE}"; exit 1; }

# shellcheck source=/dev/null
. "${ROOT}/00-env.sh"
# shellcheck source=/dev/null
. "${ROOT}/00-lib.sh"


log "[03-zammad] start"

require_cmd kubectl
require_var TICKETS_NS
require_var OPENKPI_NS
require_var STORAGE_CLASS
require_var POSTGRES_USER
require_var POSTGRES_PASSWORD
require_var POSTGRES_DB
require_var ZAMMAD_ADMIN_EMAIL
require_var ZAMMAD_ADMIN_PASSWORD

# Optional (ingress). If you don’t set them, the script will skip ingress.
: "${TLS_MODE:=off}"
: "${INGRESS_CLASS:=nginx}"
: "${CERT_CLUSTER_ISSUER:=letsencrypt-http01}"
: "${ZAMMAD_HOST:=}"
: "${ZAMMAD_TLS_SECRET:=zammad-tls}"

NS="${TICKETS_NS}"
ensure_ns "${NS}"

# ------------------------------------------------------------------------------
# 01) Postgres bootstrap (repeatable, deterministic) using in-cluster psql pod
# - no CREATE DATABASE failures
# - no silent ignore
# ------------------------------------------------------------------------------
PG_SECRET="openkpi-postgres-secret"
kubectl -n "${OPENKPI_NS}" get secret "${PG_SECRET}" >/dev/null 2>&1 \
  || die "Missing ${OPENKPI_NS}/${PG_SECRET} (run core data plane modules first)."

# Create a short-lived psql pod (no password on CLI)
cat <<YAML | kubectl -n "${OPENKPI_NS}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: zammad-psql
  labels: {app: zammad-psql}
spec:
  restartPolicy: Never
  containers:
    - name: psql
      image: postgres:16-alpine
      imagePullPolicy: IfNotPresent
      env:
        - name: PGHOST
          valueFrom: {secretKeyRef: {name: ${PG_SECRET}, key: host}}
        - name: PGPORT
          valueFrom: {secretKeyRef: {name: ${PG_SECRET}, key: port}}
        - name: PGUSER
          valueFrom: {secretKeyRef: {name: ${PG_SECRET}, key: username}}
        - name: PGPASSWORD
          valueFrom: {secretKeyRef: {name: ${PG_SECRET}, key: password}}
        - name: PGDATABASE
          valueFrom: {secretKeyRef: {name: ${PG_SECRET}, key: db}}
      command: ["sh","-lc"]
      args: ["sleep 3600"]
YAML
kubectl -n "${OPENKPI_NS}" wait --for=condition=Ready pod/zammad-psql --timeout=180s >/dev/null

Z_DB="zammad"
Z_USER="zammad"
Z_PASS="${ZAMMAD_ADMIN_PASSWORD}"
Z_PASS_SQL="${Z_PASS//\'/\'\'}"

psql_scalar() {
  local sql="$1"
  kubectl -n "${OPENKPI_NS}" exec -i zammad-psql -c psql -- sh -lc \
    "psql -v ON_ERROR_STOP=1 -q -tA" <<< "${sql}" | tr -d '[:space:]'
}
psql_exec() {
  local sql="$1"
  kubectl -n "${OPENKPI_NS}" exec -i zammad-psql -c psql -- sh -lc \
    "psql -v ON_ERROR_STOP=1 -q" <<< "${sql}"
}

log "[03-zammad] postgres preflight"
psql_exec "select 1;" >/dev/null

role_exists="$(psql_scalar "SELECT 1 FROM pg_roles WHERE rolname='${Z_USER}';" || true)"
if [[ "${role_exists}" != "1" ]]; then
  log "[03-zammad] create role ${Z_USER}"
  psql_exec "CREATE ROLE ${Z_USER} LOGIN PASSWORD '${Z_PASS_SQL}';"
else
  log "[03-zammad] role exists ${Z_USER}"
fi
log "[03-zammad] enforce role password ${Z_USER}"
psql_exec "ALTER ROLE ${Z_USER} LOGIN PASSWORD '${Z_PASS_SQL}';"

db_exists="$(psql_scalar "SELECT 1 FROM pg_database WHERE datname='${Z_DB}';" || true)"
if [[ "${db_exists}" != "1" ]]; then
  log "[03-zammad] create db ${Z_DB}"
  psql_exec "CREATE DATABASE ${Z_DB} OWNER ${Z_USER};"
else
  log "[03-zammad] db exists ${Z_DB}"
fi
psql_exec "ALTER DATABASE ${Z_DB} OWNER TO ${Z_USER};" || true
psql_exec "GRANT ALL PRIVILEGES ON DATABASE ${Z_DB} TO ${Z_USER};" || true

kubectl -n "${OPENKPI_NS}" delete pod zammad-psql --ignore-not-found >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 02) Zammad secret (kept; but do not embed passwords in manifests elsewhere)
# ------------------------------------------------------------------------------
cat <<YAML | kubectl -n "${NS}" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: zammad-secret
type: Opaque
stringData:
  DB_HOST: "openkpi-postgres.${OPENKPI_NS}.svc.cluster.local"
  DB_PORT: "5432"
  DB_NAME: "${Z_DB}"
  DB_USER: "${Z_USER}"
  DB_PASS: "${Z_PASS}"
  REDIS_HOST: "zammad-redis"
  REDIS_PORT: "6379"
  ZAMMAD_ADMIN_EMAIL: "${ZAMMAD_ADMIN_EMAIL}"
  ZAMMAD_ADMIN_PASSWORD: "${ZAMMAD_ADMIN_PASSWORD}"
YAML

# ------------------------------------------------------------------------------
# 03) PVC
# ------------------------------------------------------------------------------
cat <<YAML | kubectl -n "${NS}" apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: zammad-data-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: 30Gi
YAML

# ------------------------------------------------------------------------------
# 04) Redis
# ------------------------------------------------------------------------------
cat <<YAML | kubectl -n "${NS}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: zammad-redis
spec:
  replicas: 1
  selector:
    matchLabels: {app: zammad-redis}
  template:
    metadata:
      labels: {app: zammad-redis}
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          ports: [{containerPort: 6379}]
          readinessProbe:
            tcpSocket: {port: 6379}
            initialDelaySeconds: 5
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: zammad-redis
spec:
  type: ClusterIP
  selector: {app: zammad-redis}
  ports:
    - name: redis
      port: 6379
      targetPort: 6379
YAML
kubectl -n "${NS}" rollout status deploy/zammad-redis --timeout=5m

# ------------------------------------------------------------------------------
# 05) Zammad (repeatable + no false timeout)
# - initContainer fixes PVC perms (common cause of stuck readiness)
# - startupProbe allows long bootstrap without killing the pod
# - readiness/liveness relaxed
# ------------------------------------------------------------------------------
cat <<YAML | kubectl -n "${NS}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: zammad
spec:
  replicas: 1
  selector:
    matchLabels: {app: zammad}
  template:
    metadata:
      labels: {app: zammad}
    spec:
      securityContext:
        fsGroup: 1000
      initContainers:
        - name: volume-perms
          image: busybox:1.36
          command: ["sh","-lc"]
          args:
            - |
              set -e
              mkdir -p /opt/zammad
              chown -R 1000:1000 /opt/zammad || true
              chmod -R ug+rwX /opt/zammad || true
          volumeMounts:
            - name: zammad-data
              mountPath: /opt/zammad
      containers:
        - name: zammad
          image: zammad/zammad:6.4.1
          imagePullPolicy: IfNotPresent
          env:
            - name: RAILS_ENV
              value: "production"
            - name: ZAMMAD_RAILSSERVER_HOST
              value: "0.0.0.0"
            - name: ZAMMAD_RAILSSERVER_PORT
              value: "3000"
            - name: DATABASE_URL
              valueFrom: {secretKeyRef: {name: zammad-secret, key: DB_PASS}}
          envFrom:
            - secretRef: {name: zammad-secret}
          ports:
            - containerPort: 3000
          volumeMounts:
            - name: zammad-data
              mountPath: /opt/zammad
          startupProbe:
            httpGet: {path: /, port: 3000}
            initialDelaySeconds: 20
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 90
          readinessProbe:
            httpGet: {path: /, port: 3000}
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 30
          livenessProbe:
            httpGet: {path: /, port: 3000}
            initialDelaySeconds: 180
            periodSeconds: 20
            timeoutSeconds: 3
            failureThreshold: 10
      volumes:
        - name: zammad-data
          persistentVolumeClaim:
            claimName: zammad-data-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: zammad
spec:
  type: ClusterIP
  selector: {app: zammad}
  ports:
    - name: http
      port: 80
      targetPort: 3000
YAML

# Deterministic rollout + diagnostics
if ! kubectl -n "${NS}" rollout status deploy/zammad --timeout=15m; then
  kubectl -n "${NS}" get pods -o wide || true
  kubectl -n "${NS}" get events --sort-by=.lastTimestamp | tail -n 120 || true
  POD="$(kubectl -n "${NS}" get pod -l app=zammad -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${POD}" ]] && kubectl -n "${NS}" describe pod "${POD}" | sed -n '1,320p' || true
  [[ -n "${POD}" ]] && kubectl -n "${NS}" logs "${POD}" --all-containers --tail=300 || true
  exit 1
fi

# ------------------------------------------------------------------------------
# 06) Optional TLS + Ingress (only if ZAMMAD_HOST is set)
# ------------------------------------------------------------------------------
if [[ -n "${ZAMMAD_HOST}" ]]; then
  if [[ "${TLS_MODE}" != "off" ]]; then
    cat <<YAML | kubectl -n "${NS}" apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: zammad-tls
spec:
  secretName: ${ZAMMAD_TLS_SECRET}
  issuerRef:
    kind: ClusterIssuer
    name: ${CERT_CLUSTER_ISSUER}
  dnsNames: [${ZAMMAD_HOST}]
YAML
  fi

  if [[ "${TLS_MODE}" == "off" ]]; then
    cat <<YAML | kubectl -n "${NS}" apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: zammad-ingress
  annotations:
    kubernetes.io/ingress.class: "${INGRESS_CLASS}"
spec:
  ingressClassName: ${INGRESS_CLASS}
  rules:
    - host: ${ZAMMAD_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: {name: zammad, port: {number: 80}}
YAML
  else
    cat <<YAML | kubectl -n "${NS}" apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: zammad-ingress
  annotations:
    kubernetes.io/ingress.class: "${INGRESS_CLASS}"
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
    - hosts: [${ZAMMAD_HOST}]
      secretName: ${ZAMMAD_TLS_SECRET}
  rules:
    - host: ${ZAMMAD_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: {name: zammad, port: {number: 80}}
YAML
  fi
fi

log "[03-zammad] done"
