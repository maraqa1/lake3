#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 04-portal-api-v2.sh — OpenKPI Portal API (Flask) — PRODUCTION / REPEATABLE
#
# - Namespace: platform (default)
# - Endpoints: /api/health, /api/catalog, /api/ingestion, /api/summary
# - Repeatable / idempotent
#
# Secret compatibility:
# - Postgres secret schemas:
#     A) POSTGRES_DB / POSTGRES_USER / POSTGRES_PASSWORD
#     B) db / username / password / host / port
# - MinIO secret schemas:
#     A) MINIO_ROOT_USER / MINIO_ROOT_PASSWORD
#     B) rootUser/rootPassword OR accesskey/secretkey OR AWS_* variants
#
# App state model:
# - Emits summary.apps[] with: healthy | degraded | down | not_installed
# - FIX: per-app workload-based health (no namespace-wide false degradation)
#   * minio: openkpi-minio StatefulSet readiness
#   * dbt:  dbt Deployment readiness (ignores cronjob/job pods)
#   * n8n:  n8n Deployment readiness + only-current-ReplicaSet pod checks
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/00-env.sh"
# shellcheck source=/dev/null
. "${HERE}/00-lib.sh"

require_cmd kubectl

PLATFORM_NS="${PLATFORM_NS:-platform}"
OPENKPI_NS="${OPENKPI_NS:-${NS:-open-kpi}}"

: "${INGRESS_CLASS:=nginx}"
: "${TLS_MODE:=per-host-http01}"     # off | per-host-http01
: "${PORTAL_HOST:=${PORTAL_HOST:-}}"
[[ -n "${PORTAL_HOST}" ]] || fatal "PORTAL_HOST not set in /root/open-kpi.env"

API_NAME="portal-api"
API_SA="portal-api-sa"
API_CM="portal-api-code"
API_SECRET="portal-api-secrets"
API_DEPLOY="${API_NAME}"
API_SVC="${API_NAME}"

MINIO_SECRET_SRC="${MINIO_SECRET_SRC:-openkpi-minio-secret}"
PG_SECRET_SRC="${PG_SECRET_SRC:-openkpi-postgres-secret}"

# Defaults if secret doesn't provide host/port (internal cluster DNS)
MINIO_ENDPOINT_INTERNAL_DEFAULT="http://openkpi-minio.${OPENKPI_NS}.svc.cluster.local:9000"
PG_HOST_INTERNAL_DEFAULT="openkpi-postgres.${OPENKPI_NS}.svc.cluster.local"
PG_PORT_INTERNAL_DEFAULT="5432"

ensure_ns "${PLATFORM_NS}"

b64dec() { printf '%s' "$1" | base64 -d 2>/dev/null || true; }

get_secret_key_b64() {
  local ns="$1" secret="$2" key="$3"
  kubectl -n "${ns}" get secret "${secret}" -o "jsonpath={.data.${key}}" 2>/dev/null || true
}

get_secret_first_b64() {
  local ns="$1" secret="$2"; shift 2
  local key val
  for key in "$@"; do
    val="$(get_secret_key_b64 "$ns" "$secret" "$key")"
    if [[ -n "${val}" ]]; then
      printf '%s' "${val}"
      return 0
    fi
  done
  return 0
}

get_secret_first_dec() {
  local ns="$1" secret="$2"; shift 2
  b64dec "$(get_secret_first_b64 "$ns" "$secret" "$@")"
}

# ------------------------------------------------------------------------------
# MinIO creds (multi-schema)
# ------------------------------------------------------------------------------
MINIO_ROOT_USER="$(get_secret_first_dec "${OPENKPI_NS}" "${MINIO_SECRET_SRC}" \
  "MINIO_ROOT_USER" "rootUser" "accesskey" "AWS_ACCESS_KEY_ID" "S3_ACCESS_KEY" "s3-access-key-id")"

MINIO_ROOT_PASSWORD="$(get_secret_first_dec "${OPENKPI_NS}" "${MINIO_SECRET_SRC}" \
  "MINIO_ROOT_PASSWORD" "rootPassword" "secretkey" "AWS_SECRET_ACCESS_KEY" "S3_SECRET_KEY" "s3-secret-access-key")"

