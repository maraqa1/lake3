#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 04-portal-ui.sh — Portal UI (static nginx) in namespace platform
# - Serves HTML+JS UI at /
# - Proxies /api/* to portal-api service
# - Unprivileged-safe nginx config (pid + temp paths under /tmp, listen 8080)
# - Idempotent: kubectl apply; safe to re-run
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/00-env.sh"
# shellcheck source=/dev/null
. "${HERE}/00-lib.sh"

require_cmd kubectl

PLATFORM_NS="${PLATFORM_NS:-platform}"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
TLS_MODE="${TLS_MODE:-off}"
PORTAL_HOST="${PORTAL_HOST:-portal.${APP_DOMAIN:-}}"

ensure_ns "${PLATFORM_NS}"

TLS_BLOCK=""
if [[ "${TLS_MODE}" != "off" ]]; then
  TLS_BLOCK="tls:
  - hosts:
    - __PORTAL_HOST__
    secretName: portal-tls"
fi

log "[04B][PORTAL-UI] Applying ConfigMap (nginx.conf + index.html)"

CM_YAML="$(cat <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: portal-ui-static
  namespace: __PLATFORM_NS__
data:
  nginx.conf: |
    worker_processes  1;
    pid /tmp/nginx.pid;

    events { worker_connections  1024; }

    http {
      include       /etc/nginx/mime.types;
      default_type  application/octet-stream;

      sendfile        on;
      keepalive_timeout  65;

      client_body_temp_path /tmp/client_body;
      proxy_temp_path       /tmp/proxy;
      fastcgi_temp_path     /tmp/fastcgi;
      uwsgi_temp_path       /tmp/uwsgi;
      scgi_temp_path        /tmp/scgi;

      server {
        listen 8080;
        server_name _;

        root /usr/share/nginx/html;
        index index.html;

        location / {
          try_files $uri $uri/ /index.html;
        }

        location = /healthz {
          add_header Content-Type text/plain;
          return 200 'ok';
        }

        location /api/ {
          proxy_http_version 1.1;
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_read_timeout 30s;
          proxy_connect_timeout 5s;
          proxy_pass http://portal-api.__PLATFORM_NS__.svc.cluster.local/;
        }
      }
    }

  index.html: |
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>OpenKPI Portal</title>
      <style>
        :root{
          --bg:#0b1020; --panel:#111a33; --panel2:#0f1730; --txt:#e7ecff; --muted:#aab3d6;
          --ok:#2fe39b; --warn:#ffcc66; --bad:#ff5c7a; --line:rgba(255,255,255,.08);
        }
        *{box-sizing:border-box}
        body{margin:0;font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial;
             background:radial-gradient(1200px 700px at 10% 10%, #152454 0%, var(--bg) 60%);
             color:var(--txt)}
        header{padding:18px 20px; border-bottom:1px solid var(--line); display:flex; gap:12px; align-items:center; justify-content:space-between}
        .brand{display:flex; gap:12px; align-items:center}
        .logo{width:34px;height:34px;border-radius:10px;background:linear-gradient(135deg,#2fe39b,#4db3ff); box-shadow:0 10px 30px rgba(77,179,255,.2)}
        .title{display:flex;flex-direction:column}
        .title b{font-size:14px; letter-spacing:.5px}
        .title span{font-size:12px;color:var(--muted)}
        .statuspill{display:flex; gap:10px; align-items:center; padding:8px 12px; border:1px solid var(--line); border-radius:14px; background:rgba(17,26,51,.65)}
        .dot{width:10px;height:10px;border-radius:999px;background:var(--warn); box-shadow:0 0 0 4px rgba(255,204,102,.12)}
        .dot.ok{background:var(--ok); box-shadow:0 0 0 4px rgba(47,227,155,.12)}
        .dot.bad{background:var(--bad); box-shadow:0 0 0 4px rgba(255,92,122,.12)}
        main{padding:18px 20px; max-width:1200px; margin:0 auto}
        .grid{display:grid; gap:14px; grid-template-columns:repeat(12,1fr)}
        .card{grid-column:span 4; background:linear-gradient(180deg, rgba(17,26,51,.85), rgba(15,23,48,.75));
              border:1px solid var(--line); border-radius:16px; padding:14px; min-height:132px}
        .card h3{margin:0 0 8px 0; font-size:13px; letter-spacing:.4px}
        .sub{font-size:12px; color:var(--muted); line-height:1.35}
        .row{display:flex; gap:10px; align-items:center; justify-content:space-between}
        .kv{display:flex; gap:10px; flex-wrap:wrap; margin-top:10px}
        .tag{font-size:11px; color:var(--muted); padding:6px 10px; border:1px solid var(--line);
             border-radius:999px; background:rgba(11,16,32,.35)}
        .tag b{color:var(--txt); font-weight:600}
        .actions{display:flex; gap:8px; flex-wrap:wrap; margin-top:12px}
        a.btn{display:inline-flex; align-items:center; text-decoration:none; color:var(--txt); font-size:12px;
             padding:7px 10px; border-radius:12px; border:1px solid var(--line); background:rgba(31,42,85,.6)}
        a.btn:hover{background:rgba(36,49,97,.85)}
        .wide{grid-column:span 6; min-height:160px}
        .full{grid-column:span 12}
        pre{margin:0; padding:12px; border-radius:14px; background:rgba(11,16,32,.55); border:1px solid var(--line);
            color:#dfe6ff; overflow:auto; font-size:12px; line-height:1.45}
        @media (max-width: 980px){ .card{grid-column:span 6} .wide{grid-column:span 12} }
        @media (max-width: 620px){ .card{grid-column:span 12} }
      </style>
    </head>
    <body>
      <header>
        <div class="brand">
          <div class="logo"></div>
          <div class="title">
            <b>OpenKPI Portal</b>
            <span id="subtitle">Loading platform summary...</span>
          </div>
        </div>
        <div class="statuspill">
          <div id="dot" class="dot"></div>
          <div>
            <div style="font-size:12px"><b id="overall">Checking...</b></div>
            <div style="font-size:11px;color:var(--muted)" id="ts"></div>
          </div>
        </div>
      </header>

      <main>
        <div class="grid">
          <div class="card wide">
            <h3>Platform Overview</h3>
            <div class="sub" id="overview">—</div>
            <div class="kv">
              <div class="tag"><b id="appsUp">0</b> apps up</div>
              <div class="tag"><b id="appsDown">0</b> apps down</div>
              <div class="tag"><b id="pods">0</b> pods</div>
              <div class="tag"><b id="restarts">0</b> restarts</div>
            </div>
            <div class="actions" id="topLinks"></div>
          </div>

          <div class="card wide">
            <h3>Data Catalogue Snapshot</h3>
            <div class="sub" id="catalogSub">—</div>
            <div class="kv" id="catalogTags"></div>
            <div class="actions" id="dataLinks"></div>
          </div>

          <div class="card full">
            <h3>Applications</h3>
            <div class="grid" id="appsGrid"></div>
          </div>

          <div class="card full">
            <h3>Raw Summary (debug)</h3>
            <pre id="raw">Loading...</pre>
          </div>
        </div>
      </main>

      <script>
        function el(id){ return document.getElementById(id); }
        function fmt(x){ return (x===null || x===undefined) ? "—" : String(x); }
        function mkLink(href, label){
          var a=document.createElement("a");
          a.className="btn";
          a.href=href; a.target="_blank"; a.rel="noopener";
          a.textContent=label;
          return a;
        }
        function statusDot(ok){
          var d=el("dot"); d.className="dot";
          if(ok) d.classList.add("ok"); else d.classList.add("bad");
        }
        function appCard(name, app){
          var c=document.createElement("div");
          c.className="card";
          var up = !!app.available || !!app.ok || (app.status && String(app.status).toLowerCase()==="ok");
          var warn = !!app.warn || !!app.degraded;
          var st = up ? (warn ? "Degraded" : "Up") : "Down";
          var msg = app.message || app.error || app.note || "";
          c.innerHTML =
            '<div class="row">' +
              '<h3 style="margin:0">' + name + '</h3>' +
              '<div class="tag"><b>' + st + '</b></div>' +
            '</div>' +
            '<div class="sub">' + fmt(msg) + '</div>' +
            '<div class="kv">' +
              '<div class="tag">pods: <b>' + fmt(app.pods || app.podCount || "—") + '</b></div>' +
              '<div class="tag">restarts: <b>' + fmt(app.restarts || "—") + '</b></div>' +
              '<div class="tag">last change: <b>' + fmt(app.last_change || app.lastChange || "—") + '</b></div>' +
            '</div>';
          var actions=document.createElement("div");
          actions.className="actions";
          if(app.url) actions.appendChild(mkLink(app.url, "Open"));
          if(app.deep_link) actions.appendChild(mkLink(app.deep_link, "Deep link"));
          if(app.links && typeof app.links==="object"){
            Object.keys(app.links).forEach(function(k){
              var v = app.links[k];
              if(v) actions.appendChild(mkLink(v, k));
            });
          }
          c.appendChild(actions);
          return c;
        }

        async function main(){
          try{
            var r = await fetch("/api/summary", {cache:"no-store"});
            if(!r.ok) throw new Error("HTTP " + r.status);
            var j = await r.json();
            el("raw").textContent = JSON.stringify(j, null, 2);

            var ts = j.ts || j.time || j.generated_at || "";
            el("ts").textContent = ts ? ("ts: " + ts) : "";

            var cat = j.catalog || {};
            var minioOk = cat.minio && (cat.minio.available || (cat.minio.health && cat.minio.health.ok));
            var pgOk = cat.postgres && (cat.postgres.available || !cat.postgres.error);

            var issues = [];
            if(!minioOk) issues.push("MinIO");
            if(!pgOk) issues.push("Postgres");

            var ok = (issues.length===0);
            el("overall").textContent = ok ? "Operational" : ("Needs Attention: " + issues.join(", "));
            statusDot(ok);

            var plat = j.platform || {};
            el("pods").textContent = fmt(plat.pods || (j.pods && j.pods.total) || "—");
            el("restarts").textContent = fmt(plat.restarts || (j.pods && j.pods.restarts) || "—");

            var apps = j.apps || j.services || {};
            var appsGrid = el("appsGrid");
            appsGrid.innerHTML="";

            var keys = Object.keys(apps);
            var upCount=0, downCount=0;

            if(keys.length===0){
              appsGrid.innerHTML = '<div class="sub" style="grid-column:span 12">No apps reported by API.</div>';
            } else {
              keys.forEach(function(name){
                var a = apps[name] || {};
                var up = !!a.available || !!a.ok || (a.status && String(a.status).toLowerCase()==="ok");
                if(up) upCount++; else downCount++;
                appsGrid.appendChild(appCard(name, a));
              });
            }

            el("appsUp").textContent = String(upCount);
            el("appsDown").textContent = String(downCount);
            el("subtitle").textContent = ok ? "UI loaded; API reachable" : "UI loaded; core services incomplete";

            var tags = el("catalogTags");
            tags.innerHTML="";

            var buckets = (cat.minio && cat.minio.buckets) ? cat.minio.buckets.length : 0;
            var schemas = (cat.postgres && cat.postgres.schemas) ? cat.postgres.schemas.length : 0;
            var tables  = (cat.postgres && cat.postgres.tables) ? cat.postgres.tables.length : 0;

            var t1=document.createElement("div"); t1.className="tag"; t1.innerHTML='MinIO buckets: <b>' + fmt(buckets) + '</b>';
            var t2=document.createElement("div"); t2.className="tag"; t2.innerHTML='Postgres schemas: <b>' + fmt(schemas) + '</b>';
            var t3=document.createElement("div"); t3.className="tag"; t3.innerHTML='Postgres tables: <b>' + fmt(tables) + '</b>';

            tags.appendChild(t1); tags.appendChild(t2); tags.appendChild(t3);

            var minioText = (cat.minio && cat.minio.health && cat.minio.health.ok) ? "MinIO OK. " : "MinIO not ready. ";
            var pgText = (cat.postgres && !cat.postgres.error) ? "Postgres OK." : "Postgres not ready.";
            el("catalogSub").textContent = minioText + pgText;

            var topLinks = el("topLinks");
            var dataLinks = el("dataLinks");
            topLinks.innerHTML="";
            dataLinks.innerHTML="";

            if(j.links && typeof j.links==="object"){
              Object.keys(j.links).forEach(function(k){
                var v = j.links[k];
                if(v) topLinks.appendChild(mkLink(v, k));
              });
            } else {
              topLinks.appendChild(mkLink("/api/health", "API health"));
              topLinks.appendChild(mkLink("/api/summary", "API summary"));
            }

            if(apps.minio && apps.minio.url) dataLinks.appendChild(mkLink(apps.minio.url, "MinIO Console"));
            if(apps.airbyte && apps.airbyte.url) dataLinks.appendChild(mkLink(apps.airbyte.url, "Airbyte"));
            if(apps.n8n && apps.n8n.url) dataLinks.appendChild(mkLink(apps.n8n.url, "n8n"));
            if(apps.zammad && apps.zammad.url) dataLinks.appendChild(mkLink(apps.zammad.url, "Zammad"));

          } catch(e){
            el("subtitle").textContent = "UI loaded; failed to fetch /api/summary";
            el("overall").textContent = "API unreachable";
            statusDot(false);
            el("raw").textContent = String(e);
          }
        }

        main();
        setInterval(main, 15000);
      </script>
    </body>
    </html>
YAML
)"

CM_YAML="${CM_YAML//__PLATFORM_NS__/${PLATFORM_NS}}"
apply_yaml "${CM_YAML}"

log "[04B][PORTAL-UI] Applying portal-ui Deployment + Service"

DS_YAML="$(cat <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: portal-ui
  namespace: __PLATFORM_NS__
  labels:
    app: portal-ui
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
        - name: portal-ui
          image: nginxinc/nginx-unprivileged:1.27-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 25m
              memory: 64Mi
            limits:
              cpu: 300m
              memory: 256Mi
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 10
            timeoutSeconds: 2
            periodSeconds: 20
            failureThreshold: 6
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 3
            timeoutSeconds: 2
            periodSeconds: 10
            failureThreshold: 6
          volumeMounts:
            - name: static
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
              readOnly: true
            - name: static
              mountPath: /usr/share/nginx/html/index.html
              subPath: index.html
              readOnly: true
      volumes:
        - name: static
          configMap:
            name: portal-ui-static
---
apiVersion: v1
kind: Service
metadata:
  name: portal-ui
  namespace: __PLATFORM_NS__
  labels:
    app: portal-ui
spec:
  selector:
    app: portal-ui
  ports:
    - name: http
      port: 80
      targetPort: 8080
  type: ClusterIP
YAML
)"
DS_YAML="${DS_YAML//__PLATFORM_NS__/${PLATFORM_NS}}"
apply_yaml "${DS_YAML}"

# [PATCHES][UI]
(
  # Patch block is safe to re-run and does not overwrite index.html with blanks.
  PLATFORM_NS="${PLATFORM_NS:-platform}"

  k() { echo "+ $*"; "$@"; }

  # Ensure Service port wiring is correct
  if kubectl -n "${PLATFORM_NS}" get svc portal-ui >/dev/null 2>&1; then
    k kubectl -n "${PLATFORM_NS}" patch svc portal-ui --type='json' -p \
      '[{"op":"replace","path":"/spec/ports/0/port","value":80},{"op":"replace","path":"/spec/ports/0/targetPort","value":8080}]' \
      || true
  fi

  # Force restart so configmap changes are picked up
  if kubectl -n "${PLATFORM_NS}" get deploy portal-ui >/dev/null 2>&1; then
    k kubectl -n "${PLATFORM_NS}" rollout restart deploy/portal-ui
  fi

  echo "[PATCHES][UI] patched: cm=portal-ui-static deploy=portal-ui svc=portal-ui"
  k kubectl -n "${PLATFORM_NS}" get cm portal-ui-static -o wide || true
  k kubectl -n "${PLATFORM_NS}" get deploy portal-ui -o wide || true
  k kubectl -n "${PLATFORM_NS}" get svc portal-ui -o wide || true
)

log "[04B][PORTAL-UI] Waiting for readiness"
kubectl_wait_deploy "${PLATFORM_NS}" "portal-ui" "180s"

log "[04B][PORTAL-UI] Ensuring Ingress (host: ${PORTAL_HOST}, class: ${INGRESS_CLASS}, tls: ${TLS_MODE})"

ING_YAML="$(cat <<'YAML'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: portal
  namespace: __PLATFORM_NS__
  annotations:
    kubernetes.io/ingress.class: __INGRESS_CLASS__
spec:
  ingressClassName: __INGRESS_CLASS__
  __TLS_BLOCK__
  rules:
    - host: __PORTAL_HOST__
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: portal-api
                port:
                  number: 80
          - path: /
            pathType: Prefix
            backend:
              service:
                name: portal-ui
                port:
                  number: 80
YAML
)"

ING_YAML="${ING_YAML//__PLATFORM_NS__/${PLATFORM_NS}}"
ING_YAML="${ING_YAML//__INGRESS_CLASS__/${INGRESS_CLASS}}"
ING_YAML="${ING_YAML//__PORTAL_HOST__/${PORTAL_HOST}}"

if [[ -z "${TLS_BLOCK}" ]]; then
  ING_YAML="${ING_YAML//__TLS_BLOCK__/}"
else
  TLS_BLOCK="${TLS_BLOCK//__PORTAL_HOST__/${PORTAL_HOST}}"
  ING_YAML="${ING_YAML//__TLS_BLOCK__/${TLS_BLOCK}}"
fi

apply_yaml "${ING_YAML}"

log "[04B][PORTAL-UI] Done"
echo "Portal URL: https://${PORTAL_HOST}/"
echo "API Health: https://${PORTAL_HOST}/api/health"
echo "API Summary: https://${PORTAL_HOST}/api/summary"
