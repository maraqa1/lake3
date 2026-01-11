#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# MODULE 03D-A — APP (dbt) — DOCS GATEWAY (production / repeatable)
# FILE: 03A-app-dbt-docs.sh
#
#  First time (before docs publish): DBT_DOCS_STRICT=off ./03A-app-dbt-docs.sh

#  After dbt publishes: DBT_DOCS_STRICT=on ./03A-app-dbt-docs.sh
# Guarantees:
# - Namespace: ${PORTAL_NS:-portal}
# - Ensures MinIO bucket exists: ${DBT_DOCS_BUCKET}
# - Ensures prefix marker exists: ${DBT_DOCS_PREFIX}/.keep
# - Deploys nginx gateway + initContainer (mc) that mirrors docs from MinIO
# - Optional strict gating on docs files via DBT_DOCS_STRICT=on|off (default off)
# - Uses strategy Recreate to avoid rollouts stuck on old ReplicaSet termination
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HERE}"
while [[ "${ROOT}" != "/" && ! -f "${ROOT}/00-env.sh" ]]; do ROOT="$(dirname "${ROOT}")"; done
[[ -f "${ROOT}/00-env.sh" ]] || { echo "[FATAL] cannot find 00-env.sh above ${HERE}"; exit 1; }

# shellcheck source=/dev/null
. "${ROOT}/00-env.sh"
# shellcheck source=/dev/null
. "${ROOT}/00-lib.sh"

require_cmd kubectl

MODULE_ID="03D-A"

# ------------------------------------------------------------------------------
# Config
# ------------------------------------------------------------------------------
NS_PORTAL="${PORTAL_NS:-portal}"

: "${INGRESS_CLASS:=nginx}"
: "${TLS_MODE:=off}"
: "${PORTAL_HOST:?missing PORTAL_HOST}"
PORTAL_TLS_SECRET="${PORTAL_TLS_SECRET:-portal-tls}"

: "${DBT_DOCS_BUCKET:=dbt-docs}"
: "${DBT_DOCS_PREFIX:=his_dmo}"

# mc image pin from env contract (open-kpi.env)
: "${MINIO_MC_IMAGE:=minio/mc:RELEASE.2024-11-05T11-29-45Z}"
DBT_DOCS_MC_IMAGE="${DBT_DOCS_MC_IMAGE:-${MINIO_MC_IMAGE}}"

: "${NGINX_IMAGE:=nginx:1.27-alpine}"

# off = deploy gateway even before docs exist; on = require docs files
: "${DBT_DOCS_STRICT:=off}"  # on|off

DOCS_MINIO_SECRET="${DBT_DOCS_MINIO_SECRET:-dbt-docs-minio-secret}"

log "[${MODULE_ID}][docs] start"
ensure_ns "${NS_PORTAL}"

# ------------------------------------------------------------------------------
# Canonical MinIO endpoint + creds from env contract
# ------------------------------------------------------------------------------
: "${MINIO_SERVICE:?missing MINIO_SERVICE}"
: "${MINIO_API_PORT:?missing MINIO_API_PORT}"
: "${MINIO_ROOT_USER:?missing MINIO_ROOT_USER}"
: "${MINIO_ROOT_PASSWORD:?missing MINIO_ROOT_PASSWORD}"

MINIO_ENDPOINT="http://${MINIO_SERVICE}:${MINIO_API_PORT}"

# ------------------------------------------------------------------------------
# Portal-local MinIO secret (idempotent)
# ------------------------------------------------------------------------------
kubectl -n "${NS_PORTAL}" apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ${DOCS_MINIO_SECRET}
type: Opaque
stringData:
  endpoint: "${MINIO_ENDPOINT}"
  accessKey: "${MINIO_ROOT_USER}"
  secretKey: "${MINIO_ROOT_PASSWORD}"
YAML

# ------------------------------------------------------------------------------
# Preflight: ensure bucket + prefix marker exist (repeatable)
# - Runs mc as a short-lived pod
# - Uses portal secret values decoded on the host (mc image has no kubectl)
# ------------------------------------------------------------------------------
ENDPOINT="$(kubectl -n "${NS_PORTAL}" get secret "${DOCS_MINIO_SECRET}" -o jsonpath='{.data.endpoint}' | base64 -d)"
ACCESS="$(kubectl -n "${NS_PORTAL}" get secret "${DOCS_MINIO_SECRET}" -o jsonpath='{.data.accessKey}' | base64 -d)"
KEY="$(kubectl -n "${NS_PORTAL}" get secret "${DOCS_MINIO_SECRET}" -o jsonpath='{.data.secretKey}' | base64 -d)"

kubectl -n "${NS_PORTAL}" delete pod dbt-docs-mc-preflight --ignore-not-found >/dev/null 2>&1 || true
kubectl -n "${NS_PORTAL}" run -i --rm --restart=Never dbt-docs-mc-preflight \
  --image="${DBT_DOCS_MC_IMAGE}" \
  --env="MINIO_ENDPOINT=${ENDPOINT}" \
  --env="MINIO_ACCESS_KEY=${ACCESS}" \
  --env="MINIO_SECRET_KEY=${KEY}" \
  --command -- sh -lc "
set -euo pipefail
mc alias set ok \"\$MINIO_ENDPOINT\" \"\$MINIO_ACCESS_KEY\" \"\$MINIO_SECRET_KEY\" --api S3v4
mc mb -p \"ok/${DBT_DOCS_BUCKET}\" >/dev/null 2>&1 || true
mc cp /etc/hosts \"ok/${DBT_DOCS_BUCKET}/${DBT_DOCS_PREFIX}/.keep\" >/dev/null 2>&1 || true
mc ls \"ok/${DBT_DOCS_BUCKET}/${DBT_DOCS_PREFIX}/\" >/dev/null
" >/dev/null

