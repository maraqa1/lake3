#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 04X-api-appstate.patch.sh — Portal API: emit explicit app states in /api/summary
#
# Adds summary.apps[] with: healthy | degraded | down | not_installed
# - Core apps: platform, minio
# - Optional apps: airbyte, dbt, metabase, n8n, zammad
#
# Repeatable on a fresh VM:
# - Re-applies ConfigMap portal-api-code (only app.py changed)
# - Rollout-restarts portal-api
# - Runs minimal tests (no jq dependency)
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/00-env.sh"
# shellcheck source=/dev/null
. "${HERE}/00-lib.sh"

require_cmd kubectl
require_cmd python3
require_cmd curl

PLATFORM_NS="${PLATFORM_NS:-platform}"
OPENKPI_NS="${NS:-open-kpi}"

API_CM="${PORTAL_API_CM:-portal-api-code}"
API_DEPLOY="${PORTAL_API_DEPLOY:-portal-api}"

: "${PORTAL_HOST:=${PORTAL_HOST:-}}"
[[ -n "${PORTAL_HOST}" ]] || fatal "PORTAL_HOST not set in /root/open-kpi.env"

log(){ echo "[04X][PORTAL-API][APPSTATE] $*"; }
warn(){ echo "[04X][PORTAL-API][APPSTATE][WARN] $*" >&2; }

ensure_ns "${PLATFORM_NS}"

log "Patch ConfigMap ${PLATFORM_NS}/${API_CM} (inject apps[] state model)"
kubectl -n "${PLATFORM_NS}" apply -f - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: portal-api-code
  namespace: platform
