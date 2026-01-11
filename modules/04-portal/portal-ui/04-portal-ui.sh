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
# TLS contract (FIXED):
# - If TLS_MODE != off, this module MUST create a cert-manager Certificate that
#   writes ${PLATFORM_NS}/${PORTAL_TLS_SECRET}, then Ingress references it.
#
# Host conflict contract:
# - No other Ingress in any namespace may claim ${PORTAL_HOST}.
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
: "${CERT_CLUSTER_ISSUER:=letsencrypt-http01}"

log "[04][portal-ui] start (ns=${PLATFORM_NS}, host=${PORTAL_HOST}, tls_mode=${TLS_MODE})"

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

# ------------------------------------------------------------------------------
# Guardrail: detect host conflicts (same host claimed by multiple ingresses)
# ------------------------------------------------------------------------------
HOST_OWNERS="$(kubectl get ingress -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .spec.rules[*]}{.host}{" "}{end}{"\n"}{end}' \
  | awk -v h="${PORTAL_HOST}" '$0 ~ h {print $0}' || true)"

OWNER_COUNT="$(printf "%s\n" "${HOST_OWNERS}" | sed '/^\s*$/d' | wc -l | tr -d ' ')"
if [[ "${OWNER_COUNT}" -gt 1 ]]; then
  echo "FATAL: host ${PORTAL_HOST} is claimed by multiple Ingress objects:"
  printf "%s\n" "${HOST_OWNERS}"
  echo "Fix: delete/rename the other ingress(es) so ONLY ${PLATFORM_NS}/portal-ingress owns ${PORTAL_HOST}."
  exit 1
fi

# ------------------------------------------------------------------------------
# TLS: create Certificate -> Secret in SAME namespace as Ingress (platform)
# ------------------------------------------------------------------------------
if [[ "${TLS_ENABLED}" == "true" ]]; then
  kubectl apply -f - <<YAML
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${PORTAL_TLS_SECRET}
  namespace: ${PLATFORM_NS}
spec:
  secretName: ${PORTAL_TLS_SECRET}
  dnsNames:
    - ${PORTAL_HOST}
  issuerRef:
    kind: ClusterIssuer
    name: ${CERT_CLUSTER_ISSUER}
YAML
fi

# ------------------------------------------------------------------------------
# Ingress manifest with inline TLS (no post-patch)
# ------------------------------------------------------------------------------
INGRESS_TLS_BLOCK=""
if [[ "${TLS_ENABLED}" == "true" ]]; then
  INGRESS_TLS_BLOCK=$(cat <<EOF
  tls:
    - hosts:
        - ${PORTAL_HOST}
      secretName: ${PORTAL_TLS_SECRET}
EOF
)
fi

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
${INGRESS_TLS_BLOCK}
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

kubectl -n "${PLATFORM_NS}" rollout status "deploy/${PORTAL_UI_DEPLOY}" --timeout=300s

# If TLS is on, wait briefly for secret existence (issuer async)
if [[ "${TLS_ENABLED}" == "true" ]]; then
  for i in {1..60}; do
    if kubectl -n "${PLATFORM_NS}" get secret "${PORTAL_TLS_SECRET}" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
fi

log "[04][portal-ui] OK"
