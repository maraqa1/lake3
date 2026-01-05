from __future__ import annotations
from typing import Any, Dict
from app.probes.contract import service_obj
from app.util.http import http_get_json

def airbyte_summary(Cfg, ingress_blob: Dict[str, Any]) -> Dict[str, Any]:
    internal = f"http://airbyte-server.{Cfg.AIRBYTE_NS}.svc.cluster.local:8001"
    external = f"{Cfg.URL_SCHEME}://{Cfg.AIRBYTE_HOST}" if Cfg.AIRBYTE_HOST else ""
    api_base = internal

    health = http_get_json(f"{api_base}/api/v1/health", timeout=3)
    if not health["ok"] and external:
        api_base = external
        health = http_get_json(f"{api_base}/api/v1/health", timeout=3)

    if not health["ok"]:
        svc = service_obj(
            name="airbyte",
            status="DOWN",
            reason="Airbyte API unreachable",
            links={"ui": external, "api": api_base},
            evidence_type="http",
            evidence_details={"health_url": f"{api_base}/api/v1/health", "error": health.get("error"), "status_code": health.get("status_code")},
        )
        return {"service": svc, "last_sync": None, "airbyte": {"api_base": api_base}}

    last = None
    evidence: Dict[str, Any] = {"health": health.get("json"), "api_base": api_base}

    jobs = http_get_json(
        f"{api_base}/api/v1/jobs/list",
        timeout=5,
        method="POST",
        json_body={"configTypes": ["sync"], "pagination": {"pageSize": 10, "rowOffset": 0}},
    )

    if jobs["ok"]:
        items = (jobs.get("json") or {}).get("jobs", []) or []
        if items:
            items_sorted = sorted(items, key=lambda x: x.get("updatedAt", 0), reverse=True)
            j = items_sorted[0]
            last = {
                "id": j.get("id"),
                "status": j.get("status"),
                "createdAt": j.get("createdAt"),
                "updatedAt": j.get("updatedAt"),
                "bytesSynced": j.get("bytesSynced"),
                "recordsSynced": j.get("recordsSynced"),
            }
        evidence["jobs_list"] = {"ok": True, "count": len(items), "sample": items[:2]}
        status = "OPERATIONAL"
        reason = ""
    else:
        status = "DEGRADED"
        reason = "Airbyte jobs API not accessible"
        evidence["jobs_list"] = {"ok": False, "error": jobs.get("error"), "status_code": jobs.get("status_code")}

    svc = service_obj(
        name="airbyte",
        status=status,
        reason=reason,
        links={"ui": external, "api": api_base},
        evidence_type="http",
        evidence_details=evidence,
    )
    return {"service": svc, "last_sync": last, "airbyte": {"api_base": api_base, "last": last}}
