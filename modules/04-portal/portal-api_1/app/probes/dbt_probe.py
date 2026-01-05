from __future__ import annotations
from typing import Any, Dict
from app.probes.contract import service_obj
from app.util.s3 import s3_get_json_if_exists

def dbt_summary(Cfg, ingress_blob: Dict[str, Any], minio_blob: Dict[str, Any]) -> Dict[str, Any]:
    docs_url = ingress_blob.get("links_contract", {}).get("dbt_docs", "")
    lineage_url = ingress_blob.get("links_contract", {}).get("dbt_lineage", "")

    artifacts = {"manifest": None, "run_results": None}
    counts = {"models": None, "tests": None}

    minio_ok = (minio_blob.get("service", {}) or {}).get("status") == "OPERATIONAL"
    evidence: Dict[str, Any] = {"docs_url": docs_url, "lineage_url": lineage_url, "minio_operational": minio_ok}

    tried = []
    last_run = None

    if minio_ok:
        candidates = [
            ("dbt", "artifacts/manifest.json"),
            ("dbt", "artifacts/run_results.json"),
            ("dbt-docs", "artifacts/manifest.json"),
            ("dbt-docs", "artifacts/run_results.json"),
            ("dbt", "manifest.json"),
            ("dbt", "run_results.json"),
        ]
        for b, k in candidates:
            tried.append({"bucket": b, "key": k})

        manifest = s3_get_json_if_exists(Cfg, bucket="dbt", key="artifacts/manifest.json")
        if not manifest["ok"]:
            manifest = s3_get_json_if_exists(Cfg, bucket="dbt-docs", key="artifacts/manifest.json")

        runres = s3_get_json_if_exists(Cfg, bucket="dbt", key="artifacts/run_results.json")
        if not runres["ok"]:
            runres = s3_get_json_if_exists(Cfg, bucket="dbt-docs", key="artifacts/run_results.json")

        evidence["artifacts_try"] = tried
        evidence["manifest_found"] = bool(manifest["ok"])
        evidence["run_results_found"] = bool(runres["ok"])

        if manifest["ok"]:
            artifacts["manifest"] = {"bucket": manifest["bucket"], "key": manifest["key"]}
            m = manifest.get("json") or {}
            nodes = (m.get("nodes") or {})
            counts["models"] = sum(1 for _, v in nodes.items() if (v.get("resource_type") == "model"))
            counts["tests"] = sum(1 for _, v in nodes.items() if (v.get("resource_type") == "test"))

        if runres["ok"]:
            artifacts["run_results"] = {"bucket": runres["bucket"], "key": runres["key"]}
            j = runres.get("json") or {}
            last_run = {
                "generated_at": (j.get("metadata", {}) or {}).get("generated_at"),
                "elapsed_time": j.get("elapsed_time"),
                "results_count": len(j.get("results") or []),
            }

        if manifest["ok"] or runres["ok"]:
            status = "OPERATIONAL"
            reason = ""
        else:
            status = "INFO"
            reason = "dbt artifacts not available"
    else:
        status = "DEGRADED"
        reason = "MinIO not configured; cannot verify dbt artifacts"
        evidence["artifacts_try"] = tried

    svc = service_obj(
        name="dbt",
        status=status,
        reason=reason,
        links={"ui": docs_url or lineage_url, "api": ""},
        evidence_type="api" if minio_ok else "http",
        evidence_details=evidence,
    )

    return {
        "service": svc,
        "dbt": {"docs_url": docs_url, "lineage_url": lineage_url, "artifacts": artifacts, "counts": counts},
        "last_run": last_run,
    }
