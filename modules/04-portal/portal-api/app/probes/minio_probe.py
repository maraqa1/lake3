from __future__ import annotations
from typing import Any, Dict
import boto3
from botocore.config import Config as BotoCfg
from botocore.exceptions import BotoCoreError, ClientError
from app.probes.contract import service_obj

def minio_summary(Cfg) -> Dict[str, Any]:
    if not (Cfg.MINIO_SERVICE and Cfg.MINIO_ROOT_USER and Cfg.MINIO_ROOT_PASSWORD):
        svc = service_obj(
            name="minio",
            status="DEGRADED",
            reason="MinIO credentials not configured",
            links={"ui": f"{Cfg.URL_SCHEME}://{Cfg.MINIO_HOST}" if Cfg.MINIO_HOST else "", "api": ""},
            evidence_type="api",
            evidence_details={
                "configured": False,
                "minio_service": bool(Cfg.MINIO_SERVICE),
                "minio_root_user": bool(Cfg.MINIO_ROOT_USER),
                "minio_root_password": bool(Cfg.MINIO_ROOT_PASSWORD),
            },
        )
        return {"service": svc, "minio": {"buckets": [], "bucket_count": 0}}

    endpoint = f"http://{Cfg.MINIO_SERVICE}:{Cfg.MINIO_API_PORT}"
    try:
        s3 = boto3.client(
            "s3",
            endpoint_url=endpoint,
            aws_access_key_id=Cfg.MINIO_ROOT_USER,
            aws_secret_access_key=Cfg.MINIO_ROOT_PASSWORD,
            region_name=Cfg.AIRBYTE_S3_REGION,
            config=BotoCfg(
                s3={"addressing_style": "path"},
                connect_timeout=3,
                read_timeout=5,
                retries={"max_attempts": 1, "mode": "standard"},
            ),
        )

        resp = s3.list_buckets()
        buckets = resp.get("Buckets", []) or []
        out = [{"name": b.get("Name", ""), "creation_date": (b.get("CreationDate").isoformat() if b.get("CreationDate") else None)} for b in buckets]
        svc = service_obj(
            name="minio",
            status="OPERATIONAL",
            reason="",
            links={"ui": f"{Cfg.URL_SCHEME}://{Cfg.MINIO_HOST}" if Cfg.MINIO_HOST else "", "api": endpoint},
            evidence_type="api",
            evidence_details={"endpoint": endpoint, "bucket_count": len(out), "sample": out[:20]},
        )
        return {"service": svc, "minio": {"buckets": out, "bucket_count": len(out), "endpoint": endpoint}}
    except (BotoCoreError, ClientError, Exception) as e:
        svc = service_obj(
            name="minio",
            status="DOWN",
            reason="MinIO unreachable",
            links={"ui": f"{Cfg.URL_SCHEME}://{Cfg.MINIO_HOST}" if Cfg.MINIO_HOST else "", "api": endpoint},
            evidence_type="api",
            evidence_details={"endpoint": endpoint, "error": str(e)},
        )
        return {"service": svc, "minio": {"buckets": [], "bucket_count": 0, "endpoint": endpoint}}
