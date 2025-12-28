#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "${HERE}/00-env.sh" ]] && . "${HERE}/00-env.sh" || true

need(){ command -v "$1" >/dev/null 2>&1 || { echo "[FATAL] missing: $1" >&2; exit 1; }; }
need kubectl
need curl

log(){ echo "[04B][PORTAL-UI] $*"; }
warn(){ echo "[04B][PORTAL-UI][WARN] $*" >&2; }
fatal(){ echo "[04B][PORTAL-UI][FATAL] $*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Defaults (override in 00-env.sh)
# ------------------------------------------------------------------------------
PLATFORM_NS="${PLATFORM_NS:-platform}"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
TLS_MODE="${TLS_MODE:-per-host-http01}"                 # off | per-host-http01
PORTAL_HOST="${PORTAL_HOST:-portal.lake3.opendatalake.com}"
PORTAL_TLS_SECRET="${PORTAL_TLS_SECRET:-portal-tls}"
CLUSTER_ISSUER="${CLUSTER_ISSUER:-letsencrypt-http01}"

UI_DEPLOY="${PORTAL_UI_DEPLOY:-portal-ui}"
UI_SVC="${PORTAL_UI_SVC:-portal-ui}"
UI_CM="${PORTAL_UI_CM:-portal-ui-static}"

API_SVC="${PORTAL_API_SVC:-portal-api}"

# ------------------------------------------------------------------------------
# Ensure namespace
# ------------------------------------------------------------------------------
log "Ensure namespace ${PLATFORM_NS}"
kubectl get ns "${PLATFORM_NS}" >/dev/null 2>&1 || kubectl create ns "${PLATFORM_NS}" >/dev/null

# ------------------------------------------------------------------------------
# UI Assets ConfigMap: write YAML safely (NO bash expansion), then replace placeholders
# ------------------------------------------------------------------------------
TMP_CM="/tmp/portal-ui-static.yaml"
cat > "${TMP_CM}" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: __UI_CM__
  namespace: __PLATFORM_NS__
data:
  nginx.conf: |
    worker_processes  1;
    error_log  /tmp/error.log warn;
    access_log /tmp/access.log;
    pid        /tmp/nginx.pid;

    events { worker_connections 1024; }

    http {
      default_type application/octet-stream;

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

      sendfile on;
      keepalive_timeout 65;

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
      <title>Open KPI Platform</title>
      <link rel="stylesheet" href="/styles.css"/>
    </head>
    <body>
      <header class="topbar">
        <div class="brand">
          <div class="logo">OK</div>
          <div class="brandtxt">
            <div class="brandname">Open KPI Platform</div>
            <div class="brandmeta">
              <span class="pill pill-solid" id="envTag">—</span>
              <span class="pill" id="clusterTag">—</span>
              <span class="pill" id="tsTag">—</span>
            </div>
          </div>
        </div>

        <nav class="nav">
          <a class="navlink" href="#launchpad" id="navLaunchpad">Launchpad</a>
          <a class="navlink" href="#proof" id="navProof">Operational Proof</a>
          <a class="navlink" href="#assets" id="navAssets">Data Assets</a>
          <a class="navlink" href="#health" id="navHealth">Platform Health</a>
        </nav>
      </header>

      <main class="wrap">
        <section class="hero" id="launchpad">
          <div class="hero-left">
            <div class="kicker">DATA PLATFORM CONTROL PLANE</div>
            <h1>Deploy a governed analytics platform in days</h1>
            <p class="lead">
              One landing page for services, operational progress, and delivery proof built for regulated environments.
            </p>

            <div class="summary">
              <div class="sumcard">
                <div class="sumlabel">Platform</div>
                <div class="sumvalue" id="platformStatus">—</div>
              </div>
              <div class="sumcard">
                <div class="sumlabel">Services</div>
                <div class="sumvalue"><span id="servicesUp">—</span>/<span id="servicesTotal">—</span> operational</div>
              </div>
              <div class="sumcard">
                <div class="sumlabel">Last check</div>
                <div class="sumvalue" id="lastCheck">—</div>
              </div>
            </div>

            <div class="cta">
              <a class="btn btn-primary" href="#services">Open Services</a>
              <a class="btn btn-ghost" href="#health">View Health Matrix</a>
            </div>
          </div>

          <div class="hero-right">
            <div class="sidecard">
              <div class="sidehdr">What this platform provides</div>
              <ul class="bullets">
                <li>Single entry point for ingestion, storage, dashboards, and operations.</li>
                <li>Operational proof: last ingestion run, last model build, freshness.</li>
                <li>Clear path to governance: catalog snapshot and controlled access.</li>
              </ul>
            </div>
          </div>
        </section>

        <section class="section" id="services">
          <div class="sectionhdr">
            <div>
              <div class="sectitle">Service Launchpad</div>
              <div class="secsub">One click to open core services. Status reflects reachability from the control plane.</div>
            </div>
            <div class="pill" id="servicesBanner">—</div>
          </div>

          <div class="grid" id="serviceGrid"></div>
        </section>

        <section class="section" id="proof">
          <div class="sectionhdr">
            <div>
              <div class="sectitle">Operational Proof</div>
              <div class="secsub">Evidence signals from the platform snapshot. No raw logs. No YAML.</div>
            </div>
            <div class="muted-right">Signals from ops JSON</div>
          </div>

          <div class="proofgrid">
            <div class="card">
              <div class="cardhdr">Ingestion</div>
              <div class="kv">
                <div class="k">Airbyte reachable</div><div class="v" id="proofAirbyte">—</div>
                <div class="k">Last sync</div><div class="v" id="proofLastSync">—</div>
                <div class="k">Detail</div><div class="v" id="proofAirbyteDetail">—</div>
              </div>
            </div>

            <div class="card">
              <div class="cardhdr">Transformation</div>
              <div class="kv">
                <div class="k">dbt present</div><div class="v" id="proofDbt">—</div>
                <div class="k">Latest job</div><div class="v" id="proofDbtJob">—</div>
              </div>
            </div>

            <div class="card">
              <div class="cardhdr">Storage</div>
              <div class="kv">
                <div class="k">Buckets</div><div class="v" id="proofBuckets">—</div>
                <div class="k">Newest bucket</div><div class="v" id="proofNewestBucket">—</div>
              </div>
            </div>

            <div class="card">
              <div class="cardhdr">Database</div>
              <div class="kv">
                <div class="k">Schemas</div><div class="v" id="proofSchemas">—</div>
                <div class="k">Tables</div><div class="v" id="proofTables">—</div>
              </div>
            </div>
          </div>
        </section>

        <section class="section" id="assets">
          <div class="sectionhdr">
            <div>
              <div class="sectitle">Data Assets</div>
              <div class="secsub">Catalog snapshot from MinIO and Postgres (what exists right now).</div>
            </div>
          </div>

          <div class="assets">
            <div class="card">
              <div class="cardhdr">Object Storage</div>
              <div class="big" id="minioBuckets">—</div>
              <div class="muted">buckets</div>
              <div class="chips" id="minioBucketList"></div>
            </div>

            <div class="card">
              <div class="cardhdr">Postgres</div>
              <div class="kv">
                <div class="k">Schemas</div><div class="v" id="pgSchemas">—</div>
                <div class="k">Tables</div><div class="v" id="pgTables">—</div>
              </div>
              <div class="muted" id="pgSchemaList">—</div>
            </div>
          </div>
        </section>

        <section class="section" id="health">
          <div class="sectionhdr">
            <div>
              <div class="sectitle">Platform Health</div>
              <div class="secsub">Derived service states + readiness and restarts.</div>
            </div>
            <div class="chips">
              <button class="chip" data-filter="all" id="chipAll">All</button>
              <button class="chip" data-filter="healthy" id="chipHealthy">Healthy</button>
              <button class="chip" data-filter="degraded" id="chipDegraded">Degraded</button>
              <button class="chip" data-filter="missing" id="chipMissing">Missing</button>
            </div>
          </div>

          <div class="healthstats">
            <div class="stat"><div class="n" id="appsUp">—</div><div class="l">services up</div></div>
            <div class="stat"><div class="n" id="appsDown">—</div><div class="l">services down</div></div>
            <div class="stat"><div class="n" id="pods">—</div><div class="l">pods</div></div>
            <div class="stat"><div class="n" id="restarts24h">—</div><div class="l">restarts</div></div>
          </div>

          <div class="grid" id="healthGrid"></div>

          <details class="raw">
            <summary>Raw Summary (debug)</summary>
            <pre id="rawJson">—</pre>
          </details>
        </section>
      </main>

      <script src="/app.js"></script>
    </body>
    </html>

  styles.css: |
    :root{
      --bg:#eef2f7;
      --panel:#ffffff;
      --panel2:#f7f9fc;
      --stroke:rgba(15,23,42,.10);
      --mut:rgba(15,23,42,.62);
      --txt:#0b1220;
      --blue:#2b6cff;
      --blue2:#1f4bd6;
      --shadow:0 18px 55px rgba(16,24,40,.10);
      --r:18px;
    }
    *{box-sizing:border-box}
    body{
      margin:0;
      font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Arial;
      color:var(--txt);
      background:
        radial-gradient(900px 420px at 20% 5%, rgba(43,108,255,.10), transparent 60%),
        radial-gradient(900px 420px at 80% 0%, rgba(34,197,94,.08), transparent 60%),
        linear-gradient(180deg, #f2f5fb, var(--bg));
    }
    a{color:inherit; text-decoration:none}

    .topbar{
      position:sticky; top:0; z-index:50;
      display:flex; align-items:center; justify-content:space-between;
      padding:14px 18px;
      border-bottom:1px solid var(--stroke);
      background:rgba(9,14,28,.92);
      color:#fff;
      backdrop-filter: blur(10px);
    }
    .brand{display:flex; gap:12px; align-items:center}
    .logo{
      width:40px;height:40px;border-radius:12px;
      display:flex; align-items:center; justify-content:center;
      font-weight:900; letter-spacing:.5px;
      background: linear-gradient(135deg, rgba(43,108,255,.95), rgba(34,197,94,.85));
      box-shadow: 0 14px 35px rgba(0,0,0,.25);
    }
    .brandname{font-weight:900}
    .brandmeta{display:flex; gap:10px; align-items:center; margin-top:4px; flex-wrap:wrap}
    .pill{
      border:1px solid rgba(255,255,255,.18);
      background:rgba(255,255,255,.08);
      padding:6px 10px;
      border-radius:999px;
      font-size:12px;
      color:rgba(255,255,255,.80);
      white-space:nowrap;
    }
    .pill-solid{
      background:rgba(255,255,255,.14);
      color:#fff;
      font-weight:800;
    }

    .nav{display:flex; gap:18px; align-items:center}
    .navlink{color:rgba(255,255,255,.88); font-weight:750; font-size:14px; padding:8px 10px; border-radius:12px}
    .navlink.active{background:rgba(255,255,255,.10); border:1px solid rgba(255,255,255,.20)}

    .wrap{max-width:1250px; margin:0 auto; padding:24px 18px 80px}
    .hero{
      display:grid; grid-template-columns: 1.2fr .8fr;
      gap:18px;
      padding:18px;
      border:1px solid rgba(15,23,42,.08);
      background:rgba(255,255,255,.70);
      border-radius: var(--r);
      box-shadow: var(--shadow);
    }
    .kicker{font-weight:900; letter-spacing:.12em; font-size:12px; color:rgba(15,23,42,.55)}
    h1{margin:8px 0 10px; font-size:36px; line-height:1.12}
    .lead{margin:0; color:rgba(15,23,42,.70); max-width:62ch}

    .summary{display:grid; grid-template-columns: repeat(3, minmax(0,1fr)); gap:12px; margin-top:16px}
    .sumcard{
      border:1px solid rgba(15,23,42,.10);
      background:rgba(247,249,252,.85);
      border-radius:16px;
      padding:12px;
    }
    .sumlabel{color:rgba(15,23,42,.62); font-size:12px}
    .sumvalue{font-weight:950; margin-top:8px}
    .cta{display:flex; gap:10px; margin-top:14px; flex-wrap:wrap}
    .btn{
      border:1px solid rgba(15,23,42,.12);
      border-radius:14px;
      padding:10px 14px;
      font-weight:850;
      font-size:13px;
      background:rgba(255,255,255,.85);
    }
    .btn-primary{
      color:#fff;
      background: linear-gradient(180deg, rgba(43,108,255,.95), rgba(31,75,214,.95));
      border-color: rgba(43,108,255,.55);
    }
    .btn-ghost{background:rgba(255,255,255,.85)}
    .sidecard{
      height:100%;
      border:1px solid rgba(15,23,42,.10);
      background:rgba(247,249,252,.85);
      border-radius: 16px;
      padding:14px;
    }
    .sidehdr{font-weight:950; margin-bottom:10px}
    .bullets{margin:0; padding-left:18px; color:rgba(15,23,42,.70)}
    .bullets li{margin:10px 0}

    .section{margin-top:22px}
    .sectionhdr{display:flex; align-items:flex-end; justify-content:space-between; gap:14px; margin:0 0 12px}
    .sectitle{font-weight:950; font-size:18px}
    .secsub{color:rgba(15,23,42,.62); font-size:13px; margin-top:4px}
    .muted-right{color:rgba(15,23,42,.55); font-size:12px; font-weight:800}

    .grid{
      display:grid;
      grid-template-columns: repeat(3, minmax(0,1fr));
      gap:12px;
    }
    .card{
      border:1px solid rgba(15,23,42,.10);
      background:rgba(255,255,255,.85);
      border-radius: 16px;
      padding:14px;
      box-shadow: var(--shadow);
    }
    .svc{
      display:flex; flex-direction:column; gap:10px;
      min-height:170px;
      background:linear-gradient(180deg, rgba(255,255,255,.95), rgba(247,249,252,.95));
    }
    .svcTop{display:flex; align-items:flex-start; justify-content:space-between; gap:10px}
    .svcTitle{font-weight:950}
    .svcDesc{color:rgba(15,23,42,.62); font-size:13px; min-height:40px}
    .svcTags{display:flex; gap:8px; flex-wrap:wrap}
    .tag{
      padding:6px 10px;
      border-radius:999px;
      border:1px solid rgba(15,23,42,.10);
      background:rgba(255,255,255,.92);
      color:rgba(15,23,42,.70);
      font-size:12px;
      font-weight:850;
    }
    .svcActions{display:flex; gap:10px; flex-wrap:wrap; margin-top:auto}
    .badge{
      padding:6px 10px; border-radius:999px;
      border:1px solid rgba(15,23,42,.12);
      font-size:12px; font-weight:950;
      background:#fff;
    }
    .healthy{border-color:rgba(34,197,94,.40); color:#0f5132; background:rgba(34,197,94,.10)}
    .degraded{border-color:rgba(245,158,11,.45); color:#7a4b00; background:rgba(245,158,11,.12)}
    .missing{border-color:rgba(239,68,68,.45); color:#6b1111; background:rgba(239,68,68,.10)}

    .assets{
      display:grid;
      grid-template-columns: 1fr 1fr;
      gap:12px;
    }
    .big{font-weight:980; font-size:34px}
    .muted{color:rgba(15,23,42,.60); margin-top:6px; font-size:13px; font-weight:700}
    .chips{display:flex; gap:8px; flex-wrap:wrap}
    .chip{
      cursor:pointer;
      border:1px solid rgba(15,23,42,.12);
      background:rgba(255,255,255,.85);
      color:rgba(15,23,42,.75);
      padding:8px 10px;
      border-radius:999px;
      font-weight:900;
      font-size:12px;
    }
    .chip.active{background:rgba(15,23,42,.06)}
    .proofgrid{display:grid; grid-template-columns:1fr 1fr; gap:12px}
    .kv{display:grid; grid-template-columns: 180px 1fr; gap:10px 12px; align-items:center}
    .kv .k{color:rgba(15,23,42,.60); font-size:12px; font-weight:950}
    .kv .v{font-weight:950; color:rgba(15,23,42,.85)}
    .healthstats{display:grid; grid-template-columns: repeat(4, minmax(0,1fr)); gap:12px; margin:0 0 12px}
    .stat{border:1px solid rgba(15,23,42,.10); background:rgba(255,255,255,.85); border-radius:16px; padding:12px; box-shadow: var(--shadow)}
    .stat .n{font-weight:980; font-size:22px}
    .stat .l{color:rgba(15,23,42,.58); font-size:12px; margin-top:6px; font-weight:850}
    .raw{margin-top:14px}
    .raw pre{white-space:pre-wrap; overflow:auto; max-height:520px; padding:14px; border-radius:16px; border:1px solid rgba(15,23,42,.10); background:rgba(255,255,255,.85)}
    @media (max-width: 1050px){
      .hero{grid-template-columns:1fr}
      .grid{grid-template-columns:repeat(2, minmax(0,1fr))}
      .assets{grid-template-columns:1fr}
      .proofgrid{grid-template-columns:1fr}
      .healthstats{grid-template-columns:repeat(2, minmax(0,1fr))}
      h1{font-size:30px}
    }
    @media (max-width: 680px){
      .grid{grid-template-columns:1fr}
      .nav{display:none}
    }

  app.js: |
    const API_SUMMARY = '/api/summary?v=1';
    const el = (id)=>document.getElementById(id);
    let currentFilter = 'all';

    function fmt(v){ return (v===null || v===undefined || v==='') ? '—' : String(v); }

    function nsByName(summary, name){
      const nss = summary?.k8s?.namespaces;
      if(!Array.isArray(nss)) return null;
      return nss.find(x => x?.name === name) || null;
    }

    function sumRestartsFromPods(ns){
      const pods = ns?.pods?.items;
      if(!Array.isArray(pods)) return 0;
      return pods.reduce((a,p)=> a + Number(p?.restarts||0), 0);
    }

    function sumPodsCount(ns){ return Number(ns?.pods?.count || 0); }

    function sumPodsReady(ns){
      const pods = ns?.pods?.items;
      if(!Array.isArray(pods)) return 0;
      return pods.reduce((a,p)=> a + (p?.ready ? 1 : 0), 0);
    }

    function computeStatusFromNs(ns){
      if(!ns) return {status:'missing', reason:'namespace not found'};
      const pods = sumPodsCount(ns);
      const ready = sumPodsReady(ns);

      const depItems = ns?.deployments?.items;
      const stsItems = ns?.statefulsets?.items;

      const depCount = Array.isArray(depItems) ? depItems.length : 0;
      const stsCount = Array.isArray(stsItems) ? stsItems.length : 0;

      if(pods===0 && depCount===0 && stsCount===0) return {status:'missing', reason:'No workloads detected'};

      let degraded = false;
      if(Array.isArray(depItems)) degraded = degraded || depItems.some(d => Number(d?.ready||0) < Number(d?.replicas||0));
      if(Array.isArray(stsItems)) degraded = degraded || stsItems.some(s => Number(s?.ready||0) < Number(s?.replicas||0));
      degraded = degraded || (pods > 0 && ready < pods);

      return degraded ? {status:'degraded', reason:'Pods not fully ready / rollouts in progress'} : {status:'healthy', reason:'OK'};
    }

    function setActiveNav(){
      const hash = (window.location.hash || '#launchpad').replace('#','');
      const ids = [
        ['navLaunchpad','launchpad'],
        ['navProof','proof'],
        ['navAssets','assets'],
        ['navHealth','health']
      ];
      for(const [id, h] of ids){
        const a = el(id);
        if(!a) continue;
        a.classList.toggle('active', h===hash);
      }
    }

    function deriveApps(summary){
      const host = window.location.origin;

      if(Array.isArray(summary?.apps) && summary.apps.length){
        return summary.apps.map(a=>{
          const st = (a.status==='healthy' || a.status==='degraded' || a.status==='missing') ? a.status : 'degraded';
          return {
            id: a.id || a.name || 'unknown',
            display: a.display || a.id || a.name || 'unknown',
            category: a.category || 'core',
            status: st,
            reason: a.reason || '',
            capabilities: Array.isArray(a.capabilities) ? a.capabilities : [],
            k8s: a.k8s || {},
            links: a.links || {},
            _openHref: (a.links && a.links.open) ? a.links.open : ''
          };
        });
      }

      const defs = [
        {id:'airbyte',   display:'Data Ingestion',      ns:'airbyte',   desc:'Managed ingestion with connectors, scheduling, CDC, and audit-ready runs.', chips:['Connectors','Scheduling','CDC','Audit'], open:'Open Airbyte', openHref: summary?.links?.airbyte || ''},
        {id:'minio',     display:'Object Storage',      ns:'open-kpi',  desc:'S3-compatible object storage with secure zones, lifecycle control, and resilience.', chips:['S3','Buckets','Encryption','Lifecycle'], open:'Open MinIO', openHref: summary?.links?.minio || ''},
        {id:'analytics', display:'Analytics & BI',      ns:'open-kpi',  desc:'Self-service dashboards with governed datasets and secure sharing for users.', chips:['Dashboards','SQL','Governed KPIs','Sharing'], open:'Open Metabase', openHref: summary?.links?.metabase || ''},
        {id:'dbt',       display:'Data Transformation', ns:'transform', desc:'Reproducible transformations with versioned models, tests, and lineage.', chips:['Models','Lineage','Docs','CI-ready'], open:'Open', openHref: summary?.links?.dbt || ''},
        {id:'ops',       display:'Platform Operations', ns:'platform',  desc:'Operational visibility across the platform including health, ingress, and reachability.', chips:['Ingress','TLS','Health','Visibility'], open:'Open Platform', openHref: host + '/api/summary?v=1'},
        {id:'n8n',       display:'Workflow Automation', ns:'n8n',       desc:'Automate operational workflows, alerting, and integration tasks.', chips:['Workflows','Triggers','Ops','Integration'], open:'Open n8n', openHref: summary?.links?.n8n || ''},
        {id:'zammad',    display:'ITSM / Ticketing',    ns:'tickets',   desc:'Ticketing and support workflow for platform operations and service requests.', chips:['Tickets','SLAs','Support','Audit'], open:'Open Zammad', openHref: summary?.links?.zammad || ''},
      ];

      return defs.map(d=>{
        const ns = nsByName(summary, d.ns);
        const s = computeStatusFromNs(ns);

        if(d.id==='airbyte'){
          const ing = summary?.ingestion?.airbyte;
          if(ing?.available && ing?.detail?.ok===false){
            s.status = 'degraded';
            s.reason = ing?.detail?.error ? String(ing.detail.error) : s.reason;
          }
          if(ing?.available && ing?.detail?.error){
            s.status = 'degraded';
            s.reason = String(ing.detail.error);
          }
        }

        const pods = ns ? sumPodsCount(ns) : 0;
        const ready = ns ? sumPodsReady(ns) : 0;
        const restarts = ns ? sumRestartsFromPods(ns) : 0;

        return {
          id: d.id,
          display: d.display,
          category: 'core',
          status: s.status,
          reason: s.reason,
          desc: d.desc,
          capabilities: d.chips,
          k8s: {namespace:d.ns, pods_total:pods, pods_ready:ready, restarts_24h:restarts},
          links: {open:d.openHref},
          _openLabel: d.open,
          _openHref: d.openHref
        };
      });
    }

    function platformFromApps(summary, apps){
      if(summary?.platform) return summary.platform;

      let pods = 0;
      let restarts = 0;
      const nss = summary?.k8s?.namespaces;
      if(Array.isArray(nss)){
        for(const ns of nss){
          pods += Number(ns?.pods?.count || 0);
          restarts += Number(ns?.pods?.total_restarts || 0);
        }
      }
      const up = apps.filter(a=>a.status==='healthy').length;
      const total = apps.length;
      return {pods, restarts_24h: restarts, apps_up: up, apps_down: (total-up), total};
    }

    function renderLaunchpad(summary, apps, pf){
      const metaTs = summary?.meta?.generated_at || '';
      el('tsTag').textContent = fmt(metaTs);

      const env = summary?.meta?.env || 'PROD';
      el('envTag').textContent = fmt(env);

      const cluster = summary?.meta?.cluster || 'k3s';
      el('clusterTag').textContent = fmt(cluster);

      el('servicesUp').textContent = String(pf.apps_up);
      el('servicesTotal').textContent = String(pf.total);
      el('lastCheck').textContent = fmt(metaTs);

      const down = pf.apps_down;
      const platformStatus = down===0 ? 'OPERATIONAL' : (down<=2 ? 'DEGRADED' : 'DOWN');
      el('platformStatus').textContent = platformStatus;

      const banner = el('servicesBanner');
      banner.textContent = platformStatus;
    }

    function badgeText(status){
      if(status==='healthy') return 'OPERATIONAL';
      if(status==='degraded') return 'DEGRADED';
      return 'DOWN';
    }

    function renderServiceGrid(apps){
      const grid = el('serviceGrid');
      grid.innerHTML = '';

      for(const a of apps){
        const card = document.createElement('div');
        card.className = 'card svc';

        const tags = (a.capabilities||[]).map(t=>`<span class="tag">${t}</span>`).join('');
        const openHref = a.links?.open || a._openHref || '';
        const openLabel = a._openLabel || 'Open';

        const openBtn = openHref
          ? `<a class="btn btn-primary" href="${openHref}" target="_blank" rel="noopener">${openLabel}</a>`
          : `<span class="btn btn-primary" style="opacity:.45">${openLabel}</span>`;

        card.innerHTML = `
          <div class="svcTop">
            <div>
              <div class="kicker" style="letter-spacing:.08em">CORE</div>
              <div class="svcTitle">${a.display}</div>
              <div class="svcDesc">${a.desc || a.reason || ''}</div>
            </div>
            <div class="badge ${a.status}">${badgeText(a.status)}</div>
          </div>
          <div class="svcTags">${tags}</div>
          <div class="muted">${a.reason ? a.reason : '&nbsp;'}</div>
          <div class="svcActions">
            ${openBtn}
            <a class="btn btn-ghost" href="#health">Health</a>
          </div>
        `;
        grid.appendChild(card);
      }
    }

    function renderAssets(summary){
      const buckets = summary?.catalog?.minio?.buckets || [];
      el('minioBuckets').textContent = String(Array.isArray(buckets) ? buckets.length : 0);
      el('minioBucketList').innerHTML = Array.isArray(buckets) ? buckets.slice(0,12).map(b=>`<span class="tag">${b.name}</span>`).join('') : '';

      const schemas = summary?.catalog?.postgres?.schemas || [];
      el('pgSchemas').textContent = String(Array.isArray(schemas) ? schemas.length : 0);

      let tables = 0;
      if(Array.isArray(summary?.catalog?.postgres?.tables)) tables = summary.catalog.postgres.tables.length;
      el('pgTables').textContent = String(tables);

      el('pgSchemaList').textContent = Array.isArray(schemas) && schemas.length
        ? schemas.map(s=>s.schema || 'unknown').join(', ')
        : '—';
    }

    function renderProof(summary){
      const ing = summary?.ingestion?.airbyte;
      const ok = ing?.detail?.ok;
      el('proofAirbyte').textContent = ok===true ? 'YES' : (ok===false ? 'NO' : '—');
      el('proofLastSync').textContent = fmt(ing?.last_sync);
      el('proofAirbyteDetail').textContent = fmt(ing?.detail?.error);

      const nsTransform = nsByName(summary, 'transform');
      el('proofDbt').textContent = nsTransform ? 'YES' : 'NO';
      const pods = nsTransform?.pods?.items || [];
      const lastJob = Array.isArray(pods) ? (pods.find(p=>String(p.name||'').includes('dbt'))?.name || '') : '';
      el('proofDbtJob').textContent = fmt(lastJob);

      const buckets = summary?.catalog?.minio?.buckets || [];
      el('proofBuckets').textContent = String(Array.isArray(buckets) ? buckets.length : 0);
      const newest = Array.isArray(buckets) && buckets.length ? buckets.slice().sort((a,b)=>String(b.created).localeCompare(String(a.created)))[0] : null;
      el('proofNewestBucket').textContent = newest ? `${newest.name} (${newest.created})` : '—';

      const schemas = summary?.catalog?.postgres?.schemas || [];
      el('proofSchemas').textContent = String(Array.isArray(schemas) ? schemas.length : 0);
      const tables = Array.isArray(summary?.catalog?.postgres?.tables) ? summary.catalog.postgres.tables.length : 0;
      el('proofTables').textContent = String(tables);
    }

    function renderHealth(summary, apps, pf){
      el('appsUp').textContent = String(pf.apps_up);
      el('appsDown').textContent = String(pf.apps_down);
      el('pods').textContent = String(pf.pods);
      el('restarts24h').textContent = String(pf.restarts_24h);

      const grid = el('healthGrid');
      grid.innerHTML = '';

      const filtered = apps.filter(a => currentFilter==='all' ? true : (a.status===currentFilter));
      for(const a of filtered){
        const card = document.createElement('div');
        card.className = 'card svc';

        const pods_total = a.k8s?.pods_total ?? 0;
        const pods_ready = a.k8s?.pods_ready ?? 0;
        const restarts = a.k8s?.restarts_24h ?? 0;

        const openHref = a.links?.open || a._openHref || '';
        const openBtn = openHref
          ? `<a class="btn btn-primary" href="${openHref}" target="_blank" rel="noopener">Open</a>`
          : `<span class="btn btn-primary" style="opacity:.45">Open</span>`;

        card.innerHTML = `
          <div class="svcTop">
            <div>
              <div class="svcTitle">${a.display}</div>
              <div class="muted">pods: ${pods_ready}/${pods_total} | restarts: ${restarts}</div>
            </div>
            <div class="badge ${a.status}">${badgeText(a.status)}</div>
          </div>
          <div class="svcDesc">${a.reason || ''}</div>
          <div class="svcActions">
            ${openBtn}
            <a class="btn btn-ghost" href="#assets">Assets</a>
          </div>
        `;
        grid.appendChild(card);
      }

      const ids = { all:'chipAll', healthy:'chipHealthy', degraded:'chipDegraded', missing:'chipMissing' };
      for(const k of Object.keys(ids)){
        const b = el(ids[k]);
        if(!b) continue;
        b.classList.toggle('active', currentFilter===k);
        b.onclick = ()=>{ currentFilter = k; load(); };
      }

      el('rawJson').textContent = JSON.stringify(summary, null, 2);
    }

    async function load(){
      setActiveNav();
      const r = await fetch(API_SUMMARY, {cache:'no-store'});
      const summary = await r.json();
      const apps = deriveApps(summary);
      const pf = platformFromApps(summary, apps);

      renderLaunchpad(summary, apps, pf);
      renderServiceGrid(apps);
      renderAssets(summary);
      renderProof(summary);
      renderHealth(summary, apps, pf);
    }

    window.addEventListener('hashchange', ()=>{ setActiveNav(); });
    load().catch(()=>{});
    setInterval(()=>{ load().catch(()=>{}); }, 15000);
YAML

# Replace only placeholders (leave JS template literals intact)
sed -i \
  -e "s/__PLATFORM_NS__/${PLATFORM_NS}/g" \
  -e "s/__UI_CM__/${UI_CM}/g" \
  "${TMP_CM}"

log "Apply ConfigMap ${UI_CM} (nginx + UI assets)"
kubectl -n "${PLATFORM_NS}" apply -f "${TMP_CM}"

# ------------------------------------------------------------------------------
# Deployment + Service (apply = idempotent)
# ------------------------------------------------------------------------------
log "Apply Deployment ${UI_DEPLOY} + Service ${UI_SVC}"
kubectl -n "${PLATFORM_NS}" apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${UI_DEPLOY}
  namespace: ${PLATFORM_NS}
  labels:
    app: ${UI_DEPLOY}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${UI_DEPLOY}
  template:
    metadata:
      labels:
        app: ${UI_DEPLOY}
    spec:
      containers:
      - name: nginx
        image: nginx:1.27-alpine
        imagePullPolicy: IfNotPresent
        ports:
        - name: http
          containerPort: 8080
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 2
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
        securityContext:
          allowPrivilegeEscalation: false
        volumeMounts:
        - name: ui-static
          mountPath: /usr/share/nginx/html/index.html
          subPath: index.html
          readOnly: true
        - name: ui-static
          mountPath: /usr/share/nginx/html/styles.css
          subPath: styles.css
          readOnly: true
        - name: ui-static
          mountPath: /usr/share/nginx/html/app.js
          subPath: app.js
          readOnly: true
        - name: ui-static
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
          readOnly: true
      volumes:
      - name: ui-static
        configMap:
          name: ${UI_CM}
---
apiVersion: v1
kind: Service
metadata:
  name: ${UI_SVC}
  namespace: ${PLATFORM_NS}
  labels:
    app: ${UI_DEPLOY}
spec:
  selector:
    app: ${UI_DEPLOY}
  ports:
  - name: http
    port: 80
    targetPort: 8080
YAML

# ------------------------------------------------------------------------------
# TLS Certificate (repeatable)
# ------------------------------------------------------------------------------
if [[ "${TLS_MODE}" == "per-host-http01" ]]; then
  log "Ensure Certificate secret=${PORTAL_TLS_SECRET} issuer=${CLUSTER_ISSUER}"
  kubectl -n "${PLATFORM_NS}" apply -f - <<YAML
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: portal-cert
  namespace: ${PLATFORM_NS}
spec:
  secretName: ${PORTAL_TLS_SECRET}
  issuerRef:
    kind: ClusterIssuer
    name: ${CLUSTER_ISSUER}
  dnsNames:
    - ${PORTAL_HOST}
YAML
  kubectl -n "${PLATFORM_NS}" wait --for=condition=Ready certificate/portal-cert --timeout=600s || true
fi

# ------------------------------------------------------------------------------
# Ingress (HTTPS-ready, repeatable)
# ------------------------------------------------------------------------------
TLS_BLOCK=""
if [[ "${TLS_MODE}" == "per-host-http01" ]]; then
  TLS_BLOCK="$(cat <<EOF
  tls:
  - hosts:
    - ${PORTAL_HOST}
    secretName: ${PORTAL_TLS_SECRET}
EOF
)"
fi

log "Apply Ingress portal (host=${PORTAL_HOST}, tls_mode=${TLS_MODE})"
kubectl -n "${PLATFORM_NS}" apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: portal
  namespace: ${PLATFORM_NS}
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"
spec:
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
            name: ${UI_SVC}
            port:
              number: 80
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: ${API_SVC}
            port:
              number: 80
YAML

# ------------------------------------------------------------------------------
# Rollout + verification
# ------------------------------------------------------------------------------
log "Wait for rollout"
kubectl -n "${PLATFORM_NS}" rollout status deployment "${UI_DEPLOY}" --timeout=240s

log "Verify content types"
curl -skI "https://${PORTAL_HOST}/app.js" | tr -d '\r' | egrep -i 'HTTP/|content-type:' || true
curl -skI "https://${PORTAL_HOST}/styles.css" | tr -d '\r' | egrep -i 'HTTP/|content-type:' || true

log "Verify API health"
curl -sk "https://${PORTAL_HOST}/api/health" | head -c 200 || true
echo

log "Done"
log "URL: https://${PORTAL_HOST}/"
log "API: https://${PORTAL_HOST}/api/health"
log "SUM: https://${PORTAL_HOST}/api/summary?v=1"
