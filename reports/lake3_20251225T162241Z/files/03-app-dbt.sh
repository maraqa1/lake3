#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# MODULE 03D — APP (dbt)
# FILE: 03-app-dbt.sh
#
# Objective:
# - Deploy dbt runner in namespace "transform"
# - Create dedicated analytics DB + dbt_user in shared Postgres (open-kpi)
# - Create:
#   1) CronJob: dbt run + dbt test (nightly by default)
#   2) One-shot Job template (manual trigger instructions)
#
# Hard rules:
# - Source 00-env.sh and 00-lib.sh
# - Kubernetes-native (manifests applied via kubectl)
# - No ingress exposure
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/00-env.sh"
# shellcheck source=/dev/null
. "${HERE}/00-lib.sh"

: "${KUBECONFIG:=/root/.kube/config}"
export KUBECONFIG


require_cmd kubectl
require_cmd awk
require_cmd sed
require_cmd tr
require_cmd head

NS_TRANSFORM="transform"
NS_OPENKPI="${NS:-open-kpi}"

# ------------------------------------------------------------------------------
# Contract vars: DBT_GIT_REPO, DBT_CRON_SCHEDULE (persist to /root/open-kpi.env)
# ------------------------------------------------------------------------------

ENV_FILE="/root/open-kpi.env"
touch "${ENV_FILE}"
chmod 0600 "${ENV_FILE}"

persist_kv_if_missing() {
  local key="$1"
  local val="$2"
  if ! grep -qE "^${key}=" "${ENV_FILE}"; then
    printf '%s=%q\n' "${key}" "${val}" >> "${ENV_FILE}"
  fi
  # shellcheck disable=SC1090
  set -a; . "${ENV_FILE}"; set +a
}

: "${STORAGE_CLASS:=local-path}"

persist_kv_if_missing "DBT_GIT_REPO" "https://github.com/ORG/REPO.git"
persist_kv_if_missing "DBT_CRON_SCHEDULE" "0 2 * * *"  # nightly 02:00

# Optional image override
persist_kv_if_missing "DBT_IMAGE" "ghcr.io/dbt-labs/dbt-postgres:1.8.0"

# Dedicated dbt credentials (persisted; generated once)
if ! grep -qE "^DBT_DB_PASSWORD=" "${ENV_FILE}"; then
  # 32-char URL-safe-ish
  DBT_DB_PASSWORD_GEN="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)"
  printf 'DBT_DB_PASSWORD=%q\n' "${DBT_DB_PASSWORD_GEN}" >> "${ENV_FILE}"
fi
# shellcheck disable=SC1090
set -a; . "${ENV_FILE}"; set +a

: "${DBT_GIT_REPO:?missing DBT_GIT_REPO}"
: "${DBT_CRON_SCHEDULE:?missing DBT_CRON_SCHEDULE}"
: "${DBT_IMAGE:?missing DBT_IMAGE}"
: "${DBT_DB_PASSWORD:?missing DBT_DB_PASSWORD}"

# ------------------------------------------------------------------------------
# Shared Postgres connection (cluster-internal)
# ------------------------------------------------------------------------------
PG_SVC="openkpi-postgres"
PG_HOST="${PG_SVC}.${NS_OPENKPI}.svc.cluster.local"
PG_PORT="5432"

# Superuser secret (from data-plane module)
PG_SUPER_SECRET="openkpi-postgres-secret"

get_secret_field_b64() {
  local ns="$1"
  local secret="$2"
  local field="$3"
  kubectl -n "${ns}" get secret "${secret}" -o "jsonpath={.data.${field}}"
}

b64dec() { printf '%s' "$1" | base64 -d; }

PG_SUPER_USER="$(b64dec "$(get_secret_field_b64 "${NS_OPENKPI}" "${PG_SUPER_SECRET}" "POSTGRES_USER")")"
PG_SUPER_PASS="$(b64dec "$(get_secret_field_b64 "${NS_OPENKPI}" "${PG_SUPER_SECRET}" "POSTGRES_PASSWORD")")"

