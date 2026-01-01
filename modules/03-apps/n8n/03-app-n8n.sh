#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/../../../00-env.sh"

log "[03-n8n] start"

require_cmd kubectl

require_var N8N_NS
require_var OPENKPI_NS
require_var POSTGRES_SERVICE
require_var POSTGRES_PORT
require_var POSTGRES_USER
require_var POSTGRES_PASSWORD
require_var POSTGRES_DB

require_var N8N_PASS
require_var N8N_ENCRYPTION_KEY

NS="${N8N_NS}"
kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}"

# Create n8n role+db (inside Postgres pod)
PG_POD="$(kubectl -n "${OPENKPI_NS}" get pod -l app=openkpi-postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "${PG_POD}" ]] || die "Postgres pod not found in ${OPENKPI_NS}. Run 02-postgres first."

N8N_DB="n8n"
N8N_DB_USER="n8n"
N8N_DB_PASS="${N8N_PASS}"

kubectl -n "${OPENKPI_NS}" exec "${PG_POD}" -- bash -lc "
set -e
export PGPASSWORD='${POSTGRES_PASSWORD}'
psql -U '${POSTGRES_USER}' -d '${POSTGRES_DB}' -v ON_ERROR_STOP=1 <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${N8N_DB_USER}') THEN
    CREATE ROLE ${N8N_DB_USER} LOGIN PASSWORD '${N8N_DB_PASS}';
  END IF;
END \$\$;

SELECT 'DB exists' WHERE EXISTS (SELECT 1 FROM pg_database WHERE datname='${N8N_DB}');
\\gexec

CREATE DATABASE ${N8N_DB} OWNER ${N8N_DB_USER};
ALTER DATABASE ${N8N_DB} OWNER TO ${N8N_DB_USER};
GRANT ALL PRIVILEGES ON DATABASE ${N8N_DB} TO ${N8N_DB_USER};
SQL
" 2>/dev/null || true

# Secret for n8n
cat <<YAML | kubectl -n "${NS}" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: n8n-secret
type: Opaque
stringData:
  N8N_ENCRYPTION_KEY: "${N8N_ENCRYPTION_KEY}"
  N8N_BASIC_AUTH_USER: "admin"
  N8N_BASIC_AUTH_PASSWORD: "${N8N_PASS}"
  DB_TYPE: "postgresdb"
  DB_POSTGRESDB_HOST: "${POSTGRES_SERVICE}"
  DB_POSTGRESDB_PORT: "${POSTGRES_PORT}"
  DB_POSTGRESDB_DATABASE: "${N8N_DB}"
  DB_POSTGRESDB_USER: "${N8N_DB_USER}"
  DB_POSTGRESDB_PASSWORD: "${N8N_DB_PASS}"
YAML

# Deployment + Service
cat <<YAML | kubectl -n "${NS}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: n8n
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
      containers:
        - name: n8n
          image: n8nio/n8n:1.110.0
          imagePullPolicy: IfNotPresent
          envFrom:
            - secretRef:
                name: n8n-secret
          env:
            - name: N8N_BASIC_AUTH_ACTIVE
              value: "true"
            - name: N8N_HOST
              value: "n8n"
            - name: N8N_PORT
              value: "5678"
            - name: N8N_PROTOCOL
              value: "http"
            - name: WEBHOOK_URL
              value: "http://n8n:5678/"
          ports:
            - containerPort: 5678
          readinessProbe:
            httpGet:
              path: /
              port: 5678
            initialDelaySeconds: 20
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 18
          livenessProbe:
            httpGet:
              path: /
              port: 5678
            initialDelaySeconds: 40
            periodSeconds: 20
            timeoutSeconds: 3
            failureThreshold: 6
---
apiVersion: v1
kind: Service
metadata:
  name: n8n
spec:
  type: ClusterIP
  selector:
    app: n8n
  ports:
    - name: http
      port: 5678
      targetPort: 5678
YAML

kubectl -n "${NS}" rollout status deploy/n8n --timeout=300s

log "[03-n8n] done"
