from __future__ import annotations
from typing import Any, Dict
from app.probes.contract import service_obj
from app.util.http import http_get_text, http_get_json

def n8n_summary(Cfg, ingress_blob: Dict[str, Any]) -> Dict[str, Any]:
    ui = ingress_blob.get("links_contract", {}).get("n8n", "")
    if not ui and Cfg.N8N_HOST:
        ui = f"{Cfg.URL_SCHEME}://{Cfg.N8N_HOST}"

    ui_probe = http_get_text(ui, timeout=3) if ui else {"ok": False, "error": "n8n host not configured"}
    ui_ok = ui_probe["ok"]

    workflows = None
    active = None
    last_execution = None

    details: Dict[str, Any] = {"ui_url": ui, "ui_http_ok": ui_ok, "ui_status_code": ui_probe.get("status_code")}

    headers = {}
    auth = None
    if Cfg.N8N_API_KEY:
        headers["X-N8N-API-KEY"] = Cfg.N8N_API_KEY
    if Cfg.N8N_BASIC_USER and Cfg.N8N_BASIC_PASS:
        auth = (Cfg.N8N_BASIC_USER, Cfg.N8N_BASIC_PASS)

    api_ok = False
    api_reason = ""

    if ui and (Cfg.N8N_API_KEY or auth):
        wf = http_get_json(f"{ui}/rest/workflows", timeout=5, headers=headers, auth=auth)
        if wf["ok"]:
            api_ok = True
            data = wf.get("json") or {}
            items = data.get("data") if isinstance(data, dict) else data
            if isinstance(items, list):
                workflows = len(items)
                active = sum(1 for w in items if bool(w.get("active")))
                details["workflows_sample"] = items[:2]
        else:
            api_reason = "API auth not configured or API not accessible"
            details["api_error"] = wf.get("error")
            details["api_status_code"] = wf.get("status_code")
    else:
        api_reason = "API auth not configured"
        details["api_auth_present"] = False

    if not ui_ok and not api_ok:
        status = "DOWN"
        reason = "n8n unreachable"
    elif ui_ok and not api_ok:
        status = "DEGRADED"
        reason = api_reason or "API not accessible"
    else:
        status = "OPERATIONAL"
        reason = ""

    svc = service_obj(
        name="n8n",
        status=status,
        reason=reason,
        links={"ui": ui, "api": f"{ui}/rest" if ui else ""},
        evidence_type="http",
        evidence_details=details,
    )

    return {"service": svc, "n8n": {"workflows_total": workflows, "workflows_active": active, "last_execution_time": last_execution}}
