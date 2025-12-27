#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 04-portal-api.sh — OpenKPI Portal API (Flask)
# - Namespace: platform (default)
# - Endpoints: /api/health, /api/catalog, /api/ingestion, /api/summary
# - Contract: stable JSON for UI consumption
# - Reads MinIO + Postgres creds by copying secrets from open-kpi namespace
# - No dependency on Zammad; does not reference it
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/00-env.sh"
# shellcheck source=/dev/null
. "${HERE}/00-lib.sh"

require_cmd kubectl

PLATFORM_NS="${PLATFORM_NS:-platform}"
OPENKPI_NS="${NS:-open-kpi}"

: "${INGRESS_CLASS:=nginx}"
: "${TLS_MODE:=off}"
: "${PORTAL_HOST:=portal.lake3.opendatalake.com}"

API_NAME="portal-api"
API_SA="portal-api-sa"
API_CM="portal-api-code"
API_SECRET="portal-api-secrets"
API_DEPLOY="${API_NAME}"
API_SVC="${API_NAME}"

MINIO_SECRET_SRC="${MINIO_SECRET_SRC:-openkpi-minio-secret}"
PG_SECRET_SRC="${PG_SECRET_SRC:-openkpi-postgres-secret}"

MINIO_ENDPOINT_INTERNAL="${MINIO_ENDPOINT_INTERNAL:-http://openkpi-minio.${OPENKPI_NS}.svc.cluster.local:9000}"
PG_HOST_INTERNAL="${PG_HOST_INTERNAL:-openkpi-postgres.${OPENKPI_NS}.svc.cluster.local}"
PG_PORT_INTERNAL="${PG_PORT_INTERNAL:-5432}"

ensure_ns "${PLATFORM_NS}"

b64dec() { printf '%s' "$1" | base64 -d 2>/dev/null || true; }

get_secret_key_b64() {
  local ns="$1" secret="$2" key="$3"
  kubectl -n "${ns}" get secret "${secret}" -o "jsonpath={.data.${key}}" 2>/dev/null || true
}

MINIO_ROOT_USER="$(b64dec "$(get_secret_key_b64 "${OPENKPI_NS}" "${MINIO_SECRET_SRC}" "MINIO_ROOT_USER")")"
MINIO_ROOT_PASSWORD="$(b64dec "$(get_secret_key_b64 "${OPENKPI_NS}" "${MINIO_SECRET_SRC}" "MINIO_ROOT_PASSWORD")")"

PG_DB="$(b64dec "$(get_secret_key_b64 "${OPENKPI_NS}" "${PG_SECRET_SRC}" "POSTGRES_DB")")"
PG_USER="$(b64dec "$(get_secret_key_b64 "${OPENKPI_NS}" "${PG_SECRET_SRC}" "POSTGRES_USER")")"
PG_PASSWORD="$(b64dec "$(get_secret_key_b64 "${OPENKPI_NS}" "${PG_SECRET_SRC}" "POSTGRES_PASSWORD")")"

: "${MINIO_ROOT_USER:=}"
: "${MINIO_ROOT_PASSWORD:=}"
: "${PG_DB:=postgres}"
: "${PG_USER:=postgres}"
: "${PG_PASSWORD:=}"

apply_yaml "$(cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${API_SECRET}
  namespace: ${PLATFORM_NS}
type: Opaque
stringData:
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

apply_yaml "$(cat <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: portal-api-code
  namespace: platform
