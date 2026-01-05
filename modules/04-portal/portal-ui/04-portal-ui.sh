#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 04-portal-ui.sh — OpenKPI Portal UI (static nginx) [REPEATABLE]
# - Packages ./ui -> ui.tgz
# - Creates/updates ConfigMap ${PLATFORM_NS}/portal-ui-static with ui.tgz
# - nginx serves static UI
# - Creates/updates ONE ingress on ${PORTAL_HOST}:
#     /api -> ${PORTAL_API_SVC}:${PORTAL_API_PORT}
#     /    -> portal-ui:80
#
# Critical: uses MODULE_DIR, not HERE (00-env.sh overwrites HERE).
# ==============================================================================

MODULE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${MODULE_DIR}/../../.." && pwd)"

# shellcheck source=/dev/null
. "${ROOT_DIR}/00-env.sh"
# shellcheck source=/dev/null
. "${ROOT_DIR}/00-lib.sh"

require_cmd kubectl tar

: "${PLATFORM_NS:=platform}"
: "${INGRESS_CLASS:=nginx}"
: "${PORTAL_HOST:=portal.local}"

: "${PORTAL_UI_DEPLOY:=portal-ui}"
: "${PORTAL_UI_SVC:=portal-ui}"
: "${PORTAL_UI_CM:=portal-ui-static}"

: "${PORTAL_API_SVC:=portal-api}"
: "${PORTAL_API_PORT:=8000}"

: "${TLS_MODE:=off}"
: "${PORTAL_TLS_SECRET:=portal-tls}"

log "[04][portal-ui] start (ns=${PLATFORM_NS}, host=${PORTAL_HOST})"

kubectl get ns "${PLATFORM_NS}" >/dev/null 2>&1 || kubectl create ns "${PLATFORM_NS}" >/dev/null

UI_DIR="${MODULE_DIR}/ui"
[ -d "${UI_DIR}" ] || { echo "FATAL: missing ${UI_DIR}"; ls -la "${MODULE_DIR}"; exit 1; }
[ -f "${UI_DIR}/index.html" ] || { echo "FATAL: missing ${UI_DIR}/index.html"; ls -la "${UI_DIR}"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

tar -czf "${TMP}/ui.tgz" -C "${MODULE_DIR}" ui

kubectl -n "${PLATFORM_NS}" create configmap "${PORTAL_UI_CM}" \
  --from-file=ui.tgz="${TMP}/ui.tgz" \
  -o yaml --dry-run=client | kubectl apply -f - >/dev/null

TLS_ENABLED="false"
if [[ "${TLS_MODE}" != "off" && "${TLS_MODE}" != "OFF" ]]; then
  TLS_ENABLED="true"
fi

# IMPORTANT: portal-api ingress must NOT exist; this ingress owns /api and / on the same host.
kubectl apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${PORTAL_UI_DEPLOY}
  namespace: ${PLATFORM_NS}
  labels: { app: portal-ui }
spec:
  replicas: 1
  selector:
    matchLabels: { app: portal-ui }
  template:
    metadata:
      labels: { app: portal-ui }
    spec:
      volumes:
        - name: ui-src
          configMap:
            name: ${PORTAL_UI_CM}
        - name: ui-html
          emptyDir: {}
      initContainers:
        - name: unpack-ui
          image: alpine:3.20
          command:
            - sh
            - -lc
            - |
              set -e
              mkdir -p /www
              tar -xzf /src/ui.tgz -C /www
              rm -rf /dest/*
              cp -r /www/ui/* /dest/
          volumeMounts:
            - name: ui-src
              mountPath: /src
              readOnly: true
            - name: ui-html
              mountPath: /dest
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          volumeMounts:
            - name: ui-html
              mountPath: /usr/share/nginx/html
          readinessProbe:
            httpGet: { path: /, port: 80 }
            initialDelaySeconds: 2
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: ${PORTAL_UI_SVC}
  namespace: ${PLATFORM_NS}
  labels: { app: portal-ui }
spec:
  selector: { app: portal-ui }
  ports:
    - name: http
      port: 80
      targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: portal-ingress
  namespace: ${PLATFORM_NS}
  annotations:
    kubernetes.io/ingress.class: ${INGRESS_CLASS}
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
                name: ${PORTAL_API_SVC}
                port:
                  number: ${PORTAL_API_PORT}
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${PORTAL_UI_SVC}
                port:
                  number: 80
YAML

if [[ "${TLS_ENABLED}" == "true" ]]; then
  kubectl -n "${PLATFORM_NS}" patch ingress portal-ingress --type merge -p "{
    \"spec\": { \"tls\": [ { \"hosts\": [ \"${PORTAL_HOST}\" ], \"secretName\": \"${PORTAL_TLS_SECRET}\" } ] }
  }" >/dev/null 2>&1 || true
fi

kubectl -n "${PLATFORM_NS}" rollout status "deploy/${PORTAL_UI_DEPLOY}" --timeout=300s
log "[04][portal-ui] OK"
