#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 04-portal-api.sh — Deploy OpenKPI Portal API (Phase 1) [REPEATABLE]
# - Packages app/ as app.tgz -> ConfigMap -> initContainer extracts into /app
# - Runs: exec gunicorn -b 0.0.0.0:${PORT} --workers 2 --threads 4 --timeout 30 app.server:app (package name "app")
# - Repeatable: kubectl apply; ConfigMap replaced every run
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${HERE}/../../.." && pwd)"

# shellcheck source=/dev/null
. "${ROOT}/00-env.sh"
# shellcheck source=/dev/null
. "${ROOT}/00-lib.sh"

require_cmd kubectl tar

ns_ensure() { kubectl get ns "$1" >/dev/null 2>&1 || kubectl create ns "$1" >/dev/null; }

NS="${PLATFORM_NS:-platform}"
APP_NAME="portal-api"
SVC="${PORTAL_API_SVC:-portal-api}"
PORT="8000"

URL_SCHEME_LOCAL="http"
if [[ "${TLS_MODE:-off}" != "off" && "${TLS_MODE:-off}" != "disabled" && "${TLS_MODE:-off}" != "false" && "${TLS_MODE:-off}" != "0" ]]; then
  URL_SCHEME_LOCAL="https"
fi

log "[04-portal-api] start (ns=${NS})"
ns_ensure "${NS}"

