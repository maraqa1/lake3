from __future__ import annotations
from typing import Any, Dict
import boto3
from botocore.config import Config as BotoCfg

def _client(Cfg):
    endpoint = f"http://{Cfg.MINIO_SERVICE}:{Cfg.MINIO_API_PORT}"
    s3 = boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=Cfg.MINIO_ROOT_USER,
        aws_secret_access_key=Cfg.MINIO_ROOT_PASSWORD,
        region_name=Cfg.AIRBYTE_S3_REGION,
        config=BotoCfg(s3={"addressing_style": "path"}),
    )
    return s3, endpoint

def s3_get_json_if_exists(Cfg, bucket: str, key: str) -> Dict[str, Any]:
    if not (Cfg.MINIO_SERVICE and Cfg.MINIO_ROOT_USER and Cfg.MINIO_ROOT_PASSWORD):
        return {"ok": False, "error": "minio not configured", "bucket": bucket, "key": key}
    try:
        s3, endpoint = _client(Cfg)
        obj = s3.get_object(Bucket=bucket, Key=key)
        body = obj["Body"].read()
        import json
        return {"ok": True, "json": json.loads(body.decode("utf-8")), "bucket": bucket, "key": key, "endpoint": endpoint}
    except Exception as e:
        return {"ok": False, "error": str(e), "bucket": bucket, "key": key}
