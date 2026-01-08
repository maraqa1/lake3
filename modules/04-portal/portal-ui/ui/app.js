// DROP-IN app.js (replace entire file)
// Fixes:
// - Removes duplicate fetchDbtProjects()
// - Fixes undefined `tab` reference
// - Prevents render↔tickAssets recursion
// - Adds stable catalog polling + debounced filter
// - Keeps MinIO buckets in dedicated "Storage / MinIO" card using /api/summary services[].evidence.details.sample[]
(() => {
  const API = "/api";
  const view = document.getElementById("view");
  const apiPill = document.getElementById("apiPill");
  const lastGen = document.getElementById("lastGen");
  const tabs = Array.from(document.querySelectorAll(".tab"));

  let state = {
    tab: "overview",
    summary: null,
    assets: null,
    filter: "",
    dbtProjects: [],
    dbtProject: "his_dmo",
    page: 1,
    pageSize: 50,
  };

  let catalogFilterTimer = null;
  let summaryTimer = null;
  let assetsTimer = null;

  const esc = (s) =>
    String(s ?? "").replace(/[&<>"']/g, (c) => ({
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&#39;",
    }[c]));

  const badgeCls = (st) => {
    st = String(st || "").toUpperCase();
    if (st === "OPERATIONAL") return "badge ok";
    if (st === "DEGRADED") return "badge warn";
    if (st === "DOWN") return "badge down";
    if (st === "INFO") return "badge info";
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
      kubernetes: "Cluster workloads, namespaces, ingresses, restarts.",
    };
    return map[name] || "Service health and evidence.";
  }

  function svcLinks(summary, svc) {
    const top = summary?.links || {};
    const ui = svc?.links?.ui || top[svc.name] || "";
    const api = svc?.links?.api || "";
    const extra = [];

    if (svc.name === "dbt") {
      const portalHost = summary?.k8s?.ingresses?.find((x) => x.name === "dbt-docs-ingress")?.host;
      if (portalHost) extra.push({ label: "Docs (portal)", href: `https://${portalHost}/dbt/docs/${state.dbtProject || "his_dmo"}/` });
      if (top.dbt_docs) extra.push({ label: "Docs", href: top.dbt_docs });
      if (top.dbt_lineage) extra.push({ label: "Lineage", href: top.dbt_lineage });
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

    const services = Array.isArray(summary.services) ? summary.services.slice() : [];
    const order = ["postgres", "minio", "airbyte", "dbt", "metabase", "n8n", "zammad", "ingress_tls", "kubernetes"];
    services.sort((a, b) => (order.indexOf(a.name) - order.indexOf(b.name)));

    const svcCards = services.map((s) => {
      const links = svcLinks(summary, s);
      const btns = [];
      if (links.ui) btns.push(`<a class="btn" href="${esc(links.ui)}" target="_blank" rel="noreferrer">Open</a>`);
      if (links.api) btns.push(`<a class="btn" href="${esc(links.api)}" target="_blank" rel="noreferrer">API</a>`);
      links.extra.forEach((x) =>
        btns.push(`<a class="btn" href="${esc(x.href)}" target="_blank" rel="noreferrer">${esc(x.label)}</a>`)
      );

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
      <div class="sectionTitle"><div class="t">Storage</div><div class="s">MinIO</div></div>
      <div class="card" id="minioBucketsCard"></div>
    `;
  }

  function renderOps(summary) {
    const ing = summary?.k8s?.ingresses || [];
    const rows = ing.map((x) => `
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

  function renderCatalogShell() {
    const total = (state.assets?.pagination?.total != null)
      ? state.assets.pagination.total
      : (state.assets?.tables?.length ?? 0);

    return `
      <div class="card">
        <div class="hd">
          <div style="font-weight:900">Data assets</div>
          <div class="small">Catalog snapshot (dbt project)</div>
        </div>
        <div class="bd">
          <div class="filterRow" style="gap:10px;align-items:center">
            <input class="input" id="filter" placeholder="Filter by schema / table / owner" value="${esc(state.filter)}"/>
            <select class="input" id="dbtProject" style="max-width:260px">
              ${(state.dbtProjects || []).map((p) => `<option value="${esc(p)}"${p === state.dbtProject ? " selected" : ""}>${esc(p)}</option>`).join("")}
            </select>
            <span class="small" id="catalogTotal">Total: ${esc(total)}</span>
          </div>

          <div class="tableWrap">
            <table>
              <thead>
                <tr><th>Schema</th><th>Table</th><th>Rows</th><th>Last update</th><th>Owner</th></tr>
              </thead>
              <tbody id="catalogBody">
                <tr><td colspan="5" class="small">Loading…</td></tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    `;
  }

  function updateCatalogRows() {
    const tbody = document.getElementById("catalogBody");
    const totalEl = document.getElementById("catalogTotal");
    if (!tbody) return;

    const tables = state.assets?.tables || [];
    const total = (state.assets?.pagination?.total != null) ? state.assets.pagination.total : tables.length;
    if (totalEl) totalEl.textContent = `Total: ${total}`;

    const q = String(state.filter || "").trim().toLowerCase();
    const filtered = q
      ? tables.filter((t) =>
          String(t.schema || "").toLowerCase().includes(q) ||
          String(t.table || "").toLowerCase().includes(q) ||
          String(t.owner || "").toLowerCase().includes(q)
        )
      : tables;

    const rows = filtered.map((t) => `
      <tr>
        <td>${esc(t.schema || "")}</td>
        <td>${esc(t.table || "")}</td>
        <td>${esc(t.rows ?? "")}</td>
        <td>${esc(t.last_update ?? "")}</td>
        <td>${esc(t.owner ?? "")}</td>
      </tr>
    `).join("");

    tbody.innerHTML = rows || `<tr><td colspan="5" class="small">No rows</td></tr>`;
  }

  function renderMinioBucketsFromSummary(summary) {
    const el = document.getElementById("minioBucketsCard");
    if (!el) return;

    const services = Array.isArray(summary.services) ? summary.services : [];
    const minio = services.find((x) => x && x.name === "minio") || {};
    const details = ((minio.evidence || {}).details || {});
    const sample = Array.isArray(details.sample) ? details.sample : [];

    const pills = sample.map((b) => {
      const n = b?.name;
      const d = b?.creation_date;
      if (!n) return "";
      return `<div class="bucketPill" title="${esc(d || "")}">${esc(n)}</div>`;
    }).filter(Boolean).join("");

    const count = (details.bucket_count != null) ? details.bucket_count : sample.length;

    el.innerHTML = `
      <div class="hd">
        <div style="font-weight:900">MinIO Buckets</div>
        <div class="${badgeCls(minio.status)}">${esc(minio.status || "INFO")}</div>
      </div>
      <div class="bd">
        <div class="small">Count: <b>${esc(count)}</b></div>
        <div class="bucketGrid" style="margin-top:10px">
          ${pills || `<div class="small">No buckets</div>`}
        </div>
      </div>
    `;
  }

  function bindNavHandlers() {
    document.querySelectorAll("[data-nav]").forEach((a) => {
      a.addEventListener("click", (e) => {
        e.preventDefault();
        setTab(e.target.getAttribute("data-nav"));
      });
    });
  }

  function bindCatalogHandlers() {
    const filter = document.getElementById("filter");
    if (filter) {
      filter.value = state.filter || "";
      filter.oninput = (e) => {
        state.filter = e.target.value || "";
        clearTimeout(catalogFilterTimer);
        catalogFilterTimer = setTimeout(() => tickAssets(true), 250);
      };
    }

    const sel = document.getElementById("dbtProject");
    if (sel) {
      sel.value = state.dbtProject || "";
      sel.onchange = async (e) => {
        state.dbtProject = e.target.value || "his_dmo";
        state.assets = null;
        await tickAssets(true);
      };
    }
  }

  function render() {
    const s = state.summary;

    if (!s) {
      view.innerHTML = `<div class="card"><div class="bd"><div class="small">Loading…</div></div></div>`;
      return;
    }

    if (state.tab === "overview") {
      view.innerHTML = renderOverview(s);
      renderMinioBucketsFromSummary(s);
      bindNavHandlers();
      return;
    }

    if (state.tab === "catalog") {
      view.innerHTML = renderCatalogShell();
      bindCatalogHandlers();
      updateCatalogRows();
      bindNavHandlers();
      return;
    }

    if (state.tab === "ops") {
      view.innerHTML = renderOps(s);
      bindNavHandlers();
      return;
    }

    view.innerHTML = `<div class="card"><div class="bd"><div class="small">Placeholder tab: ${esc(state.tab)}</div></div></div>`;
    bindNavHandlers();
  }

  function setTab(tab) {
    state.tab = tab;
    tabs.forEach((t) => t.classList.toggle("active", t.dataset.tab === tab));
    render();
    if (tab === "catalog") tickAssets(true);
  }

  async function fetchSummary() {
    const r = await fetch(`${API}/summary`, { cache: "no-store" });
    if (!r.ok) throw new Error(`summary ${r.status}`);
    return r.json();
  }

  async function fetchDbtProjects() {
    const r = await fetch(`${API}/dbt/projects`, { cache: "no-store" });
    if (!r.ok) return [];
    const d = await r.json();
    return (Array.isArray(d.projects) ? d.projects : []).map((p) => p.id).filter(Boolean);
  }

  async function fetchSearch(project, q, page, pageSize) {
    const qp = new URLSearchParams({
      project: project || "",
      q: q || "",
      page: String(page || 1),
      page_size: String(pageSize || 50),
    });
    const r = await fetch(`${API}/search?${qp.toString()}`, { cache: "no-store" });
    if (!r.ok) return null;
    return r.json();
  }

  async function tickAssets(force = false) {
    if (state.tab !== "catalog") return;

    if (!state.dbtProject) state.dbtProject = "his_dmo";
    if (!state.page) state.page = 1;
    if (!state.pageSize) state.pageSize = 50;

    if (force || !Array.isArray(state.dbtProjects) || state.dbtProjects.length === 0) {
      state.dbtProjects = await fetchDbtProjects();
      if (state.dbtProjects.length && !state.dbtProjects.includes(state.dbtProject)) {
        state.dbtProject = state.dbtProjects[0];
      }
      // re-render shell to populate dropdown deterministically
      render();
    }

    const d = await fetchSearch(state.dbtProject, state.filter || "", state.page, state.pageSize);
    if (d && d.assets) state.assets = d.assets;

    // Update rows in-place clarify; do not call full render unless needed
    updateCatalogRows();
  }

  async function tickSummary() {
    try {
      apiPill.textContent = "API: checking…";
      const s = await fetchSummary();
      apiPill.textContent = "API: ok";
      state.summary = s;

      // Avoid nuking catalog UI every 30s; only full render if not in catalog
      if (state.tab !== "catalog") {
        render();
      } else {
        // still refresh MinIO card if user is on overview? (not applicable)
        // keep catalog stable; nothing to update here from summary
      }
    } catch {
      apiPill.textContent = "API: down";
      view.innerHTML = `<div class="card"><div class="bd"><div class="small">Failed to load /api/summary</div></div></div>`;
    }
  }

  // Tab click wiring
  tabs.forEach((btn) => btn.addEventListener("click", () => setTab(btn.dataset.tab)));

  // Boot
  setTab("overview");
  tickSummary();

  summaryTimer = setInterval(tickSummary, 30000);
  assetsTimer = setInterval(() => tickAssets(false), 60000);
})();
