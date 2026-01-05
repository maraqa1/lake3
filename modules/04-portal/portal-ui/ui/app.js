// Phase 1 UI aligned to portal-api_updated routes.
// API_BASE:
// - If PORTAL_API_BASE is injected at build-time, honor it via global.
// - Otherwise default to same-host split ingress at /api.

const API_BASE = (window.PORTAL_API_BASE || "/api").replace(/\/+$/,"");
document.getElementById("apiBaseLabel").textContent = API_BASE;

const ep = {
  health: `${API_BASE}/health`,
  services: `${API_BASE}/services`,
  k8s: `${API_BASE}/k8s/summary`,
  summary: `${API_BASE}/summary`,
  catalogTables: `${API_BASE}/catalog/tables`,
  catalogSearch: (q) => `${API_BASE}/catalog/search?q=${encodeURIComponent(q)}`,
  // Some deployments expose /api/search; fallback supported.
  legacySearch: (q) => `${API_BASE}/search?q=${encodeURIComponent(q)}`
};

const state = {
  health: null,
  services: [],
  k8s: null,
  summary: null,
  catalog: { tables: null, search: null, q: "" },
  ingestion: null,
  tickets: null,
  ops: null,
  lastChecked: null,
  errors: { health: null, services: null, k8s: null, summary: null }
};

function badgeClass(status){
  const s = String(status||"").toUpperCase();
  if (s === "OPERATIONAL" || s === "UP" || s === "OK") return "ok";
  if (s === "DEGRADED" || s === "WARN" || s === "WARNING") return "warn";
  if (s === "DOWN" || s === "ERROR") return "down";
  if (s === "INFO") return "info";
  return "neutral";
}

function safeText(x){
  if (x === null || x === undefined) return "";
  if (typeof x === "string") return x;
  try { return JSON.stringify(x); } catch { return String(x); }
}

async function jget(url){
  try{
    const r = await fetch(url, { cache: "no-store" });
    const t = await r.text();
    const data = t ? JSON.parse(t) : null;
    return { ok: r.ok, status: r.status, data };
  }catch(e){
    return { ok:false, status:0, data:{ error:String(e) } };
  }
}

function route(){
  const h = (location.hash || "#overview").replace("#","");
  return ["overview","catalog","ingestion","decisioning","tickets","ops"].includes(h) ? h : "overview";
}

function setRoute(r){ location.hash = `#${r}`; }
function setActiveNav(r){
  document.querySelectorAll(".nav-item").forEach(a=>{
    a.classList.toggle("active", a.dataset.route === r);
  });
  document.querySelectorAll(".route").forEach(s=>{
    s.classList.toggle("hidden", s.id !== `route-${r}`);
  });
}

function setTopline(){
  const badge = document.getElementById("platformStatus");
  const ts = document.getElementById("lastChecked");
  const st = (state.summary?.platform_status) || (state.summary?.status) || (state.health?.status === "ok" ? "OPERATIONAL" : "INFO");
  badge.textContent = st;
  badge.className = `badge ${badgeClass(st)}`;
  if (state.lastChecked){
    ts.textContent = ` • last checked ${new Date(state.lastChecked).toLocaleString()}`;
  }
}

function serviceCard(svc){
  const name = svc?.name || svc?.id || "service";
  const status = svc?.status || "INFO";
  const reason = svc?.reason || "";
  const links = svc?.links || {};
  const last = svc?.last_checked || "";

  const btns = [];
  for (const [k,v] of Object.entries(links)){
    if (!v) continue;
    btns.push(`<a class="btn small" href="${v}" target="_blank" rel="noreferrer">${k}</a>`);
  }
  const metaLine = [
    svc?.namespace ? `ns=${svc.namespace}` : "",
    svc?.internal ? `internal=${svc.internal}` : "",
    svc?.external ? `external=${svc.external}` : ""
  ].filter(Boolean).join(" • ");

  return `
  <div class="card">
    <div class="card-head">
      <div>
        <div class="card-title">${name}</div>
        <div class="card-sub">${metaLine || " "}</div>
      </div>
      <div class="badge ${badgeClass(status)}">${status}</div>
    </div>
    <div class="card-body">
      ${reason ? safeText(reason) : " "}
      ${last ? `<div class="muted" style="margin-top:6px;">checked: ${safeText(last)}</div>` : ""}
    </div>
    <div class="card-actions">
      ${btns.join("")}
    </div>
  </div>`;
}

function renderOverview(){
  const el = document.getElementById("route-overview");
  const services = state.services || [];
  const grid = services.map(serviceCard).join("");

  el.innerHTML = `
    <div class="section-title">Services</div>
    <div class="grid">${grid || `<div class="card"><div class="card-title">No services</div><div class="card-body">/api/services returned empty</div></div>`}</div>
  `;
}

