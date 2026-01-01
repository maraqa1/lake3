#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/../../00-env.sh"

log "[04-portal-ui] start"

require_cmd kubectl
require_var PLATFORM_NS
require_var PORTAL_HOST
require_var INGRESS_CLASS

NS="${PLATFORM_NS}"
DEPLOY="${PORTAL_UI_DEPLOY:-portal-ui}"
SVC="${PORTAL_UI_SVC:-portal-ui}"
CM="${PORTAL_UI_CM:-portal-ui-static}"

kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}"

# Static HTML content
cat <<'HTML' > /tmp/index.html
<!doctype html>
<html>
<head>
  <meta charset="utf-8"/>
  <title>OpenKPI Portal</title>
  <style>
    body{font-family:Arial,Helvetica,sans-serif;margin:40px}
    .grid{display:grid;grid-template-columns:repeat(3,minmax(220px,1fr));gap:14px}
    .card{border:1px solid #ddd;border-radius:10px;padding:14px}
    .card a{display:block;margin-top:8px}
    .small{color:#666;font-size:12px;margin-top:6px}
  </style>
</head>
<body>
<h1>OpenKPI</h1>
<div class="small">Single-node k3s • Modular installer • Contract-driven env</div>

<h2>Services</h2>
<div class="grid">
  <div class="card"><b>Airbyte</b><div class="small">Ingestion</div><a href="#" id="airbyte">Open</a></div>
  <div class="card"><b>MinIO</b><div class="small">Object storage</div><a href="#" id="minio">Open</a></div>
  <div class="card"><b>Metabase</b><div class="small">BI</div><a href="#" id="metabase">Open</a></div>
  <div class="card"><b>n8n</b><div class="small">Automation</div><a href="#" id="n8n">Open</a></div>
  <div class="card"><b>Zammad</b><div class="small">Ticketing</div><a href="#" id="zammad">Open</a></div>
</div>

<h2>API</h2>
<div class="card">
  <b>Portal API</b>
  <div class="small">Health and service links</div>
  <a href="/api" target="_blank">/api</a>
</div>

<script>
  const links = {
    airbyte:   "https://airbyte.lake1.opendatalake.com",
    minio:     "https://minio.lake1.opendatalake.com/console",
    metabase:  "https://metabase.lake1.opendatalake.com",
    n8n:       "https://n8n.lake1.opendatalake.com",
    zammad:    "https://zammad.lake1.opendatalake.com"
  };
  Object.keys(links).forEach(k=>{
    const el=document.getElementById(k);
    if(el) { el.href = links[k]; el.target="_blank"; }
  });
</script>
</body>
</html>
HTML

# ConfigMap for static assets
kubectl -n "${NS}" create configmap "${CM}" --from-file=index.html=/tmp/index.html --dry-run=client -o yaml | kubectl apply -f -

# Nginx deployment serving /usr/share/nginx/html
cat <<YAML | kubectl -n "${NS}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${DEPLOY}
  template:
    metadata:
      labels:
        app: ${DEPLOY}
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          volumeMounts:
            - name: web
              mountPath: /usr/share/nginx/html
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 3
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 10
            periodSeconds: 10
      volumes:
        - name: web
          configMap:
            name: ${CM}
---
apiVersion: v1
kind: Service
metadata:
  name: ${SVC}
spec:
  type: ClusterIP
  selector:
    app: ${DEPLOY}
  ports:
    - name: http
      port: 80
      targetPort: 80
YAML

kubectl -n "${NS}" rollout status deploy/"${DEPLOY}" --timeout=180s

# Ingress: root path -> UI. API is already /api on separate ingress.
if tls_enabled; then
  require_var PORTAL_TLS_SECRET
  cat <<YAML | kubectl -n "${NS}" apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: portal-ui-ingress
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
          - path: /
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
  name: portal-ui-ingress
  annotations:
    kubernetes.io/ingress.class: "${INGRESS_CLASS}"
spec:
  ingressClassName: "${INGRESS_CLASS}"
  rules:
    - host: ${PORTAL_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${SVC}
                port:
                  number: 80
YAML
fi

log "[04-portal-ui] done"
