from __future__ import annotations
from typing import Any, Dict, List
from kubernetes import client, config
from app.probes.contract import service_obj

def _load():
    try:
        config.load_incluster_config()
    except Exception:
        config.load_kube_config()

def _ingresses_all() -> List[client.V1Ingress]:
    net = client.NetworkingV1Api()
    return net.list_ingress_for_all_namespaces(watch=False).items

def _ingress_rows(ings: List[client.V1Ingress]) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for ing in ings:
        ns = ing.metadata.namespace
        name = ing.metadata.name
        for rule in (ing.spec.rules or []):
            host = rule.host or ""
            http = rule.http
            if not http:
                continue
            for p in (http.paths or []):
                path = p.path or "/"
                svc = ""
                port = None
                try:
                    if p.backend and p.backend.service:
                        svc = p.backend.service.name or ""
                        port = p.backend.service.port.number if p.backend.service.port else None
                except Exception:
                    pass
                rows.append({"namespace": ns, "name": name, "host": host, "path": path, "service": svc, "service_port": port})
    return rows

def ingress_links_and_inventory(Cfg, k8s_blob: Dict[str, Any]) -> Dict[str, Any]:
    try:
        _load()
        ings = _ingresses_all()
        rows = _ingress_rows(ings)

        scheme = Cfg.URL_SCHEME

        links_contract = {
            "portal": f"{scheme}://{Cfg.PORTAL_HOST}" if Cfg.PORTAL_HOST else "",
            "airbyte": f"{scheme}://{Cfg.AIRBYTE_HOST}" if Cfg.AIRBYTE_HOST else "",
            "minio": f"{scheme}://{Cfg.MINIO_HOST}" if Cfg.MINIO_HOST else "",
            "metabase": f"{scheme}://{Cfg.METABASE_HOST}" if Cfg.METABASE_HOST else "",
            "dbt_docs": f"{scheme}://{Cfg.DBT_HOST}/docs" if Cfg.DBT_HOST else "",
            "dbt_lineage": f"{scheme}://{Cfg.DBT_HOST}/#!/overview" if Cfg.DBT_HOST else "",
            "n8n": f"{scheme}://{Cfg.N8N_HOST}" if Cfg.N8N_HOST else "",
            "zammad": f"{scheme}://{Cfg.ZAMMAD_HOST}" if Cfg.ZAMMAD_HOST else "",
        }

        evidence = {
            "scheme": scheme,
            "ingresses_found": len(ings),
            "routes_found": len(rows),
            "sample_routes": rows[:30],
        }

        status = "OPERATIONAL"
        reason = ""
        if len(ings) == 0:
            status = "DEGRADED"
            reason = "No ingresses discovered"

        svc = service_obj(
            name="ingress_tls",
            status=status,
            reason=reason,
            links={"ui": links_contract.get("portal", ""), "api": f"{links_contract.get('portal','')}/api" if links_contract.get("portal") else ""},
            evidence_type="k8s",
            evidence_details=evidence,
        )

        k8s_blob["k8s"]["ingresses"] = rows

        return {"service": svc, "ingresses": rows, "links_contract": links_contract}
    except Exception as e:
        svc = service_obj(
            name="ingress_tls",
            status="DOWN",
            reason="Ingress discovery failed",
            links={"ui": "", "api": ""},
            evidence_type="k8s",
            evidence_details={"error": str(e)},
        )
        return {
            "service": svc,
            "ingresses": [],
            "links_contract": {"portal": "", "airbyte": "", "minio": "", "metabase": "", "dbt_docs": "", "dbt_lineage": "", "n8n": "", "zammad": ""},
        }
