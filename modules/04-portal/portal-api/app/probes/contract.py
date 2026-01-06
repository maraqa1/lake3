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
    reason: str = "",
    last_checked: str = "",
    links: Dict[str, str] | None = None,
    evidence: Dict[str, Any] | None = None,
    evidence_type: str | None = None,
    evidence_details: Dict[str, Any] | None = None,
) -> Dict[str, Any]:
    """
    Canonical service object.

    Guarantees:
    - Always includes BOTH "name" and "service" (same value)
    - Always includes: status, reason, last_checked, links, evidence
    - evidence supports either:
        evidence={"type":..., "details":...}
      OR kwargs:
        evidence_type=..., evidence_details=...
    """
    if status not in STATUSES:
        status = "INFO"

    if not last_checked:
        last_checked = utc_now_iso()

    links = links or {}
    out_links = {
        "ui": (links.get("ui") or ""),
        "api": (links.get("api") or ""),
    }

    if evidence is None:
        evidence = {
            "type": (evidence_type or "INFO"),
            "details": (evidence_details or {}),
        }
    else:
        if not isinstance(evidence, dict):
            evidence = {"type": "INFO", "details": {}}
        evidence = {
            "type": (evidence.get("type") or "INFO"),
            "details": (evidence.get("details") or {}),
        }

    return {
        "service": name,
        "name": name,
        "status": status,
        "reason": (reason or ""),
        "last_checked": last_checked,
        "links": out_links,
        "evidence": evidence,
    }


def _unwrap_service(blob: Any, fallback_name: str = "unknown") -> Dict[str, Any]:
    """
    Accepts any of:
      A) wrapper: {"service": {...}}
      B) direct:  {"name":..., "status":...}
      C) legacy:  {"service":"postgres", "status":...}
    Returns canonical service dict with name+service keys.
    """
    base: Dict[str, Any] = {}

    if isinstance(blob, dict) and isinstance(blob.get("service"), dict):
        base = blob["service"]
    elif isinstance(blob, dict):
        base = blob

    name = (
        base.get("name")
        or (base.get("service") if isinstance(base.get("service"), str) else None)
        or fallback_name
    )

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


def operational_fraction(services: List[Dict[str, Any]]) -> Dict[str, int]:
    """
    Returns {"x": operational_required, "y": total_required}
    Only counts REQUIRED_SERVICES_ORDER.
    """
    required = list(REQUIRED_SERVICES_ORDER)
    if not required:
        return {"x": 0, "y": 0}

    norm = [_unwrap_service(s) for s in (services or [])]

    x = 0
    for r in required:
        svc = next((d for d in norm if d.get("name") == r), None)
        if svc and svc.get("status") == "OPERATIONAL":
            x += 1

    return {"x": x, "y": len(required)}


def compute_platform_status(services: List[Dict[str, Any]]) -> str:
    """
    Rules:
    - If any critical service is DOWN => DOWN
    - Else if any service is DOWN or DEGRADED => DEGRADED
    - Else => OPERATIONAL
    """
    norm = [_unwrap_service(s) for s in (services or [])]
    critical = {"kubernetes", "postgres", "ingress_tls"}

    if any(s.get("name") in critical and s.get("status") == "DOWN" for s in norm):
        return "DOWN"
    if any(s.get("status") in ("DOWN", "DEGRADED") for s in norm):
        return "DEGRADED"
    return "OPERATIONAL"
