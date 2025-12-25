#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/00-env.sh"
# shellcheck source=/dev/null
. "${HERE}/00-lib.sh"

# ==============================================================================
# 04A — PORTAL API (OpenKPI)
# - Deploys a read-only Kubernetes-aware API + best-effort RO bootstrap for PG/MinIO
# - Idempotent: safe to re-run; converges state via kubectl apply
# - Never blocks API rollout if Postgres/MinIO bootstrap fails
# ==============================================================================

PLATFORM_NS="platform"
API_NAME="portal-api"
SA_NAME="portal-api"
SVC_NAME="portal-api"
CM_NAME="portal-api-code"
SECRET_NAME="portal-catalog-secret"

TARGET_NAMESPACES=("open-kpi" "airbyte" "n8n" "tickets" "transform" "platform")

log "[04A][PORTAL-API] Ensure namespace"
ensure_ns "${PLATFORM_NS}"

# ------------------------------------------------------------------------------
# RBAC: cluster-wide read-only access to required resource types
# ------------------------------------------------------------------------------
log "[04A][PORTAL-API] Ensure ServiceAccount + RBAC (read-only across target namespaces)"
kubectl -n "${PLATFORM_NS}" apply -f - <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SA_NAME}
  namespace: ${PLATFORM_NS}
YAML

kubectl apply -f - <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: portal-api-readonly
rules:
  - apiGroups: ["apps"]
    resources: ["deployments","statefulsets","replicasets"]
    verbs: ["get","list","watch"]
  - apiGroups: [""]
    resources: ["pods","services","events","namespaces"]
    verbs: ["get","list","watch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get","list","watch"]
YAML

kubectl apply -f - <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: portal-api-readonly
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: portal-api-readonly
subjects:
  - kind: ServiceAccount
    name: ${SA_NAME}
    namespace: ${PLATFORM_NS}
YAML

# ------------------------------------------------------------------------------
# Secrets: portal-catalog-secret (stable, generated only when missing)
# ------------------------------------------------------------------------------
log "[04A][PORTAL-API] Ensure portal secrets exist (stable, generated only when missing)"

# Cluster-internal endpoints (defaults)
OPENKPI_PG_HOST="${OPENKPI_PG_HOST:-openkpi-postgres.open-kpi.svc.cluster.local}"
OPENKPI_PG_PORT="${OPENKPI_PG_PORT:-5432}"
OPENKPI_PG_DB="${OPENKPI_PG_DB:-openkpi}"

OPENKPI_MINIO_HOST="${OPENKPI_MINIO_HOST:-openkpi-minio.open-kpi.svc.cluster.local}"
OPENKPI_MINIO_PORT="${OPENKPI_MINIO_PORT:-9000}"
OPENKPI_MINIO_CONSOLE_PORT="${OPENKPI_MINIO_CONSOLE_PORT:-9001}"

# RO identities (only used to seed secret when missing; never rotated automatically)
PG_RO_USER="${PG_RO_USER:-portal_ro}"
PG_RO_PASS="${PG_RO_PASS:-$(openssl rand -base64 24 | tr -d '\n' | tr '/+' 'AZ' | cut -c1-24)}"
MINIO_RO_USER="${MINIO_RO_USER:-portal_ro}"
MINIO_RO_PASS="${MINIO_RO_PASS:-$(openssl rand -base64 24 | tr -d '\n' | tr '/+' 'AZ' | cut -c1-24)}"

if ! kubectl -n "${PLATFORM_NS}" get secret "${SECRET_NAME}" >/dev/null 2>&1; then
  kubectl -n "${PLATFORM_NS}" create secret generic "${SECRET_NAME}" \
    --from-literal=PG_HOST="${OPENKPI_PG_HOST}" \
    --from-literal=PG_PORT="${OPENKPI_PG_PORT}" \
    --from-literal=PG_DB="${OPENKPI_PG_DB}" \
    --from-literal=PG_RO_USER="${PG_RO_USER}" \
    --from-literal=PG_RO_PASSWORD="${PG_RO_PASS}" \
    --from-literal=MINIO_ENDPOINT="http://${OPENKPI_MINIO_HOST}:${OPENKPI_MINIO_PORT}" \
    --from-literal=MINIO_CONSOLE="http://${OPENKPI_MINIO_HOST}:${OPENKPI_MINIO_CONSOLE_PORT}" \
    --from-literal=MINIO_RO_USER="${MINIO_RO_USER}" \
    --from-literal=MINIO_RO_PASSWORD="${MINIO_RO_PASS}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# Best-effort bootstrap uses superuser secrets from open-kpi namespace if present
