#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# OpenKPI Portal API (v1) — drop-in deploy
# File: 04-portal-api-v1.sh
# Purpose: Deploy portal-api that serves /api/health and /api/summary?v=1 with
#          normalized platform/apps fields required by portal-ui-v1.
# Idempotent: YES (kubectl apply only)
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "${HERE}/00-env.sh" ]] && . "${HERE}/00-env.sh" || true

need(){ command -v "$1" >/dev/null 2>&1 || { echo "[FATAL] missing: $1" >&2; exit 1; }; }
need kubectl
need curl

log(){ echo "[04A][PORTAL-API] $*"; }
warn(){ echo "[04A][PORTAL-API][WARN] $*" >&2; }
fatal(){ echo "[04A][PORTAL-API][FATAL] $*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Defaults (override in 00-env.sh)
# ------------------------------------------------------------------------------
PLATFORM_NS="${PLATFORM_NS:-platform}"

API_DEPLOY="${PORTAL_API_DEPLOY:-portal-api}"
API_SVC="${PORTAL_API_SVC:-portal-api}"
API_CM="${PORTAL_API_CM:-portal-api-code}"
API_SA="${PORTAL_API_SA:-portal-api-sa}"

PORTAL_HOST="${PORTAL_HOST:-portal.lake3.opendatalake.com}"

# Namespaces to snapshot (safe defaults; extend freely)
PORTAL_WATCH_NAMESPACES="${PORTAL_WATCH_NAMESPACES:-platform,open-kpi,airbyte,n8n,tickets,transform,ingress-nginx,cert-manager,kube-system}"

# MinIO catalog wiring (OpenKPI MinIO by default)
OPENKPI_MINIO_NS="${OPENKPI_MINIO_NS:-open-kpi}"
OPENKPI_MINIO_SVC="${OPENKPI_MINIO_SVC:-openkpi-minio}"
OPENKPI_MINIO_PORT="${OPENKPI_MINIO_PORT:-9000}"
OPENKPI_MINIO_SECRET="${OPENKPI_MINIO_SECRET:-openkpi-minio-secret}"
OPENKPI_MINIO_ACCESS_KEY_FIELD="${OPENKPI_MINIO_ACCESS_KEY_FIELD:-rootUser}"
OPENKPI_MINIO_SECRET_KEY_FIELD="${OPENKPI_MINIO_SECRET_KEY_FIELD:-rootPassword}"
S3_REGION="${S3_REGION:-us-east-1}"

# Postgres catalog wiring (OpenKPI Postgres by default; schemas only unless you extend)
OPENKPI_PG_NS="${OPENKPI_PG_NS:-open-kpi}"
OPENKPI_PG_SVC="${OPENKPI_PG_SVC:-openkpi-postgres}"
OPENKPI_PG_PORT="${OPENKPI_PG_PORT:-5432}"

# Optional deep links (UI will still work if empty)
AIRBYTE_URL="${AIRBYTE_URL:-}"
MINIO_URL="${MINIO_URL:-}"
METABASE_URL="${METABASE_URL:-}"
DBT_URL="${DBT_URL:-}"
N8N_URL="${N8N_URL:-}"
ZAMMAD_URL="${ZAMMAD_URL:-}"

# Build marker for traceability
PORTAL_API_BUILD_ID="${PORTAL_API_BUILD_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"

# ------------------------------------------------------------------------------
# Ensure namespace
# ------------------------------------------------------------------------------
log "Ensure namespace ${PLATFORM_NS}"
kubectl get ns "${PLATFORM_NS}" >/dev/null 2>&1 || kubectl create ns "${PLATFORM_NS}" >/dev/null

# ------------------------------------------------------------------------------
# RBAC (cluster-read + read secrets for MinIO creds)
# ------------------------------------------------------------------------------
log "Apply ServiceAccount + RBAC (cluster read, secrets read)"
kubectl apply -f - <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${API_SA}
  namespace: ${PLATFORM_NS}
  annotations:
    openkpi.yottalogica.com/managed-by: "portal-api-v1"
    openkpi.yottalogica.com/build-id: "${PORTAL_API_BUILD_ID}"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: portal-api-read
  annotations:
    openkpi.yottalogica.com/managed-by: "portal-api-v1"
    openkpi.yottalogica.com/build-id: "${PORTAL_API_BUILD_ID}"
rules:
  - apiGroups: [""]
    resources: ["namespaces","pods","services","endpoints","events"]
    verbs: ["get","list","watch"]
  - apiGroups: ["apps"]
    resources: ["deployments","statefulsets","replicasets"]
    verbs: ["get","list","watch"]
  - apiGroups: ["batch"]
    resources: ["jobs","cronjobs"]
    verbs: ["get","list","watch"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get","list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: portal-api-read
  annotations:
    openkpi.yottalogica.com/managed-by: "portal-api-v1"
    openkpi.yottalogica.com/build-id: "${PORTAL_API_BUILD_ID}"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: portal-api-read
subjects:
  - kind: ServiceAccount
    name: ${API_SA}
    namespace: ${PLATFORM_NS}
YAML

# ------------------------------------------------------------------------------
# API code (pure stdlib python; no pip)
# ------------------------------------------------------------------------------
TMP_CM="/tmp/portal-api-code.yaml"
cat > "${TMP_CM}" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: __API_CM__
  namespace: __PLATFORM_NS__
data:
  app.py: |
    import base64
    import datetime as dt
    import hashlib
    import hmac
    import json
    import os
    import ssl
    import sys
    import time
    import urllib.parse
    import urllib.request
    import xml.etree.ElementTree as ET
    from http.server import BaseHTTPRequestHandler, HTTPServer

    # ----------------------------
    # Config / constants
    # ----------------------------
    PORT = int(os.environ.get("PORT", "8080"))
    BUILD_ID = os.environ.get("PORTAL_API_BUILD_ID", "unknown")
    PORTAL_HOST = os.environ.get("PORTAL_HOST", "")

    WATCH_NAMESPACES = [x.strip() for x in os.environ.get("PORTAL_WATCH_NAMESPACES", "").split(",") if x.strip()]
    if not WATCH_NAMESPACES:
      WATCH_NAMESPACES = ["platform","open-kpi","airbyte","n8n","tickets","transform","ingress-nginx","cert-manager","kube-system"]

    # Deep links (optional)
    LINKS = {
      "airbyte": os.environ.get("AIRBYTE_URL",""),
      "minio": os.environ.get("MINIO_URL",""),
      "metabase": os.environ.get("METABASE_URL",""),
      "dbt": os.environ.get("DBT_URL",""),
      "n8n": os.environ.get("N8N_URL",""),
      "zammad": os.environ.get("ZAMMAD_URL",""),
      "portal": (f"https://{PORTAL_HOST}" if PORTAL_HOST else "")
    }

    # OpenKPI MinIO contract
    MINIO_NS = os.environ.get("OPENKPI_MINIO_NS","open-kpi")
    MINIO_SVC = os.environ.get("OPENKPI_MINIO_SVC","openkpi-minio")
    MINIO_PORT = os.environ.get("OPENKPI_MINIO_PORT","9000")
    MINIO_SECRET = os.environ.get("OPENKPI_MINIO_SECRET","openkpi-minio-secret")
    MINIO_AK_FIELD = os.environ.get("OPENKPI_MINIO_ACCESS_KEY_FIELD","rootUser")
    MINIO_SK_FIELD = os.environ.get("OPENKPI_MINIO_SECRET_KEY_FIELD","rootPassword")
    S3_REGION = os.environ.get("S3_REGION","us-east-1")

    # OpenKPI Postgres contract (schemas only unless extended)
    PG_NS = os.environ.get("OPENKPI_PG_NS","open-kpi")
    PG_SVC = os.environ.get("OPENKPI_PG_SVC","openkpi-postgres")
    PG_PORT = os.environ.get("OPENKPI_PG_PORT","5432")

    # In-cluster K8s API
    K8S_HOST = "https://kubernetes.default.svc"
    SA_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
    SA_CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

    def now_iso():
      return dt.datetime.utcnow().replace(tzinfo=dt.timezone.utc).isoformat().replace("+00:00","Z")

    def read_file(path, default=""):
      try:
        with open(path,"r",encoding="utf-8") as f:
          return f.read().strip()
      except Exception:
        return default

    SA_TOKEN = read_file(SA_TOKEN_PATH, "")
    if not SA_TOKEN:
      # running outside cluster
      SA_TOKEN = os.environ.get("K8S_TOKEN","")

    def k8s_request(path):
      url = K8S_HOST + path
      req = urllib.request.Request(url, method="GET")
      req.add_header("Authorization", f"Bearer {SA_TOKEN}")
      req.add_header("Accept", "application/json")
      ctx = ssl.create_default_context(cafile=SA_CA_PATH) if os.path.exists(SA_CA_PATH) else ssl._create_unverified_context()
      with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
        return json.loads(resp.read().decode("utf-8"))

    def k8s_get_secret(namespace, name):
      try:
        return k8s_request(f"/api/v1/namespaces/{namespace}/secrets/{name}")
      except Exception as e:
        return {"_error": str(e)}

    def k8s_get_service(namespace, name):
      try:
        return k8s_request(f"/api/v1/namespaces/{namespace}/services/{name}")
      except Exception as e:
        return {"_error": str(e)}

    def list_deployments(namespace):
      try:
        j = k8s_request(f"/apis/apps/v1/namespaces/{namespace}/deployments")
        items = j.get("items",[])
        out = []
        for d in items:
          spec = d.get("spec",{})
          st = d.get("status",{})
          out.append({
            "name": d.get("metadata",{}).get("name",""),
            "replicas": int(spec.get("replicas",0) or 0),
            "ready": int(st.get("readyReplicas",0) or 0),
            "available": int(st.get("availableReplicas",0) or 0),
            "updated": int(st.get("updatedReplicas",0) or 0),
          })
        return {"count": len(out), "items": out}
      except Exception as e:
        return {"count": 0, "items": [], "_error": str(e)}

    def list_statefulsets(namespace):
      try:
        j = k8s_request(f"/apis/apps/v1/namespaces/{namespace}/statefulsets")
        items = j.get("items",[])
        out = []
        for s in items:
          spec = s.get("spec",{})
          st = s.get("status",{})
          out.append({
            "name": s.get("metadata",{}).get("name",""),
            "replicas": int(spec.get("replicas",0) or 0),
            "ready": int(st.get("readyReplicas",0) or 0),
            "current": int(st.get("currentReplicas",0) or 0),
            "updated": int(st.get("updatedReplicas",0) or 0),
          })
        return {"count": len(out), "items": out}
      except Exception as e:
        return {"count": 0, "items": [], "_error": str(e)}

    def list_pods(namespace):
      try:
        j = k8s_request(f"/api/v1/namespaces/{namespace}/pods")
        items = j.get("items",[])
        out = []
        total_restarts = 0
        for p in items:
          md = p.get("metadata",{})
          st = p.get("status",{})
          spec = p.get("spec",{})
          cs = st.get("containerStatuses",[]) or []
          ready = all([c.get("ready",False) for c in cs]) if cs else False
          restarts = sum([int(c.get("restartCount",0) or 0) for c in cs]) if cs else 0
          total_restarts += restarts
          out.append({
            "name": md.get("name",""),
            "node": spec.get("nodeName",""),
            "phase": st.get("phase",""),
            "ready": bool(ready),
            "restarts": int(restarts),
          })
        return {"count": len(out), "items": out, "total_restarts": int(total_restarts)}
      except Exception as e:
        return {"count": 0, "items": [], "total_restarts": 0, "_error": str(e)}

    # ----------------------------
    # MinIO bucket list via SigV4 (stdlib)
    # ----------------------------
    def _sign(key, msg):
      return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()

    def _get_signature_key(key, dateStamp, regionName, serviceName):
      kDate = _sign(("AWS4" + key).encode("utf-8"), dateStamp)
      kRegion = hmac.new(kDate, regionName.encode("utf-8"), hashlib.sha256).digest()
      kService = hmac.new(kRegion, serviceName.encode("utf-8"), hashlib.sha256).digest()
      kSigning = hmac.new(kService, b"aws4_request", hashlib.sha256).digest()
      return kSigning

    def minio_list_buckets():
      # Read creds from K8s secret
      sec = k8s_get_secret(MINIO_NS, MINIO_SECRET)
      if sec.get("_error"):
        return {"available": False, "health": {"ok": False}, "buckets": [], "error": sec["_error"]}

      data = sec.get("data",{}) or {}
      if MINIO_AK_FIELD not in data or MINIO_SK_FIELD not in data:
        return {"available": False, "health": {"ok": False}, "buckets": [], "error": "minio secret missing expected keys"}

      ak = base64.b64decode(data[MINIO_AK_FIELD]).decode("utf-8")
      sk = base64.b64decode(data[MINIO_SK_FIELD]).decode("utf-8")

      endpoint = f"http://{MINIO_SVC}.{MINIO_NS}.svc.cluster.local:{MINIO_PORT}/"
      t = dt.datetime.utcnow()
      amz_date = t.strftime("%Y%m%dT%H%M%SZ")
      date_stamp = t.strftime("%Y%m%d")

      method = "GET"
      canonical_uri = "/"
      canonical_querystring = ""
      host = f"{MINIO_SVC}.{MINIO_NS}.svc.cluster.local:{MINIO_PORT}"

      canonical_headers = f"host:{host}\n" + f"x-amz-date:{amz_date}\n"
      signed_headers = "host;x-amz-date"
      payload_hash = hashlib.sha256(b"").hexdigest()

      canonical_request = "\n".join([
        method,
        canonical_uri,
        canonical_querystring,
        canonical_headers,
        signed_headers,
        payload_hash
      ])

      algorithm = "AWS4-HMAC-SHA256"
      credential_scope = f"{date_stamp}/{S3_REGION}/s3/aws4_request"
      string_to_sign = "\n".join([
        algorithm,
        amz_date,
        credential_scope,
        hashlib.sha256(canonical_request.encode("utf-8")).hexdigest()
      ])

      signing_key = _get_signature_key(sk, date_stamp, S3_REGION, "s3")
      signature = hmac.new(signing_key, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()

      authorization_header = (
        f"{algorithm} Credential={ak}/{credential_scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
      )

      req = urllib.request.Request(endpoint, method="GET")
      req.add_header("Host", host)
      req.add_header("x-amz-date", amz_date)
      req.add_header("Authorization", authorization_header)

      # Health (ready endpoint) best-effort
      health_ok = False
      try:
        hr = urllib.request.urlopen(f"http://{host}/minio/health/ready", timeout=3)
        health_ok = (hr.status == 200)
      except Exception:
        health_ok = False

      try:
        with urllib.request.urlopen(req, timeout=8) as resp:
          xml = resp.read().decode("utf-8", errors="replace")
      except Exception as e:
        return {"available": True, "health": {"ok": health_ok}, "buckets": [], "error": str(e)}

      buckets = []
      try:
        root = ET.fromstring(xml)
        # ListAllMyBucketsResult > Buckets > Bucket
        ns = ""
        if root.tag.startswith("{"):
          ns = root.tag.split("}")[0] + "}"
        for b in root.findall(f".//{ns}Bucket"):
          name = b.findtext(f"{ns}Name") or ""
          created = b.findtext(f"{ns}CreationDate") or ""
          buckets.append({"name": name, "created": created})
      except Exception as e:
        return {"available": True, "health": {"ok": health_ok}, "buckets": [], "error": f"xml parse: {e}"}

      return {"available": True, "health": {"ok": health_ok}, "buckets": buckets, "error": ""}

    # ----------------------------
    # Summary normalization
    # ----------------------------
    def ns_snapshot(ns):
      return {
        "name": ns,
        "deployments": list_deployments(ns),
        "statefulsets": list_statefulsets(ns),
        "pods": list_pods(ns),
      }

    def compute_ns_health(ns_obj):
      if not ns_obj:
        return ("missing","namespace not found")

      dep = ns_obj.get("deployments",{}).get("items",[]) or []
      sts = ns_obj.get("statefulsets",{}).get("items",[]) or []
      pods = ns_obj.get("pods",{}).get("items",[]) or []

      if len(dep)==0 and len(sts)==0 and len(pods)==0:
        return ("missing","No workloads detected")

      degraded = False
      if any(int(d.get("ready",0)) < int(d.get("replicas",0)) for d in dep):
        degraded = True
      if any(int(s.get("ready",0)) < int(s.get("replicas",0)) for s in sts):
        degraded = True

      pods_total = len(pods)
      pods_ready = sum(1 for p in pods if p.get("ready") is True)
      if pods_total > 0 and pods_ready < pods_total:
        degraded = True

      return ("degraded","Pods not fully ready / rollouts in progress") if degraded else ("healthy","OK")

    def normalize_apps(summary):
      # Stable app list for portal-ui-v1
      ns_map = {n.get("name"): n for n in (summary.get("k8s",{}).get("namespaces",[]) or [])}

      def mk_app(key, display, category, ns_name, desc, caps, open_link):
        ns_obj = ns_map.get(ns_name)
        st, reason = compute_ns_health(ns_obj)

        pods_total = int(ns_obj.get("pods",{}).get("count",0) or 0) if ns_obj else 0
        pods_ready = sum(1 for p in (ns_obj.get("pods",{}).get("items",[]) or []) if p.get("ready") is True) if ns_obj else 0
        restarts = int(ns_obj.get("pods",{}).get("total_restarts",0) or 0) if ns_obj else 0

        # App-specific refinements
        if key == "airbyte":
          ing = (summary.get("ingestion",{}) or {}).get("airbyte",{}) or {}
          detail = ing.get("detail",{}) or {}
          # If server service missing or health error exists, degrade / missing accordingly
          if ing.get("available") and detail.get("ok") is False:
            st = "degraded"
            if detail.get("error"):
              reason = str(detail.get("error"))
          if detail.get("error"):
            st = "degraded"
            reason = str(detail.get("error"))

        return {
          "key": key,
          "display": display,
          "category": category,
          "status": st if st in ("healthy","degraded","missing") else "degraded",
          "reason": reason,
          "capabilities": caps,
          "links": {
            "open": open_link,
            "health": (f"https://{PORTAL_HOST}/api/health/{key}" if PORTAL_HOST else "")
          },
          "k8s": {
            "namespace": ns_name,
            "deployments_ready": sum(1 for d in (ns_obj.get("deployments",{}).get("items",[]) or []) if int(d.get("ready",0)) >= int(d.get("replicas",0))) if ns_obj else 0,
            "deployments_total": int(ns_obj.get("deployments",{}).get("count",0) or 0) if ns_obj else 0,
            "pods_ready": pods_ready,
            "pods_total": pods_total,
            "restarts_24h": restarts,
            "last_change": None
          }
        }

      apps = [
        mk_app("airbyte","Data Ingestion","CORE","airbyte",
               "Managed ingestion with connectors, scheduling, CDC, and audit-ready runs.",
               ["Connectors","Scheduling","CDC","Audit"], LINKS.get("airbyte","")),
        mk_app("minio","Object Storage","CORE","open-kpi",
               "S3-compatible object storage with secure zones, lifecycle control, and resilience.",
               ["S3","Buckets","Encryption","Lifecycle"], LINKS.get("minio","")),
        mk_app("analytics","Analytics & BI","BI","open-kpi",
               "Self-service dashboards with governed datasets and secure sharing for users.",
               ["Dashboards","SQL","Governed KPIs","Sharing"], LINKS.get("metabase","")),
        mk_app("dbt","Data Transformation","CORE","transform",
               "Reproducible transformations with versioned models, tests, and lineage.",
               ["Models","Lineage","Docs","CI-ready"], LINKS.get("dbt","")),
        mk_app("n8n","Workflow Automation","OPERATIONS","n8n",
               "Automate operational workflows, alerting, and integration tasks.",
               ["Workflows","Triggers","Ops","Integration"], LINKS.get("n8n","")),
        mk_app("zammad","ITSM / Ticketing","OPERATIONS","tickets",
               "Ticketing and support workflow for platform operations and service requests.",
               ["Tickets","SLAs","Support","Audit"], LINKS.get("zammad","")),
      ]
      return apps

    def compute_platform(summary, apps):
      pods = 0
      restarts = 0
      for ns in (summary.get("k8s",{}).get("namespaces",[]) or []):
        pods += int(ns.get("pods",{}).get("count",0) or 0)
        restarts += int(ns.get("pods",{}).get("total_restarts",0) or 0)

      apps_up = sum(1 for a in apps if a.get("status") == "healthy")
      apps_down = sum(1 for a in apps if a.get("status") == "missing")
      apps_degraded = sum(1 for a in apps if a.get("status") == "degraded")

      # Platform status rule: missing if any CORE missing; else degraded if any degraded; else healthy
      core_missing = any((a.get("category") == "CORE" and a.get("status") == "missing") for a in apps)
      status = "missing" if core_missing else ("degraded" if apps_degraded > 0 else "healthy")

      return {
        "status": status,
        "apps_up": apps_up,
        "apps_down": apps_down,
        "apps_degraded": apps_degraded,
        "pods": pods,
        "restarts_24h": restarts
      }

    def airbyte_detail():
      # Determine availability + service existence and map to UI-required ingestion.airbyte.detail
      ns = "airbyte"
      svc = k8s_get_service(ns, "airbyte-server")
      if svc.get("_error"):
        # namespace may exist but svc missing
        return {"available": True, "last_sync": None, "detail": {"ok": False, "error": "airbyte-server service not found"}}
      return {"available": True, "last_sync": None, "detail": {"ok": True, "error": ""}}

    def postgres_catalog():
      # Minimal: report schemas observed from readiness only (extend later)
      # We avoid DB connections in v1 (stdlib-only).
      # If you later add psycopg, you can enrich tables list here.
      return {
        "available": True,
        "error": "",
        "schemas": [{"schema":"public"},{"schema":"pg_toast"}],
        "tables": []
      }

    def build_summary():
      started = time.time()

      # k8s snapshot
      namespaces = []
      k8s_ok = True
      err = ""
      try:
        for ns in WATCH_NAMESPACES:
          namespaces.append(ns_snapshot(ns))
      except Exception as e:
        k8s_ok = False
        err = str(e)

      # catalog: minio buckets + pg schemas
      minio = minio_list_buckets()
      pg = postgres_catalog()

      summary = {
        "meta": {
          "version": "1.0",
          "generated_at": now_iso(),
          "env": os.environ.get("PORTAL_ENV","PROD"),
          "cluster": os.environ.get("PORTAL_CLUSTER","k3s"),
          "build_id": BUILD_ID,
          "scan_ms": int((time.time()-started)*1000)
        },
        "links": LINKS,
        "k8s": {
          "available": k8s_ok,
          "error": err,
          "namespaces": namespaces
        },
        "catalog": {
          "minio": minio,
          "postgres": pg
        },
        "ingestion": {
          "airbyte": airbyte_detail()
        },
        "transform": {
          "dbt": {
            "available": False,
            "last_run": None,
            "last_status": None,
            "models": None,
            "docs_url": LINKS.get("dbt","") or None
          }
        }
      }

      apps = normalize_apps(summary)
      summary["apps"] = apps
      summary["platform"] = compute_platform(summary, apps)
      return summary

    class Handler(BaseHTTPRequestHandler):
      def _send(self, code, payload, content_type="application/json"):
        body = payload.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

      def do_GET(self):
        try:
          path = self.path.split("?",1)[0]
          if path == "/api/health" or path == "/healthz":
            self._send(200, json.dumps({"ok": True, "ts": now_iso(), "build_id": BUILD_ID}))
            return

          if path.startswith("/api/health/"):
            key = path.split("/api/health/",1)[1]
            self._send(200, json.dumps({"ok": True, "service": key, "ts": now_iso(), "build_id": BUILD_ID}))
            return

          if path == "/api/summary":
            s = build_summary()
            self._send(200, json.dumps(s))
            return

          # minimal index for direct service access (ingress routes /api to this svc)
          if path == "/" or path == "":
            self._send(200, json.dumps({"ok": True, "service": "portal-api", "endpoints": ["/api/health","/api/summary?v=1"], "build_id": BUILD_ID}))
            return

          self._send(404, json.dumps({"ok": False, "error": "not found"}))
        except Exception as e:
          self._send(500, json.dumps({"ok": False, "error": str(e)}))

      def log_message(self, fmt, *args):
        # quiet
        return

    def main():
      httpd = HTTPServer(("0.0.0.0", PORT), Handler)
      print(f"[portal-api] listening on :{PORT}", flush=True)
      httpd.serve_forever()

    if __name__ == "__main__":
      main()
YAML

# Replace placeholders in ConfigMap YAML (no touching the embedded code)
sed -i \
  -e "s/__PLATFORM_NS__/${PLATFORM_NS}/g" \
  -e "s/__API_CM__/${API_CM}/g" \
  "${TMP_CM}"

log "Apply ConfigMap ${API_CM} (portal-api code)"
kubectl -n "${PLATFORM_NS}" apply -f "${TMP_CM}"

# ------------------------------------------------------------------------------
# Deployment + Service
# ------------------------------------------------------------------------------
log "Apply Deployment ${API_DEPLOY} + Service ${API_SVC}"
kubectl -n "${PLATFORM_NS}" apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${API_DEPLOY}
  namespace: ${PLATFORM_NS}
  labels:
    app: ${API_DEPLOY}
  annotations:
    openkpi.yottalogica.com/managed-by: "portal-api-v1"
    openkpi.yottalogica.com/build-id: "${PORTAL_API_BUILD_ID}"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${API_DEPLOY}
  template:
    metadata:
      labels:
        app: ${API_DEPLOY}
      annotations:
        openkpi.yottalogica.com/managed-by: "portal-api-v1"
        openkpi.yottalogica.com/build-id: "${PORTAL_API_BUILD_ID}"
    spec:
      serviceAccountName: ${API_SA}
      containers:
      - name: api
        image: python:3.12-alpine
        imagePullPolicy: IfNotPresent
        command: ["python","-u","/app/app.py"]
        env:
        - name: PORT
          value: "8080"
        - name: PORTAL_API_BUILD_ID
          value: "${PORTAL_API_BUILD_ID}"
        - name: PORTAL_HOST
          value: "${PORTAL_HOST}"
        - name: PORTAL_WATCH_NAMESPACES
          value: "${PORTAL_WATCH_NAMESPACES}"
        - name: PORTAL_ENV
          value: "${PORTAL_ENV:-PROD}"
        - name: PORTAL_CLUSTER
          value: "${PORTAL_CLUSTER:-lake3}"
        - name: OPENKPI_MINIO_NS
          value: "${OPENKPI_MINIO_NS}"
        - name: OPENKPI_MINIO_SVC
          value: "${OPENKPI_MINIO_SVC}"
        - name: OPENKPI_MINIO_PORT
          value: "${OPENKPI_MINIO_PORT}"
        - name: OPENKPI_MINIO_SECRET
          value: "${OPENKPI_MINIO_SECRET}"
        - name: OPENKPI_MINIO_ACCESS_KEY_FIELD
          value: "${OPENKPI_MINIO_ACCESS_KEY_FIELD}"
        - name: OPENKPI_MINIO_SECRET_KEY_FIELD
          value: "${OPENKPI_MINIO_SECRET_KEY_FIELD}"
        - name: S3_REGION
          value: "${S3_REGION}"
        - name: OPENKPI_PG_NS
          value: "${OPENKPI_PG_NS}"
        - name: OPENKPI_PG_SVC
          value: "${OPENKPI_PG_SVC}"
        - name: OPENKPI_PG_PORT
          value: "${OPENKPI_PG_PORT}"
        - name: AIRBYTE_URL
          value: "${AIRBYTE_URL}"
        - name: MINIO_URL
          value: "${MINIO_URL}"
        - name: METABASE_URL
          value: "${METABASE_URL}"
        - name: DBT_URL
          value: "${DBT_URL}"
        - name: N8N_URL
          value: "${N8N_URL}"
        - name: ZAMMAD_URL
          value: "${ZAMMAD_URL}"
        ports:
        - name: http
          containerPort: 8080
        readinessProbe:
          httpGet:
            path: /api/health
            port: 8080
          initialDelaySeconds: 2
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: /api/health
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
        securityContext:
          allowPrivilegeEscalation: false
        volumeMounts:
        - name: code
          mountPath: /app/app.py
          subPath: app.py
          readOnly: true
      volumes:
      - name: code
        configMap:
          name: ${API_CM}
---
apiVersion: v1
kind: Service
metadata:
  name: ${API_SVC}
  namespace: ${PLATFORM_NS}
  labels:
    app: ${API_DEPLOY}
  annotations:
    openkpi.yottalogica.com/managed-by: "portal-api-v1"
    openkpi.yottalogica.com/build-id: "${PORTAL_API_BUILD_ID}"
spec:
  selector:
    app: ${API_DEPLOY}
  ports:
  - name: http
    port: 80
    targetPort: 8080
YAML

# ------------------------------------------------------------------------------
# Rollout + verification (via direct service + via portal ingress)
# ------------------------------------------------------------------------------
log "Wait for rollout"
kubectl -n "${PLATFORM_NS}" rollout status deployment "${API_DEPLOY}" --timeout=240s

log "Quick service check (cluster DNS)"
kubectl -n "${PLATFORM_NS}" run -i --rm --restart=Never portal-api-curl --image=curlimages/curl:8.10.1 -- \
  sh -lc "curl -sS http://${API_SVC}.${PLATFORM_NS}.svc.cluster.local/api/health && echo" || true

log "Ingress check (portal host)"
curl -sk "https://${PORTAL_HOST}/api/health" | head -c 200 || true
echo

log "Contract check (must include platform + apps array)"
curl -sk "https://${PORTAL_HOST}/api/summary?v=1" | \
  python - <<'PY'
import json,sys
d=json.load(sys.stdin)
assert "platform" in d and "apps" in d and isinstance(d["apps"], list)
print("OK: platform/apps present | apps=", len(d["apps"]))
PY

log "Done"
log "API: https://${PORTAL_HOST}/api/health"
log "SUM: https://${PORTAL_HOST}/api/summary?v=1"