# ------------------------------------------------------------------------------
# Ensure namespace
# ------------------------------------------------------------------------------
ensure_ns "${NS_TRANSFORM}"

# ------------------------------------------------------------------------------
# Ensure analytics DB + dbt_user in shared Postgres (idempotent)
# - Connect via a temporary psql pod in open-kpi namespace (no local psql required)
# ------------------------------------------------------------------------------
log "[03D][dbt] Ensuring Postgres objects: db=analytics, role=dbt_user"

PSQL_POD="psql-admin-$$"
cleanup_psql_pod() { kubectl -n "${NS_OPENKPI}" delete pod "${PSQL_POD}" --ignore-not-found >/dev/null 2>&1 || true; }
trap cleanup_psql_pod EXIT

kubectl -n "${NS_OPENKPI}" apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${PSQL_POD}
  labels:
    app: psql-admin
spec:
  restartPolicy: Never
  containers:
  - name: psql
    image: postgres:16
    command: ["bash","-lc","sleep 3600"]
    env:
    - name: PGPASSWORD
      value: "${PG_SUPER_PASS}"
YAML

retry 40 3 kubectl -n "${NS_OPENKPI}" wait --for=condition=Ready "pod/${PSQL_POD}" --timeout=5s >/dev/null

# FIX: CREATE DATABASE cannot run inside DO $$ ... $$.
# Replace the failing "ensure DB" block with plain SQL + \gexec pattern.

# --- in 03-app-dbt.sh, replace the SQL=... heredoc with this:

SQL=$(cat <<'EOSQL'
-- role (safe in DO)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_user') THEN
    CREATE ROLE dbt_user LOGIN PASSWORD '__DBT_PASS__';
  END IF;
END
$$;

-- database (must be top-level, not inside DO)
-- create only if missing using SELECT ... \gexec
SELECT format('CREATE DATABASE %I OWNER %I', 'analytics', 'dbt_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'analytics')
\gexec

-- ensure ownership even if DB already existed (safe)
ALTER DATABASE analytics OWNER TO dbt_user;

-- optional: default search_path for role
ALTER ROLE dbt_user SET search_path TO public;
EOSQL
)
SQL="${SQL/__DBT_PASS__/${DBT_DB_PASSWORD}}"

kubectl -n "${NS_OPENKPI}" exec -i "${PSQL_POD}" -- bash -lc \
  "psql -h '${PG_HOST}' -p '${PG_PORT}' -U '${PG_SUPER_USER}' -d postgres -v ON_ERROR_STOP=1" \
  <<<"${SQL}" >/dev/null

# ------------------------------------------------------------------------------
# Create/Apply dbt secret in transform namespace
# ------------------------------------------------------------------------------
log "[03D][dbt] Applying dbt-secret in namespace ${NS_TRANSFORM}"

kubectl -n "${NS_TRANSFORM}" create secret generic dbt-secret \
  --from-literal=DB_HOST="${PG_HOST}" \
  --from-literal=DB_PORT="${PG_PORT}" \
  --from-literal=DB_NAME="analytics" \
  --from-literal=DB_USER="dbt_user" \
  --from-literal=DB_PASSWORD="${DBT_DB_PASSWORD}" \
  --from-literal=DBT_GIT_REPO="${DBT_GIT_REPO}" \
  --from-literal=DBT_IMAGE="${DBT_IMAGE}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# ------------------------------------------------------------------------------
# PVC for workdir/artifacts (repo + target + logs)
# ------------------------------------------------------------------------------
log "[03D][dbt] Ensuring PVC dbt-workdir-pvc (StorageClass=${STORAGE_CLASS})"

kubectl -n "${NS_TRANSFORM}" apply -f - <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: dbt-workdir-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: 2Gi
YAML

# ------------------------------------------------------------------------------
# CronJob + manual Job template (derived from CronJob)
# - Repo clone via initContainer (alpine/git)
# - dbt runner writes profiles.yml at runtime from secret env vars
# ------------------------------------------------------------------------------
log "[03D][dbt] Applying CronJob dbt-nightly (schedule=${DBT_CRON_SCHEDULE})"


kubectl -n "${NS_TRANSFORM}" delete cronjob dbt-nightly --ignore-not-found >/dev/null 2>&1 || true

CRON_YAML="$(cat <<'YAML'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: dbt-nightly
  namespace: transform
spec:
  schedule: "__DBT_CRON_SCHEDULE__"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      ttlSecondsAfterFinished: 86400
      template:
        spec:
          restartPolicy: Never
          volumes:
          - name: workdir
            persistentVolumeClaim:
              claimName: dbt-workdir-pvc
          initContainers:
          - name: git-sync
            image: alpine/git:2.45.2
            env:
            - name: DBT_GIT_REPO
              valueFrom:
                secretKeyRef:
                  name: dbt-secret
                  key: DBT_GIT_REPO
            command: ["sh","-lc"]
            args:
              - |
                set -euo pipefail
                mkdir -p /workspace
                rm -rf /workspace/repo
                git clone --depth 1 "${DBT_GIT_REPO}" /workspace/repo
            volumeMounts:
            - name: workdir
              mountPath: /workspace
          containers:
          - name: dbt
            image: __DBT_IMAGE__
            env:
            - name: DB_HOST
              valueFrom: {secretKeyRef: {name: dbt-secret, key: DB_HOST}}
            - name: DB_PORT
              valueFrom: {secretKeyRef: {name: dbt-secret, key: DB_PORT}}
            - name: DB_NAME
              valueFrom: {secretKeyRef: {name: dbt-secret, key: DB_NAME}}
            - name: DB_USER
              valueFrom: {secretKeyRef: {name: dbt-secret, key: DB_USER}}
            - name: DB_PASSWORD
              valueFrom: {secretKeyRef: {name: dbt-secret, key: DB_PASSWORD}}
            workingDir: /workspace/repo
            command: ["bash","-lc"]
            args:
              - |
                set -euo pipefail
                mkdir -p /workspace/profiles
                cat > /workspace/profiles/profiles.yml <<EOF
                default:
                  outputs:
                    prod:
                      type: postgres
                      host: \$DB_HOST
                      port: \$DB_PORT
                      user: \$DB_USER
                      password: \$DB_PASSWORD
                      dbname: \$DB_NAME
                      schema: analytics
                      threads: 4
                      keepalives_idle: 0
                  target: prod
                EOF

                export DBT_PROFILES_DIR=/workspace/profiles
                mkdir -p /workspace/repo/target /workspace/repo/logs

                if [ -f "packages.yml" ]; then
                  dbt deps
                fi

                dbt --version
                dbt run
                dbt test
            volumeMounts:
            - name: workdir
              mountPath: /workspace
YAML
)"