function renderCatalog(){
  const el = document.getElementById("route-catalog");
  const tables = state.catalog.tables?.tables || state.catalog.tables?.items || state.catalog.tables || null;
  const rows = Array.isArray(tables) ? tables : [];

  const q = state.catalog.q || "";
  const results = state.catalog.search?.results || state.catalog.search?.items || state.catalog.search?.rows || state.catalog.search || null;
  const rrows = Array.isArray(results) ? results : [];

  const tablesTable = rows.length ? `
    <table class="table">
      <thead><tr><th>Schema</th><th>Table</th><th>Columns</th></tr></thead>
      <tbody>
        ${rows.slice(0,200).map(x=>{
          const schema = x.schema || x.table_schema || x.s || "";
          const table = x.table || x.table_name || x.t || "";
          const cols = x.columns_count || x.columns || x.col_count || "";
          return `<tr><td>${safeText(schema)}</td><td>${safeText(table)}</td><td>${safeText(cols)}</td></tr>`;
        }).join("")}
      </tbody>
    </table>` : `<div class="card"><div class="card-title">Tables</div><div class="card-body">No rows yet. Use refresh.</div></div>`;

  const resTable = rrows.length ? `
    <table class="table" style="margin-top:12px;">
      <thead><tr><th>Match</th><th>Details</th></tr></thead>
      <tbody>
        ${rrows.slice(0,200).map(x=>{
          const a = x.match || x.name || x.table || x.column || "";
          return `<tr><td>${safeText(a)}</td><td>${safeText(x)}</td></tr>`;
        }).join("")}
      </tbody>
    </table>` : (q ? `<div class="card" style="margin-top:12px;"><div class="card-title">Search</div><div class="card-body">No results.</div></div>` : "");

  el.innerHTML = `
    <div class="section-title">Catalog</div>

    <div class="row" style="margin-bottom:10px;">
      <input id="q" class="input" placeholder="Search tables/columns..." value="${q.replace(/"/g,"&quot;")}" />
      <button id="btnSearch" class="btn">Search</button>
      <button id="btnTables" class="btn ghost">Refresh tables</button>
      <a class="btn ghost" href="${ep.catalogTables}" target="_blank" rel="noreferrer">Open JSON</a>
    </div>

    ${tablesTable}
    ${resTable}
  `;

  document.getElementById("btnTables").onclick = async () => {
    const r = await jget(ep.catalogTables);
    state.catalog.tables = r.ok ? r.data : { error: r.data };
    render();
  };

  document.getElementById("btnSearch").onclick = async () => {
    const val = (document.getElementById("q").value || "").trim();
    state.catalog.q = val;
    if (!val){
      state.catalog.search = null;
      render();
      return;
    }
    // primary: /api/catalog/search?q=
    let r = await jget(ep.catalogSearch(val));
    // fallback: /api/search?q=
    if (!r.ok && (r.status === 404 || r.status === 405)){
      r = await jget(ep.legacySearch(val));
    }
    state.catalog.search = r.ok ? r.data : { error: r.data };
    render();
  };
}

async function renderEndpointCard(el, title, json){
  el.innerHTML = `
    <div class="section-title">${title}</div>
    <div class="card">
      <div class="card-title">${title}</div>
      <div class="card-body"><pre style="white-space:pre-wrap;margin:0;color:var(--muted);font-size:12px;">${safeText(json)}</pre></div>
    </div>`;
}

function renderIngestion(){
  const el = document.getElementById("route-ingestion");
  const j = state.ingestion || { note: "loading" };
  return renderEndpointCard(el, "Ingestion (Airbyte)", j);
}

function renderDecisioning(){
  const el = document.getElementById("route-decisioning");
  const j = state.ops?.n8n || state.ops?.ops?.n8n || state.summary?.n8n || { note: "Decisioning uses n8n; see Ops tab." };
  return renderEndpointCard(el, "Decisioning (n8n)", j);
}

function renderTickets(){
  const el = document.getElementById("route-tickets");
  const j = state.tickets || { note: "loading" };
  return renderEndpointCard(el, "Tickets (Zammad)", j);
}

function renderOps(){
  const el = document.getElementById("route-ops");
  const k8s = state.k8s || { note: "loading" };
  return renderEndpointCard(el, "Ops (Kubernetes summary)", k8s);
}

function render(){
  const r = route();
  setActiveNav(r);
  setTopline();

  if (r === "overview") renderOverview();
  if (r === "catalog") renderCatalog();
  if (r === "ingestion") renderIngestion();
  if (r === "decisioning") renderDecisioning();
  if (r === "tickets") renderTickets();
  if (r === "ops") renderOps();
}

async function pollHealthAndServices(){
  const [h, s] = await Promise.all([jget(ep.health), jget(ep.services)]);
  state.health = h.ok ? h.data : null;
  state.services = s.ok ? (s.data?.services || []) : [];
  state.lastChecked = new Date().toISOString();
  render();
}

async function pollK8s(){
  const k = await jget(ep.k8s);
  state.k8s = k.ok ? k.data : { error: k.data };
  render();
}

async function pollSummary(){
  const s = await jget(ep.summary);
  state.summary = s.ok ? s.data : { error: s.data };
  // Also pull endpoint tabs from summary if present
  state.ops = s.ok ? s.data : null;
  render();
}

async function pollDetails(){
  // These endpoints exist in the uploaded API zip:
  // /api/ingestion/airbyte, /api/itsm/zammad
  const [i, t] = await Promise.all([jget(`${API_BASE}/ingestion/airbyte`), jget(`${API_BASE}/itsm/zammad`)]);
  state.ingestion = i.ok ? i.data : { error: i.data };
  state.tickets = t.ok ? t.data : { error: t.data };
  render();
}

function wireNav(){
  document.querySelectorAll(".nav-item").forEach(a=>{
    a.addEventListener("click", ()=> setRoute(a.dataset.route));
  });
  window.addEventListener("hashchange", render);
}

(async function boot(){
  wireNav();
  await pollSummary();
  await pollHealthAndServices();
  await pollK8s();
  await pollDetails();

  // Cadence per spec
  setInterval(pollHealthAndServices, 30_000);
  setInterval(pollSummary, 30_000); // spec wants /api/services; summary is cheap and useful
  setInterval(pollK8s, 60_000);
})();