data:
  app.py: |
    import os, datetime
    from typing import Dict, Any, Optional, List

    from flask import Flask, jsonify, request

    try:
      import boto3
      from botocore.config import Config as BotoConfig
    except Exception:
      boto3 = None

    try:
      import psycopg2
    except Exception:
      psycopg2 = None

    try:
      from kubernetes import client, config
    except Exception:
      client = None
      config = None

    app = Flask(__name__)

    def now_iso():
      return datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"

    def env(name: str, default: str = "") -> str:
      return os.getenv(name, default)

    def load_k8s():
      if config is None:
        return None
      try:
        config.load_incluster_config()
        return client
      except Exception:
        return None

    def deny_path(path: str) -> bool:
      bad = ["/.env", "/.git", "/.git/config", "/.gitignore", "/.svn", "/.hg", "/.DS_Store"]
      if path in bad:
        return True
      if path.startswith("/.git/") or path.startswith("/.svn/") or path.startswith("/.hg/"):
        return True
      return False

    @app.before_request
    def _block_sensitive():
      if deny_path(request.path):
        return ("Not Found", 404)

    # -----------------------------
    # K8s summarizers
    # -----------------------------
    def summarize_pods(v1, ns: str) -> Dict[str, Any]:
      pods = v1.list_namespaced_pod(ns).items
      out = []
      total_restarts = 0
      for p in pods:
        restarts = 0
        cs = (p.status.container_statuses or [])
        for c in cs:
          restarts += int(getattr(c, "restart_count", 0) or 0)
        total_restarts += restarts
        out.append({
          "name": p.metadata.name,
          "phase": p.status.phase,
          "ready": all([(c.ready is True) for c in cs]) if cs else False,
          "restarts": restarts,
          "node": p.spec.node_name or "",
        })
      return {"count": len(out), "total_restarts": total_restarts, "items": sorted(out, key=lambda x: x["name"])}

    def summarize_deployments(apps, ns: str) -> Dict[str, Any]:
      deps = apps.list_namespaced_deployment(ns).items
      out = []
      for d in deps:
        spec = d.spec.replicas or 0
        avail = d.status.available_replicas or 0
        ready = d.status.ready_replicas or 0
        out.append({
          "name": d.metadata.name,
          "replicas": int(spec),
          "ready": int(ready),
          "available": int(avail),
          "updated": int(d.status.updated_replicas or 0),
        })
      return {"count": len(out), "items": sorted(out, key=lambda x: x["name"])}

    def summarize_statefulsets(apps, ns: str) -> Dict[str, Any]:
      stss = apps.list_namespaced_stateful_set(ns).items
      out = []
      for s in stss:
        spec = s.spec.replicas or 0
        ready = s.status.ready_replicas or 0
        out.append({
          "name": s.metadata.name,
          "replicas": int(spec),
          "ready": int(ready),
          "current": int(s.status.current_replicas or 0),
          "updated": int(s.status.updated_replicas or 0),
        })
      return {"count": len(out), "items": sorted(out, key=lambda x: x["name"])}

    def k8s_summary() -> Dict[str, Any]:
      k8s = load_k8s()
      if k8s is None:
        return {"available": False, "error": "kubernetes client unavailable"}
      v1 = k8s.CoreV1Api()
      apps_api = k8s.AppsV1Api()

      try:
        nss = [n.metadata.name for n in v1.list_namespace().items]
      except Exception as e:
        return {"available": False, "error": f"cannot list namespaces: {str(e)}"}

      namespaces = []
      for ns in sorted(nss):
        try:
          pods = summarize_pods(v1, ns)
          deps = summarize_deployments(apps_api, ns)
          stss = summarize_statefulsets(apps_api, ns)
          namespaces.append({"name": ns, "pods": pods, "deployments": deps, "statefulsets": stss})
        except Exception as e:
          namespaces.append({
            "name": ns,
            "error": str(e),
            "pods": {"count": 0, "total_restarts": 0, "items": []},
            "deployments": {"count": 0, "items": []},
            "statefulsets": {"count": 0, "items": []},
          })

      return {"available": True, "namespaces": namespaces}

    # -----------------------------
    # Ingress links discovery
    # -----------------------------
    def _ingress_host(net, ns: str, ingress_name: str) -> Optional[str]:
      try:
        ing = net.read_namespaced_ingress(ingress_name, ns)
        rules = (ing.spec.rules or [])
        if not rules:
          return None
        host = rules[0].host or ""
        return host if host else None
      except Exception:
        return None

    def _first_ingress_host(net, ns: str) -> Optional[str]:
      try:
        ings = net.list_namespaced_ingress(ns).items
        for ing in ings:
          rules = (ing.spec.rules or [])
          if rules and rules[0].host:
            return rules[0].host
        return None
      except Exception:
        return None

    def build_links() -> Dict[str, str]:
      out = {"portal":"", "airbyte":"", "minio":"", "metabase":"", "n8n":"", "zammad":"", "dbt":""}

      tls_mode = (env("TLS_MODE","off") or "off").strip()
      scheme = "https" if tls_mode == "per-host-http01" else "http"

      portal_host = env("PORTAL_HOST","")
      if portal_host:
        out["portal"] = f"{scheme}://{portal_host}"

      k8s = load_k8s()
      if k8s is None:
        return out

      net = k8s.NetworkingV1Api()
      openkpi_ns = env("OPENKPI_NS","open-kpi")

      candidates = {
        "airbyte":  [("airbyte","airbyte")],
        "metabase": [("analytics","metabase"), ("metabase","metabase")],
        "n8n":      [("n8n","n8n")],
        "zammad":   [("tickets","zammad")],
        "dbt":      [("transform","dbt"), ("transform","dbt-docs"), ("transform","dbt-ui")],
        "minio":    [(openkpi_ns,"minio"), (openkpi_ns,"openkpi-minio")]
      }

      for key, tries in candidates.items():
        host = None
        for ns, name in tries:
          host = _ingress_host(net, ns, name)
          if host:
            break
        if not host and tries:
          ns0 = tries[0][0]
          host = _first_ingress_host(net, ns0)
        if host:
          out[key] = f"{scheme}://{host}"

      return out

    # -----------------------------
    # Postgres + MinIO
    # -----------------------------
    def pg_catalog() -> Dict[str, Any]:
      host = env("PG_HOST")
      port = env("PG_PORT", "5432")
      db = env("PG_DB", "postgres")
      user = env("PG_USER", "postgres")
      pw = env("PG_PASSWORD", "")

      if psycopg2 is None:
        return {"available": False, "error": "psycopg2 not installed", "schemas": [], "tables": []}

      try:
        conn = psycopg2.connect(host=host, port=int(port), dbname=db, user=user, password=pw, connect_timeout=3)
        cur = conn.cursor()

        cur.execute("""
          SELECT schema_name
          FROM information_schema.schemata
          WHERE schema_name NOT IN ('pg_catalog','information_schema')
          ORDER BY schema_name;
        """)
        schemas = [{"schema": r[0]} for r in cur.fetchall()]

        cur.execute("""
          SELECT table_schema, table_name
          FROM information_schema.tables
          WHERE table_type='BASE TABLE'
            AND table_schema NOT IN ('pg_catalog','information_schema')
          ORDER BY table_schema, table_name
          LIMIT 2000;
        """)
        tables = [{"schema": r[0], "table": r[1]} for r in cur.fetchall()]

        cur.close()
        conn.close()
        return {"available": True, "schemas": schemas, "tables": tables}
      except Exception as e:
        return {"available": False, "error": str(e), "schemas": [], "tables": []}

    def minio_catalog() -> Dict[str, Any]:
      endpoint = env("MINIO_ENDPOINT")
      ak = env("MINIO_ACCESS_KEY")
      sk = env("MINIO_SECRET_KEY")

      if not endpoint or not ak or not sk:
        return {"available": False, "health": {"ok": False, "error": "missing minio credentials"}, "buckets": []}

      if boto3 is None:
        return {"available": False, "health": {"ok": False, "error": "boto3 not installed"}, "buckets": []}

      try:
        s3 = boto3.client(
          "s3",
          endpoint_url=endpoint,
          aws_access_key_id=ak,
          aws_secret_access_key=sk,
          region_name="us-east-1",
          config=BotoConfig(signature_version="s3v4"),
          verify=False,
        )
        buckets_resp = s3.list_buckets()
        buckets = []
        for b in buckets_resp.get("Buckets", []):
          created = b.get("CreationDate")
          buckets.append({"name": b.get("Name",""), "created": (created.isoformat() if created else "")})
        return {"available": True, "health": {"ok": True}, "buckets": sorted(buckets, key=lambda x: x["name"])}
      except Exception as e:
        return {"available": False, "health": {"ok": False, "error": str(e)}, "buckets": []}

    # -----------------------------
    # Airbyte
    # -----------------------------
    def airbyte_ingestion() -> Dict[str, Any]:
      k8s = load_k8s()
      if k8s is None:
        return {"available": False, "error": "kubernetes client unavailable"}

      v1 = k8s.CoreV1Api()
      try:
        _ = v1.read_namespace("airbyte")
      except Exception:
        return {"available": False}

      try:
        svc_candidates = [("airbyte-airbyte-server",8001), ("airbyte-server",8001), ("airbyte-airbyte-api-server",8001)]
        base = None
        for name, port in svc_candidates:
          try:
            v1.read_namespaced_service(name, "airbyte")
            base = f"http://{name}.airbyte.svc.cluster.local:{port}"
            break
          except Exception:
            continue
        if base is None:
          return {"available": True, "last_sync": None, "detail": {"ok": False, "error": "airbyte server service not found"}}

        import requests
        url = base + "/api/v1/jobs/list"
        payload = {"configTypes":["sync"], "includingJobId":0, "pagination":{"pageSize":20,"rowOffset":0}}
        r = requests.post(url, json=payload, timeout=3)
        if r.status_code != 200:
          return {"available": True, "last_sync": None, "detail": {"ok": False, "error": f"http {r.status_code}"}}

        data = r.json() or {}
        jobs = (data.get("jobs") or [])
        if not jobs:
          return {"available": True, "last_sync": None, "detail": {"ok": True, "note": "no jobs returned"}}

        best = None
        for j in jobs:
          job = j.get("job") or {}
          created = job.get("createdAt") or job.get("created_at") or 0
          if best is None or (created and created > best[0]):
            best = (created, j)

        jobwrap = best[1]
        job = jobwrap.get("job") or {}
        attempts = jobwrap.get("attempts") or []
        attempt = attempts[0] if attempts else {}

        last_sync = {
          "jobId": job.get("id"),
          "status": job.get("status"),
          "createdAt": job.get("createdAt") or job.get("created_at"),
          "updatedAt": job.get("updatedAt") or job.get("updated_at"),
          "attempt": {
            "status": attempt.get("status"),
            "bytesSynced": attempt.get("bytesSynced") or attempt.get("bytes_synced"),
            "recordsSynced": attempt.get("recordsSynced") or attempt.get("records_synced"),
            "endedAt": attempt.get("endedAt") or attempt.get("ended_at"),
          }
        }
        return {"available": True, "last_sync": last_sync, "detail": {"ok": True, "base": base}}
      except Exception as e:
        return {"available": True, "last_sync": None, "detail": {"ok": False, "error": str(e)}}

    # -----------------------------
    # Apps state model (core vs optional)
    # -----------------------------
    def ns_by_name(k8s_namespaces: List[Dict[str, Any]], name: str) -> Optional[Dict[str, Any]]:
      for ns in k8s_namespaces:
        if (ns.get("name") or "") == name:
          return ns
      return None

    def pods_ready_count(ns: Dict[str, Any]) -> int:
      pods = (ns.get("pods") or {}).get("items") or []
      return sum(1 for p in pods if p.get("ready") is True)

    def pods_total_count(ns: Dict[str, Any]) -> int:
      return int((ns.get("pods") or {}).get("count") or 0)

    def restarts_total(ns: Dict[str, Any]) -> int:
      return int((ns.get("pods") or {}).get("total_restarts") or 0)

    def workloads_exist(ns: Dict[str, Any]) -> bool:
      deps = int((ns.get("deployments") or {}).get("count") or 0)
      stss = int((ns.get("statefulsets") or {}).get("count") or 0)
      pods = pods_total_count(ns)
      return (deps + stss + pods) > 0

    def workloads_degraded(ns: Dict[str, Any]) -> bool:
      deps = (ns.get("deployments") or {}).get("items") or []
      stss = (ns.get("statefulsets") or {}).get("items") or []
      for d in deps:
        if int(d.get("ready") or 0) < int(d.get("replicas") or 0):
          return True
      for s in stss:
        if int(s.get("ready") or 0) < int(s.get("replicas") or 0):
          return True
      # pods can exist without being ready
      if pods_total_count(ns) > 0 and pods_ready_count(ns) < pods_total_count(ns):
        return True
      return False

    def compute_app_status(k8s_namespaces: List[Dict[str, Any]], ns_candidates: List[str], optional: bool) -> Dict[str, Any]:
      ns_obj = None
      chosen = ""
      for n in ns_candidates:
        ns_obj = ns_by_name(k8s_namespaces, n)
        if ns_obj is not None:
          chosen = n
          break

      if ns_obj is None:
        return {"status": ("not_installed" if optional else "down"), "reason": "namespace not found", "k8s": {"namespace": ns_candidates[0] if ns_candidates else ""}}

      if not workloads_exist(ns_obj):
        return {"status": ("not_installed" if optional else "down"), "reason": "no workloads detected", "k8s": {"namespace": chosen}}

      if workloads_degraded(ns_obj):
        return {"status": "degraded", "reason": "pods not fully ready / rollouts in progress", "k8s": {"namespace": chosen}}

      return {"status": "healthy", "reason": "OK", "k8s": {"namespace": chosen}}

    def build_apps(k8s_block: Dict[str, Any], links: Dict[str, str]) -> List[Dict[str, Any]]:
      nss = (k8s_block.get("namespaces") or []) if k8s_block.get("available") else []

      openkpi_ns = env("OPENKPI_NS","open-kpi")

      defs = [
        # core
        {"id":"platform", "display":"Platform Operations", "category":"core", "optional": False, "ns":[env("PLATFORM_NS","platform"), "platform"], "open": links.get("portal","")},
        {"id":"minio", "display":"Object Storage", "category":"core", "optional": False, "ns":[openkpi_ns], "open": links.get("minio","")},

        # optional apps
        {"id":"metabase", "display":"Analytics & BI", "category":"apps", "optional": True, "ns":["metabase","analytics",openkpi_ns], "open": links.get("metabase","")},
        {"id":"n8n", "display":"Workflow Automation", "category":"apps", "optional": True, "ns":["n8n"], "open": links.get("n8n","")},
        {"id":"zammad", "display":"ITSM / Ticketing", "category":"apps", "optional": True, "ns":["tickets"], "open": links.get("zammad","")},
        {"id":"airbyte", "display":"Data Ingestion", "category":"apps", "optional": True, "ns":["airbyte"], "open": links.get("airbyte","")},
        {"id":"dbt", "display":"Data Transformation", "category":"apps", "optional": True, "ns":["transform"], "open": links.get("dbt","")},
      ]

      apps_out = []
      for d in defs:
        s = compute_app_status(nss, d["ns"], bool(d["optional"]))
        nsname = (s.get("k8s") or {}).get("namespace") or (d["ns"][0] if d["ns"] else "")
        ns_obj = ns_by_name(nss, nsname) if nsname else None

        pods_total = pods_total_count(ns_obj) if ns_obj else 0
        pods_ready = pods_ready_count(ns_obj) if ns_obj else 0
        restarts = restarts_total(ns_obj) if ns_obj else 0

        apps_out.append({
          "id": d["id"],
          "display": d["display"],
          "category": d["category"],
          "status": s.get("status","degraded"),
          "reason": s.get("reason",""),
          "k8s": {"namespace": nsname, "pods_total": pods_total, "pods_ready": pods_ready, "restarts_24h": restarts},
          "links": {"open": d.get("open","")}
        })
      return apps_out

    # -----------------------------
    # Summary contract
    # -----------------------------
    def build_summary() -> Dict[str, Any]:
      k8s = k8s_summary()
      pg = pg_catalog()
      mn = minio_catalog()
      ing = airbyte_ingestion()
      links = build_links()
      apps = build_apps({"available": bool(k8s.get("available")), "namespaces": (k8s.get("namespaces") or [])}, links)

      return {
        "meta": {"generated_at": now_iso(), "version": "1.2"},
        "links": links,
        "apps": apps,
        "k8s": {"available": bool(k8s.get("available")), "namespaces": (k8s.get("namespaces") or []) if k8s.get("available") else []},
        "catalog": {
          "postgres": {"available": bool(pg.get("available")), "schemas": pg.get("schemas") or [], "tables": pg.get("tables") or [], "error": pg.get("error","")},
          "minio": {"available": bool(mn.get("available")), "health": mn.get("health") or {"ok": False}, "buckets": mn.get("buckets") or []},
        },
        "ingestion": {"airbyte": ing},
      }

    @app.get("/api/health")
    def api_health():
      return jsonify({"ok": True, "ts": now_iso()})

    @app.get("/api/catalog")
    def api_catalog():
      s = build_summary()
      return jsonify({"catalog": s["catalog"], "meta": s["meta"], "links": s["links"], "apps": s["apps"]})

    @app.get("/api/ingestion")
    def api_ingestion():
      s = build_summary()
      return jsonify({"ingestion": s["ingestion"], "meta": s["meta"], "links": s["links"], "apps": s["apps"]})

    @app.get("/api/summary")
    def api_summary():
      return jsonify(build_summary())

    @app.get("/")
    def root():
      return jsonify({"ok": True, "service": "portal-api", "ts": now_iso()})

  requirements.txt: |
    Flask==3.0.3
    gunicorn==22.0.0
    kubernetes==30.1.0
    boto3==1.34.162
    botocore==1.34.162
    psycopg2-binary==2.9.9
    requests==2.32.3
