import os
from urllib.parse import quote_plus


def getenv(name: str, default=None):
    v = os.getenv(name)
    return v if v not in (None, "") else default


class Config:
    # namespaces
    PLATFORM_NS = getenv("PLATFORM_NS", "platform")
    OPENKPI_NS = getenv("OPENKPI_NS", "open-kpi")

    # TLS / URL scheme (normalized)
    TLS_MODE_RAW = getenv("TLS_MODE", "off")
    TLS_MODE = (TLS_MODE_RAW or "off").strip().lower()
    URL_SCHEME = "https" if TLS_MODE not in ("off", "disabled", "false", "0") else "http"

    # external hosts (ingress)
    PORTAL_HOST = getenv("PORTAL_HOST", "")
    AIRBYTE_HOST = getenv("AIRBYTE_HOST", "")
    MINIO_HOST = getenv("MINIO_HOST", "")
    METABASE_HOST = getenv("METABASE_HOST", "")
    N8N_HOST = getenv("N8N_HOST", "")
    ZAMMAD_HOST = getenv("ZAMMAD_HOST", "")
    DBT_HOST = getenv("DBT_HOST", "")

    # optional explicit bases (preferred for link-building)
    PORTAL_UI_BASE = getenv("PORTAL_UI_BASE", "")        # e.g. https://portal.example.com
    PORTAL_API_BASE = getenv("PORTAL_API_BASE", "")      # e.g. https://portal.example.com/api

    # internal services (cluster DNS defaults)
    POSTGRES_SERVICE = getenv("POSTGRES_SERVICE", "openkpi-postgres.open-kpi.svc.cluster.local")
    POSTGRES_PORT = int(getenv("POSTGRES_PORT", "5432") or "5432")
    POSTGRES_DB = getenv("POSTGRES_DB", "")
    POSTGRES_USER = getenv("POSTGRES_USER", "")
    POSTGRES_PASSWORD = getenv("POSTGRES_PASSWORD", "")

    MINIO_SERVICE = getenv("MINIO_SERVICE", "openkpi-minio.open-kpi.svc.cluster.local")
    MINIO_API_PORT = int(getenv("MINIO_API_PORT", "9000") or "9000")
    MINIO_CONSOLE_PORT = int(getenv("MINIO_CONSOLE_PORT", "9001") or "9001")
    MINIO_ROOT_USER = getenv("MINIO_ROOT_USER", "")
    MINIO_ROOT_PASSWORD = getenv("MINIO_ROOT_PASSWORD", "")
    AIRBYTE_S3_REGION = getenv("AIRBYTE_S3_REGION", "us-east-1")

    # auth tokens / keys
    N8N_API_KEY = getenv("N8N_API_KEY", "")
    N8N_BASIC_USER = getenv("N8N_BASIC_USER", "")
    N8N_BASIC_PASS = getenv("N8N_BASIC_PASS", "")
    ZAMMAD_API_TOKEN = getenv("ZAMMAD_API_TOKEN", "")
    METABASE_API_KEY = getenv("METABASE_API_KEY", "")

    # service names / namespaces
    PORTAL_API_SVC = getenv("PORTAL_API_SVC", "portal-api")
    AIRBYTE_NS = getenv("AIRBYTE_NS", "airbyte")
    TRANSFORM_NS = getenv("TRANSFORM_NS", "transform")
    ANALYTICS_NS = getenv("ANALYTICS_NS", "analytics")
    N8N_NS = getenv("N8N_NS", "n8n")
    TICKETS_NS = getenv("TICKETS_NS", "tickets")

    # -------------------------
    # URL helpers (link-building)
    # -------------------------

    @classmethod
    def host_url(cls, host: str) -> str:
        return f"{cls.URL_SCHEME}://{host}" if host else ""

    @classmethod
    def portal_ui_url(cls) -> str:
        return cls.PORTAL_UI_BASE or cls.host_url(cls.PORTAL_HOST)

    @classmethod
    def portal_api_url(cls) -> str:
        return cls.PORTAL_API_BASE or (cls.portal_ui_url() + "/api" if cls.portal_ui_url() else "")

    # -------------------------
    # Postgres helpers
    # -------------------------

    @classmethod
    def pg_dsn(cls) -> str:
        host = cls.POSTGRES_SERVICE
        port = cls.POSTGRES_PORT
        db = cls.POSTGRES_DB or "postgres"
        user = cls.POSTGRES_USER
        pwd = cls.POSTGRES_PASSWORD

        if not host:
            raise RuntimeError("POSTGRES_SERVICE is empty")
        if not user:
            raise RuntimeError("POSTGRES_USER is empty")
        if pwd in (None, ""):
            raise RuntimeError("POSTGRES_PASSWORD is empty")

        return f"postgresql://{quote_plus(user)}:{quote_plus(pwd)}@{host}:{port}/{quote_plus(db)}"

    @classmethod
    def pg_dsn_safe(cls) -> str | None:
        try:
            return cls.pg_dsn()
        except Exception:
            return None

    # -------------------------
    # MinIO helpers
    # -------------------------

    @classmethod
    def minio_endpoint(cls) -> str:
        svc = cls.MINIO_SERVICE
        port = cls.MINIO_API_PORT
        if not svc:
            raise RuntimeError("MINIO_SERVICE is empty")
        return f"http://{svc}:{port}"

    @classmethod
    def minio_endpoint_safe(cls) -> str | None:
        try:
            return cls.minio_endpoint()
        except Exception:
            return None

    @classmethod
    def minio_auth(cls) -> tuple[str, str]:
        if not cls.MINIO_ROOT_USER:
            raise RuntimeError("MINIO_ROOT_USER is empty")
        if not cls.MINIO_ROOT_PASSWORD:
            raise RuntimeError("MINIO_ROOT_PASSWORD is empty")
        return cls.MINIO_ROOT_USER, cls.MINIO_ROOT_PASSWORD

    @classmethod
    def minio_auth_safe(cls) -> tuple[str, str] | None:
        try:
            return cls.minio_auth()
        except Exception:
            return None