CRON_YAML="${CRON_YAML/__DBT_CRON_SCHEDULE__/${DBT_CRON_SCHEDULE}}"
CRON_YAML="${CRON_YAML/__DBT_IMAGE__/${DBT_IMAGE}}"

printf '%s\n' "${CRON_YAML}" | kubectl -n "${NS_TRANSFORM}" apply -f -

retry 10 1 kubectl -n "${NS_TRANSFORM}" get cronjob dbt-nightly >/dev/null
# ------------------------------------------------------------------------------
# Readiness / visibility (CronJob existence)
# ------------------------------------------------------------------------------
retry 10 1 kubectl -n "${NS_TRANSFORM}" get cronjob dbt-nightly >/dev/null

# ------------------------------------------------------------------------------
# Manual trigger instructions (echo only)
# ------------------------------------------------------------------------------
echo "[03D][dbt] Installed CronJob: transform/dbt-nightly"
echo "[03D][dbt] Manual run (one-shot Job) command:"
echo "kubectl -n transform create job --from=cronjob/dbt-nightly dbt-manual-\$(date +%s)"
log "[03D][dbt] Verification"

# 0) Ensure CronJob exists
retry 10 1 kubectl -n "${NS_TRANSFORM}" get cronjob dbt-nightly >/dev/null
kubectl -n "${NS_TRANSFORM}" get cronjob dbt-nightly -o wide