# ------------------------------------------------------------------------------
# Deployment (Recreate)
# - mirror is best-effort (won't fail pod when strict=off)
# - strict=on enforces presence of index/manifest/catalog
# ------------------------------------------------------------------------------
cat <<YAML | kubectl -n "${NS_PORTAL}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dbt-docs-gateway
  labels: {app: dbt-docs-gateway}
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels: {app: dbt-docs-gateway}
  template:
    metadata:
      labels: {app: dbt-docs-gateway}
    spec:
      volumes:
        - name: html
          emptyDir: {}
      initContainers:
        - name: sync
          image: ${DBT_DOCS_MC_IMAGE}
          imagePullPolicy: IfNotPresent
          env:
            - name: MINIO_ENDPOINT
              valueFrom: {secretKeyRef: {name: ${DOCS_MINIO_SECRET}, key: endpoint}}
            - name: MINIO_ACCESS_KEY
              valueFrom: {secretKeyRef: {name: ${DOCS_MINIO_SECRET}, key: accessKey}}
            - name: MINIO_SECRET_KEY
              valueFrom: {secretKeyRef: {name: ${DOCS_MINIO_SECRET}, key: secretKey}}
            - name: DBT_DOCS_BUCKET
              value: "${DBT_DOCS_BUCKET}"
            - name: DBT_DOCS_PREFIX
              value: "${DBT_DOCS_PREFIX}"
            - name: DBT_DOCS_STRICT
              value: "${DBT_DOCS_STRICT}"
          command: ["sh","-lc"]
          args:
            - |
              set -euo pipefail
              mc alias set ok "\${MINIO_ENDPOINT}" "\${MINIO_ACCESS_KEY}" "\${MINIO_SECRET_KEY}" --api S3v4
              rm -rf /html/* || true
              mc mirror --overwrite "ok/\${DBT_DOCS_BUCKET}/\${DBT_DOCS_PREFIX}/" /html || true
              # Always ensure a probeable page exists (prevents nginx 403 on empty dir)
              if [ ! -f /html/index.html ]; then
                cat > /html/index.html <<'EOF'
              <!doctype html>
              <html><head><meta charset="utf-8"><title>dbt docs not published</title></head>
              <body style="font-family: Arial, sans-serif">
                <h3>dbt docs not published yet</h3>
                <p>MinIO prefix is empty. Publish docs, then re-run this module.</p>
              </body></html>
              EOF
              fi
              
              if [ "\${DBT_DOCS_STRICT}" = "on" ]; then
                test -f /html/index.html
                test -f /html/manifest.json
                test -f /html/catalog.json
              fi
          volumeMounts:
            - {name: html, mountPath: /html}
      containers:
        - name: nginx
          image: ${NGINX_IMAGE}
          imagePullPolicy: IfNotPresent
          ports:
            - {containerPort: 80}
          readinessProbe:
            httpGet: {path: /index.html, port: 80}
            initialDelaySeconds: 2
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 12
          livenessProbe:
            httpGet: {path: /index.html, port: 80}
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 6
          volumeMounts:
            - {name: html, mountPath: /usr/share/nginx/html}
YAML

kubectl -n "${NS_PORTAL}" apply -f - <<YAML
apiVersion: v1
kind: Service
metadata:
  name: dbt-docs-gateway
  labels: {app: dbt-docs-gateway}
spec:
  selector: {app: dbt-docs-gateway}
  ports:
    - name: http
      port: 80
      targetPort: 80
YAML

if [[ "${TLS_MODE}" == "off" ]]; then
  kubectl -n "${NS_PORTAL}" apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dbt-docs-ingress
  labels: {app: dbt-docs-gateway}
spec:
  ingressClassName: ${INGRESS_CLASS}
  rules:
    - host: ${PORTAL_HOST}
      http:
        paths:
          - path: /dbt/docs/his_dmo/
            pathType: Prefix
            backend:
              service:
                name: dbt-docs-gateway
                port:
                  number: 80
YAML
else
  kubectl -n "${NS_PORTAL}" apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dbt-docs-ingress
  labels: {app: dbt-docs-gateway}
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
    - hosts: [${PORTAL_HOST}]
      secretName: ${PORTAL_TLS_SECRET}
  rules:
    - host: ${PORTAL_HOST}
      http:
        paths:
          - path: /dbt/docs/his_dmo/
            pathType: Prefix
            backend:
              service:
                name: dbt-docs-gateway
                port:
                  number: 80
YAML
fi

# ------------------------------------------------------------------------------
# Rollout + deterministic diagnostics on failure
# ------------------------------------------------------------------------------
if ! kubectl -n "${NS_PORTAL}" rollout status deploy/dbt-docs-gateway --timeout=240s; then
  POD="$(kubectl -n "${NS_PORTAL}" get pods -l app=dbt-docs-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  kubectl -n "${NS_PORTAL}" get pods -l app=dbt-docs-gateway -o wide || true
  [[ -n "${POD}" ]] && kubectl -n "${NS_PORTAL}" describe pod "${POD}" | sed -n '1,240p' || true
  [[ -n "${POD}" ]] && kubectl -n "${NS_PORTAL}" logs "${POD}" -c sync --tail=200 || true
  exit 1
fi

URL_SCHEME="http"; [[ "${TLS_MODE}" != "off" ]] && URL_SCHEME="https"
log "[${MODULE_ID}][docs] OK (${URL_SCHEME}://${PORTAL_HOST}/dbt/docs/his_dmo/ ; strict=${DBT_DOCS_STRICT})"
