from __future__ import annotations
from typing import Any, Dict
import requests

def http_get_text(url: str, timeout: int = 3, headers: Dict[str, str] | None = None, auth=None) -> Dict[str, Any]:
    if not url:
        return {"ok": False, "error": "empty url"}
    try:
        r = requests.get(url, timeout=timeout, headers=headers, auth=auth, allow_redirects=True)
        return {"ok": r.status_code < 400, "status_code": r.status_code, "text_head": r.text[:200]}
    except Exception as e:
        return {"ok": False, "error": str(e)}

def http_get_json(url: str, timeout: int = 3, headers: Dict[str, str] | None = None, auth=None, method: str = "GET", json_body=None) -> Dict[str, Any]:
    if not url:
        return {"ok": False, "error": "empty url"}
    try:
        if method.upper() == "POST":
            r = requests.post(url, timeout=timeout, headers=headers, auth=auth, json=json_body)
        else:
            r = requests.get(url, timeout=timeout, headers=headers, auth=auth)
        if r.status_code >= 400:
            return {"ok": False, "status_code": r.status_code, "error": r.text[:300]}
        try:
            return {"ok": True, "status_code": r.status_code, "json": r.json()}
        except Exception:
            return {"ok": False, "status_code": r.status_code, "error": "invalid json", "text_head": r.text[:200]}
    except Exception as e:
        return {"ok": False, "error": str(e)}