PG_SU_SECRET="openkpi-postgres-secret"
MINIO_SU_SECRET="openkpi-minio-secret"

# ------------------------------------------------------------------------------
# API code ConfigMap (Flask + kubernetes client)
# - Uses in-cluster SA token; must not use default SA
# ------------------------------------------------------------------------------
log "[04A][PORTAL-API] Apply API code ConfigMap + Deployment + Service (always)"

kubectl -n "${PLATFORM_NS}" apply -f - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: portal-api-code
  namespace: platform
data:
  app.py: |
    import os, json
    from datetime import datetime, timezone
    from flask import Flask, jsonify
    from kubernetes import client, config
    import psycopg2
    from psycopg2.extras import RealDictCursor
    import requests

    app = Flask(__name__)

    TARGET_NS = ["open-kpi","airbyte","n8n","tickets","transform","platform"]

    def now():
      return datetime.now(timezone.utc).isoformat()

    def k8s():
      try:
        config.load_incluster_config()
      except Exception:
        config.load_kube_config()
      return client.AppsV1Api(), client.CoreV1Api(), client.NetworkingV1Api()

    def list_workloads():
      apps, core, net = k8s()
      out = []
      errors = []
      for ns in TARGET_NS:
        try:
          deps = apps.list_namespaced_deployment(ns).items
          stss = apps.list_namespaced_stateful_set(ns).items

          for d in deps:
            out.append({
              "namespace": ns,
              "kind": "Deployment",
              "name": d.metadata.name,
              "ready": f"{(d.status.ready_replicas or 0)}/{(d.status.replicas or 0)}",
              "observedGeneration": d.status.observed_generation,
              "generation": d.metadata.generation,
            })

          for s in stss:
            out.append({
              "namespace": ns,
              "kind": "StatefulSet",
              "name": s.metadata.name,
              "ready": f"{(s.status.ready_replicas or 0)}/{(s.status.replicas or 0)}",
              "observedGeneration": s.status.observed_generation,
              "generation": s.metadata.generation,
            })
        except Exception as e:
          errors.append({"namespace": ns, "error": str(e)})
      return out, errors

    def pg_query(q, params=None):
      host = os.environ.get("PG_HOST")
      port = int(os.environ.get("PG_PORT", "5432"))
      db   = os.environ.get("PG_DB")
      user = os.environ.get("PG_RO_USER")
      pw   = os.environ.get("PG_RO_PASSWORD")
      if not all([host, db, user, pw]):
        raise RuntimeError("Postgres env incomplete")
      conn = psycopg2.connect(host=host, port=port, dbname=db, user=user, password=pw, connect_timeout=2)
      try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
          cur.execute(q, params or ())
          return cur.fetchall()
      finally:
        conn.close()

    def minio_health():
      endpoint = os.environ.get("MINIO_ENDPOINT")
      if not endpoint:
        raise RuntimeError("MinIO endpoint missing")
      r = requests.get(endpoint + "/minio/health/ready", timeout=2)
      return {"ready_http": (r.status_code == 200), "status_code": r.status_code}

    def airbyte_last_sync():
      return {"available": False}

    @app.get("/api/health")
    def health():
      workloads, errors = list_workloads()
      return jsonify({"ts": now(), "overall_ok": (len(errors) == 0), "workloads": workloads, "errors": errors})

    @app.get("/api/catalog")
    def catalog():
      result = {"ts": now(), "postgres": {"ok": False}, "minio": {"ok": False}}
      try:
        rows = pg_query("""
          select table_schema, table_name
          from information_schema.tables
          where table_type='BASE TABLE'
            and table_schema not in ('pg_catalog','information_schema')
          order by table_schema, table_name
          limit 500
        """)
        result["postgres"] = {"ok": True, "tables": rows}
      except Exception as e:
        result["postgres"] = {"ok": False, "error": str(e)}

      try:
        result["minio"] = {"ok": True, "health": minio_health()}
      except Exception as e:
        result["minio"] = {"ok": False, "error": str(e)}

      return jsonify(result)

    @app.get("/api/ingestion")
    def ingestion():
      return jsonify({"ts": now(), "airbyte": airbyte_last_sync()})

    @app.get("/api/summary")
    def summary():
      workloads, errors = list_workloads()
      cat = {}
      try:
        # call local function directly
        cat = json.loads(catalog().get_data(as_text=True))
      except Exception:
        cat = {"error": "catalog failed"}
      return jsonify({
        "ts": now(),
        "overall_ok": (len(errors) == 0),
        "k8s": {"workloads": workloads, "errors": errors},
        "catalog": cat
      })

    if __name__ == "__main__":
      app.run(host="0.0.0.0", port=8000)
