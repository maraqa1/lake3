from __future__ import annotations
from typing import Any, Dict
from kubernetes import client, config
from app.probes.contract import service_obj

def _load():
    try:
        config.load_incluster_config()
        return "incluster"
    except Exception:
        config.load_kube_config()
        return "kubeconfig"

def k8s_summary(Cfg) -> Dict[str, Any]:
    mode = ""
    try:
        mode = _load()
        v1 = client.CoreV1Api()
        apps = client.AppsV1Api()
        net = client.NetworkingV1Api()

        ns_items = v1.list_namespace().items
        namespaces = [n.metadata.name for n in ns_items]

        pods = v1.list_pod_for_all_namespaces(watch=False).items
        deployments = apps.list_deployment_for_all_namespaces(watch=False).items
        statefulsets = apps.list_stateful_set_for_all_namespaces(watch=False).items

        def pod_ready(p) -> bool:
            cs = p.status.container_statuses or []
            return all(c.ready for c in cs) if cs else False

        pods_ready = sum(1 for p in pods if pod_ready(p))
        pods_total = len(pods)

        dep_ready = sum(1 for d in deployments if (d.status.available_replicas or 0) >= 1)
        dep_total = len(deployments)

        sts_ready = sum(1 for s in statefulsets if (s.status.ready_replicas or 0) >= 1)
        sts_total = len(statefulsets)

        restarts_total = 0
        for p in pods:
            for cs in (p.status.container_statuses or []):
                restarts_total += int(cs.restart_count or 0)

        ing_count = len(net.list_ingress_for_all_namespaces(watch=False).items)

        evidence = {
            "config_mode": mode,
            "namespaces_count": len(namespaces),
            "pods": {"ready": pods_ready, "total": pods_total},
            "deployments": {"ready": dep_ready, "total": dep_total},
            "statefulsets": {"ready": sts_ready, "total": sts_total},
            "restarts_total": restarts_total,
            "ingresses_count": ing_count,
        }

        status = "OPERATIONAL"
        reason = ""
        if pods_total > 0 and pods_ready < max(1, int(pods_total * 0.70)):
            status = "DEGRADED"
            reason = "Low ready pod ratio"

        svc = service_obj(
            name="kubernetes",
            status=status,
            reason=reason,
            links={"ui": "", "api": ""},
            evidence_type="k8s",
            evidence_details=evidence,
        )

        return {
            "service": svc,
            "k8s": {
                "namespaces": namespaces,
                "workloads": {
                    "pods": {"ready": pods_ready, "total": pods_total},
                    "deployments": {"ready": dep_ready, "total": dep_total},
                    "statefulsets": {"ready": sts_ready, "total": sts_total},
                },
                "restarts_total": restarts_total,
                "ingresses": [],
            },
            "raw": {"ingresses_count": ing_count},
        }
    except Exception as e:
        svc = service_obj(
            name="kubernetes",
            status="DOWN",
            reason="Kubernetes API unreachable",
            links={"ui": "", "api": ""},
            evidence_type="k8s",
            evidence_details={"error": str(e), "config_mode": mode},
        )
        return {"service": svc, "k8s": {"namespaces": [], "workloads": {}, "restarts_total": 0, "ingresses": []}, "raw": {}}
