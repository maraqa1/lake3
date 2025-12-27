# ==============================================================================
# MODULE 04B — PORTAL UI (Static nginx, idempotent)
# FILE: 04-portal-ui.sh
#
# Purpose:
#   Deploy the OpenKPI Portal UI in namespace "platform" as a static nginx site
#   with a reverse-proxy for /api/* to the in-cluster Portal API service.
#
# What this script converges (safe to re-run):
#   1) Namespace: platform (if missing)
#   2) ConfigMaps:
#      - platform/portal-ui-nginx  (nginx.conf with late DNS resolver)
#      - platform/portal-ui-web    (index.html single-page UI)
#   3) UI Deployment:
#      - nginx-unprivileged on :8080
#      - readiness/liveness via /healthz
#      - never CrashLoops if API is absent (resolver + variable proxy_pass)
#   4) UI Service:
#      - platform/portal-ui (ClusterIP) on port 80 -> target 8080
#   5) Ingress:
#      - host: ${PORTAL_HOST}
#      - ingressClass: ${INGRESS_CLASS}
#      - TLS only when TLS_MODE=per-host-http01 (secret: portal-tls)
#   6) Deterministic rollout readiness wait for portal-ui Deployment
#
# Reverse proxy:
#   - /api/*  -> http://portal-api.platform.svc.cluster.local:8000
#
# Inputs (from 00-env.sh contract):
#   PORTAL_HOST, KUBE_DNS_IP, INGRESS_CLASS, TLS_MODE
# ==============================================================================

#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/00-env.sh"
# shellcheck source=/dev/null
. "${HERE}/00-lib.sh"

require_cmd kubectl

: "${KUBE_DNS_IP:=10.43.0.10}"
: "${INGRESS_CLASS:=nginx}"
: "${TLS_MODE:=off}"
: "${NS_PLATFORM:=platform}"

: "${PORTAL_HOST:?missing PORTAL_HOST}"

PLATFORM_NS="${NS_PLATFORM}"

ensure_ns "${PLATFORM_NS}"

TLS_BLOCK=""
if [[ "${TLS_MODE}" == "per-host-http01" ]]; then
  TLS_BLOCK=$(cat <<EOF
  tls:
    - hosts:
        - ${PORTAL_HOST}
      secretName: portal-tls
EOF
)
fi

CM_ISSUER_ANN=""
if [[ "${TLS_MODE}" == "per-host-http01" ]]; then
  CM_ISSUER_ANN=$'    cert-manager.io/cluster-issuer: letsencrypt-http01\n'
fi


log "[04B][PORTAL-UI] Deploy static nginx UI (ConfigMap) with late DNS resolver + variable proxy_pass"
kubectl -n "${PLATFORM_NS}" apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: portal-ui-nginx
  namespace: ${PLATFORM_NS}
data:
  nginx.conf: |
    worker_processes  1;
    error_log  /dev/stderr warn;
    pid        /tmp/nginx.pid;

    events { worker_connections 1024; }

    http {
      include       /etc/nginx/mime.types;
      default_type  application/octet-stream;
      sendfile      on;
      keepalive_timeout  65;

      # Late DNS resolution: never crash if API is not yet up
      resolver ${KUBE_DNS_IP} valid=10s ipv6=off;

      server {
        listen 8080;
        server_name _;

        root /usr/share/nginx/html;
        index index.html;

        location = /healthz {
          return 200 "ok\n";
        }

        location /api/ {
          set \$upstream "http://portal-api.platform.svc.cluster.local:8000";
          proxy_http_version 1.1;
          proxy_set_header Host \$host;
          proxy_set_header X-Real-IP \$remote_addr;
          proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto \$scheme;
          proxy_connect_timeout 2s;
          proxy_read_timeout 30s;
          proxy_send_timeout 30s;
          proxy_next_upstream error timeout http_502 http_503 http_504;
          proxy_pass \$upstream;
        }

        location / {
          try_files \$uri \$uri/ /index.html;
        }
      }
    }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: portal-ui-web
  namespace: ${PLATFORM_NS}