data:
  app.py: |
    import os, json, time, datetime
    from typing import Dict, Any, List

    from flask import Flask, jsonify, request

    # Lazy imports (installed at container start)
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
      return {
        "count": len(out),
        "total_restarts": total_restarts,
        "items": sorted(out, key=lambda x: x["name"]),
      }

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
      apps = k8s.AppsV1Api()

      try:
        nss = [n.metadata.name for n in v1.list_namespace().items]
      except Exception as e:
        return {"available": False, "error": f"cannot list namespaces: {str(e)}"}

      namespaces = []
      for ns in sorted(nss):
        try:
          pods = summarize_pods(v1, ns)
          deps = summarize_deployments(apps, ns)
          stss = summarize_statefulsets(apps, ns)
          namespaces.append({
            "name": ns,
            "pods": pods,
            "deployments": deps,
            "statefulsets": stss,
          })
        except Exception as e:
          namespaces.append({
            "name": ns,
            "error": str(e),
            "pods": {"count": 0, "total_restarts": 0, "items": []},
            "deployments": {"count": 0, "items": []},
            "statefulsets": {"count": 0, "items": []},
          })

      return {"available": True, "namespaces": namespaces}

    def pg_catalog() -> Dict[str, Any]:
      host = env("PG_HOST")
      port = env("PG_PORT", "5432")
      db = env("PG_DB", "postgres")
      user = env("PG_USER", "postgres")
      pw = env("PG_PASSWORD", "")

      if psycopg2 is None:
        return {"available": False, "error": "psycopg2 not installed"}

      try:
        conn = psycopg2.connect(
          host=host, port=int(port), dbname=db, user=user, password=pw,
          connect_timeout=3,
        )
        cur = conn.cursor()
        # Schemas (exclude system)
        cur.execute("""
          SELECT schema_name
          FROM information_schema.schemata
          WHERE schema_name NOT IN ('pg_catalog','information_schema')
          ORDER BY schema_name;
        """)
        schemas = [{"schema": r[0]} for r in cur.fetchall()]

        # Tables (exclude system)
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
          buckets.append({"name": b.get("Name", ""), "created": (b.get("CreationDate").isoformat() if b.get("CreationDate") else "")})
        return {"available": True, "health": {"ok": True}, "buckets": sorted(buckets, key=lambda x: x["name"])}
      except Exception as e:
        return {"available": False, "health": {"ok": False, "error": str(e)}, "buckets": []}

    def airbyte_ingestion() -> Dict[str, Any]:
      k8s = load_k8s()
      if k8s is None:
        return {"available": False, "error": "kubernetes client unavailable"}

      v1 = k8s.CoreV1Api()
      try:
        _ = v1.read_namespace("airbyte")
      except Exception:
        return {"available": False}

      # Best-effort: call Airbyte API inside cluster if service exists.
      # If it fails, still return available:true with empty last_sync.
      last_sync = None
      detail = {"method": "airbyte-api", "ok": False}

      try:
        # service name varies by chart; try common ones.
        svc_candidates = [
          ("airbyte-airbyte-server", 8001),
          ("airbyte-server", 8001),
          ("airbyte-airbyte-api-server", 8001),
        ]
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
        # Jobs list endpoint (older Airbyte uses /api/v1/jobs/list)
        url = base + "/api/v1/jobs/list"
        payload = {"configTypes": ["sync"], "includingJobId": 0, "pagination": {"pageSize": 20, "rowOffset": 0}}
        r = requests.post(url, json=payload, timeout=3)
        if r.status_code != 200:
          return {"available": True, "last_sync": None, "detail": {"ok": False, "error": f"http {r.status_code}"}}

        data = r.json() or {}
        jobs = (data.get("jobs") or [])
        best = None
        for j in jobs:
          job = j.get("job") or {}
          attempts = j.get("attempts") or []
          status = (job.get("status") or "").lower()
          created = job.get("createdAt") or job.get("created_at") or 0
          # prefer succeeded/completed
          if best is None:
            best = (status, created, j)
          else:
            if created and created > best[1]:
              best = (status, created, j)

        if best is None:
          return {"available": True, "last_sync": None, "detail": {"ok": True, "note": "no jobs returned"}}

        jobwrap = best[2]
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
        detail = {"ok": True, "base": base}
      except Exception as e:
        return {"available": True, "last_sync": None, "detail": {"ok": False, "error": str(e)}}

      return {"available": True, "last_sync": last_sync, "detail": detail}

    def build_summary() -> Dict[str, Any]:
      k8s = k8s_summary()
      pg = pg_catalog()
      mn = minio_catalog()
      ing = airbyte_ingestion()

      # normalize to UI contract
      out = {
        "meta": {"generated_at": now_iso(), "version": "1.0"},
        "k8s": {"available": bool(k8s.get("available")), "namespaces": (k8s.get("namespaces") or []) if k8s.get("available") else []},
        "catalog": {
          "postgres": {"available": bool(pg.get("available")), "schemas": pg.get("schemas") or [], "tables": pg.get("tables") or [], "error": pg.get("error", "")},
          "minio": {"available": bool(mn.get("available")), "health": mn.get("health") or {"ok": False}, "buckets": mn.get("buckets") or []},
        },
        "ingestion": {"airbyte": ing},
      }
      return out

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

    @app.get("/api/health")
    def api_health():
      return jsonify({"ok": True, "ts": now_iso()})

    @app.get("/api/catalog")
    def api_catalog():
      s = build_summary()
      return jsonify({"catalog": s["catalog"], "meta": s["meta"]})

    @app.get("/api/ingestion")
    def api_ingestion():
      s = build_summary()
      return jsonify({"ingestion": s["ingestion"], "meta": s["meta"]})

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

