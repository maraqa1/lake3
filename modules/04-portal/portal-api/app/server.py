from app.probes.k8s_probe import k8s_summary
from flask import Flask, jsonify, request
import os

from .config import Config
from .util.time import utc_now_iso

from .probes.k8s_probe import k8s_summary
from .probes.ingress_probe import ingress_links_and_inventory
from .probes.postgres_probe import postgres_catalog_tables, postgres_search, postgres_summary
from .probes.minio_probe import minio_summary
from .probes.airbyte_probe import airbyte_summary
from .probes.dbt_probe import dbt_summary
from .probes.n8n_probe import n8n_summary
from .probes.zammad_probe import zammad_summary
from .probes.metabase_probe import metabase_summary

from .probes.contract import (
    compute_platform_status,
    operational_fraction,
    REQUIRED_SERVICES_ORDER,
    service_obj,
)

app = Flask(__name__)

def _ensure_dict(x):
    return x if isinstance(x, dict) else {}

def _catalog_unpack(cat, page: int, page_size: int):
    """
    Accept catalog outputs in any of these forms:
      A) {"tables":[...], "pagination":{...}}
      B) {"assets":{"tables":[...], "pagination":{...}}}
      C) [ {...table row...}, ... ]  (legacy list)
    Return: (tables_list, pagination_dict)
    """
    if isinstance(cat, dict):
        if isinstance(cat.get("tables"), list):
            tables = cat.get("tables") or []
            pag = cat.get("pagination") or {"page": page, "page_size": page_size, "total": len(tables)}
            return tables, pag
        assets = cat.get("assets")
        if isinstance(assets, dict) and isinstance(assets.get("tables"), list):
            tables = assets.get("tables") or []
            pag = assets.get("pagination") or {"page": page, "page_size": page_size, "total": len(tables)}
            return tables, pag
    if isinstance(cat, list):
        tables = cat
        pag = {"page": page, "page_size": page_size, "total": len(tables)}
        return tables, pag
    return [], {"page": page, "page_size": page_size, "total": 0}

def _down_service(name: str, reason: str):
    return service_obj(
        name=name,
        status="DOWN",
        reason=reason,
        links={"ui":"", "api":""},
        evidence={"type":"error", "details":{"reason": reason}}
    )



def _as_int(v, default: int) -> int:
    try:
        return int(v)
    except Exception:
        return default


def _unwrap_to_contract(blob, fallback_name: str):
    """
    Accept:
      A) {"service": {...}} wrapper
      B) {...} direct
      C) legacy {"service": "postgres", ...}
      D) non-dict / None
    Return: canonical service_obj() dict (always has name+service, status, etc.)
    """
    base = {}
    if isinstance(blob, dict) and isinstance(blob.get("service"), dict):
        base = blob["service"]
    elif isinstance(blob, dict):
        base = blob

    name = base.get("name") or (base.get("service") if isinstance(base.get("service"), str) else None) or fallback_name
    status = base.get("status") or "DOWN"
    reason = base.get("reason") or ""
    last_checked = base.get("last_checked") or utc_now_iso()

    links = base.get("links") if isinstance(base.get("links"), dict) else {}
    evidence = base.get("evidence") if isinstance(base.get("evidence"), dict) else None

    return service_obj(
        name=str(name),
        status=str(status),
        reason=str(reason),
        last_checked=str(last_checked),
        links={"ui": (links.get("ui") or ""), "api": (links.get("api") or "")},
        evidence=evidence,
    )


def _ingress_blob(ingress_result):
    # your ingress probe returns {"service":..., "ingresses":..., "links_contract":...}
    if isinstance(ingress_result, dict) and "ingresses" in ingress_result:
        return ingress_result["ingresses"]
    return ingress_result


def _links_contract(ingress_result):
    # ingress probe returns {"service":..., "ingresses":[...], "links_contract":{...}}
    if isinstance(ingress_result, dict) and isinstance(ingress_result.get("links_contract"), dict):
        return ingress_result["links_contract"]
    return {}


def _minio_blob(minio_result):
    # your minio probe returns {"service":..., "minio":...}
    if isinstance(minio_result, dict) and "minio" in minio_result:
        return minio_result["minio"]
    return minio_result


@app.get("/api/health")
def health():
    return jsonify(
        {
            "status": "ok",
            "generated_at": utc_now_iso(),
            "service": "portal-api",
            "version": "phase1",
        }
    )


@app.get("/api/version")
def version():
    return jsonify(
        {
            "api_version": "v1",
            "contract": "portal-ui-2026-01-06",
            "build": "portal-api_06_01_2026",
            "generated_at": utc_now_iso(),
        }
    )



