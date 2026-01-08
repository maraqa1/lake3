from __future__ import annotations

import json
import time
from typing import Any, Dict, List, Tuple

import boto3
from botocore.config import Config as BotoCfg
from botocore.exceptions import BotoCoreError, ClientError

# 60s cache to avoid hitting MinIO on every UI poll
_CACHE: Dict[str, Any] = {}
_CACHE_TTL_SEC = 60


def _s3_client(Cfg):
    endpoint = f"http://{Cfg.MINIO_SERVICE}:{int(Cfg.MINIO_API_PORT)}"
    return boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=Cfg.MINIO_ROOT_USER,
        aws_secret_access_key=Cfg.MINIO_ROOT_PASSWORD,
        region_name=getattr(Cfg, "AIRBYTE_S3_REGION", "us-east-1"),
        config=BotoCfg(s3={"addressing_style": "path"}),
    )


def list_dbt_projects(Cfg) -> Dict[str, Any]:
    """
    Discover dbt projects under the docs bucket.
    A "project" is any top-level prefix that contains <prefix>/catalog.json.
    Returns only projects that actually have a catalog.json (so UI shows usable ones).
    """
    bucket = getattr(Cfg, "DBT_DOCS_BUCKET", "dbt-docs")
    s3 = _s3_client(Cfg)

    resp = s3.list_objects_v2(Bucket=bucket, Delimiter="/")
    prefixes = [p.get("Prefix") for p in (resp.get("CommonPrefixes") or []) if p.get("Prefix")]

    projects: List[Dict[str, str]] = []
    for pref in prefixes:
        pid = pref.rstrip("/")
        cat_key = f"{pid}/catalog.json"
        man_key = f"{pid}/manifest.json"

        try:
            s3.head_object(Bucket=bucket, Key=cat_key)
            projects.append({"id": pid, "catalog_key": cat_key, "manifest_key": man_key})
        except Exception:
            # no catalog, skip
            continue

    projects.sort(key=lambda x: x["id"])
    endpoint = f"http://{Cfg.MINIO_SERVICE}:{int(Cfg.MINIO_API_PORT)}"
    return {"bucket": bucket, "endpoint": endpoint, "projects": projects}


def _load_catalog(Cfg, project: str) -> Dict[str, Any]:
    """
    Loads <project>/catalog.json from MinIO bucket DBT_DOCS_BUCKET with caching.
    """
    bucket = getattr(Cfg, "DBT_DOCS_BUCKET", "dbt-docs")
    project = (project or "").strip().strip("/")
    if not project:
        project = getattr(Cfg, "DBT_DEFAULT_PROJECT", "his_dmo")

    key = f"{project}/catalog.json"
    cache_key = f"{bucket}:{key}"

    now = int(time.time())
    hit = _CACHE.get(cache_key)
    if hit and (now - int(hit.get("ts", 0))) <= _CACHE_TTL_SEC:
        return hit["payload"]

    s3 = _s3_client(Cfg)
    obj = s3.get_object(Bucket=bucket, Key=key)
    raw = obj["Body"].read()
    payload = json.loads(raw.decode("utf-8"))

    _CACHE[cache_key] = {"ts": now, "payload": payload}
    return payload


def _rows_from_catalog(cat: Dict[str, Any]) -> List[Dict[str, Any]]:
    """
    Convert dbt catalog.json into portal table rows:
      {schema, table, rows, last_update, owner}
    """
    meta = (cat.get("metadata") or {})
    generated_at = meta.get("generated_at") or ""

    nodes = (cat.get("nodes") or {})
    sources = (cat.get("sources") or {})

    out: List[Dict[str, Any]] = []

    def push(item: Dict[str, Any], owner: str):
        md = (item.get("metadata") or {})
        stats = (item.get("stats") or {})
        schema = md.get("schema") or ""
        name = md.get("name") or ""
        if not schema or not name:
            return
        out.append(
            {
                "schema": schema,
                "table": name,
                "rows": stats.get("num_rows", ""),
                "last_update": generated_at,
                "owner": owner,
            }
        )

    for _, v in nodes.items():
        typ = str((v.get("metadata") or {}).get("type") or "node")
        push(v, owner=typ)

    for _, v in sources.items():
        push(v, owner="source")

    # de-dupe + stable sort
    seen = set()
    uniq = []
    for r in out:
        k = (r["schema"], r["table"], r["owner"])
        if k in seen:
            continue
        seen.add(k)
        uniq.append(r)

    uniq.sort(key=lambda x: (x["schema"], x["table"], x["owner"]))
    return uniq


def get_dbt_catalog_assets(
    Cfg,
    project: str,
    q: str,
    page: int,
    page_size: int,
) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    """
    Returns:
      assets: { pagination: {...}, tables: [...] }
      evidence: { bucket, key, total, returned, cache_ttl_sec }
    """
    bucket = getattr(Cfg, "DBT_DOCS_BUCKET", "dbt-docs")
    project = (project or "").strip().strip("/")
    if not project:
        project = getattr(Cfg, "DBT_DEFAULT_PROJECT", "his_dmo")

    cat = _load_catalog(Cfg, project=project)
    rows = _rows_from_catalog(cat)

    term = (q or "").strip().lower()
    if term:
        rows = [
            r for r in rows
            if term in str(r.get("schema", "")).lower()
            or term in str(r.get("table", "")).lower()
            or term in str(r.get("owner", "")).lower()
        ]

    total = len(rows)
    page = max(1, int(page or 1))
    page_size = max(1, min(200, int(page_size or 50)))
    start = (page - 1) * page_size
    end = start + page_size
    page_rows = rows[start:end]

    assets = {
        "pagination": {"page": page, "page_size": page_size, "total": total},
        "tables": page_rows,
    }
    evidence = {
        "bucket": bucket,
        "key": f"{project}/catalog.json",
        "project": project,
        "total": total,
        "returned": len(page_rows),
        "cache_ttl_sec": _CACHE_TTL_SEC,
    }
    return assets, evidence