YAML

kubectl -n "${PLATFORM_NS}" apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${API_NAME}
  namespace: ${PLATFORM_NS}
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
      serviceAccountName: ${SA_NAME}
      containers:
        - name: api
          image: python:3.12-slim
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8000
          envFrom:
            - secretRef:
                name: ${SECRET_NAME}
          env:
            - name: PYTHONUNBUFFERED
              value: "1"
          command: ["/bin/sh","-lc"]
          args:
            - |
              set -e
              pip -q install --no-cache-dir flask kubernetes psycopg2-binary requests >/tmp/pip.log 2>&1 || (cat /tmp/pip.log && exit 1)
              python /app/app.py
          volumeMounts:
            - name: code
              mountPath: /app
          readinessProbe:
            httpGet:
              path: /api/health
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 12
          livenessProbe:
            httpGet:
              path: /api/health
              port: 8000
            initialDelaySeconds: 20
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 6
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
      volumes:
        - name: code
          configMap:
            name: ${CM_NAME}
YAML

kubectl -n "${PLATFORM_NS}" apply -f - <<YAML
apiVersion: v1
kind: Service
metadata:
  name: ${SVC_NAME}
  namespace: ${PLATFORM_NS}
spec:
  type: ClusterIP
  selector:
    app: ${API_NAME}
  ports:
    - name: http
      port: 8000
      targetPort: 8000
YAML

# ------------------------------------------------------------------------------
# Best-effort RO bootstrap jobs (do not block API)
# ------------------------------------------------------------------------------
log "[04A][PORTAL-API] Best-effort RO bootstrap jobs (do not block API)"

kubectl -n "${PLATFORM_NS}" delete job portal-pg-ro --ignore-not-found >/dev/null 2>&1 || true
kubectl -n "${PLATFORM_NS}" delete job portal-minio-ro --ignore-not-found >/dev/null 2>&1 || true

# --- Postgres RO job (best-effort)
if ! kubectl -n "${PLATFORM_NS}" apply -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: portal-pg-ro
  namespace: ${PLATFORM_NS}