@app.get("/api/services")
def services():
    # Base probes
    k8s = k8s_summary(Config)
    ingress = ingress_links_and_inventory(Config, k8s)
    s3 = minio_summary(Config)

    # IMPORTANT:
    # - ingress rows (list) are for UI inventory only
    # - links_contract (dict) is what dependent probes must receive
    ingress_rows = _ingress_blob(ingress)
    links_contract = _links_contract(ingress)
    minio_blob = _minio_blob(s3)

    # Dependent probes (pass links_contract dict, not ingress_rows list)
    pg = postgres_summary(Config)
    ab = airbyte_summary(Config, links_contract)
    dbt = dbt_summary(Config, links_contract, minio_blob)
    n8n = n8n_summary(Config, links_contract)
    zammad = zammad_summary(Config, links_contract)
    metabase = metabase_summary(Config, links_contract)

    services_map = {
        "kubernetes": _unwrap_to_contract(k8s, "kubernetes"),
        "ingress_tls": _unwrap_to_contract(ingress, "ingress_tls"),
        "postgres": _unwrap_to_contract(pg, "postgres"),
        "minio": _unwrap_to_contract(s3, "minio"),
        "airbyte": _unwrap_to_contract(ab, "airbyte"),
        "dbt": _unwrap_to_contract(dbt, "dbt"),
        "n8n": _unwrap_to_contract(n8n, "n8n"),
        "zammad": _unwrap_to_contract(zammad, "zammad"),
        "metabase": _unwrap_to_contract(metabase, "metabase"),
    }

    services_list = list(services_map.values())
    platform_status = compute_platform_status(services_list)

    return jsonify(
        {
            "generated_at": utc_now_iso(),
            "status": platform_status,
            "operational_fraction": operational_fraction(services_list),
            "required_order": REQUIRED_SERVICES_ORDER,
            "services": services_map,
            "ingresses": ingress_rows,  # UI convenience (optional)
        }
    )


