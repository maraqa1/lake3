#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# patch-portal-repeatable.sh
# Repeatable, idempotent portal patcher (UI + Ingress + optional cert-manager Certificate)
# Fixes included:
# - Works when executed as a script (BASH_SOURCE set) AND when pasted in shell (BASH_SOURCE unset)
# - No corrupted log lines
# - No unmatched if/fi blocks
# ==============================================================================

# Safe HERE resolver (prevents: -bash: BASH_SOURCE[0]: unbound variable)
if [[ -n "${BASH_SOURCE[0]-}" ]]; then
  HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
else
  HERE="$(pwd)"
fi

# Optional shared env/lib (non-fatal)
[[ -f "${HERE}/00-env.sh" ]] && . "${HERE}/00-env.sh" || true
[[ -f "${HERE}/00-lib.sh" ]] && . "${HERE}/00-lib.sh" || true

need(){ command -v "$1" >/dev/null 2>&1 || { echo "[portal-patch][FATAL] missing: $1" >&2; exit 1; }; }
need kubectl

log(){ echo "[portal-patch] $*"; }
warn(){ echo "[portal-patch][WARN] $*" >&2; }

# -----------------------------
# Defaults (override via env)
# -----------------------------
PLATFORM_NS="${PLATFORM_NS:-platform}"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
TLS_MODE="${TLS_MODE:-per-host-http01}"     # off | per-host-http01 | ...
PORTAL_HOST="${PORTAL_HOST:-portal.lake3.opendatalake.com}"
PORTAL_TLS_SECRET="${PORTAL_TLS_SECRET:-portal-tls}"
CLUSTER_ISSUER="${CLUSTER_ISSUER:-letsencrypt-http01}"

UI_DEPLOY="${PORTAL_UI_DEPLOY:-portal-ui}"
UI_SVC="${PORTAL_UI_SVC:-portal-ui}"
UI_CM="${PORTAL_UI_CM:-portal-ui-static}"

API_DEPLOY="${PORTAL_API_DEPLOY:-portal-api}"
API_SVC="${PORTAL_API_SVC:-portal-api}"

# ------------------------------------------------------------------------------
# helpers
# ------------------------------------------------------------------------------
apply(){ kubectl apply -f - <<<"$1" >/dev/null; }
exists(){ kubectl -n "$1" get "$2" "$3" >/dev/null 2>&1; }
rollout(){ kubectl -n "${PLATFORM_NS}" rollout status "$1/$2" --timeout="${3:-180s}" >/dev/null; }
restart(){ kubectl -n "${PLATFORM_NS}" rollout restart "$1/$2" >/dev/null; }

ensure_ns(){
  if ! kubectl get ns "${PLATFORM_NS}" >/dev/null 2>&1; then
    kubectl create ns "${PLATFORM_NS}" >/dev/null
  fi
}

# ------------------------------------------------------------------------------
# TLS Certificate (repeatable): ensures portal-tls exists, otherwise NGINX serves fake cert
# ------------------------------------------------------------------------------
ensure_portal_certificate(){
  if [[ "${TLS_MODE}" != "per-host-http01" ]]; then
    return 0
  fi

  CERT_NAME="portal-cert"
  log "Ensure Certificate ${PLATFORM_NS}/${CERT_NAME} -> secret=${PORTAL_TLS_SECRET} (issuer=${CLUSTER_ISSUER}, host=${PORTAL_HOST})"

  apply "$(cat <<YAML
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${CERT_NAME}
  namespace: ${PLATFORM_NS}
spec:
  secretName: ${PORTAL_TLS_SECRET}
  issuerRef:
    kind: ClusterIssuer
    name: ${CLUSTER_ISSUER}
  dnsNames:
    - ${PORTAL_HOST}
YAML
)"

  if kubectl -n "${PLATFORM_NS}" wait --for=condition=Ready "certificate/${CERT_NAME}" --timeout=600s >/dev/null 2>&1; then
    log "Certificate Ready: ${CERT_NAME}"
  else
    warn "Certificate not Ready after 600s. Evidence:"
    kubectl -n "${PLATFORM_NS}" get certificate "${CERT_NAME}" -o wide || true
    kubectl -n "${PLATFORM_NS}" describe certificate "${CERT_NAME}" | sed -n '1,240p' || true
    kubectl -n "${PLATFORM_NS}" get certificaterequest,order,challenge -l "cert-manager.io/certificate-name=${CERT_NAME}" -o wide || true
  fi

  if kubectl -n "${PLATFORM_NS}" get secret "${PORTAL_TLS_SECRET}" >/dev/null 2>&1; then
    log "TLS secret present: ${PORTAL_TLS_SECRET}"
  else
    warn "TLS secret missing: ${PORTAL_TLS_SECRET} (NGINX will serve default/fake cert)"
  fi
}

