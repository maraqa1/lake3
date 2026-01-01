#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/../../../00-env.sh"

log "[03-metabase] start"

require_cmd kubectl

require_var ANALYTICS_NS
require_var OPENKPI_NS
require_var POSTGRES_SERVICE
require_var POSTGRES_PORT
require_var POSTGRES_USER
require_var POSTGRES_PASSWORD

require_var METABASE_DB_NAME
require_var METABASE_DB_USER
require_var METABASE_DB_PASSWORD
require_var METABASE_IMAGE_REPO
require_var METABASE_IMAGE_TAG

NS="${ANALYTICS_NS}"
kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}"

# Create Metabase role+db in shared Postgres (runs inside the Postgres pod)
PG_POD="$(kubectl -n "${OPENKPI_NS}" get pod -l app=openkpi-postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "${PG_POD}" ]] || die "Postgres pod not found in ${OPENKPI_NS}. Run 02-postgres first."

kubectl -n "${OPENKPI_NS}" exec "${PG_POD}" -- bash -lc "
set -e
export PGPASSWORD='${POSTGRES_PASSWORD}'
psql -U '${POSTGRES_USER}' -d '${POSTGRES_DB}' -v ON_ERROR_STOP=1 <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${METABASE_DB_USER}') THEN
    CREATE ROLE ${METABASE_DB_USER} LOGIN PASSWORD '${METABASE_DB_PASSWORD}';
  END IF;
END \$\$;

SELECT 'DB exists' WHERE EXISTS (SELECT 1 FROM pg_database WHERE datname='${METABASE_DB_NAME}');
\\gexec

CREATE DATABASE ${METABASE_DB_NAME} OWNER ${METABASE_DB_USER};
ALTER DATABASE ${METABASE_DB_NAME} OWNER TO ${METABASE_DB_USER};
GRANT ALL PRIVILEGES ON DATABASE ${METABASE_DB_NAME} TO ${METABASE_DB_USER};
SQL
" 2>/dev/null || true

# Secret for Metabase app DB
cat <<YAML | kubectl -n "${NS}" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: metabase-db-secret
type: Opaque
stringData:
  MB_DB_TYPE: "postgres"
  MB_DB_HOST: "${POSTGRES_SERVICE}"
  MB_DB_PORT: "${POSTGRES_PORT}"
  MB_DB_DBNAME: "${METABASE_DB_NAME}"
  MB_DB_USER: "${METABASE_DB_USER}"
  MB_DB_PASS: "${METABASE_DB_PASSWORD}"
YAML

# Deployment + Service
cat <<YAML | kubectl -n "${NS}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: metabase
spec:
  replicas: 1
  selector:
    matchLabels:
      app: metabase
  template:
    metadata:
      labels:
        app: metabase
    spec:
      containers:
        - name: metabase
          image: ${METABASE_IMAGE_REPO}:${METABASE_IMAGE_TAG}
          imagePullPolicy: IfNotPresent
          envFrom:
            - secretRef:
                name: metabase-db-secret
          ports:
            - containerPort: 3000
          readinessProbe:
            httpGet:
              path: /api/health
              port: 3000
            initialDelaySeconds: 20
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 18
          livenessProbe:
            httpGet:
              path: /api/health
              port: 3000
            initialDelaySeconds: 40
            periodSeconds: 20
            timeoutSeconds: 3
            failureThreshold: 6
---
apiVersion: v1
kind: Service
metadata:
  name: metabase
spec:
  type: ClusterIP
  selector:
    app: metabase
  ports:
    - name: http
      port: 3000
      targetPort: 3000
YAML

kubectl -n "${NS}" rollout status deploy/metabase --timeout=300s

log "[03-metabase] done"
