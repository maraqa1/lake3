from __future__ import annotations

from typing import Any, Dict, List, Optional, Tuple

import psycopg2
import psycopg2.extras

from app.probes.contract import service_obj
from app.util.time import utc_now_iso


def _query(dsn: str, sql: str, params: Optional[Tuple[Any, ...]] = None) -> List[Dict[str, Any]]:
    """Execute a SQL query and return rows as dicts."""
    with psycopg2.connect(dsn) as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(sql, params or ())
            return list(cur.fetchall())


def postgres_catalog_tables(Cfg, page: int, page_size: int) -> Dict[str, Any]:
    """Return a paginated list of tables across non-system schemas."""
    dsn = Cfg.pg_dsn()
    page = max(int(page or 1), 1)
    page_size = max(min(int(page_size or 50), 200), 1)
    offset = (page - 1) * page_size

    total_rows = _query(
        dsn,
        """
        select count(*)::int as n
        from information_schema.tables
        where table_type='BASE TABLE'
          and table_schema not in ('pg_catalog','information_schema')
        """,
    )
    total = int(total_rows[0]["n"]) if total_rows else 0

    rows = _query(
        dsn,
        """
        select
          table_schema,
          table_name
        from information_schema.tables
        where table_type='BASE TABLE'
          and table_schema not in ('pg_catalog','information_schema')
        order by table_schema, table_name
        limit %s offset %s
        """,
        (page_size, offset),
    )

    tables = [{"schema": r["table_schema"], "table": r["table_name"]} for r in rows]
    return {"tables": tables, "pagination": {"page": page, "page_size": page_size, "total": total}}


def postgres_search(Cfg, q: str) -> Dict[str, Any]:
    """Case-insensitive search across schema+table names, limited to 50."""
    dsn = Cfg.pg_dsn()
    q = (q or "").strip()
    if not q:
        return {"q": q, "matches": []}

    rows = _query(
        dsn,
        """
        select
          table_schema,
          table_name
        from information_schema.tables
        where table_type='BASE TABLE'
          and table_schema not in ('pg_catalog','information_schema')
          and (table_schema ilike %s or table_name ilike %s)
        order by table_schema, table_name
        limit 50
        """,
        (f"%{q}%", f"%{q}%"),
    )

    matches = [{"schema": r["table_schema"], "table": r["table_name"]} for r in rows]
    return {"q": q, "matches": matches}


def postgres_summary(Config) -> Dict[str, Any]:
    """Return a canonical service object plus a postgres details blob."""

    name = "postgres"
    ui = getattr(Config, "POSTGRES_UI_URL", "") if hasattr(Config, "POSTGRES_UI_URL") else ""
    api = ""

    host = getattr(Config, "POSTGRES_SERVICE", None) or getattr(Config, "POSTGRES_HOST", None)
    port = int(getattr(Config, "POSTGRES_PORT", 5432))
    db = getattr(Config, "POSTGRES_DB", None)
    user = getattr(Config, "POSTGRES_USER", None)
    pwd = getattr(Config, "POSTGRES_PASSWORD", None)

    if not all([host, db, user, pwd]):
        svc = service_obj(
            name=name,
            status="INFO",
            reason="postgres not configured",
            last_checked=utc_now_iso(),
            links={"ui": ui, "api": api},
            evidence={"type": "db", "details": {"configured": False}},
        )
        return {"service": svc, "postgres": {"configured": False}}

    try:
        dsn = f"host={host} port={port} dbname={db} user={user} password={pwd} connect_timeout=3"
        with psycopg2.connect(dsn) as c:
            with c.cursor() as cur:
                cur.execute(
                    """
                    select count(*)::int
                    from information_schema.schemata
                    where schema_name not like 'pg_%'
                      and schema_name <> 'information_schema'
                    """
                )
                schemas = int(cur.fetchone()[0])

                cur.execute(
                    """
                    select count(*)::int
                    from information_schema.tables
                    where table_schema not like 'pg_%'
                      and table_schema <> 'information_schema'
                      and table_type='BASE TABLE'
                    """
                )
                tables = int(cur.fetchone()[0])

        details = {"host": host, "port": port, "db": db, "schemas_count": schemas, "tables_count": tables}
        svc = service_obj(
            name=name,
            status="OPERATIONAL",
            reason="",
            last_checked=utc_now_iso(),
            links={"ui": ui, "api": api},
            evidence={"type": "db", "details": details},
        )
        return {"service": svc, "postgres": details}
    except Exception as e:
        svc = service_obj(
            name=name,
            status="DOWN",
            reason="postgres connection/query failed",
            last_checked=utc_now_iso(),
            links={"ui": ui, "api": api},
            evidence={"type": "db", "details": {"error": str(e), "host": host, "port": port, "db": db}},
        )
        return {"service": svc, "postgres": {"error": str(e), "host": host, "port": port, "db": db}}
