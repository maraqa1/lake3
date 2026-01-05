from __future__ import annotations
from typing import Any, Dict
from app.probes.contract import service_obj
from app.util.http import http_get_text, http_get_json

def zammad_summary(Cfg, ingress_blob: Dict[str, Any]) -> Dict[str, Any]:
    ui = ingress_blob.get("links_contract", {}).get("zammad", "")
    if not ui and Cfg.ZAMMAD_HOST:
        ui = f"{Cfg.URL_SCHEME}://{Cfg.ZAMMAD_HOST}"

    ui_probe = http_get_text(ui, timeout=3) if ui else {"ok": False, "error": "zammad host not configured"}
    ui_ok = ui_probe["ok"]

    token = Cfg.ZAMMAD_API_TOKEN
    api_ok = False
    open_tickets = None
    total_tickets = None
    last_updated = None

    details: Dict[str, Any] = {"ui_url": ui, "ui_http_ok": ui_ok, "ui_status_code": ui_probe.get("status_code"), "token_present": bool(token)}

    if ui and token:
        headers = {"Authorization": f"Token token={token}"}
        search = http_get_json(f"{ui}/api/v1/tickets/search?query=state.name:open", timeout=5, headers=headers)
        if search["ok"] and isinstance(search.get("json"), list):
            api_ok = True
            open_tickets = len(search["json"])
            details["open_search_ok"] = True
        else:
            details["open_search_ok"] = False
            details["api_status_code"] = search.get("status_code")
            details["api_error"] = search.get("error")

    if not ui_ok and not api_ok:
        status = "DOWN"
        reason = "Zammad unreachable"
    elif ui_ok and not api_ok:
        status = "DEGRADED"
        reason = "API token not configured" if not token else "Zammad API not accessible"
    else:
        status = "OPERATIONAL"
        reason = ""

    svc = service_obj(
        name="zammad",
        status=status,
        reason=reason,
        links={"ui": ui, "api": f"{ui}/api/v1" if ui else ""},
        evidence_type="http",
        evidence_details=details,
    )

    return {"service": svc, "zammad": {"open_tickets": open_tickets, "total_tickets": total_tickets, "last_updated": last_updated}}
