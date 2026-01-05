from __future__ import annotations
from typing import Any, Dict, List
from app.util.time import utc_now_iso

STATUSES = ("OPERATIONAL", "DEGRADED", "DOWN", "INFO")

REQUIRED_SERVICES_ORDER = [
    "kubernetes",
    "postgres",
    "minio",
    "ingress_tls",
    "airbyte",
    "dbt",
    "n8n",
    "zammad",
    "metabase",
]

def service_obj(
    name: str,
    status: str,
    reason: str,
    links: Dict[str, str] | None,
    evidence_type: str,
    evidence_details: Dict[str, Any],
) -> Dict[str, Any]:
    if status not in STATUSES:
        status = "INFO"
    return {
        "name": name,
        "status": status,
        "reason": reason or "",
        "last_checked": utc_now_iso(),
        "links": links or {"ui": "", "api": ""},
        "evidence": {"type": evidence_type, "details": evidence_details or {}},
    }

def compute_platform_status(services: List[Dict[str, Any]]) -> str:
    critical = {"kubernetes", "postgres", "ingress_tls"}
    if any(s["name"] in critical and s["status"] == "DOWN" for s in services):
        return "DOWN"
    if any(s["status"] in ("DOWN", "DEGRADED") for s in services):
        return "DEGRADED"
    return "OPERATIONAL"

def operational_fraction(services: List[Dict[str, Any]]) -> Dict[str, int]:
    y = len(services)
    x = sum(1 for s in services if s["status"] == "OPERATIONAL")
    return {"x": x, "y": y}
