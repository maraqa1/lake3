\
from __future__ import annotations

import os
import socket
from datetime import datetime, timezone
from typing import Any, Dict, List

import requests
from flask import Flask, jsonify
from flask_cors import CORS

from .services.k8s import k8s_summary
from .services.health import check_postgres, check_minio, check_http

APP_VERSION = os.environ.get("APP_VERSION", "phase1")

def iso_now() -> str:
    return datetime.now(timezone.utc).isoformat()

def service_obj(name: str, status: str, reason: str, links: Dict[str, str] | None = None) -> Dict[str, Any]:
    return {
        "name": name,
        "status": status,
        "reason": reason,
        "last_checked": iso_now(),
        "links": links or {},
    }

def build_services() -> List[Dict[str, Any]]:
    # Hosts are external, services are internal. UI uses external links, API checks internal where possible.
    app_domain = os.environ.get("APP_DOMAIN", "")
    portal_host = os.environ.get("PORTAL_HOST", "")

    # external hosts (optional)
    hosts = {
        "postgres": os.environ.get("POSTGRES_HOST_EXT", f"postgres.{app_domain}" if app_domain else ""),
        "minio": os.environ.get("MINIO_HOST_EXT", f"minio.{app_domain}" if app_domain else ""),
        "airbyte": os.environ.get("AIRBYTE_HOST", ""),
        "metabase": os.environ.get("METABASE_HOST", f"metabase.{app_domain}" if app_domain else ""),
        "n8n": os.environ.get("N8N_HOST", f"n8n.{app_domain}" if app_domain else ""),
        "zammad": os.environ.get("ZAMMAD_HOST", f"zammad.{app_domain}" if app_domain else ""),
        "dbt": os.environ.get("DBT_HOST", f"dbt.{app_domain}" if app_domain else ""),
        "portal": portal_host,
    }

    # internal endpoints for checks
    pg_ok, pg_reason = check_postgres()
    minio_ok, minio_reason = check_minio()

    # best-effort HTTP checks (inside cluster)
    # These are "INFO" grade: do not fail whole response if unreachable.
    airbyte_ok, airbyte_reason = check_http("airbyte", os.environ.get("AIRBYTE_SVC_URL", ""))
    metabase_ok, metabase_reason = check_http("metabase", os.environ.get("METABASE_SVC_URL", ""))
    n8n_ok, n8n_reason = check_http("n8n", os.environ.get("N8N_SVC_URL", ""))
    zammad_ok, zammad_reason = check_http("zammad", os.environ.get("ZAMMAD_SVC_URL", ""))

    services: List[Dict[str, Any]] = []

    services.append(service_obj(
        "kubernetes",
        "OPERATIONAL",
        "",
        links={"namespaces": "/api/k8s/summary"},
    ))

    services.append(service_obj(
        "postgres",
        "OPERATIONAL" if pg_ok else "DOWN",
        "" if pg_ok else pg_reason,
        links={"host": hosts["postgres"]} if hosts["postgres"] else {},
    ))

    services.append(service_obj(
        "minio",
        "OPERATIONAL" if minio_ok else "DOWN",
        "" if minio_ok else minio_reason,
        links={"host": hosts["minio"]} if hosts["minio"] else {},
    ))

    # Airbyte / Metabase / n8n / Zammad — keep represented even if not checkable
    def status_from_http(ok: bool, reason: str) -> tuple[str, str]:
        if ok:
            return "OPERATIONAL", ""
        if reason.startswith("not_configured"):
            return "INFO", "no in-cluster endpoint configured"
        return "DEGRADED", reason

    st, rs = status_from_http(airbyte_ok, airbyte_reason)
    services.append(service_obj("airbyte", st, rs, links={"host": hosts["airbyte"]} if hosts["airbyte"] else {}))

    st, rs = status_from_http(metabase_ok, metabase_reason)
    services.append(service_obj("metabase", st, rs, links={"host": hosts["metabase"]} if hosts["metabase"] else {}))

    st, rs = status_from_http(n8n_ok, n8n_reason)
    services.append(service_obj("n8n", st, rs, links={"host": hosts["n8n"]} if hosts["n8n"] else {}))

    st, rs = status_from_http(zammad_ok, zammad_reason)
    services.append(service_obj("zammad", st, rs, links={"host": hosts["zammad"]} if hosts["zammad"] else {}))

    services.append(service_obj("dbt", "INFO", "dbt status is evidence-based (jobs/docs); not checked in phase 1",
                                links={"host": hosts["dbt"]} if hosts["dbt"] else {}))

    services.append(service_obj("portal", "OPERATIONAL", "", links={"host": hosts["portal"]} if hosts["portal"] else {}))
    return services

app = Flask(__name__)
CORS(app)

@app.get("/api/health")
def api_health():
    return jsonify({
        "status": "ok",
        "version": APP_VERSION,
        "time": iso_now(),
        "node": socket.gethostname(),
    })

@app.get("/api/services")
def api_services():
    return jsonify({
        "time": iso_now(),
        "services": build_services(),
    })

@app.get("/api/k8s/summary")
def api_k8s_summary():
    return jsonify({
        "time": iso_now(),
        "summary": k8s_summary(),
    })