MINIO_ENDPOINT_SECRET="$(get_secret_first_dec "${OPENKPI_NS}" "${MINIO_SECRET_SRC}" \
  "MINIO_ENDPOINT" "S3_ENDPOINT" "endpoint")"

MINIO_ENDPOINT_INTERNAL="${MINIO_ENDPOINT_INTERNAL:-${MINIO_ENDPOINT_SECRET:-${MINIO_ENDPOINT_INTERNAL_DEFAULT}}}"

: "${MINIO_ROOT_USER:=}"
: "${MINIO_ROOT_PASSWORD:=}"

# ------------------------------------------------------------------------------
# Postgres connection (multi-schema)
# Your openkpi-postgres-secret keys currently: db/username/password/host/port
# ------------------------------------------------------------------------------
PG_DB="$(get_secret_first_dec "${OPENKPI_NS}" "${PG_SECRET_SRC}" "POSTGRES_DB" "db")"
PG_USER="$(get_secret_first_dec "${OPENKPI_NS}" "${PG_SECRET_SRC}" "POSTGRES_USER" "username")"
PG_PASSWORD="$(get_secret_first_dec "${OPENKPI_NS}" "${PG_SECRET_SRC}" "POSTGRES_PASSWORD" "password")"

PG_HOST_SECRET="$(get_secret_first_dec "${OPENKPI_NS}" "${PG_SECRET_SRC}" "PG_HOST" "POSTGRES_HOST" "host")"
PG_PORT_SECRET="$(get_secret_first_dec "${OPENKPI_NS}" "${PG_SECRET_SRC}" "PG_PORT" "POSTGRES_PORT" "port")"

PG_HOST_INTERNAL="${PG_HOST_INTERNAL:-${PG_HOST_SECRET:-${PG_HOST_INTERNAL_DEFAULT}}}"
PG_PORT_INTERNAL="${PG_PORT_INTERNAL:-${PG_PORT_SECRET:-${PG_PORT_INTERNAL_DEFAULT}}}"

: "${PG_DB:=postgres}"
: "${PG_USER:=postgres}"
: "${PG_PASSWORD:=}"

[[ -n "${PG_PASSWORD}" ]] || fatal "missing Postgres password in ${OPENKPI_NS}/${PG_SECRET_SRC} (expected POSTGRES_PASSWORD or password)"
[[ -n "${PG_HOST_INTERNAL}" ]] || fatal "missing Postgres host"
[[ -n "${PG_PORT_INTERNAL}" ]] || fatal "missing Postgres port"

if [[ -z "${MINIO_ROOT_USER}" || -z "${MINIO_ROOT_PASSWORD}" ]]; then
  warn "MinIO credentials not found in ${OPENKPI_NS}/${MINIO_SECRET_SRC}; MinIO catalog will report unavailable"
fi

# ------------------------------------------------------------------------------
# API runtime config secret (platform namespace)
# ------------------------------------------------------------------------------
apply_yaml "$(cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${API_SECRET}
  namespace: ${PLATFORM_NS}
type: Opaque
stringData:
  TLS_MODE: "${TLS_MODE}"
  PORTAL_HOST: "${PORTAL_HOST}"
  INGRESS_CLASS: "${INGRESS_CLASS}"
  OPENKPI_NS: "${OPENKPI_NS}"
  PLATFORM_NS: "${PLATFORM_NS}"

  MINIO_ENDPOINT: "${MINIO_ENDPOINT_INTERNAL}"
  MINIO_ACCESS_KEY: "${MINIO_ROOT_USER}"
  MINIO_SECRET_KEY: "${MINIO_ROOT_PASSWORD}"

  PG_HOST: "${PG_HOST_INTERNAL}"
  PG_PORT: "${PG_PORT_INTERNAL}"
  PG_DB: "${PG_DB}"
  PG_USER: "${PG_USER}"
  PG_PASSWORD: "${PG_PASSWORD}"
EOF
)"

# ------------------------------------------------------------------------------
# API code + requirements ConfigMap  (REPLACEMENT BLOCK for 04-portal-api-v2.sh)
# ------------------------------------------------------------------------------
apply_yaml "$(cat <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: portal-api-code
  namespace: platform