data:
  index.html: |
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width,initial-scale=1"/>
      <title>OpenKPI Portal</title>
      <style>
        body { font-family: system-ui, -apple-system, Segoe UI, Roboto, Arial, sans-serif; margin: 0; background: #0b1220; color: #e6eaf2; }
        header { padding: 18px 22px; background: #0f1a33; border-bottom: 1px solid rgba(255,255,255,0.08); }
        h1 { font-size: 18px; margin: 0; letter-spacing: 0.3px; }
        main { padding: 18px 22px; display: grid; gap: 14px; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 12px; }
        .card { background: #0f1a33; border: 1px solid rgba(255,255,255,0.08); border-radius: 10px; padding: 12px 12px; }
        .card h2 { font-size: 14px; margin: 0 0 8px 0; color: #cfe0ff; }
        .k { opacity: 0.8; }
        .ok { color: #58d68d; }
        .bad { color: #ff6b6b; }
        table { width: 100%; border-collapse: collapse; font-size: 12px; }
        th, td { padding: 6px 6px; border-bottom: 1px solid rgba(255,255,255,0.06); vertical-align: top; }
        th { text-align: left; opacity: 0.85; }
        a { color: #8fb5ff; text-decoration: none; }
        a:hover { text-decoration: underline; }
        .small { font-size: 12px; opacity: 0.85; }
        .muted { opacity: 0.7; }
        .row { display:flex; gap:10px; flex-wrap:wrap; }
        .pill { padding: 2px 8px; border-radius: 999px; border: 1px solid rgba(255,255,255,0.12); font-size: 12px; }
      </style>
    </head>
    <body>
      <header>
        <h1>OpenKPI Portal</h1>
        <div class="small muted" id="statusline">Loading…</div>
      </header>

      <main>
        <div class="grid">
          <div class="card">
            <h2>Overall platform status</h2>
            <div class="row" id="overall"></div>
          </div>
          <div class="card">
            <h2>Deep links</h2>
            <div class="small">
              <div><span class="k">Portal API:</span> <a href="/api/health" target="_blank" rel="noreferrer">/api/health</a></div>
              <div><span class="k">Airbyte:</span> <a id="airbyteLink" href="#" target="_blank" rel="noreferrer">—</a></div>
              <div><span class="k">MinIO:</span> <a id="minioLink" href="#" target="_blank" rel="noreferrer">—</a></div>
              <div><span class="k">n8n:</span> <a id="n8nLink" href="#" target="_blank" rel="noreferrer">—</a></div>
              <div><span class="k">Zammad:</span> <a id="zammadLink" href="#" target="_blank" rel="noreferrer">—</a></div>
            </div>
          </div>
        </div>

        <div class="grid">
          <div class="card">
            <h2>Per-app health (pods/deployments)</h2>
            <div id="apps"></div>
          </div>
          <div class="card">
            <h2>Data catalogue snapshot</h2>
            <div id="catalog"></div>
          </div>
        </div>

        <div class="card">
          <h2>Last ingestion summary (Airbyte)</h2>
          <div id="ingestion"></div>
        </div>
      </main>

      <script>
        function esc(s){ return String(s).replaceAll("&","&amp;").replaceAll("<","&lt;").replaceAll(">","&gt;"); }
        function pill(text, ok=true){ return '<span class="pill ' + (ok?'ok':'bad') + '">' + esc(text) + '</span>'; }

        function linkFromHost(host) {
          if (!host) return "—";
          return window.location.protocol + "//" + host + "/";
        }

        async function load() {
          const statusline = document.getElementById("statusline");
          const overall = document.getElementById("overall");
          const apps = document.getElementById("apps");
          const catalog = document.getElementById("catalog");
          const ingestion = document.getElementById("ingestion");

          let summary = null;
          try {
            const r = await fetch("/api/summary", { cache: "no-store" });
            summary = await r.json();
            statusline.textContent = "API reachable. Updated: " + new Date().toISOString();
          } catch (e) {
            statusline.innerHTML = '<span class="bad">API unreachable</span> (UI stays up; retrying)';
            overall.innerHTML = pill("API down", false);
            apps.innerHTML = '<div class="small muted">No data</div>';
            catalog.innerHTML = '<div class="small muted">No data</div>';
            ingestion.innerHTML = '<div class="small muted">No data</div>';
            return;
          }

          overall.innerHTML = pill("API OK", true);

          const ns = (summary.k8s && summary.k8s.namespaces) ? summary.k8s.namespaces : [];
          const nsMap = {};
          ns.forEach(x => nsMap[x.name] = x);

          function renderNsCard(name, data) {
            const pods = (data.pods || []);
            const deps = (data.deployments || []);
            const stss = (data.statefulsets || []);

            const badPods = pods.filter(p => (p.phase !== "Running" && p.phase !== "Succeeded"));
            const restartSum = pods.reduce((a,p)=>a+(p.restarts||0),0);

            const lines = [];
            lines.push('<div class="row">' + pill(name, badPods.length===0) + pill("pods: " + pods.length, true) + pill("restarts: " + restartSum, restartSum===0) + '</div>');
            if (deps.length) {
              lines.push('<div class="small"><span class="k">deployments</span><ul>');
              deps.slice(0,12).forEach(d => lines.push('<li>' + esc(d.name) + ' <span class="muted">(' + esc(d.ready) + ')</span></li>'));
              lines.push('</ul></div>');
            }
            if (stss.length) {
              lines.push('<div class="small"><span class="k">statefulsets</span><ul>');
              stss.slice(0,12).forEach(s => lines.push('<li>' + esc(s.name) + ' <span class="muted">(' + esc(s.ready) + ')</span></li>'));
              lines.push('</ul></div>');
            }
            return '<div class="card" style="margin:0 0 10px 0;">' + lines.join("") + '</div>';
          }

          const targets = ["open-kpi","airbyte","n8n","tickets","transform","platform"];
          apps.innerHTML = targets
            .filter(n => nsMap[n])
            .map(n => renderNsCard(n, nsMap[n]))
            .join("") || '<div class="small muted">No namespaces visible</div>';

          const pg = (summary.catalog && summary.catalog.postgres) ? summary.catalog.postgres : {};
          const mi = (summary.catalog && summary.catalog.minio) ? summary.catalog.minio : {};

          const pgOk = !!pg.ok;
          const miOk = !!mi.ok;

          let catHtml = '<div class="row">' + pill("Postgres: " + (pgOk?"OK":"N/A"), pgOk) + pill("MinIO: " + (miOk?"OK":"N/A"), miOk) + '</div>';

          catHtml += '<div class="small" style="margin-top:8px;"><div class="k">Postgres schemas</div>';
          if (pgOk) {
            catHtml += '<div class="muted">' + esc((pg.schemas||[]).slice(0,30).join(", ") || "—") + '</div>';
            catHtml += '<div class="k" style="margin-top:6px;">Tables (first 50)</div>';
            const rows = (pg.tables||[]).slice(0,50).map(t => '<tr><td>'+esc(t.schema)+'</td><td>'+esc(t.table)+'</td></tr>').join("");
            catHtml += '<table><thead><tr><th>Schema</th><th>Table</th></tr></thead><tbody>' + rows + '</tbody></table>';
          } else {
            catHtml += '<div class="muted">' + esc(pg.error || "Unavailable") + '</div>';
          }
          catHtml += '</div>';

          catHtml += '<div class="small" style="margin-top:10px;"><div class="k">MinIO buckets</div>';
          if (miOk) {
            const rows = (mi.buckets||[]).slice(0,50).map(b => '<tr><td>'+esc(b.name)+'</td><td class="muted">'+esc(b.created||"")+'</td></tr>').join("");
            catHtml += '<table><thead><tr><th>Bucket</th><th>Created</th></tr></thead><tbody>' + rows + '</tbody></table>';
          } else {
            catHtml += '<div class="muted">' + esc(mi.error || "Unavailable") + '</div>';
          }
          catHtml += '</div>';

          catalog.innerHTML = catHtml;

          const ing = summary.ingestion || {};
          const ab = ing.airbyte || {};
          const abPods = ab.pods || [];
          const abEv = ab.events || [];

          let ingHtml = '<div class="row">' + pill("Airbyte pods: " + abPods.length, true) + '</div>';
          if (abPods.length) {
            const rows = abPods.slice(0,30).map(p => '<tr><td>'+esc(p.name)+'</td><td>'+esc(p.phase)+'</td><td>'+esc(p.restarts||0)+'</td></tr>').join("");
            ingHtml += '<table><thead><tr><th>Pod</th><th>Phase</th><th>Restarts</th></tr></thead><tbody>' + rows + '</tbody></table>';
          }
          if (abEv.length) {
            ingHtml += '<div class="small" style="margin-top:10px;"><div class="k">Recent events</div><ul>';
            abEv.slice(0,12).forEach(e => ingHtml += '<li><span class="muted">'+esc(e.ts||"")+'</span> ' + esc(e.reason||"") + ' — ' + esc(e.message||"") + '</li>');
            ingHtml += '</ul></div>';
          }
          ingestion.innerHTML = ingHtml;

          // Deep links (host inference only; safe even if absent)
          // Prefer commonly used subdomains; if not present in env, show portal host base.
          const base = window.location.host;
          document.getElementById("airbyteLink").textContent = "airbyte." + base;
          document.getElementById("airbyteLink").href = window.location.protocol + "//" + "airbyte." + base + "/";
          document.getElementById("minioLink").textContent = "minio." + base;
          document.getElementById("minioLink").href = window.location.protocol + "//" + "minio." + base + "/";
          document.getElementById("n8nLink").textContent = "n8n." + base;
          document.getElementById("n8nLink").href = window.location.protocol + "//" + "n8n." + base + "/";
          document.getElementById("zammadLink").textContent = "zammad." + base;
          document.getElementById("zammadLink").href = window.location.protocol + "//" + "zammad." + base + "/";
        }

        load();
        setInterval(load, 15000);
      </script>
    </body>
    </html>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: portal-ui
  namespace: ${PLATFORM_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: portal-ui
  template:
    metadata:
      labels:
        app: portal-ui
    spec:
      containers:
        - name: nginx
          image: nginxinc/nginx-unprivileged:1.27-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: nginxconf
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
            - name: web
              mountPath: /usr/share/nginx/html/index.html
              subPath: index.html
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 2
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 6
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 6
      volumes:
        - name: nginxconf
          configMap:
            name: portal-ui-nginx
        - name: web
          configMap:
            name: portal-ui-web
---
apiVersion: v1
kind: Service
metadata:
  name: portal-ui
  namespace: ${PLATFORM_NS}
spec:
  type: ClusterIP
  selector:
    app: portal-ui
  ports:
    - name: http
      port: 80
      targetPort: 8080
YAML

log "[04B][PORTAL-UI] Create/update Ingress (host=${PORTAL_HOST}, class=${INGRESS_CLASS}, TLS_MODE=${TLS_MODE})"

# Replace your block with this (adds conditional cert-manager annotation safely):

CM_ISSUER_ANN=""
if [[ "${TLS_MODE}" == "per-host-http01" ]]; then
  CM_ISSUER_ANN=$'    cert-manager.io/cluster-issuer: letsencrypt-http01\n'
fi

kubectl -n "${PLATFORM_NS}" apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: portal
  namespace: ${PLATFORM_NS}
  annotations:
    kubernetes.io/ingress.class: ${INGRESS_CLASS}
${CM_ISSUER_ANN}spec:
  ingressClassName: ${INGRESS_CLASS}
${TLS_BLOCK}
  rules:
    - host: ${PORTAL_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: portal-ui
                port:
                  number: 80
YAML


log "[04B][PORTAL-UI] Readiness check (deterministic)"
kubectl_wait_deploy "${PLATFORM_NS}" portal-ui 180s

log "[04B][PORTAL-UI] Done"
