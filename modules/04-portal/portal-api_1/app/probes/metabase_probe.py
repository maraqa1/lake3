from __future__ import annotations
from typing import Any, Dict
from app.probes.contract import service_obj
from app.util.http import http_get_text

def metabase_summary(Cfg, ingress_blob: Dict[str, Any]) -> Dict[str, Any]:
    ui = ingress_blob.get("links_contract", {}).get("metabase", "")
    if not ui and Cfg.METABASE_HOST:
        ui = f"{Cfg.URL_SCHEME}://{Cfg.METABASE_HOST}"

    ui_probe = http_get_text(ui, timeout=3) if ui else {"ok": False, "error": "metabase host not configured"}
    ui_ok = ui_probe["ok"]

    details: Dict[str, Any] = {"ui_url": ui, "ui_http_ok": ui_ok, "ui_status_code": ui_probe.get("status_code"), "api_key_present": bool(Cfg.METABASE_API_KEY)}
    status = "OPERATIONAL" if ui_ok else "DOWN"
    reason = "" if ui_ok else "Metabase unreachable"

    if ui_ok and Cfg.METABASE_API_KEY:
        status = "DEGRADED"
        reason = "Metabase API auth not configured (Phase 1 optional)"

    svc = service_obj(
        name="metabase",
        status=status,
        reason=reason,
        links={"ui": ui, "api": f"{ui}/api" if ui else ""},
        evidence_type="http",
        evidence_details=details,
    )
    return {"service": svc, "metabase": {"reachable": ui_ok}}