data:
  app.py: |
    import os, datetime
    from typing import Dict, Any, Optional, List, Tuple

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
    # K8s helpers (workload-scoped; avoids namespace-wide false degradation)
    # -----------------------------
    def _k8s() -> Optional[Any]:
      return load_k8s()

    def _ns_exists(v1, ns: str) -> bool:
      try:
        v1.read_namespace(ns)
        return True
      except Exception:
        return False

    def _deployment_status(apps, ns: str, name: str) -> Optional[Dict[str, Any]]:
      try:
        d = apps.read_namespaced_deployment(name, ns)
        spec = int(d.spec.replicas or 0)
        ready = int(d.status.ready_replicas or 0)
        avail = int(d.status.available_replicas or 0)
        updated = int(d.status.updated_replicas or 0)
        return {"replicas": spec, "ready": ready, "available": avail, "updated": updated}
      except Exception:
        return None

    def _statefulset_status(apps, ns: str, name: str) -> Optional[Dict[str, Any]]:
      try:
        s = apps.read_namespaced_stateful_set(name, ns)
        spec = int(s.spec.replicas or 0)
        ready = int(s.status.ready_replicas or 0)
        current = int(s.status.current_replicas or 0)
        updated = int(s.status.updated_replicas or 0)
        return {"replicas": spec, "ready": ready, "current": current, "updated": updated}
      except Exception:
        return None

    def _current_rs_hash_for_deployment(apps, ns: str, deploy_name: str) -> Optional[str]:
      # Newest ReplicaSet owned by deploy_name => its pod-template-hash.
      try:
        rss = apps.list_namespaced_replica_set(ns).items
      except Exception:
        return None

      owned: List[Tuple[int, Any]] = []
      for rs in rss:
        owners = rs.metadata.owner_references or []
        if not any(o.kind == "Deployment" and o.name == deploy_name for o in owners):
          continue
        rev = rs.metadata.annotations.get("deployment.kubernetes.io/revision", "0") if rs.metadata.annotations else "0"
        try:
          rev_i = int(rev)
        except Exception:
          rev_i = 0
        owned.append((rev_i, rs))

      if not owned:
        return None
      owned.sort(key=lambda t: t[0], reverse=True)
      rs = owned[0][1]
      labels = rs.spec.selector.match_labels or {}
      return labels.get("pod-template-hash")

    def _pods_for_selector(v1, ns: str, selector: str) -> List[Any]:
      try:
        return v1.list_namespaced_pod(ns, label_selector=selector).items
      except Exception:
        return []

    def _pod_ready(p) -> bool:
      cs = p.status.container_statuses or []
      return all([(c.ready is True) for c in cs]) if cs else False

    def _pod_is_bad(p) -> bool:
      # Ignore completed/terminated job pods and terminating pods
      if p.metadata.deletion_timestamp is not None:
        return False
      phase = (p.status.phase or "")
      if phase in ("Succeeded",):
        return False

      cs = p.status.container_statuses or []
      for c in cs:
        if c.state and c.state.waiting and (c.state.waiting.reason or "") in ("CrashLoopBackOff", "Error"):
          return True
        if (c.ready is False) and phase in ("Running", "Pending"):
          return True

      if not cs and phase not in ("Running", "Succeeded"):
        return True
      return False

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

      k8s = _k8s()
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
    # Postgres + MinIO catalogs
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
    # Airbyte (optional runtime signal)
    # -----------------------------
    def airbyte_ingestion() -> Dict[str, Any]:
      k8s = _k8s()
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
    # App states (workload-scoped) + n8n enhancement (current ReplicaSet only)
    # -----------------------------
    def _status_from_deploy(apps, ns: str, name: str) -> Tuple[str, str, Dict[str, Any]]:
      st = _deployment_status(apps, ns, name)
      if st is None:
        return ("not_installed", "deployment not found", {"deployment": name})
      replicas = int(st["replicas"])
      ready = int(st["ready"])
      updated = int(st["updated"])
      if replicas == 0:
        return ("down", "replicas=0", {"deployment": name, **st})
      if ready < replicas or updated < replicas:
        return ("degraded", "deployment not fully ready/updated", {"deployment": name, **st})
      return ("healthy", "OK", {"deployment": name, **st})

    def _status_from_sts(apps, ns: str, name: str) -> Tuple[str, str, Dict[str, Any]]:
      st = _statefulset_status(apps, ns, name)
      if st is None:
        return ("not_installed", "statefulset not found", {"statefulset": name})
      replicas = int(st["replicas"])
      ready = int(st["ready"])
      if replicas == 0:
        return ("down", "replicas=0", {"statefulset": name, **st})
      if ready < replicas:
        return ("degraded", "statefulset not fully ready", {"statefulset": name, **st})
      return ("healthy", "OK", {"statefulset": name, **st})

    def _status_n8n_precise(k8s, ns: str = "n8n", deploy: str = "n8n") -> Tuple[str, str, Dict[str, Any]]:
      v1 = k8s.CoreV1Api()
      apps = k8s.AppsV1Api()

      if not _ns_exists(v1, ns):
        return ("not_installed", "namespace not found", {"namespace": ns})

      st = _deployment_status(apps, ns, deploy)
      if st is None:
        return ("not_installed", "deployment not found", {"namespace": ns, "deployment": deploy})

      replicas = int(st["replicas"])
      ready = int(st["ready"])
      updated = int(st["updated"])

      rs_hash = _current_rs_hash_for_deployment(apps, ns, deploy)
      selector = "app=n8n"
      if rs_hash:
        selector = f"app=n8n,pod-template-hash={rs_hash}"

      pods = _pods_for_selector(v1, ns, selector)
      pods_total = len(pods)
      pods_ready = sum(1 for p in pods if _pod_ready(p))
      bad = [p.metadata.name for p in pods if _pod_is_bad(p)]

      detail = {
        "namespace": ns,
        "deployment": deploy,
        "replicas": replicas,
        "ready": ready,
        "updated": updated,
        "pod_selector": selector,
        "pods_total": pods_total,
        "pods_ready": pods_ready,
        "bad_pods": bad[:10],
      }

      if replicas == 0:
        return ("down", "replicas=0", detail)
      if bad:
        return ("degraded", "current ReplicaSet pods unhealthy", detail)
      if ready < replicas or updated < replicas:
        return ("degraded", "deployment not fully ready/updated", detail)
      return ("healthy", "OK", detail)

    def build_apps(links: Dict[str, str]) -> List[Dict[str, Any]]:
      k8s = _k8s()
      out: List[Dict[str, Any]] = []

      openkpi_ns = env("OPENKPI_NS","open-kpi")
      platform_ns = env("PLATFORM_NS","platform")

      defs = [
        {"id":"platform", "display":"Platform Operations", "category":"core", "optional": False, "kind":"deploy", "ns":platform_ns, "name":"portal-ui", "open": links.get("portal","")},
        {"id":"minio", "display":"Object Storage", "category":"core", "optional": False, "kind":"sts", "ns":openkpi_ns, "name":"openkpi-minio", "open": links.get("minio","")},

        {"id":"metabase", "display":"Analytics & BI", "category":"apps", "optional": True, "kind":"deploy", "ns":"analytics", "name":"metabase", "open": links.get("metabase","")},
        {"id":"n8n", "display":"Workflow Automation", "category":"apps", "optional": True, "kind":"n8n",  "ns":"n8n", "name":"n8n", "open": links.get("n8n","")},
        {"id":"zammad", "display":"ITSM / Ticketing", "category":"apps", "optional": True, "kind":"deploy", "ns":"tickets", "name":"zammad-nginx", "open": links.get("zammad","")},
        {"id":"airbyte", "display":"Data Ingestion", "category":"apps", "optional": True, "kind":"deploy", "ns":"airbyte", "name":"airbyte-server", "open": links.get("airbyte","")},
        {"id":"dbt", "display":"Data Transformation", "category":"apps", "optional": True, "kind":"deploy", "ns":"transform", "name":"dbt", "open": links.get("dbt","")},
      ]

      if k8s is None:
        for d in defs:
          out.append({
            "id": d["id"],
            "display": d["display"],
            "category": d["category"],
            "status": ("down" if not d["optional"] else "not_installed"),
            "reason": "kubernetes client unavailable",
            "k8s": {"namespace": d["ns"], "workload": d["name"]},
            "links": {"open": d.get("open","")}
          })
        return out

      v1 = k8s.CoreV1Api()
      apps = k8s.AppsV1Api()

      for d in defs:
        ns = d["ns"]
        name = d["name"]
        optional = bool(d["optional"])

        if not _ns_exists(v1, ns):
          status = "not_installed" if optional else "down"
          out.append({
            "id": d["id"], "display": d["display"], "category": d["category"],
            "status": status, "reason": "namespace not found",
            "k8s": {"namespace": ns, "workload": name},
            "links": {"open": d.get("open","")}
          })
          continue

        if d["kind"] == "sts":
          st, reason, detail = _status_from_sts(apps, ns, name)
        elif d["kind"] == "deploy":
          st, reason, detail = _status_from_deploy(apps, ns, name)
        elif d["kind"] == "n8n":
          st, reason, detail = _status_n8n_precise(k8s, ns=ns, deploy=name)
        else:
          st, reason, detail = ("degraded", "unknown workload kind", {"namespace": ns, "workload": name})

        if optional and st == "down":
          st = "not_installed"
          reason = "optional workload not present"

        out.append({
          "id": d["id"],
          "display": d["display"],
          "category": d["category"],
          "status": st,
          "reason": reason,
          "k8s": {"namespace": ns, "workload": name, "detail": detail},
          "links": {"open": d.get("open","")}
        })

      return out

    def build_summary() -> Dict[str, Any]:
      links = build_links()
      pg = pg_catalog()
      mn = minio_catalog()
      ing = airbyte_ingestion()
      apps = build_apps(links)

      return {
        "meta": {"generated_at": now_iso(), "version": "1.2"},
        "links": links,
        "apps": apps,
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
EOF
)"


