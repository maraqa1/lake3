from flask import Flask, jsonify, request
from config import Config
from util.time import utc_now_iso
from probes.k8s_probe import k8s_summary
from probes.ingress_probe import ingress_links_and_inventory
from probes.postgres_probe import postgres_catalog_tables, postgres_search, postgres_summary
from probes.minio_probe import minio_summary
from probes.airbyte_probe import airbyte_summary
from probes.dbt_probe import dbt_summary
from probes.n8n_probe import n8n_summary
from probes.zammad_probe import zammad_summary
from probes.metabase_probe import metabase_summary
from probes.contract import compute_platform_status, operational_fraction, REQUIRED_SERVICES_ORDER

app = Flask(__name__)

@app.get("/api/health")
def health():
    return jsonify({
        "status": "ok",
        "generated_at": utc_now_iso(),
        "service": "portal-api",
        "version": "phase1",
    })

@app.get("/api/services")
def services():
    k8s = k8s_summary(Config)
    ingress = ingress_links_and_inventory(Config, k8s)
    pg = postgres_summary(Config)
    s3 = minio_summary(Config)
    ab = airbyte_summary(Config, ingress)
    dbt = dbt_summary(Config, ingress, s3)
    n8n = n8n_summary(Config, ingress)
    zammad = zammad_summary(Config, ingress)
    metabase = metabase_summary(Config, ingress)

    services_map = {
        "kubernetes": k8s["service"],
        "postgres": pg["service"],
        "minio": s3["service"],
        "ingress_tls": ingress["service"],
        "airbyte": ab["service"],
        "dbt": dbt["service"],
        "n8n": n8n["service"],
        "zammad": zammad["service"],
        "metabase": metabase["service"],
    }
    services_list = [services_map[name] for name in REQUIRED_SERVICES_ORDER]
    return jsonify({"generated_at": utc_now_iso(), "services": services_list})

@app.get("/api/catalog/tables")
def catalog_tables():
    page = max(int(request.args.get("page", "1")), 1)
    page_size = min(max(int(request.args.get("page_size", "50")), 1), 200)
    return jsonify(postgres_catalog_tables(Config, page=page, page_size=page_size))

@app.get("/api/catalog/search")
def catalog_search():
    q = (request.args.get("q") or "").strip()
    if not q:
        return jsonify({"q": "", "matches": []})
    return jsonify(postgres_search(Config, q=q))

@app.get("/api/ingestion/airbyte")
def ingestion_airbyte():
    k8s = k8s_summary(Config)
    ingress = ingress_links_and_inventory(Config, k8s)
    return jsonify(airbyte_summary(Config, ingress))

@app.get("/api/transform/dbt")
def transform_dbt():
    k8s = k8s_summary(Config)
    ingress = ingress_links_and_inventory(Config, k8s)
    s3 = minio_summary(Config)
    return jsonify(dbt_summary(Config, ingress, s3))

@app.get("/api/ops/n8n")
def ops_n8n():
    k8s = k8s_summary(Config)
    ingress = ingress_links_and_inventory(Config, k8s)
    return jsonify(n8n_summary(Config, ingress))

@app.get("/api/itsm/zammad")
def itsm_zammad():
    k8s = k8s_summary(Config)
    ingress = ingress_links_and_inventory(Config, k8s)
    return jsonify(zammad_summary(Config, ingress))

@app.get("/api/summary")
def summary():
    generated_at = utc_now_iso()

    k8s = k8s_summary(Config)
    ingress = ingress_links_and_inventory(Config, k8s)
    pg_sum = postgres_summary(Config)
    s3_sum = minio_summary(Config)
    ab_sum = airbyte_summary(Config, ingress)
    dbt_sum = dbt_summary(Config, ingress, s3_sum)
    n8n_sum = n8n_summary(Config, ingress)
    zammad_sum = zammad_summary(Config, ingress)
    metabase_sum = metabase_summary(Config, ingress)

    services_map = {
        "kubernetes": k8s["service"],
        "postgres": pg_sum["service"],
        "minio": s3_sum["service"],
        "ingress_tls": ingress["service"],
        "airbyte": ab_sum["service"],
        "dbt": dbt_sum["service"],
        "n8n": n8n_sum["service"],
        "zammad": zammad_sum["service"],
        "metabase": metabase_sum["service"],
    }
    services_list = [services_map[name] for name in REQUIRED_SERVICES_ORDER]

    platform_status = compute_platform_status(services_list)
    op = operational_fraction(services_list)

    assets = postgres_catalog_tables(Config, page=1, page_size=50)

    links = ingress["links_contract"]
    if not links.get("portal"):
        links["portal"] = f"{Config.URL_SCHEME}://{Config.PORTAL_HOST}" if Config.PORTAL_HOST else ""

    proof = {
        "airbyte_last_sync": ab_sum.get("last_sync"),
        "dbt_last_run": dbt_sum.get("last_run"),
        "data_availability": {
            "schemas": pg_sum["postgres"].get("schemas_count", 0),
            "tables": pg_sum["postgres"].get("tables_count", 0),
        },
    }

    return jsonify({
        "generated_at": generated_at,
        "platform_status": platform_status,
        "operational": op,
        "links": links,
        "services": services_list,
        "k8s": k8s["k8s"],
        "postgres": pg_sum["postgres"],
        "assets": assets,
        "proof": proof,
    })

if __name__ == "__main__":
    import os
    port = int(os.getenv("PORT", "8000"))
    app.run(host="0.0.0.0", port=port)
