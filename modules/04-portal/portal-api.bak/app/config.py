import os

def getenv(name: str, default=None):
    v = os.getenv(name)
    return v if v not in (None, "") else default

class Config:
    PLATFORM_NS = getenv("PLATFORM_NS", "platform")
    OPENKPI_NS = getenv("OPENKPI_NS", "open-kpi")

    TLS_MODE = getenv("TLS_MODE", "off")
    URL_SCHEME = "https" if TLS_MODE not in ("off", "disabled", "false", "0") else "http"

    PORTAL_HOST = getenv("PORTAL_HOST", "")
    AIRBYTE_HOST = getenv("AIRBYTE_HOST", "")
    MINIO_HOST = getenv("MINIO_HOST", "")
    METABASE_HOST = getenv("METABASE_HOST", "")
    N8N_HOST = getenv("N8N_HOST", "")
    ZAMMAD_HOST = getenv("ZAMMAD_HOST", "")
    DBT_HOST = getenv("DBT_HOST", "")

    POSTGRES_SERVICE = getenv("POSTGRES_SERVICE", "")
    POSTGRES_PORT = int(getenv("POSTGRES_PORT", "5432") or "5432")
    POSTGRES_DB = getenv("POSTGRES_DB", "")
    POSTGRES_USER = getenv("POSTGRES_USER", "")
    POSTGRES_PASSWORD = getenv("POSTGRES_PASSWORD", "")

    MINIO_SERVICE = getenv("MINIO_SERVICE", "")
    MINIO_API_PORT = int(getenv("MINIO_API_PORT", "9000") or "9000")
    MINIO_ROOT_USER = getenv("MINIO_ROOT_USER", "")
    MINIO_ROOT_PASSWORD = getenv("MINIO_ROOT_PASSWORD", "")
    AIRBYTE_S3_REGION = getenv("AIRBYTE_S3_REGION", "us-east-1")

    N8N_API_KEY = getenv("N8N_API_KEY", "")
    N8N_BASIC_USER = getenv("N8N_BASIC_USER", "")
    N8N_BASIC_PASS = getenv("N8N_BASIC_PASS", "")
    ZAMMAD_API_TOKEN = getenv("ZAMMAD_API_TOKEN", "")
    METABASE_API_KEY = getenv("METABASE_API_KEY", "")

    PORTAL_API_SVC = getenv("PORTAL_API_SVC", "portal-api")
    AIRBYTE_NS = getenv("AIRBYTE_NS", "airbyte")
    TRANSFORM_NS = getenv("TRANSFORM_NS", "transform")
    ANALYTICS_NS = getenv("ANALYTICS_NS", "analytics")
    N8N_NS = getenv("N8N_NS", "n8n")
    TICKETS_NS = getenv("TICKETS_NS", "tickets")