spec:
  ttlSecondsAfterFinished: 300
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: psql
          image: postgres:16
          env:
            - name: PGHOST
              value: "${OPENKPI_PG_HOST}"
            - name: PGPORT
              value: "${OPENKPI_PG_PORT}"
            - name: PGDATABASE
              valueFrom:
                secretKeyRef:
                  name: ${PG_SU_SECRET}
                  key: POSTGRES_DB
                  optional: true
            - name: PGUSER
              valueFrom:
                secretKeyRef:
                  name: ${PG_SU_SECRET}
                  key: POSTGRES_USER
                  optional: true
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${PG_SU_SECRET}
                  key: POSTGRES_PASSWORD
                  optional: true
            - name: RO_USER
              valueFrom:
                secretKeyRef:
                  name: ${SECRET_NAME}
                  key: PG_RO_USER
            - name: RO_PASS
              valueFrom:
                secretKeyRef:
                  name: ${SECRET_NAME}
                  key: PG_RO_PASSWORD
            - name: RO_DB
              valueFrom:
                secretKeyRef:
                  name: ${SECRET_NAME}
                  key: PG_DB
          command: ["/bin/sh","-lc"]
          args:
            - |-
              set -e

              if [ -z "\${PGUSER:-}" ] || [ -z "\${PGPASSWORD:-}" ] || [ -z "\${PGDATABASE:-}" ]; then
                echo "Missing Postgres superuser secret; skipping"
                exit 0
              fi

              psql -v ON_ERROR_STOP=1 -v ro_user="\$RO_USER" -v ro_pass="\$RO_PASS" -c "DO \$\$ BEGIN
                    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'ro_user') THEN
                      EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', :'ro_user', :'ro_pass');
                    END IF;
                  END \$\$;"

              psql -v ON_ERROR_STOP=1 -d "\$RO_DB" -v ro_user="\$RO_USER" -c "DO \$\$ DECLARE r record;
                  BEGIN
                    EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'ro_user');
                    FOR r IN (SELECT nspname FROM pg_namespace WHERE nspname NOT IN ('pg_catalog','information_schema')) LOOP
                      EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', r.nspname, :'ro_user');
                      EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO %I', r.nspname, :'ro_user');
                      EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT ON TABLES TO %I', r.nspname, :'ro_user');
                    END LOOP;
                  END \$\$;" || true

              echo "Postgres RO ensured"
YAML
then
  warn "[04A][PORTAL-API] portal-pg-ro apply failed (non-fatal)"
fi

# --- MinIO RO job (best-effort)
if ! kubectl -n "${PLATFORM_NS}" apply -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: portal-minio-ro
  namespace: ${PLATFORM_NS}
spec:
  ttlSecondsAfterFinished: 300
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: mc
          image: minio/mc:RELEASE.2025-07-23T15-54-02Z
          env:
            - name: MINIO_ENDPOINT
              value: "http://${OPENKPI_MINIO_HOST}:${OPENKPI_MINIO_PORT}"
            - name: MINIO_ROOT_USER
              valueFrom:
                secretKeyRef:
                  name: ${MINIO_SU_SECRET}
                  key: MINIO_ROOT_USER
                  optional: true
            - name: MINIO_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${MINIO_SU_SECRET}
                  key: MINIO_ROOT_PASSWORD
                  optional: true
            - name: RO_USER
              valueFrom:
                secretKeyRef:
                  name: ${SECRET_NAME}
                  key: MINIO_RO_USER
            - name: RO_PASS
              valueFrom:
                secretKeyRef:
                  name: ${SECRET_NAME}
                  key: MINIO_RO_PASSWORD
          command: ["/bin/sh","-lc"]
          args:
            - |-
              set -e

              if [ -z "\${MINIO_ROOT_USER:-}" ] || [ -z "\${MINIO_ROOT_PASSWORD:-}" ]; then
                echo "Missing MinIO superuser secret; skipping"
                exit 0
              fi

              mc alias set openkpi "\${MINIO_ENDPOINT}" "\${MINIO_ROOT_USER}" "\${MINIO_ROOT_PASSWORD}" >/dev/null

              POLICY_JSON='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetBucketLocation","s3:ListAllMyBuckets","s3:ListBucket"],"Resource":["arn:aws:s3:::*"]},{"Effect":"Allow","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::*/*"]}]}'
              printf "%s" "\$POLICY_JSON" | mc admin policy add openkpi portal-readonly - >/dev/null 2>&1 || true

              mc admin user add openkpi "\$RO_USER" "\$RO_PASS" >/dev/null 2>&1 || true
              mc admin policy attach openkpi portal-readonly --user "\$RO_USER" >/dev/null 2>&1 || true

              echo "MinIO RO ensured"
YAML
then
  warn "[04A][PORTAL-API] portal-minio-ro apply failed (non-fatal)"
fi

# ------------------------------------------------------------------------------
# Deterministic readiness check
# ------------------------------------------------------------------------------
log "[04A][PORTAL-API] Readiness check (deterministic)"
kubectl -n "${PLATFORM_NS}" rollout status deploy/${API_NAME} --timeout=240s

log "[04A][PORTAL-API] Done"
