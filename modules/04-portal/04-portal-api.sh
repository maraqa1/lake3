#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/../../00-env.sh"

log "[04-portal-api] start"

require_cmd kubectl
require_var PLATFORM_NS
require_var PORTAL_HOST
require_var INGRESS_CLASS
require_var PORTAL_API_SVC

NS="${PLATFORM_NS}"
APP="portal-api"
SVC="${PORTAL_API_SVC}"
PORT=8080

kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}"

# Deployment: simple API placeholder (swap image later)
cat <<YAML | kubectl -n "${NS}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP}
  template:
    metadata:
      labels:
        app: ${APP}
    spec:
      containers:
        - name: api
          image: hashicorp/http-echo:1.0
          args:
            - "-listen=:${PORT}"
            - "-text={\"ok\":true,\"service\":\"portal-api\",\"host\":\"${PORTAL_HOST}\",\"health\":\"${PORTAL_SHOW_HEALTH:-on}\",\"links\":\"${PORTAL_SHOW_LINKS:-on}\"}"
          ports:
            - containerPort: ${PORT}
          readinessProbe:
            httpGet:
              path: /
              port: ${PORT}
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /
              port: ${PORT}
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: ${SVC}
spec:
  type: ClusterIP
  selector:
    app: ${APP}
  ports:
    - name: http
      port: 80
      targetPort: ${PORT}
YAML

kubectl -n "${NS}" rollout status deploy/${APP} --timeout=180s

# Ingress for /api (share same host with portal UI later)
if tls_enabled; then
  require_var CLUSTER_ISSUER
  require_var PORTAL_TLS_SECRET

  cat <<YAML | kubectl -n "${NS}" apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: portal-cert
spec:
  secretName: ${PORTAL_TLS_SECRET}
  issuerRef:
    kind: ClusterIssuer
    name: ${CLUSTER_ISSUER}
  dnsNames:
    - ${PORTAL_HOST}
YAML

  cat <<YAML | kubectl -n "${NS}" apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: portal-api-ingress
  annotations:
    kubernetes.io/ingress.class: "${INGRESS_CLASS}"
spec:
  ingressClassName: "${INGRESS_CLASS}"
  tls:
    - hosts: ["${PORTAL_HOST}"]
      secretName: ${PORTAL_TLS_SECRET}
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
                  number: 80
YAML
else
  cat <<YAML | kubectl -n "${NS}" apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: portal-api-ingress
  annotations:
    kubernetes.io/ingress.class: "${INGRESS_CLASS}"
spec:
  ingressClassName: "${INGRESS_CLASS}"
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
                  number: 80
YAML
fi

log "[04-portal-api] done"