# 1) Cleanup old dbt jobs (manual + verify) to keep namespace clean
log "[03D][dbt] Cleanup old dbt jobs (dbt-verify-*, dbt-manual-*)"
kubectl -n "${NS_TRANSFORM}" delete job \
  --ignore-not-found \
  $(kubectl -n "${NS_TRANSFORM}" get jobs -o name 2>/dev/null | grep -E 'job.batch/(dbt-verify-|dbt-manual-)' || true) \
  >/dev/null 2>&1 || true

# Also delete orphaned pods from prior jobs (safety)
kubectl -n "${NS_TRANSFORM}" delete pod \
  --ignore-not-found \
  $(kubectl -n "${NS_TRANSFORM}" get pods -o name 2>/dev/null | grep -E 'pod/(dbt-verify-|dbt-manual-)' || true) \
  >/dev/null 2>&1 || true

# 2) Start fresh verify job
VERIFY_JOB="dbt-verify-$(date +%s)"
log "[03D][dbt] Starting verify Job: ${VERIFY_JOB}"
kubectl -n "${NS_TRANSFORM}" create job --from=cronjob/dbt-nightly "${VERIFY_JOB}" >/dev/null

log "[03D][dbt] Waiting for job/${VERIFY_JOB} (timeout 20m)"

# 3) Wait for pod, then stream logs
POD=""
for _ in $(seq 1 60); do
  POD="$(kubectl -n "${NS_TRANSFORM}" get pods -l job-name="${VERIFY_JOB}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "${POD}" ] && break
  sleep 1
done

LOG1_PID=""
LOG2_PID=""
if [ -n "${POD}" ]; then
  log "[03D][dbt] Verify pod: ${POD}"
  kubectl -n "${NS_TRANSFORM}" get pod "${POD}" -o wide || true

  kubectl -n "${NS_TRANSFORM}" logs -f "${POD}" -c git-sync --tail=50 &
  LOG1_PID=$!
  kubectl -n "${NS_TRANSFORM}" logs -f "${POD}" -c dbt --tail=50 &
  LOG2_PID=$!
else
  warn "[03D][dbt] Verify pod did not appear within 60s."
fi

finish_verify_cleanup() {
  [ -n "${LOG1_PID:-}" ] && kill "${LOG1_PID}" >/dev/null 2>&1 || true
  [ -n "${LOG2_PID:-}" ] && kill "${LOG2_PID}" >/dev/null 2>&1 || true
  kubectl -n "${NS_TRANSFORM}" delete job "${VERIFY_JOB}" --ignore-not-found >/dev/null 2>&1 || true
}
trap finish_verify_cleanup EXIT

# 4) Wait for completion; on failure dump diagnostics and exit non-zero
if ! kubectl -n "${NS_TRANSFORM}" wait --for=condition=complete "job/${VERIFY_JOB}" --timeout=20m; then
  warn "[03D][dbt] Verify job failed or timed out. Diagnostics follow."
  kubectl -n "${NS_TRANSFORM}" get job "${VERIFY_JOB}" -o wide || true
  kubectl -n "${NS_TRANSFORM}" describe job "${VERIFY_JOB}" | sed -n '1,260p' || true

  POD="$(kubectl -n "${NS_TRANSFORM}" get pods -l job-name="${VERIFY_JOB}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${POD}" ]; then
    kubectl -n "${NS_TRANSFORM}" describe pod "${POD}" | sed -n '1,260p' || true
    kubectl -n "${NS_TRANSFORM}" logs "${POD}" -c git-sync --tail=200 || true
    kubectl -n "${NS_TRANSFORM}" logs "${POD}" -c dbt --tail=400 || true
  fi

  fatal "[03D][dbt] Verification failed."
fi

log "[03D][dbt] Verification succeeded."

# show tail logs for evidence (trap will cleanup job)
POD="$(kubectl -n "${NS_TRANSFORM}" get pods -l job-name="${VERIFY_JOB}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -n "${POD}" ]; then
  kubectl -n "${NS_TRANSFORM}" logs "${POD}" -c git-sync --tail=80 || true
  kubectl -n "${NS_TRANSFORM}" logs "${POD}" -c dbt --tail=200 || true
fi







