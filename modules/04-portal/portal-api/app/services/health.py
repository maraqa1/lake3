\
from __future__ import annotations

import os
from typing import Tuple

import requests

def check_postgres() -> Tuple[bool, str]:
    host = os.environ.get("POSTGRES_HOST", "")
    port = int(os.environ.get("POSTGRES_PORT", "5432"))
    db = os.environ.get("POSTGRES_DB", "")
    user = os.environ.get("POSTGRES_USER", "")
    pw = os.environ.get("POSTGRES_PASSWORD", "")
    if not host or not db or not user:
        return False, "not_configured:postgres_env_missing"
    try:
        import psycopg2  # type: ignore
        conn = psycopg2.connect(host=host, port=port, dbname=db, user=user, password=pw, connect_timeout=3)
        cur = conn.cursor()
        cur.execute("select 1;")
        cur.fetchone()
        cur.close()
        conn.close()
        return True, ""
    except Exception as e:
        return False, f"postgres_error:{e.__class__.__name__}"

def check_minio() -> Tuple[bool, str]:
    host = os.environ.get("MINIO_HOST", "")
    port = os.environ.get("MINIO_PORT", "")
    user = os.environ.get("MINIO_USER", "")
    pw = os.environ.get("MINIO_PASSWORD", "")
    if not host or not port or not user or not pw:
        return False, "not_configured:minio_env_missing"
    # Minimal TCP-ish check via HTTP GET to /minio/health/ready
    url = f"http://{host}:{port}/minio/health/ready"
    try:
        r = requests.get(url, timeout=3)
        if r.status_code == 200:
            return True, ""
        return False, f"minio_http_{r.status_code}"
    except Exception as e:
        return False, f"minio_error:{e.__class__.__name__}"

def check_http(name: str, url: str) -> Tuple[bool, str]:
    if not url:
        return False, "not_configured:http_url_missing"
    try:
        r = requests.get(url, timeout=3)
        if 200 <= r.status_code < 500:
            return True, ""
        return False, f"{name}_http_{r.status_code}"
    except Exception as e:
        return False, f"{name}_error:{e.__class__.__name__}"