@app.get("/api/summary")
def summary():
    # UI contract:
    # - must return HTTP 200 always
    # - must include: generated_at, platform_status, operational{x,y}, k8s{workloads,restarts_total,ingresses[]},
    #   services[] (array), postgres{schemas_count,tables_count}, links{}, assets{tables,pagination}
    try:
        # Base probes
        k8s_probe = k8s_summary(Config)
        ingress = ingress_links_and_inventory(Config, k8s_probe)
        s3 = minio_summary(Config)

        links_contract = _links_contract(ingress)
        minio_blob = _minio_blob(s3)

        # Dependent probes (dict in, never list)
        pg = postgres_summary(Config)
        ab = airbyte_summary(Config, links_contract)
        dbt = dbt_summary(Config, links_contract, minio_blob)
        n8n = n8n_summary(Config, links_contract)
        zammad = zammad_summary(Config, links_contract)
        metabase = metabase_summary(Config, links_contract)

        services_list = [
            _unwrap_to_contract(k8s_probe, "kubernetes"),
            _unwrap_to_contract(ingress, "ingress_tls"),
            _unwrap_to_contract(pg, "postgres"),
            _unwrap_to_contract(s3, "minio"),
            _unwrap_to_contract(ab, "airbyte"),
            _unwrap_to_contract(dbt, "dbt"),
            _unwrap_to_contract(n8n, "n8n"),
            _unwrap_to_contract(zammad, "zammad"),
            _unwrap_to_contract(metabase, "metabase"),
        ]

        platform_status = compute_platform_status(services_list)
        op = operational_fraction(services_list)

        # k8s blob (includes ingresses list from k8s_probe)
        k8s_blob = (k8s_probe.get("k8s") if isinstance(k8s_probe, dict) else {}) or {}
        workloads = (k8s_blob.get("workloads") if isinstance(k8s_blob, dict) else {}) or {}

        pods = workloads.get("pods") or {"ready": 0, "total": 0}
        deps = workloads.get("deployments") or {"ready": 0, "total": 0}
        stss = workloads.get("statefulsets") or {"ready": 0, "total": 0}
        ing_rows = (k8s_blob.get("ingresses") or []) if isinstance(k8s_blob, dict) else []

        k8s_out = {
            "workloads": {
                "deployments": {"ready": int(deps.get("ready") or 0), "total": int(deps.get("total") or 0)},
                "pods": {"ready": int(pods.get("ready") or 0), "total": int(pods.get("total") or 0)},
                "statefulsets": {"ready": int(stss.get("ready") or 0), "total": int(stss.get("total") or 0)},
            },
            "restarts_total": int(k8s_blob.get("restarts_total") or 0) if isinstance(k8s_blob, dict) else 0,
            "ingresses": ing_rows,
        }

        # postgres counts
        pg_details = (pg.get("postgres") if isinstance(pg, dict) else {}) or {}
        postgres_counts = {
            "schemas_count": int(pg_details.get("schemas_count") or 0),
            "tables_count": int(pg_details.get("tables_count") or 0),
        }

        # links
        links = {
            "postgres": "",
            "minio": links_contract.get("minio", "") or "",
            "airbyte": links_contract.get("airbyte", "") or "",
            "metabase": links_contract.get("metabase", "") or "",
            "n8n": links_contract.get("n8n", "") or "",
            "zammad": links_contract.get("zammad", "") or "",
            "dbt_docs": links_contract.get("dbt_docs", "") or "",
            "dbt_lineage": links_contract.get("dbt_lineage", "") or "",
        }

        # assets (catalog)
        page = _as_int(request.args.get("page"), 1)
        page_size = _as_int(request.args.get("page_size"), 50)
        try:
            cat = postgres_catalog_tables(Config, page=page, page_size=page_size)
            cat_tables = cat.get("tables") or []
            cat_pagination = cat.get("pagination") or {"page": page, "page_size": page_size, "total": 0}
        except Exception:
            cat_tables = []
            cat_pagination = {"page": page, "page_size": page_size, "total": 0}

        ui_tables = [{"schema": t.get("schema", ""), "table": t.get("table", ""), "rows": 0, "last_update": "", "owner": ""} for t in cat_tables]

        proof = {"airbyte_last_sync": "", "dbt_last_run": "", "data_availability": ""}

        return jsonify(
            {
                "generated_at": utc_now_iso(),
                "platform_status": platform_status,
                "operational": op,
                "k8s": k8s_out,
                "services": services_list,
                "postgres": postgres_counts,
                "proof": proof,
                "links": links,
                "assets": {"tables": ui_tables, "pagination": cat_pagination},
            }
        )
    except Exception as e:
        return jsonify(
            {
                "generated_at": utc_now_iso(),
                "platform_status": "DOWN",
                "operational": {"x": 0, "y": len(REQUIRED_SERVICES_ORDER)},
                "k8s": {"workloads": {"deployments": {"ready": 0, "total": 0}, "pods": {"ready": 0, "total": 0}, "statefulsets": {"ready": 0, "total": 0}}, "restarts_total": 0, "ingresses": []},
                "services": [],
                "postgres": {"schemas_count": 0, "tables_count": 0},
                "proof": {"airbyte_last_sync": "", "dbt_last_run": "", "data_availability": ""},
                "links": {},
                "assets": {"tables": [], "pagination": {"page": 1, "page_size": 50, "total": 0}},
                "error": str(e),
            }
        ), 200

@app.get("/api/catalog/tables")
def catalog_tables():
    page = _as_int(request.args.get("page"), 1)
    page_size = _as_int(request.args.get("page_size"), 50)
    return jsonify(postgres_catalog_tables(Config, page=page, page_size=page_size))


@app.get("/api/search")
def search():
    # UI contract: /api/search must work with empty q.
    q = (request.args.get("q") or "").strip()
    page = _as_int(request.args.get("page"), 1)
    page_size = _as_int(request.args.get("page_size"), 50)

    if not q:
        cat = postgres_catalog_tables(Config, page=page, page_size=page_size)
        tables = cat.get("tables") or []
        pagination = cat.get("pagination") or {"page": page, "page_size": page_size, "total": 0}
        ui_tables = [
            {"schema": t.get("schema", ""), "table": t.get("table", ""), "rows": 0, "last_update": "", "owner": ""}
            for t in tables
        ]
        return jsonify({"assets": {"tables": ui_tables, "pagination": pagination}})

    res = postgres_search(Config, q)
    matches = res.get("matches") or []
    ui_tables = [{"schema": m.get("schema", ""), "table": m.get("table", ""), "rows": 0, "last_update": "", "owner": ""} for m in matches]
    return jsonify({"assets": {"tables": ui_tables, "pagination": {"page": 1, "page_size": 50, "total": len(ui_tables)}}, "q": q})


@app.get("/api/k8s/summary")
def k8s_summary_endpoint():
    # Not used by the current UI, but kept for compatibility with Phase-1 API contract.
    k8s = k8s_summary(Config)
    blob = k8s.get("k8s") if isinstance(k8s, dict) else {}
    return jsonify(blob or {})

if __name__ == "__main__":
    # Fallback dev server (production uses gunicorn from the module script)
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8000")))