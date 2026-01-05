from __future__ import annotations
from typing import Any, Dict, List
import psycopg2
import psycopg2.extras
from app.probes.contract import service_obj

def _conn(Cfg):
    return psycopg2.connect(
        host=Cfg.POSTGRES_SERVICE,
        port=Cfg.POSTGRES_PORT,
        dbname=Cfg.POSTGRES_DB,
        user=Cfg.POSTGRES_USER,
        password=Cfg.POSTGRES_PASSWORD,
        connect_timeout=3,
    )

def postgres_summary(Cfg) -> Dict[str, Any]:
    try:
        with _conn(Cfg) as conn:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                cur.execute("select current_database() as db, current_user as usr")
                ident = dict(cur.fetchone() or {})

                cur.execute("""
                    select count(*)::int as schemas_count
                    from information_schema.schemata
                    where schema_name not like 'pg_%' and schema_name <> 'information_schema'
                """)
                schemas_count = int((cur.fetchone() or {}).get("schemas_count", 0))

                cur.execute("""
                    select count(*)::int as tables_count
                    from information_schema.tables
                    where table_schema not like 'pg_%'
                      and table_schema <> 'information_schema'
                      and table_type='BASE TABLE'
                """)
                tables_count = int((cur.fetchone() or {}).get("tables_count", 0))

        svc = service_obj(
            name="postgres",
            status="OPERATIONAL",
            reason="",
            links={"ui": "", "api": ""},
            evidence_type="db",
            evidence_details={
                "connectivity": "ok",
                "identity": ident,
                "schemas_count": schemas_count,
                "tables_count": tables_count,
                "host": Cfg.POSTGRES_SERVICE,
                "port": Cfg.POSTGRES_PORT,
            },
        )
        return {"service": svc, "postgres": {"schemas_count": schemas_count, "tables_count": tables_count}}
    except Exception as e:
        svc = service_obj(
            name="postgres",
            status="DOWN",
            reason="Postgres unreachable",
            links={"ui": "", "api": ""},
            evidence_type="db",
            evidence_details={"error": str(e), "host": Cfg.POSTGRES_SERVICE, "port": Cfg.POSTGRES_PORT},
        )
        return {"service": svc, "postgres": {"schemas_count": 0, "tables_count": 0}}

def postgres_catalog_tables(Cfg, page: int, page_size: int) -> Dict[str, Any]:
    offset = (page - 1) * page_size
    try:
        with _conn(Cfg) as conn:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                cur.execute("""
                    select count(*)::int as total
                    from information_schema.tables
                    where table_schema not like 'pg_%'
                      and table_schema <> 'information_schema'
                      and table_type='BASE TABLE'
                """)
                total = int((cur.fetchone() or {}).get("total", 0))
                cap_total = min(total, 2000)

                cur.execute("""
                    with t as (
                      select table_schema, table_name
                      from information_schema.tables
                      where table_schema not like 'pg_%'
                        and table_schema <> 'information_schema'
                        and table_type='BASE TABLE'
                      order by table_schema, table_name
                      limit 2000
                    )
                    select t.table_schema as schema,
                           t.table_name as table,
                           coalesce(pc.reltuples::bigint, 0)::bigint as rows_estimate,
                           null::timestamptz as last_update,
                           null::text as owner
                    from t
                    left join pg_class pc on pc.relname = t.table_name
                    left join pg_namespace pn on pn.oid = pc.relnamespace and pn.nspname = t.table_schema
                    order by t.table_schema, t.table_name
                    offset %s limit %s
                """, (offset, page_size))
                rows = cur.fetchall() or []

        return {
            "tables": [
                {
                    "schema": r.get("schema", ""),
                    "table": r.get("table", ""),
                    "rows_estimate": int(r.get("rows_estimate", 0) or 0),
                    "last_update": None,
                    "owner": None,
                }
                for r in rows
            ],
            "pagination": {"page": page, "page_size": page_size, "total": cap_total},
        }
    except Exception as e:
        return {"tables": [], "pagination": {"page": page, "page_size": page_size, "total": 0}, "error": str(e)}

def postgres_search(Cfg, q: str) -> Dict[str, Any]:
    q_like = f"%{q.lower()}%"
    matches: List[Dict[str, Any]] = []
    try:
        with _conn(Cfg) as conn:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                cur.execute("""
                    select table_schema, table_name
                    from information_schema.tables
                    where table_type='BASE TABLE'
                      and table_schema not like 'pg_%'
                      and table_schema <> 'information_schema'
                      and (lower(table_schema) like %s or lower(table_name) like %s)
                    order by table_schema, table_name
                    limit 200
                """, (q_like, q_like))
                for r in (cur.fetchall() or []):
                    matches.append({"type": "table", "schema": r["table_schema"], "table": r["table_name"], "column": None})

                cur.execute("""
                    select table_schema, table_name, column_name
                    from information_schema.columns
                    where table_schema not like 'pg_%'
                      and table_schema <> 'information_schema'
                      and (lower(column_name) like %s or lower(table_name) like %s or lower(table_schema) like %s)
                    order by table_schema, table_name, column_name
                    limit 300
                """, (q_like, q_like, q_like))
                for r in (cur.fetchall() or []):
                    matches.append({"type": "column", "schema": r["table_schema"], "table": r["table_name"], "column": r["column_name"]})

        return {"q": q, "matches": matches}
    except Exception as e:
        return {"q": q, "matches": [], "error": str(e)}