# ------------------------------------------------------------------------------
# UI static assets (index.html, app.js, styles.css) + nginx.conf (unprivileged-safe)
# ------------------------------------------------------------------------------
apply_ui_configmap(){
  log "Apply ${UI_CM} ConfigMap (UI assets + nginx.conf)"
  apply "$(cat <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: portal-ui-static
  namespace: platform
data:
  nginx.conf: |
    worker_processes  1;
    error_log  /tmp/error.log warn;
    pid        /tmp/nginx.pid;

    events { worker_connections  1024; }

    http {
    
     types {
       text/html  html htm;
       text/css   css;
       application/javascript js;
       application/json json;
       image/svg+xml svg;
       image/png png;
       image/jpeg jpg jpeg;
       font/woff woff;
       font/woff2 woff2;
      }
      

      sendfile        on;
      keepalive_timeout  65;

      client_body_temp_path /tmp/client_temp;
      proxy_temp_path       /tmp/proxy_temp;
      fastcgi_temp_path     /tmp/fastcgi_temp;
      uwsgi_temp_path       /tmp/uwsgi_temp;
      scgi_temp_path        /tmp/scgi_temp;

      server {
        listen 8080;
        server_name _;
        root /usr/share/nginx/html;
        index index.html;

        location / {
          try_files $uri $uri/ /index.html;
        }
      }
    }

  index.html: |
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width, initial-scale=1"/>
      <title>OpenKPI Portal</title>
      <link rel="stylesheet" href="/styles.css"/>
    </head>
    <body>
      <header class="topbar">
        <div class="brand">
          <div class="logo"></div>
          <div class="title">
            <div class="h1">OpenKPI Portal</div>
            <div class="sub" id="substatus">Loading…</div>
          </div>
        </div>

        <div class="meta">
          <div class="pill" id="envpill">env: —</div>
          <div class="pill" id="clusterpill">cluster: —</div>
          <div class="pill" id="commitpill">commit: —</div>
          <div class="pill" id="durpill">scan: —</div>
          <div class="status" id="overall">
            <span class="dot"></span>
            <span id="overallText">—</span>
            <span class="ts" id="ts">—</span>
          </div>
        </div>
      </header>

      <main class="wrap">
        <section class="grid2">
          <div class="card">
            <div class="cardhdr">
              <div class="cardttl">Platform Overview</div>
              <div class="chips">
                <button class="chip" data-filter="all" id="chipAll">All</button>
                <button class="chip" data-filter="healthy" id="chipHealthy">Healthy</button>
                <button class="chip" data-filter="degraded" id="chipDegraded">Degraded</button>
                <button class="chip" data-filter="missing" id="chipMissing">Missing</button>
              </div>
            </div>
            <div class="metrics" id="platformMetrics">
              <div class="metric"><div class="k" id="appsUp">—</div><div class="l">apps up</div></div>
              <div class="metric"><div class="k" id="appsDown">—</div><div class="l">apps down</div></div>
              <div class="metric"><div class="k" id="pods">—</div><div class="l">pods</div></div>
              <div class="metric"><div class="k" id="restarts24h">—</div><div class="l">restarts 24h</div></div>
            </div>
            <div class="btnrow">
              <a class="btn" href="/api/health" target="_blank" rel="noopener">API health</a>
              <a class="btn" href="/api/summary?v=1" target="_blank" rel="noopener">API summary</a>
            </div>
          </div>

          <div class="card">
            <div class="cardhdr">
              <div class="cardttl">Data Catalogue Snapshot</div>
              <div class="note" id="catalogNote">—</div>
            </div>
            <div class="catalog">
              <div class="pill">MinIO buckets: <span id="minioBuckets">—</span></div>
              <div class="pill">Postgres schemas: <span id="pgSchemas">—</span></div>
              <div class="pill">Postgres tables: <span id="pgTables">—</span></div>
            </div>
            <div class="small" id="catalogDetails"></div>
          </div>
        </section>

        <section class="card">
          <div class="cardhdr">
            <div class="cardttl">Applications</div>
            <div class="note" id="appsNote">Rendered from /api/summary</div>
          </div>
          <div class="apps" id="apps"></div>
        </section>

        <section class="card">
          <div class="cardhdr">
            <div class="cardttl">Raw Summary (debug)</div>
            <div class="note">cached</div>
          </div>
          <pre class="pre" id="raw">—</pre>
        </section>
      </main>

      <div class="modal" id="modal">
        <div class="modalbox">
          <div class="modalhdr">
            <div class="modaltitle" id="modalTitle">Diagnose</div>
            <button class="x" id="modalClose">×</button>
          </div>
          <pre class="pre" id="modalBody">—</pre>
        </div>
      </div>

      <script src="/app.js"></script>
    </body>
    </html>

  styles.css: |
    :root{
      --bg:#070a12;
      --panel:rgba(255,255,255,.05);
      --panel2:rgba(255,255,255,.03);
      --b:rgba(255,255,255,.08);
      --t:#e9ecff;
      --m:rgba(233,236,255,.7);
      --mut:rgba(233,236,255,.55);
      --good:#32d296;
      --warn:#ffb020;
      --bad:#ff5d5d;
    }
    *{box-sizing:border-box}
    body{
      margin:0;
      font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Arial;
      background: radial-gradient(1200px 600px at 20% 10%, rgba(89,116,255,.18), transparent 60%),
                  radial-gradient(900px 500px at 80% 20%, rgba(43,223,200,.12), transparent 60%),
                  var(--bg);
      color:var(--t);
    }
    a{color:var(--t); text-decoration:none}
    .topbar{
      display:flex; align-items:center; justify-content:space-between;
      padding:18px 22px;
      border-bottom:1px solid var(--b);
      background: linear-gradient(180deg, rgba(255,255,255,.04), rgba(255,255,255,.02));
    }
    .brand{display:flex; gap:14px; align-items:center}
    .logo{width:34px;height:34px;border-radius:10px;background:linear-gradient(135deg,#54f0c5,#5f74ff)}
    .h1{font-weight:700; letter-spacing:.2px}
    .sub{color:var(--mut); font-size:12px; margin-top:2px}
    .meta{display:flex; gap:10px; align-items:center}
    .pill{
      padding:8px 10px; border:1px solid var(--b); border-radius:12px;
      background:rgba(255,255,255,.03); color:var(--m); font-size:12px;
      white-space:nowrap;
    }
    .status{
      display:flex; gap:8px; align-items:center;
      padding:8px 10px; border:1px solid var(--b); border-radius:12px;
      background:rgba(255,255,255,.03); font-size:12px;
    }
    .dot{width:8px;height:8px;border-radius:50%; background:var(--m)}
    .ts{color:var(--mut); margin-left:8px}
    .wrap{padding:22px; max-width:1280px; margin:0 auto}
    .grid2{display:grid; grid-template-columns:1fr 1fr; gap:16px}
    .card{
      border:1px solid var(--b);
      background: linear-gradient(180deg, rgba(255,255,255,.06), rgba(255,255,255,.03));
      border-radius:16px;
      padding:16px;
      box-shadow: 0 20px 60px rgba(0,0,0,.25);
    }
    .cardhdr{display:flex; align-items:center; justify-content:space-between; gap:14px; margin-bottom:12px}
    .cardttl{font-weight:700}
    .note{color:var(--mut); font-size:12px}
    .chips{display:flex; gap:8px; flex-wrap:wrap}
    .chip{
      border:1px solid var(--b); background:rgba(255,255,255,.03); color:var(--m);
      padding:6px 10px; border-radius:999px; cursor:pointer; font-size:12px;
    }
    .chip.active{border-color:rgba(255,255,255,.25); color:var(--t)}
    .metrics{display:flex; gap:16px; flex-wrap:wrap; margin:12px 0 8px}
    .metric{min-width:120px; padding:12px; border:1px solid var(--b); border-radius:14px; background:rgba(255,255,255,.02)}
    .metric .k{font-weight:800; font-size:18px}
    .metric .l{color:var(--mut); font-size:12px; margin-top:6px}
    .btnrow{display:flex; gap:10px; margin-top:10px}
    .btn{
      border:1px solid var(--b); border-radius:12px; padding:10px 12px;
      background:rgba(255,255,255,.03); color:var(--t); font-size:12px;
    }
    .apps{display:grid; grid-template-columns:repeat(3, minmax(0, 1fr)); gap:12px}
    .app{
      border:1px solid var(--b); border-radius:16px; padding:14px;
      background:radial-gradient(500px 260px at 30% 0%, rgba(95,116,255,.10), transparent 65%),
                 rgba(255,255,255,.02);
      min-height:140px;
      display:flex; flex-direction:column; justify-content:space-between;
    }
    .row{display:flex; align-items:center; justify-content:space-between; gap:10px}
    .name{font-weight:700}
    .badge{
      font-size:11px; padding:6px 10px; border-radius:999px; border:1px solid var(--b);
      color:var(--m); background:rgba(255,255,255,.02);
      text-transform:capitalize;
    }
    .badge.healthy{border-color:rgba(50,210,150,.35); color:#bff5e1}
    .badge.degraded{border-color:rgba(255,176,32,.35); color:#ffe1b0}
    .badge.missing{border-color:rgba(255,93,93,.35); color:#ffc1c1}
    .reason{color:var(--mut); font-size:12px; margin-top:8px; min-height:34px}
    .facts{display:flex; gap:8px; flex-wrap:wrap; margin-top:10px}
    .fact{border:1px solid var(--b); border-radius:999px; padding:6px 9px; font-size:11px; color:var(--m); background:rgba(255,255,255,.02)}
    .actions{display:flex; gap:10px; margin-top:12px}
    .pre{
      margin:0; padding:14px; border-radius:14px; border:1px solid var(--b);
      background:rgba(0,0,0,.25); color:rgba(233,236,255,.85);
      overflow:auto; max-height:420px;
      font-size:12px; line-height:1.4;
    }
    .small{color:var(--mut); font-size:12px; margin-top:8px}
    .modal{position:fixed; inset:0; background:rgba(0,0,0,.55); display:none; align-items:center; justify-content:center; padding:18px}
    .modal.show{display:flex}
    .modalbox{width:min(980px, 95vw); border:1px solid var(--b); border-radius:16px; background:rgba(10,12,20,.92); box-shadow:0 30px 90px rgba(0,0,0,.45)}
    .modalhdr{display:flex; justify-content:space-between; align-items:center; padding:14px 16px; border-bottom:1px solid var(--b)}
    .modaltitle{font-weight:800}
    .x{border:1px solid var(--b); background:rgba(255,255,255,.03); color:var(--t); border-radius:10px; padding:6px 10px; cursor:pointer}
    @media (max-width: 980px){ .apps{grid-template-columns:repeat(2, minmax(0, 1fr))} .grid2{grid-template-columns:1fr} }
    @media (max-width: 640px){ .apps{grid-template-columns:1fr} .meta{display:none} }

  app.js: |
    const API_SUMMARY = '/api/summary?v=1';
    const el = (id)=>document.getElementById(id);
    const appsEl = el('apps');
    const rawEl  = el('raw');

    const modal = el('modal');
    const modalTitle = el('modalTitle');
    const modalBody = el('modalBody');
    el('modalClose').onclick = ()=>modal.classList.remove('show');
    modal.addEventListener('click', (e)=>{ if(e.target===modal) modal.classList.remove('show'); });

    let currentFilter = 'all';

    function setOverall(status, ts){
      const dot = document.querySelector('#overall .dot');
      const t = el('overallText');
      const sub = el('substatus');

      if(status === 'healthy'){ dot.style.background = 'var(--good)'; t.textContent='Operational'; sub.textContent='UI loaded; API reachable'; }
      else if(status === 'degraded'){ dot.style.background = 'var(--warn)'; t.textContent='Degraded'; sub.textContent='Investigate degraded services'; }
      else { dot.style.background = 'var(--bad)'; t.textContent='Issue'; sub.textContent='API reachable but platform has missing services'; }

      el('ts').textContent = ts ? `ts: ${ts}` : '';
    }

    function badgeClass(s){
      if(s==='healthy') return 'healthy';
      if(s==='degraded') return 'degraded';
      return 'missing';
    }

    function fmt(v){ return (v===null || v===undefined) ? '—' : String(v); }

    function renderMetrics(summary){
      el('appsUp').textContent = fmt(summary?.platform?.apps_up);
      el('appsDown').textContent = fmt(summary?.platform?.apps_down);
      el('pods').textContent = fmt(summary?.platform?.pods);
      el('restarts24h').textContent = fmt(summary?.platform?.restarts_24h);

      el('envpill').textContent = `env: ${fmt(summary?.meta?.env)}`;
      el('clusterpill').textContent = `cluster: ${fmt(summary?.meta?.cluster)}`;
      el('commitpill').textContent = `commit: ${fmt(summary?.meta?.commit)}`;
      el('durpill').textContent = `scan: ${fmt(summary?.meta?.duration_ms)}ms`;
    }

    function renderCatalog(summary){
      const cat = summary?.catalog || {};
      const minio = cat?.minio || {};
      const pg = cat?.postgres || {};

      el('minioBuckets').textContent = fmt((minio?.buckets || []).length);
      el('pgSchemas').textContent = fmt((pg?.schemas || []).length);

      let tables = 0;
      if(Array.isArray(pg?.schemas)){
        for(const s of pg.schemas){ tables += (s?.tables || 0); }
      }
      el('pgTables').textContent = fmt(tables);

      const ok = (minio?.available && pg?.available);
      el('catalogNote').textContent = ok ? 'MinIO OK. Postgres OK.' : 'Catalogue partially available.';

      const details = [];
      if(Array.isArray(pg?.schemas) && pg.schemas.length){
        const top = pg.schemas.slice(0,5).map(s=>`${s.name}: ${s.tables||0} tables`).join(' | ');
        details.push(`Postgres: ${top}${pg.schemas.length>5 ? ' …' : ''}`);
      } else {
        details.push('Postgres: no schemas reported yet');
      }
      if(Array.isArray(minio?.buckets) && minio.buckets.length){
        const b = minio.buckets.slice(0,6).map(x=>x.name).join(', ');
        details.push(`MinIO: ${b}${minio.buckets.length>6 ? ' …' : ''}`);
      } else {
        details.push('MinIO: no buckets reported yet');
      }
      el('catalogDetails').textContent = details.join(' • ');
    }

    function renderApps(summary){
      appsEl.innerHTML = '';
      const apps = Array.isArray(summary?.apps) ? summary.apps : [];
      const filtered = apps.filter(a => currentFilter==='all' ? true : (a.status===currentFilter));

      for(const a of filtered){
        const div = document.createElement('div');
        div.className = 'app';

        const status = a.status || 'missing';
        const reason = a.reason || '';

        const pods = a?.k8s?.pods;
        const ready = a?.k8s?.ready;
        const restarts = a?.k8s?.restarts_24h;
        const last = a?.k8s?.last_change;

        const openLink = (a?.links || []).find(x=>x.label==='Open')?.href || '';
        const diagLink = (a?.actions || []).find(x=>x.label==='Diagnose')?.href || '';

        div.innerHTML = `
          <div>
            <div class="row">
              <div class="name">${a.display || a.id}</div>
              <div class="badge ${badgeClass(status)}">${status}</div>
            </div>
            <div class="reason">${reason || '&nbsp;'}</div>
            <div class="facts">
              <div class="fact">pods: ${fmt(pods)}</div>
              <div class="fact">ready: ${fmt(ready)}</div>
              <div class="fact">restarts 24h: ${fmt(restarts)}</div>
              <div class="fact">last change: ${fmt(last)}</div>
            </div>
          </div>
          <div class="actions">
            ${openLink ? `<a class="btn" href="${openLink}" target="_blank" rel="noopener">Open</a>` : `<span class="btn" style="opacity:.45">Open</span>`}
            ${diagLink ? `<button class="btn" data-diag="${diagLink}">Diagnose</button>` : `<span class="btn" style="opacity:.45">Diagnose</span>`}
          </div>
        `;

        div.querySelector('button[data-diag]')?.addEventListener('click', async (e)=>{
          const url = e.currentTarget.getAttribute('data-diag');
          modalTitle.textContent = `${a.display || a.id} — Diagnose`;
          modalBody.textContent = 'Loading…';
          modal.classList.add('show');
          try{
            const r = await fetch(url, {cache:'no-store'});
            const j = await r.json();
            modalBody.textContent = JSON.stringify(j, null, 2);
          }catch(err){
            modalBody.textContent = String(err);
          }
        });

        appsEl.appendChild(div);
      }

      if(filtered.length===0){
        appsEl.innerHTML = `<div class="small">No apps match filter.</div>`;
      }
    }

    function setFilterButtons(){
      const ids = { all:'chipAll', healthy:'chipHealthy', degraded:'chipDegraded', missing:'chipMissing' };
      for(const k of Object.keys(ids)){
        const b = el(ids[k]);
        if(!b) continue;
        b.classList.toggle('active', currentFilter===k);
        b.onclick = ()=>{ currentFilter = k; load(); };
      }
    }

    async function load(){
      setFilterButtons();
      try{
        const r = await fetch(API_SUMMARY, {cache:'no-store'});
        const j = await r.json();

        renderMetrics(j);
        renderCatalog(j);
        renderApps(j);

        rawEl.textContent = JSON.stringify(j, null, 2);

        const down = Number(j?.platform?.apps_down || 0);
        const overall = down===0 ? 'healthy' : (down <= 2 ? 'degraded' : 'missing');
        setOverall(overall, j?.meta?.ts || '');

      }catch(err){
        setOverall('missing', '');
        rawEl.textContent = String(err);
        appsEl.innerHTML = `<div class="small">API not reachable. Check /api/health.</div>`;
      }
    }

    load();
    setInterval(load, 15000);
YAML
)"
}

# ------------------------------------------------------------------------------
# Ensure Ingress routes:
#   /api/* -> portal-api
#   /      -> portal-ui
# ------------------------------------------------------------------------------
ensure_ingress(){
  log "Ensure Ingress portal routes /api and /"
  if [[ "${TLS_MODE}" == "off" ]]; then
    apply "$(cat <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: portal
  namespace: ${PLATFORM_NS}
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
                name: ${API_SVC}
                port:
                  number: 80
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${UI_SVC}
                port:
                  number: 80
YAML
)"
  else
    apply "$(cat <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: portal
  namespace: ${PLATFORM_NS}
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
    - hosts:
        - ${PORTAL_HOST}
      secretName: ${PORTAL_TLS_SECRET}
  rules:
    - host: ${PORTAL_HOST}
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: ${API_SVC}
                port:
                  number: 80
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${UI_SVC}
                port:
                  number: 80
YAML
)"
  fi
}

# ------------------------------------------------------------------------------
# Restart UI deployment to pick up new ConfigMap content
# ------------------------------------------------------------------------------
restart_ui_if_present(){
  if exists "${PLATFORM_NS}" "deploy" "${UI_DEPLOY}"; then
    log "Restart ${UI_DEPLOY} to load updated ConfigMap"
    restart deployment "${UI_DEPLOY}" || true
    rollout deployment "${UI_DEPLOY}" 180s || warn "UI rollout not confirmed within timeout"
  else
    warn "UI deployment ${PLATFORM_NS}/${UI_DEPLOY} not found; applied ConfigMap + Ingress only."
  fi
}

# ------------------------------------------------------------------------------
# main
# ------------------------------------------------------------------------------
ensure_ns
ensure_portal_certificate
apply_ui_configmap
ensure_ingress
restart_ui_if_present

log "Done"
log "URL: https://${PORTAL_HOST}/"
log "API: https://${PORTAL_HOST}/api/health"
log "SUM: https://${PORTAL_HOST}/api/summary?v=1"