log "[04-portal-api] apply RBAC"
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: portal-api
  namespace: ${NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: portal-api-readonly
rules:
  - apiGroups: [""]
    resources: ["namespaces","pods","services","endpoints","configmaps"]
    verbs: ["get","list","watch"]
  - apiGroups: ["apps"]
    resources: ["deployments","statefulsets","replicasets"]
    verbs: ["get","list","watch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get","list","watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: portal-api-readonly
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: portal-api-readonly
subjects:
  - kind: ServiceAccount
    name: portal-api
    namespace: ${NS}
YAML


# Build requirements block (indented for YAML) from requirements.txt if present
REQ_FILE="${ROOT}/modules/04-portal/portal-api/requirements.txt"
if [[ -f "${REQ_FILE}" ]]; then
  PORTAL_API_REQUIREMENTS_BLOCK="$(sed 's/^/    /' "${REQ_FILE}")"
else
  PORTAL_API_REQUIREMENTS_BLOCK="$(cat <<'REQ'
    flask==3.0.3
    requests==2.32.3
    kubernetes==30.1.0
    psycopg2-binary==2.9.9
    boto3==1.34.162
    botocore==1.34.162
REQ
)"
fi
export PORTAL_API_REQUIREMENTS_BLOCK

log "[04-portal-api] apply requirements + optional secret"
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: portal-api-requirements
  namespace: ${NS}
data:
  requirements.txt: |
    # Populated from requirements.txt in the module folder when present.
    # If missing, fallback to a minimal pinned set.
    ${PORTAL_API_REQUIREMENTS_BLOCK}

---
apiVersion: v1
kind: Secret
metadata:
  name: portal-api-secret-optional
  namespace: ${NS}
type: Opaque
stringData:
  N8N_API_KEY: "${N8N_API_KEY:-}"
  N8N_BASIC_USER: "${N8N_BASIC_USER:-}"
  N8N_BASIC_PASS: "${N8N_BASIC_PASS:-}"
  ZAMMAD_API_TOKEN: "${ZAMMAD_API_TOKEN:-}"
  METABASE_API_KEY: "${METABASE_API_KEY:-}"
YAML

log "[04-portal-api] package app/ -> app.tgz and publish to ConfigMap"
APP_DIR="${ROOT}/modules/04-portal/portal-api/app"
[[ -d "${APP_DIR}" ]] || { echo "[FATAL] missing ${APP_DIR}"; exit 1; }

# Ensure package markers exist (idempotent)
mkdir -p "${APP_DIR}/util" "${APP_DIR}/probes"
touch "${APP_DIR}/__init__.py" "${APP_DIR}/util/__init__.py" "${APP_DIR}/probes/__init__.py"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Tar must contain top-level folder "app/"
( cd "${ROOT}/modules/04-portal/portal-api" && tar -czf "${TMP}/app.tgz" app )

kubectl -n "${NS}" delete configmap portal-api-app-src --ignore-not-found >/dev/null 2>&1 || true
kubectl -n "${NS}" create configmap portal-api-app-src \
  --from-file=app.tgz="${TMP}/app.tgz" \
  --dry-run=client -o yaml | kubectl apply -f -

log "[04-portal-api] apply env + pg/minio secrets"
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: portal-api-env
  namespace: ${NS}
data:
  PLATFORM_NS: "${PLATFORM_NS:-platform}"
  OPENKPI_NS: "${OPENKPI_NS:-open-kpi}"
  TLS_MODE: "${TLS_MODE:-off}"
  PORTAL_HOST: "${PORTAL_HOST:-}"
  AIRBYTE_HOST: "${AIRBYTE_HOST:-}"
  MINIO_HOST: "${MINIO_HOST:-}"
  METABASE_HOST: "${METABASE_HOST:-}"
  N8N_HOST: "${N8N_HOST:-}"
  ZAMMAD_HOST: "${ZAMMAD_HOST:-}"
  DBT_HOST: "${DBT_HOST:-}"
  AIRBYTE_NS: "${AIRBYTE_NS:-airbyte}"
  TRANSFORM_NS: "${TRANSFORM_NS:-transform}"
  ANALYTICS_NS: "${ANALYTICS_NS:-analytics}"
  N8N_NS: "${N8N_NS:-n8n}"
  TICKETS_NS: "${TICKETS_NS:-tickets}"
  PORTAL_API_SVC: "${PORTAL_API_SVC:-portal-api}"
  AIRBYTE_S3_REGION: "${AIRBYTE_S3_REGION:-us-east-1}"
---
apiVersion: v1
kind: Secret
metadata:
  name: portal-api-pg
  namespace: ${NS}
type: Opaque
stringData:
  POSTGRES_SERVICE: "${POSTGRES_SERVICE:?missing POSTGRES_SERVICE}"
  POSTGRES_PORT: "${POSTGRES_PORT:?missing POSTGRES_PORT}"
  POSTGRES_DB: "${POSTGRES_DB:?missing POSTGRES_DB}"
  POSTGRES_USER: "${POSTGRES_USER:?missing POSTGRES_USER}"
  POSTGRES_PASSWORD: "${POSTGRES_PASSWORD:?missing POSTGRES_PASSWORD}"
---
apiVersion: v1
kind: Secret
metadata:
  name: portal-api-minio
  namespace: ${NS}
type: Opaque
stringData:
  MINIO_SERVICE: "${MINIO_SERVICE:-}"
  MINIO_API_PORT: "${MINIO_API_PORT:-9000}"
  MINIO_ROOT_USER: "${MINIO_ROOT_USER:-}"
  MINIO_ROOT_PASSWORD: "${MINIO_ROOT_PASSWORD:-}"
YAML

log "[04-portal-api] apply deployment + service"
cat <<YAML | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  namespace: ${NS}
  labels: { app: ${APP_NAME} }
spec:
  replicas: 1
  selector:
    matchLabels: { app: ${APP_NAME} }
  template:
    metadata:
      labels: { app: ${APP_NAME} }
    spec:
      serviceAccountName: portal-api
      volumes:
        - name: app-src
          configMap: { name: portal-api-app-src }
        - name: app
          emptyDir: {}
        - name: req
          configMap: { name: portal-api-requirements }
      initContainers:
        - name: unpack
          image: busybox:1.36
          command: ["sh","-lc"]
          args:
            - |
              set -euo pipefail
              mkdir -p /app
              tar -xzf /src/app.tgz -C /app
              test -f /app/app/server.py
          volumeMounts:
            - name: app-src
              mountPath: /src
            - name: app
              mountPath: /app
      containers:
        - name: api
          image: python:3.11-slim
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: ${PORT}
          envFrom:
            - configMapRef: { name: portal-api-env }
            - secretRef: { name: portal-api-secret-optional, optional: true }
          env:
            - name: PYTHONPATH
              value: "/app"
            - name: POSTGRES_SERVICE
              valueFrom: { secretKeyRef: { name: portal-api-pg, key: POSTGRES_SERVICE } }
            - name: POSTGRES_PORT
              valueFrom: { secretKeyRef: { name: portal-api-pg, key: POSTGRES_PORT } }
            - name: POSTGRES_DB
              valueFrom: { secretKeyRef: { name: portal-api-pg, key: POSTGRES_DB } }
            - name: POSTGRES_USER
              valueFrom: { secretKeyRef: { name: portal-api-pg, key: POSTGRES_USER } }
            - name: POSTGRES_PASSWORD
              valueFrom: { secretKeyRef: { name: portal-api-pg, key: POSTGRES_PASSWORD } }
            - name: MINIO_SERVICE
              valueFrom: { secretKeyRef: { name: portal-api-minio, key: MINIO_SERVICE, optional: true } }
            - name: MINIO_API_PORT
              valueFrom: { secretKeyRef: { name: portal-api-minio, key: MINIO_API_PORT, optional: true } }
            - name: MINIO_ROOT_USER
              valueFrom: { secretKeyRef: { name: portal-api-minio, key: MINIO_ROOT_USER, optional: true } }
            - name: MINIO_ROOT_PASSWORD
              valueFrom: { secretKeyRef: { name: portal-api-minio, key: MINIO_ROOT_PASSWORD, optional: true } }
            - name: MINIO_ENDPOINT
              value: "http://openkpi-minio.open-kpi.svc.cluster.local:9000"
            - name: MINIO_SECURE
              value: "false"
          volumeMounts:
            - name: app
              mountPath: /app
            - name: req
              mountPath: /requirements
          command: ["sh","-lc"]
          args:
            - |
              set -euo pipefail
              python3 -m pip install --no-cache-dir -r /requirements/requirements.txt >/dev/null
              cd /app
              exec gunicorn -b 0.0.0.0:${PORT} --workers 2 --threads 4 --timeout 30 app.server:app
          readinessProbe:
            httpGet: { path: /api/health, port: ${PORT} }
            initialDelaySeconds: 15
            periodSeconds: 10
          startupProbe:
            httpGet: { path: /api/health, port: ${PORT} }
            failureThreshold: 30
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 6
          livenessProbe:
            httpGet: { path: /api/health, port: ${PORT} }
            initialDelaySeconds: 15
            periodSeconds: 20
            timeoutSeconds: 2
            failureThreshold: 6
---
apiVersion: v1
kind: Service
metadata:
  name: ${SVC}
  namespace: ${NS}
  labels: { app: ${APP_NAME} }
spec:
  selector: { app: ${APP_NAME} }
  ports:
    - name: http
      port: ${PORT}
      targetPort: ${PORT}
YAML

log "[04-portal-api] apply ingress (/api -> portal-api)"
if [[ "${URL_SCHEME_LOCAL}" == "https" ]]; then
cat <<YAML | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${APP_NAME}-ingress
  namespace: ${NS}
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
    - hosts: ["${PORTAL_HOST}"]
      secretName: ${PORTAL_TLS_SECRET:-portal-tls}
  rules:
    - host: ${PORTAL_HOST}
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: ${SVC}
                port:
                  number: ${PORT}
YAML
else
cat <<YAML | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${APP_NAME}-ingress
  namespace: ${NS}
spec:
  ingressClassName: ${INGRESS_CLASS}
  rules:
    - host: ${PORTAL_HOST}
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: ${SVC}
                port:
                  number: ${PORT}
YAML
fi

log "[04-portal-api] rollout"
kubectl -n "${NS}" rollout status "deploy/${APP_NAME}" --timeout=240s
log "[04-portal-api] done"