YAML

log "Restart API deployment to pick up new ConfigMap"
kubectl -n "${PLATFORM_NS}" rollout restart "deployment/${API_DEPLOY}"
kubectl -n "${PLATFORM_NS}" rollout status "deployment/${API_DEPLOY}" --timeout=240s

log "TEST 1: /api/health"
curl -sk "https://${PORTAL_HOST}/api/health" | python3 - <<'PY'
import json,sys
d=json.load(sys.stdin)
assert d.get("ok") is True
print("OK")
PY

log "TEST 2: /api/summary includes apps[] with expected ids + statuses"
curl -sk "https://${PORTAL_HOST}/api/summary?v=1" | python3 - <<'PY'
import json,sys
d=json.load(sys.stdin)
apps=d.get("apps") or []
ids=set(a.get("id") for a in apps)
need={"platform","minio","metabase","n8n","zammad","airbyte","dbt"}
missing=need-ids
assert not missing, f"missing app ids: {sorted(missing)}"
allowed={"healthy","degraded","down","not_installed"}
bad=[(a.get("id"),a.get("status")) for a in apps if a.get("status") not in allowed]
assert not bad, f"bad statuses: {bad}"
print("OK")
PY

log "TEST 3: show compact app table"
curl -sk "https://${PORTAL_HOST}/api/summary?v=1" | python3 - <<'PY'
import json,sys
d=json.load(sys.stdin)
apps=d.get("apps") or []
for a in apps:
  print(f'{a.get("id"):9} {a.get("status"):13} {a.get("k8s",{}).get("namespace",""):10} {a.get("reason","")}')
PY

log "Done"
