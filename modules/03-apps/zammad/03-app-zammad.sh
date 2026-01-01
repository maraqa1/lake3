#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/../../../00-env.sh"

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

NS="${TICKETS_NS}"
kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}"

# --- Create zammad role+db in shared Postgres (inside Postgres pod) ---
PG_POD="$(kubectl -n "${OPENKPI_NS}" get pod -l app=openkpi-postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "${PG_POD}" ]] || die "Postgres pod not found in ${OPENKPI_NS}. Run 02-postgres first."

Z_DB="zammad"
Z_USER="zammad"
Z_PASS="${ZAMMAD_ADMIN_PASSWORD}"

kubectl -n "${OPENKPI_NS}" exec "${PG_POD}" -- bash -lc "
set -e
export PGPASSWORD='${POSTGRES_PASSWORD}'
psql -U '${POSTGRES_USER}' -d '${POSTGRES_DB}' -v ON_ERROR_STOP=1 <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${Z_USER}') THEN
    CREATE ROLE ${Z_USER} LOGIN PASSWORD '${Z_PASS}';
  END IF;
END \$\$;

SELECT 'DB exists' WHERE EXISTS (SELECT 1 FROM pg_database WHERE datname='${Z_DB}');
\\gexec

CREATE DATABASE ${Z_DB} OWNER ${Z_USER};
ALTER DATABASE ${Z_DB} OWNER TO ${Z_USER};
GRANT ALL PRIVILEGES ON DATABASE ${Z_DB} TO ${Z_USER};
SQL
" 2>/dev/null || true

# --- Secrets ---
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

# --- PVC for attachments/data ---
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

# --- Redis (in-namespace) ---
cat <<YAML | kubectl -n "${NS}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: zammad-redis
spec:
  replicas: 1
  selector:
    matchLabels:
      app: zammad-redis
  template:
    metadata:
      labels:
        app: zammad-redis
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          ports:
            - containerPort: 6379
          readinessProbe:
            tcpSocket:
              port: 6379
            initialDelaySeconds: 5
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: zammad-redis
spec:
  type: ClusterIP
  selector:
    app: zammad-redis
  ports:
    - name: redis
      port: 6379
      targetPort: 6379
YAML

kubectl -n "${NS}" rollout status deploy/zammad-redis --timeout=180s

# --- Zammad (single pod) ---
# Image line: zammad/zammad-docker-compose is outdated; use official monolith image.
# This is a pragmatic single-container deployment for MVP. Later split into web/scheduler/worker.
cat <<YAML | kubectl -n "${NS}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: zammad
spec:
  replicas: 1
  selector:
    matchLabels:
      app: zammad
  template:
    metadata:
      labels:
        app: zammad
    spec:
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
              value: "postgres://${Z_USER}:${Z_PASS}@openkpi-postgres.${OPENKPI_NS}.svc.cluster.local:5432/${Z_DB}"
            - name: REDIS_URL
              value: "redis://zammad-redis:6379"
          ports:
            - containerPort: 3000
          volumeMounts:
            - name: zammad-data
              mountPath: /opt/zammad
          readinessProbe:
            httpGet:
              path: /
              port: 3000
            initialDelaySeconds: 60
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 30
          livenessProbe:
            httpGet:
              path: /
              port: 3000
            initialDelaySeconds: 120
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
  selector:
    app: zammad
  ports:
    - name: http
      port: 80
      targetPort: 3000
YAML

kubectl -n "${NS}" rollout status deploy/zammad --timeout=600s

log "[03-zammad] done"
