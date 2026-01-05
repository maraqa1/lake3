\
from __future__ import annotations

import os
from typing import Any, Dict, List

from kubernetes import client, config  # type: ignore

def _load():
    try:
        config.load_incluster_config()
    except Exception:
        config.load_kube_config()

def k8s_summary() -> Dict[str, Any]:
    _load()
    v1 = client.CoreV1Api()

    namespaces = [
        os.environ.get("OPENKPI_NS", "open-kpi"),
        os.environ.get("PLATFORM_NS", "platform"),
        os.environ.get("AIRBYTE_NS", "airbyte"),
        os.environ.get("ANALYTICS_NS", "analytics"),
        os.environ.get("N8N_NS", "n8n"),
        os.environ.get("TICKETS_NS", "tickets"),
        os.environ.get("TRANSFORM_NS", "transform"),
    ]
    out: Dict[str, Any] = {"namespaces": []}
    for ns in namespaces:
        try:
            pods = v1.list_namespaced_pod(ns, timeout_seconds=3)
            counts = {"Running": 0, "Pending": 0, "Failed": 0, "Succeeded": 0, "Unknown": 0}
            for p in pods.items:
                phase = (p.status.phase or "Unknown")
                counts[phase] = counts.get(phase, 0) + 1
            out["namespaces"].append({"name": ns, "pod_counts": counts})
        except Exception as e:
            out["namespaces"].append({"name": ns, "error": e.__class__.__name__})
    return out