# RBAC (needs list/read for apps/pods/rs/ingresses)
apply_yaml "$(cat <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${API_SA}
  namespace: ${PLATFORM_NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${API_NAME}-cr
rules:
  - apiGroups: [""]
    resources: ["namespaces","pods","services","endpoints"]
    verbs: ["get","list","watch"]
  - apiGroups: ["apps"]
    resources: ["deployments","statefulsets","replicasets"]
    verbs: ["get","list","watch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get","list","watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${API_NAME}-crb
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${API_NAME}-cr
subjects:
  - kind: ServiceAccount
    name: ${API_SA}
    namespace: ${PLATFORM_NS}
EOF
)"

# Deployment + Service
apply_yaml "$(cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${API_DEPLOY}
  namespace: ${PLATFORM_NS}
  labels:
    app: ${API_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${API_NAME}
  template:
    metadata:
      labels:
        app: ${API_NAME}
    spec:
      serviceAccountName: ${API_SA}
      securityContext:
        fsGroup: 1000
      volumes:
        - name: code
          configMap:
            name: ${API_CM}
        - name: work
          emptyDir: {}
      containers:
        - name: ${API_NAME}
          image: python:3.12-slim
          imagePullPolicy: IfNotPresent
          securityContext:
            runAsUser: 1000
            runAsGroup: 1000
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
          envFrom:
            - secretRef:
                name: ${API_SECRET}
          env:
            - name: PYTHONUNBUFFERED
              value: "1"
          ports:
            - name: http
              containerPort: 8080
          volumeMounts:
            - name: code
              mountPath: /app
              readOnly: true
            - name: work
              mountPath: /work
          command: ["/bin/sh","-lc"]
          args:
            - |
              set -euo pipefail
              python -m venv /work/venv
              . /work/venv/bin/activate
              pip install --no-cache-dir -r /app/requirements.txt
              exec gunicorn -w 2 -k gthread -t 30 -b 0.0.0.0:8080 --chdir /app app:app
          readinessProbe:
            httpGet:
              path: /api/health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 6
          livenessProbe:
            httpGet:
              path: /api/health
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 20
            timeoutSeconds: 2
            failureThreshold: 6
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: ${API_SVC}
  namespace: ${PLATFORM_NS}
  labels:
    app: ${API_NAME}
spec:
  selector:
    app: ${API_NAME}
  ports:
    - name: http
      port: 80
      targetPort: 8080
  type: ClusterIP
EOF
)"

kubectl_wait_deploy "${PLATFORM_NS}" "${API_DEPLOY}" "240s"
log "[04][PORTAL-API] Ready: https://${PORTAL_HOST}/api/summary?v=1"
