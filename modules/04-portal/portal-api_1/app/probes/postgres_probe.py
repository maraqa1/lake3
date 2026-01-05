from __future__ import annotations

from typing import Any, Dict, List, Optional
import psycopg2
import psycopg2.extras


def _query(dsn: str, sql: str, params: Optional[tuple] = None) -> List[Dict[str, Any]]:
    with psycopg2.connect(dsn) as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(sql, params or ())
            return list(cur.fetchall())


def postgres_catalog_tables(Cfg, page: int, page_size: int) -> Dict[str, Any]:
    """
    Returns a paginated list of tables across *all non-system schemas*.
    """
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
        """
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
    """
    Case-insensitive search across schema+table names, limited to 50.
    """
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
