(() => {
  const API = "/api";
  const view = document.getElementById("view");
  const apiPill = document.getElementById("apiPill");
  const lastGen = document.getElementById("lastGen");
  const tabs = Array.from(document.querySelectorAll(".tab"));

  let state = { tab: "overview", summary: null, assets: null, filter: "" };

  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const badgeCls = (st) => {
    st = String(st||"").toUpperCase();
    if (st==="OPERATIONAL") return "badge ok";
    if (st==="DEGRADED") return "badge warn";
    if (st==="DOWN") return "badge down";
    if (st==="INFO") return "badge info";
    return "badge unk";
  };

  function svcDesc(name) {
    const map = {
      postgres: "Core database connectivity, schemas/tables evidence.",
      minio: "Object storage (S3/MinIO) bucket count and console link.",
      airbyte: "Ingestion engine health and last sync proof.",
      dbt: "Transform evidence and docs/lineage links.",
      metabase: "Analytics UI availability and API reachability.",
      n8n: "Automation workflows; API auth optional.",
      zammad: "Ticketing portal; UI + API reachability.",
      ingress_tls: "Ingress routing and TLS scheme checks.",
      kubernetes: "Cluster workloads, namespaces, ingresses, restarts."
    };
    return map[name] || "Service health and evidence.";
  }

  function svcLinks(summary, svc) {
    const top = summary?.links || {};
    const ui = svc?.links?.ui || top[svc.name] || "";
    const api = svc?.links?.api || "";
    const extra = [];

    if (svc.name === "dbt") {
      const portalHost = summary?.k8s?.ingresses?.find(x => x.name==="dbt-docs-ingress")?.host;
      if (portalHost) extra.push({label:"Docs (portal)", href:`https://${portalHost}/dbt/docs/his_dmo/`});
      if (top.dbt_docs) extra.push({label:"Docs", href:top.dbt_docs});
      if (top.dbt_lineage) extra.push({label:"Lineage", href:top.dbt_lineage});
    }

    return { ui, api, extra };
  }

  function renderOverview(summary) {
    const status = summary.platform_status || "UNKNOWN";
    const opx = summary?.operational?.x ?? 0;
    const opy = summary?.operational?.y ?? 0;
    const gen = summary.generated_at || "";
    lastGen.textContent = gen ? `Generated: ${gen}` : "—";

    const k = summary.k8s || {};
    const wl = k.workloads || {};
    const deps = wl.deployments || {};
    const pods = wl.pods || {};
    const ssets = wl.statefulsets || {};

    const hero = `
      <div class="grid2">
        <div class="card">
          <div class="hd">
            <div>
              <div style="font-weight:900">Deploy a governed analytics platform in days</div>
              <div class="small">Control plane health, operational proof, and catalog snapshot.</div>
            </div>
            <div class="${badgeCls(status)}">${esc(status)}</div>
          </div>
          <div class="bd">
            <div class="kv">
              <div><span class="small">Operational</span> <b>${esc(opx)}/${esc(opy)}</b></div>
              <div><span class="small">Deployments</span> <b>${esc(deps.ready)}/${esc(deps.total)}</b></div>
              <div><span class="small">Pods</span> <b>${esc(pods.ready)}/${esc(pods.total)}</b></div>
              <div><span class="small">StatefulSets</span> <b>${esc(ssets.ready)}/${esc(ssets.total)}</b></div>
              <div><span class="small">Restarts</span> <b>${esc(k.restarts_total ?? 0)}</b></div>
            </div>
            <div class="btnrow">
              <a class="btn" href="#/overview" data-nav="overview">Open services</a>
              <a class="btn" href="#/catalog" data-nav="catalog">View catalog</a>
              <a class="btn" href="#/ops" data-nav="ops">Health matrix</a>
            </div>
          </div>
        </div>

        <div class="card">
          <div class="hd"><div style="font-weight:900">What this platform provides</div></div>
          <div class="bd">
            <ul class="small" style="margin:0;padding-left:16px;color:var(--muted);line-height:1.6">
              <li>Single entry point for Airbyte, MinIO, dashboards, and operations.</li>
              <li>Operational proof: ingestion run, last model build, freshness.</li>
              <li>Clear path to governance: catalog snapshot and controlled access.</li>
            </ul>
          </div>
        </div>
      </div>
    `;

    const services = Array.isArray(summary.services) ? summary.services : [];
    const order = ["postgres","minio","airbyte","dbt","metabase","n8n","zammad","ingress_tls","kubernetes"];
    services.sort((a,b)=> order.indexOf(a.name)-order.indexOf(b.name));

    const svcCards = services.map(s => {
      const links = svcLinks(summary, s);
      const btns = [];
      if (links.ui) btns.push(`<a class="btn" href="${esc(links.ui)}" target="_blank" rel="noreferrer">Open</a>`);
      if (links.api) btns.push(`<a class="btn" href="${esc(links.api)}" target="_blank" rel="noreferrer">API</a>`);
      links.extra.forEach(x => btns.push(`<a class="btn" href="${esc(x.href)}" target="_blank" rel="noreferrer">${esc(x.label)}</a>`));

      return `
        <div class="svcCard">
          <div class="svcTop">
            <div class="svcName">${esc(s.name)}</div>
            <div class="${badgeCls(s.status)}">${esc(s.status)}</div>
          </div>
          <div class="svcMeta">${esc(s.reason || svcDesc(s.name))}</div>
          <div class="btnrow">${btns.join("") || `<span class="small">No links</span>`}</div>
        </div>
      `;
    }).join("");

    const proof = `
      <div class="card">
        <div class="hd"><div style="font-weight:900">Operational proof</div><div class="small">Evidence captured by API</div></div>
        <div class="bd">
          <div class="kv">
            <div><span class="small">Schemas</span> <b>${esc(summary?.postgres?.schemas_count ?? 0)}</b></div>
            <div><span class="small">Tables</span> <b>${esc(summary?.postgres?.tables_count ?? 0)}</b></div>
            <div><span class="small">Airbyte last sync</span> <b>${esc(summary?.proof?.airbyte_last_sync ?? "—")}</b></div>
            <div><span class="small">dbt last run</span> <b>${esc(summary?.proof?.dbt_last_run ?? "—")}</b></div>
            <div><span class="small">Data availability</span> <b>${esc(summary?.proof?.data_availability?.schemas ?? 0)}/${esc(summary?.proof?.data_availability?.tables ?? 0)}</b></div>
          </div>
        </div>
      </div>
    `;

    return `
      ${hero}
      <div class="sectionTitle"><div class="t">Service launchpad</div><div class="s">${esc(status)}</div></div>
      <div class="svcGrid">${svcCards}</div>
      <div class="sectionTitle"><div class="t">Operational proof</div><div class="s">From API summary</div></div>
      ${proof}
    `;
  }

  function renderCatalog(summary, assets) {
    const tables = assets?.tables || [];
    const q = state.filter.trim().toLowerCase();

    const filtered = q
      ? tables.filter(t =>
          String(t.schema||"").toLowerCase().includes(q) ||
          String(t.table||"").toLowerCase().includes(q) ||
          String(t.owner||"").toLowerCase().includes(q)
        )
      : tables;

    const rows = filtered.map(t => `
      <tr>
        <td>${esc(t.schema || "")}</td>
        <td>${esc(t.table || "")}</td>
        <td>${esc(t.rows ?? "")}</td>
        <td>${esc(t.last_update ?? "")}</td>
        <td>${esc(t.owner ?? "")}</td>
      </tr>
    `).join("");

    return `
      <div class="card">
        <div class="hd"><div style="font-weight:900">Data assets</div><div class="small">Catalog snapshot</div></div>
        <div class="bd">
          <div class="filterRow">
            <input class="input" id="filter" placeholder="Filter by schema / table / owner" value="${esc(state.filter)}"/>
            <span class="small">Total: ${esc(assets?.pagination?.total ?? tables.length)}</span>
          </div>

          <div class="tableWrap">
            <table>
              <thead>
                <tr><th>Schema</th><th>Table</th><th>Rows</th><th>Last update</th><th>Owner</th></tr>
              </thead>
              <tbody>
                ${rows || `<tr><td colspan="5" class="small">No rows</td></tr>`}
              </tbody>
            </table>
          </div>
        </div>
      </div>
    `;
  }

  function renderOps(summary) {
    const ing = summary?.k8s?.ingresses || [];
    const rows = ing.map(x => `
      <tr>
        <td>${esc(x.namespace)}</td>
        <td>${esc(x.name)}</td>
        <td>${esc(x.host)}</td>
        <td>${esc(x.path)}</td>
        <td>${esc(x.service)}:${esc(x.service_port)}</td>
      </tr>
    `).join("");

    return `
      <div class="card">
        <div class="hd"><div style="font-weight:900">Ingress routes</div><div class="small">From cluster inventory</div></div>
        <div class="bd">
          <div class="tableWrap">
            <table>
              <thead><tr><th>NS</th><th>Name</th><th>Host</th><th>Path</th><th>Backend</th></tr></thead>
              <tbody>${rows || `<tr><td colspan="5" class="small">No ingresses</td></tr>`}</tbody>
            </table>
          </div>
        </div>
      </div>
    `;
  }

  function render() {
    const s = state.summary;
    if (!s) {
      view.innerHTML = `<div class="card"><div class="bd"><div class="small">Loading…</div></div></div>`;
      return;
    }

    if (state.tab === "overview") view.innerHTML = renderOverview(s);
    else if (state.tab === "catalog") view.innerHTML = renderCatalog(s, state.assets || s.assets);
    else if (state.tab === "ops") view.innerHTML = renderOps(s);
    else view.innerHTML = `<div class="card"><div class="bd"><div class="small">Placeholder tab: ${esc(state.tab)}</div></div></div>`;

    const filter = document.getElementById("filter");
    if (filter) {
      filter.addEventListener("input", (e) => {
        state.filter = e.target.value || "";
        render();
      });
    }

    document.querySelectorAll("[data-nav]").forEach(a => {
      a.addEventListener("click", (e) => {
        e.preventDefault();
        setTab(e.target.getAttribute("data-nav"));
      });
    });
  }

  function setTab(tab) {
    state.tab = tab;
    tabs.forEach(t => t.classList.toggle("active", t.dataset.tab === tab));
    render();
  }

  async function fetchSummary() {
    const r = await fetch(`${API}/summary`, { cache: "no-store" });
    if (!r.ok) throw new Error(`summary ${r.status}`);
    return r.json();
  }

  async function fetchSearch() {
    const r = await fetch(`${API}/search?q=&page=1&page_size=50`, { cache: "no-store" });
    if (!r.ok) return null;
    return r.json();
  }

  async function tickSummary() {
    try {
      apiPill.textContent = "API: checking…";
      const s = await fetchSummary();
      apiPill.textContent = "API: ok";
      state.summary = s;
      render();
    } catch {
      apiPill.textContent = "API: down";
      view.innerHTML = `<div class="card"><div class="bd"><div class="small">Failed to load /api/summary</div></div></div>`;
    }
  }

  async function tickAssets() {
    if (state.tab !== "catalog") return;
    const a = await fetchSearch();
    if (a && a.assets) state.assets = a.assets;
    render();
  }

  tabs.forEach(btn => btn.addEventListener("click", () => setTab(btn.dataset.tab)));

  setTab("overview");
  tickSummary();
  setInterval(tickSummary, 30000);
  setInterval(tickAssets, 60000);
})();
