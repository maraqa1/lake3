#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 04-portal-ui.sh — Deploy OpenKPI Portal UI (Phase 1)
# - Namespace: ${PLATFORM_NS}
# - Service: portal-ui:80
# - Ingress (single host split):
#     /     -> portal-ui:80
#     /api  -> ${PORTAL_API_SVC:-portal-api}:${PORTAL_API_PORT:-8000}
# - UI served by nginx, assets packaged as tgz -> ConfigMap -> initContainer extract
# - No Helm; kubectl apply only
# ==============================================================================

HERE="0 0cd -- "0 0dirname -- "")" && pwd)"
ROOT="0 0cd -- "/../../.." && pwd)"

# shellcheck source=/dev/null
. "${ROOT}/00-env.sh"
# shellcheck source=/dev/null
. "${ROOT}/00-lib.sh"

require_cmd kubectl tar

NS="${PLATFORM_NS:-platform}"
UI_NAME="portal-ui"
API_SVC="${PORTAL_API_SVC:-portal-api}"
API_PORT="${PORTAL_API_PORT:-8000}"

# ensure namespace exists
kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}" >/dev/null

# package UI assets
[[ -d "${HERE}/ui" ]] || { echo "[FATAL] missing ${HERE}/ui"; ls -la "${HERE}"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# tar must contain top-level folder "ui/"
tar -czf "${TMP}/ui.tgz" -C "${HERE}" ui

kubectl -n "${NS}" delete configmap portal-ui-src --ignore-not-found >/dev/null 2>&1 || true
kubectl -n "${NS}" create configmap portal-ui-src --from-file=ui.tgz="${TMP}/ui.tgz" --dry-run=client -o yaml \
  | kubectl apply -f -

kapply <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${UI_NAME}
  namespace: ${NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${UI_NAME}
  template:
    metadata:
      labels:
        app: ${UI_NAME}
    spec:
      volumes:
        - name: ui-src
          configMap:
            name: portal-ui-src
        - name: ui-www
          emptyDir: {}
      initContainers:
        - name: unpack
          image: busybox:1.36
          command:
            - sh
            - -lc
            - |
              set -e
              mkdir -p /tmp/ui && tar -xzf /src/ui.tgz -C /tmp/ui
              cp -r /tmp/ui/ui/* /usr/share/nginx/html/
          volumeMounts:
            - name: ui-src
              mountPath: /src
            - name: ui-www
              mountPath: /usr/share/nginx/html
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 256Mi
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 3
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 10
            periodSeconds: 20
          volumeMounts:
            - name: ui-www
              mountPath: /usr/share/nginx/html
---
apiVersion: v1
kind: Service
metadata:
  name: ${UI_NAME}
  namespace: ${NS}
spec:
  selector:
    app: ${UI_NAME}
  ports:
    - name: http
      port: 80
      targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: portal-ingress
  namespace: ${NS}
  annotations:
    kubernetes.io/ingress.class: "${INGRESS_CLASS}"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    cert-manager.io/cluster-issuer: "${CLUSTER_ISSUER}"
spec:
  ingressClassName: "${INGRESS_CLASS}"
  tls:
    - hosts:
        - "${PORTAL_HOST}"
      secretName: portal-tls
  rules:
    - host: "${PORTAL_HOST}"
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: ${API_SVC}
                port:
                  number: ${API_PORT}
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${UI_NAME}
                port:
                  number: 80
YAML

wait_deploy "${NS}" "${UI_NAME}"
log "[04-portal-ui] OK (ns=${NS}, host=${PORTAL_HOST})"
