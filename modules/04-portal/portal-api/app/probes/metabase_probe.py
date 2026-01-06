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

    details: Dict[str, Any] = {
        "ui_url": ui,
        "ui_http_ok": ui_ok,
        "ui_status_code": ui_probe.get("status_code"),
        "api_key_present": bool(Cfg.METABASE_API_KEY),
        # Phase 1: API key is optional; do not degrade the service solely due to auth.
        "notes": "Phase 1: UI reachability drives status; API auth is optional.",
    }

    status = "OPERATIONAL" if ui_ok else "DOWN"
    reason = "" if ui_ok else "Metabase unreachable"

    svc = service_obj(
        name="metabase",
        status=status,
        reason=reason,
        links={"ui": ui, "api": f"{ui}/api" if ui else ""},
        evidence_type="http",
        evidence_details=details,
    )
    return {"service": svc, "metabase": {"reachable": ui_ok}}