if [[ "${TLS_MODE}" == "per-host-http01" ]]; then
  apply_yaml "$(cat <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: portal
  namespace: ${PLATFORM_NS}
  annotations:
    kubernetes.io/ingress.class: ${INGRESS_CLASS}
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
    - hosts:
        - ${PORTAL_HOST}
      secretName: portal-tls
  rules:
    - host: ${PORTAL_HOST}
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: ${API_SVC}
                port:
                  number: 80
EOF
)"
else
  apply_yaml "$(cat <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: portal
  namespace: ${PLATFORM_NS}
  annotations:
    kubernetes.io/ingress.class: ${INGRESS_CLASS}
spec:
  ingressClassName: ${INGRESS_CLASS}
  rules:
    - host: ${PORTAL_HOST}
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: ${API_SVC}
                port:
                  number: 80
EOF
)"
fi

kubectl_wait_deploy "${PLATFORM_NS}" "${API_DEPLOY}" "180s"

# [PATCHES][API]
(
  HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=/dev/null
  . "${HERE}/00-env.sh"
  # shellcheck source=/dev/null
  . "${HERE}/00-lib.sh"

  PLATFORM_NS="${PLATFORM_NS:-platform}"
  PATCH_IMAGE="minio/mc:RELEASE.2025-07-23T15-54-02Z-cpuv1"

  log "[PATCHES][API] Start (ns=${PLATFORM_NS})"

  k() { echo "+ $*"; "$@"; }

  find_named_like() {
    # args: kind (deploy|job|cronjob) pattern
    local kind="$1" pat="$2"
    kubectl -n "${PLATFORM_NS}" get "${kind}" -o name 2>/dev/null | sed 's|^.*/||' | grep -i "${pat}" || true
  }

  patch_deploy_image() {
    local name="$1"
    local cname
    cname="$(kubectl -n "${PLATFORM_NS}" get deploy "${name}" -o jsonpath='{.spec.template.spec.containers[0].name}' 2>/dev/null || true)"
    if [[ -z "${cname}" ]]; then
      warn "[PATCHES][API] Deployment ${name}: could not determine container name"
      return 0
    fi

    k kubectl -n "${PLATFORM_NS}" patch deploy "${name}" --type='strategic' -p \
      "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"${cname}\",\"image\":\"${PATCH_IMAGE}\"}]}}}}"

    echo "[PATCHES][API] patched kind=Deployment name=${name} image=${PATCH_IMAGE}"

    k kubectl -n "${PLATFORM_NS}" rollout restart deploy/"${name}"
    k kubectl -n "${PLATFORM_NS}" rollout status deploy/"${name}" --timeout=180s
    k kubectl -n "${PLATFORM_NS}" get deploy/"${name}" -o wide
    k kubectl -n "${PLATFORM_NS}" get pods -l app="${name}" -o wide 2>/dev/null || true
  }

  patch_job_image_and_refresh() {
    local name="$1"
    local cname
    cname="$(kubectl -n "${PLATFORM_NS}" get job "${name}" -o jsonpath='{.spec.template.spec.containers[0].name}' 2>/dev/null || true)"
    if [[ -z "${cname}" ]]; then
      warn "[PATCHES][API] Job ${name}: could not determine container name"
      return 0
    fi

    k kubectl -n "${PLATFORM_NS}" patch job "${name}" --type='strategic' -p \
      "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"${cname}\",\"image\":\"${PATCH_IMAGE}\"}]}}}}"

    echo "[PATCHES][API] patched kind=Job name=${name} image=${PATCH_IMAGE}"

    local complete
    complete="$(kubectl -n "${PLATFORM_NS}" get job "${name}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
    if [[ "${complete}" == "True" ]]; then
      # completed jobs won't re-run; delete so module can recreate on next run
      k kubectl -n "${PLATFORM_NS}" delete job "${name}" --ignore-not-found=true
      echo "[PATCHES][API] refresh action: deleted completed job=${name} (will be recreated by module on next run)"
    else
      # force fresh pod with new image
      k kubectl -n "${PLATFORM_NS}" delete pod -l job-name="${name}" --ignore-not-found=true
      echo "[PATCHES][API] refresh action: deleted pods for job=${name} (new pod should be created)"
      k kubectl -n "${PLATFORM_NS}" get job/"${name}" -o wide || true
      k kubectl -n "${PLATFORM_NS}" get pods -l job-name="${name}" -o wide || true
    fi
  }

  patch_cronjob_image_and_refresh() {
    local name="$1"
    local cname
    cname="$(kubectl -n "${PLATFORM_NS}" get cronjob "${name}" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].name}' 2>/dev/null || true)"
    if [[ -z "${cname}" ]]; then
      warn "[PATCHES][API] CronJob ${name}: could not determine container name"
      return 0
    fi

    k kubectl -n "${PLATFORM_NS}" patch cronjob "${name}" --type='strategic' -p \
      "{\"spec\":{\"jobTemplate\":{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"${cname}\",\"image\":\"${PATCH_IMAGE}\"}]}}}}}}"

    echo "[PATCHES][API] patched kind=CronJob name=${name} image=${PATCH_IMAGE}"

    # delete any currently-running pods from jobs created by this CronJob (won't interrupt future schedules)
    local jobs
    jobs="$(kubectl -n "${PLATFORM_NS}" get jobs -o jsonpath="{range .items[?(@.metadata.labels['cronjob-name']=='${name}')]}{.metadata.name}{'\n'}{end}" 2>/dev/null || true)"
    if [[ -n "${jobs}" ]]; then
      while IFS= read -r j; do
        [[ -z "${j}" ]] && continue
        k kubectl -n "${PLATFORM_NS}" delete pod -l job-name="${j}" --ignore-not-found=true
      done <<< "${jobs}"
      echo "[PATCHES][API] refresh action: deleted pods for jobs owned by cronjob=${name}"
    fi

    k kubectl -n "${PLATFORM_NS}" get cronjob/"${name}" -o wide
    k kubectl -n "${PLATFORM_NS}" get jobs -l cronjob-name="${name}" -o wide 2>/dev/null || true
  }

  # --- discover and patch any resource whose name contains "portal-minio-ro" ---
  DEP_MATCHES="$(find_named_like deploy portal-minio-ro)"
  JOB_MATCHES="$(find_named_like job portal-minio-ro)"
  CJ_MATCHES="$(find_named_like cronjob portal-minio-ro)"

  if [[ -z "${DEP_MATCHES}${JOB_MATCHES}${CJ_MATCHES}" ]]; then
    warn "[PATCHES][API] No resources found with name containing 'portal-minio-ro' in ns=${PLATFORM_NS}"
  fi

  if [[ -n "${DEP_MATCHES}" ]]; then
    while IFS= read -r n; do
      [[ -z "${n}" ]] && continue
      patch_deploy_image "${n}"
    done <<< "${DEP_MATCHES}"
  fi

  if [[ -n "${CJ_MATCHES}" ]]; then
    while IFS= read -r n; do
      [[ -z "${n}" ]] && continue
      patch_cronjob_image_and_refresh "${n}"
    done <<< "${CJ_MATCHES}"
  fi

  if [[ -n "${JOB_MATCHES}" ]]; then
    while IFS= read -r n; do
      [[ -z "${n}" ]] && continue
      patch_job_image_and_refresh "${n}"
    done <<< "${JOB_MATCHES}"
  fi

  log "[PATCHES][API] Status (matching resources)"
  k kubectl -n "${PLATFORM_NS}" get deploy,cronjob,job,pod -o wide | (grep -i 'portal-minio-ro' || true)
)

