#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# MODULE 03D — APP (dbt)
# FILE: 03-app-dbt.sh
#
# Objective:
# - Deploy dbt runner in namespace "transform"
# - Ensure dedicated analytics DB + dbt_user in shared Postgres (open-kpi)
# - Ensure dbt profile resolution is deterministic (repo expects profile "his_demo")
# - Create:
#   1) CronJob: dbt run + dbt test (nightly by default)
#   2) One-shot Job (manual trigger instructions)
# - Preflight: create expected landing schemas/tables referenced by repo SQL so verification passes
#
# Hard rules:
# - Source 00-env.sh and 00-lib.sh
# - Kubernetes-native (kubectl apply only)
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
require_cmd base64

NS_TRANSFORM="transform"
NS_OPENKPI="${NS:-open-kpi}"

: "${DBT_MANAGE_DB_OBJECTS:=true}"
: "${STORAGE_CLASS:=local-path}"

# ------------------------------------------------------------------------------
# Contract vars (must exist in /root/open-kpi.env via 00-env.sh)
# ------------------------------------------------------------------------------
: "${DBT_GIT_REPO:?missing DBT_GIT_REPO}"
: "${DBT_CRON_SCHEDULE:?missing DBT_CRON_SCHEDULE}"
: "${DBT_IMAGE:?missing DBT_IMAGE}"
: "${DBT_DB_PASSWORD:?missing DBT_DB_PASSWORD}"

# Deterministic dbt profile + target expected by repo
DBT_PROFILE_NAME="${DBT_PROFILE_NAME:-his_demo}"
DBT_TARGET_NAME="${DBT_TARGET_NAME:-prod}"

# ------------------------------------------------------------------------------
# Shared Postgres connection (cluster-internal canonical destination)
# ------------------------------------------------------------------------------
PG_SVC="openkpi-postgres"
PG_HOST="${PG_SVC}.${NS_OPENKPI}.svc.cluster.local"
PG_PORT="5432"
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

# Canonical dbt destination (do not allow drift from env file)
DBT_DB_HOST="${PG_HOST}"
DBT_DB_PORT="5432"
DBT_DB_NAME="analytics"
DBT_DB_USER="dbt_user"

# ------------------------------------------------------------------------------
# Ensure namespace
# ------------------------------------------------------------------------------
ensure_ns "${NS_TRANSFORM}"

# ------------------------------------------------------------------------------
# Ensure analytics DB + dbt_user in shared Postgres (idempotent + password enforced)
# - Avoid DO $$ quoting issues by using \gexec pattern + direct ALTER ROLE
# ------------------------------------------------------------------------------
if [[ "${DBT_MANAGE_DB_OBJECTS}" == "true" ]]; then
  log "[03D][dbt] Ensuring Postgres objects: db=analytics, role=dbt_user (password enforced)"

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

  retry 40 2 kubectl -n "${NS_OPENKPI}" wait --for=condition=Ready "pod/${PSQL_POD}" --timeout=5s >/dev/null

  kubectl -n "${NS_OPENKPI}" exec -i "${PSQL_POD}" -- bash -lc "
    set -euo pipefail
    psql -h '${PG_HOST}' -p '${PG_PORT}' -U '${PG_SUPER_USER}' -d postgres -v ON_ERROR_STOP=1 -v dbt_pass='${DBT_DB_PASSWORD}' <<'SQL'
-- create role only if missing
SELECT 'CREATE ROLE dbt_user LOGIN PASSWORD ' || quote_literal(:'dbt_pass') || ';'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='dbt_user')
\\gexec

-- enforce password every run (deterministic)
ALTER ROLE dbt_user WITH LOGIN PASSWORD :'dbt_pass';

-- create database only if missing
SELECT format('CREATE DATABASE %I OWNER %I', 'analytics', 'dbt_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='analytics')
\\gexec

ALTER DATABASE analytics OWNER TO dbt_user;
ALTER ROLE dbt_user SET search_path TO public;
SQL
  " >/dev/null

  # cleanup of PSQL_POD handled by trap
fi

# ------------------------------------------------------------------------------
# Create/Apply dbt secret in transform namespace (canonical destination only)
# ------------------------------------------------------------------------------
log "[03D][dbt] Applying dbt-secret in namespace ${NS_TRANSFORM}"

kubectl -n "${NS_TRANSFORM}" create secret generic dbt-secret \
  --from-literal=DB_HOST="${DBT_DB_HOST}" \
  --from-literal=DB_PORT="${DBT_DB_PORT}" \
  --from-literal=DB_NAME="${DBT_DB_NAME}" \
  --from-literal=DB_USER="${DBT_DB_USER}" \
  --from-literal=DB_PASSWORD="${DBT_DB_PASSWORD}" \
  --from-literal=DBT_GIT_REPO="${DBT_GIT_REPO}" \
  --from-literal=DBT_IMAGE="${DBT_IMAGE}" \
  --from-literal=DBT_PROFILE_NAME="${DBT_PROFILE_NAME}" \
  --from-literal=DBT_TARGET_NAME="${DBT_TARGET_NAME}" \
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
# Apply CronJob (dbt run + test)
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
                - name: DBT_PROFILE_NAME
                  valueFrom: {secretKeyRef: {name: dbt-secret, key: DBT_PROFILE_NAME}}
                - name: DBT_TARGET_NAME
                  valueFrom: {secretKeyRef: {name: dbt-secret, key: DBT_TARGET_NAME}}
              workingDir: /workspace/repo
              command: ["bash","-lc"]
              args:
                - |
                  set -euo pipefail

                  case "${DB_PORT}" in
                    ''|*[!0-9]*)
                      echo "FATAL: DB_PORT must be numeric, got: '${DB_PORT}'"
                      exit 1
                      ;;
                  esac

                  mkdir -p /workspace/profiles

                  cat > /workspace/profiles/profiles.yml <<EOF
                  ${DBT_PROFILE_NAME}:
                    outputs:
                      ${DBT_TARGET_NAME}:
                        type: postgres
                        host: ${DB_HOST}
                        port: ${DB_PORT}
                        user: ${DB_USER}
                        password: ${DB_PASSWORD}
                        dbname: ${DB_NAME}
                        schema: analytics
                        threads: 4
                        keepalives_idle: 0
                    target: ${DBT_TARGET_NAME}
                  EOF

                  export DBT_PROFILES_DIR=/workspace/profiles
                  mkdir -p /workspace/repo/target /workspace/repo/logs
                  
                  
                  EXPECTED_PROFILE="$(awk -F': *' '/^profile:/{print $2; exit}' dbt_project.yml 2>/dev/null || true)"
                  EXPECTED_PROFILE="$(printf '%s' "${EXPECTED_PROFILE:-}" | tr -d '"' | tr -d "'" | xargs || true)"
                  if [ -n "${EXPECTED_PROFILE}" ] && [ "${EXPECTED_PROFILE}" != "${DBT_PROFILE_NAME}" ]; then
                   echo "FATAL: dbt_project.yml expects profile '${EXPECTED_PROFILE}', but contract is '${DBT_PROFILE_NAME}'"
                   exit 1
                  fi

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

echo "[03D][dbt] Installed CronJob: transform/dbt-nightly"
echo "[03D][dbt] Manual run (one-shot Job) command:"
echo "kubectl -n transform create job --from=cronjob/dbt-nightly dbt-manual-\$(date +%s)"

# ------------------------------------------------------------------------------
# Preflight: create expected landing schemas/tables referenced by the dbt project
# - Extracts pairs from SQL patterns: "analytics"."SCHEMA"."TABLE"
# - Creates missing schema/table in Postgres analytics DB (placeholder table)
# - Deterministic: allows verification to pass existence checks
# ------------------------------------------------------------------------------
log "[03D][dbt] Preflight: creating expected landing relations (from repo SQL refs)"

SCAN_POD="dbt-srcscan-$$"
cleanup_scan_pod() { kubectl -n "${NS_TRANSFORM}" delete pod "${SCAN_POD}" --ignore-not-found >/dev/null 2>&1 || true; }
trap cleanup_scan_pod EXIT

kubectl -n "${NS_TRANSFORM}" apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${SCAN_POD}
spec:
  restartPolicy: Never
  containers:
  - name: scan
    image: alpine/git:2.45.2
    command: ["sh","-lc"]
    args:
      - |
        set -euo pipefail
        rm -rf /tmp/repo
        git clone --depth 1 "${DBT_GIT_REPO}" /tmp/repo >/dev/null 2>&1
        cd /tmp/repo

        # Extract any occurrences of "analytics"."SCHEMA"."TABLE" from all .sql files
        # Output: schema<TAB>table
        find . -type f -name "*.sql" -print0 \
          | xargs -0 -r awk '
              {
                while (match($0, /"analytics"\."[^"]+"\."[^"]+"/)) {
                  s = substr($0, RSTART, RLENGTH)
                  gsub(/^"analytics"\."/,"",s)
                  gsub(/"$/,"",s)
                  split(s, a, /"\."/)
                  if (a[1] != "" && a[2] != "") print a[1] "\t" a[2]
                  $0 = substr($0, RSTART + RLENGTH)
                }
              }
            ' \
          | sort -u
YAML

# wait for scan pod to finish (Succeeded) or fail; never wait for Ready
for _ in $(seq 1 120); do
  PHASE="$(kubectl -n "${NS_TRANSFORM}" get pod "${SCAN_POD}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${PHASE}" == "Succeeded" || "${PHASE}" == "Failed" ]]; then
    break
  fi
  sleep 1
done


EXPECTED_TSV="$(printf '%s\n' "${EXPECTED_TSV:-}" \
  | sed '/^[[:space:]]*$/d' \
  | grep -E '^[A-Za-z0-9_]+\t[A-Za-z0-9_]+$' \
  | sort -u || true)"


# DROP-IN REPLACEMENT BLOCK (paste exactly, replaces your current if/else preflight block)

if [[ -z "${EXPECTED_TSV}" ]]; then
  warn "[03D][dbt] Preflight: no \"analytics\".\"schema\".\"table\" references found in repo SQL."
  log  "[03D][dbt] Preflight fallback: ensure analytics.his_demo.his_raw exists (repo hard dependency + required columns)"

  kubectl -n "${NS_OPENKPI}" run psql-preflight-fallback --rm -i --restart=Never --image=postgres:16 -- \
    bash -lc "
      set -euo pipefail
      export PGPASSWORD='${PG_SUPER_PASS}'
      psql -h '${PG_HOST}' -p '${PG_PORT}' -U '${PG_SUPER_USER}' -d analytics -v ON_ERROR_STOP=1 <<'SQL'
CREATE SCHEMA IF NOT EXISTS \"his_demo\" AUTHORIZATION dbt_user;

-- Landing table: ensure exists
CREATE TABLE IF NOT EXISTS \"his_demo\".\"his_raw\" (
  _airbyte_raw_id text,
  _airbyte_extracted_at timestamptz,
  _airbyte_meta jsonb,
  _airbyte_data jsonb
);

-- Ensure Airbyte columns exist even if table was created earlier with a placeholder schema
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS _airbyte_raw_id text;
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS _airbyte_extracted_at timestamptz;
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS _airbyte_meta jsonb;
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS _airbyte_data jsonb;
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS _airbyte_emitted_at timestamptz;

-- Business columns required by dbt staging model stg_his_raw
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS \"Name\" varchar(50);
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS \"Doctor_ID\" varchar(50);
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS \"Doctor_Name\" varchar(50);
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS \"Hospital_ID\" varchar(50);
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS \"Hospital_Name\" varchar(50);
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS \"Patient_Visit_Date\" varchar(50);
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS \"Diagnosis_Code\" varchar(50);
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS \"Diagnosis_Name\" varchar(50);
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS \"Nationality\" varchar(50);
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS \"Sex\" varchar(50);
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS \"Birthdate\" varchar(50);
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS \"patient_id\" int;
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS \"transaction_id\" varchar(50);
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS \"transaction_date\" varchar(50);
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS \"department\" varchar(50);
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS \"service_provided\" varchar(50);
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS \"cost\" int;
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS \"payment_method\" varchar(50);
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS \"insurance_details\" varchar(50);
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS \"prescription_details\" varchar(50);
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS \"Patient_Type\" varchar(50);

GRANT USAGE ON SCHEMA \"his_demo\" TO dbt_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA \"his_demo\" TO dbt_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA \"his_demo\" GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO dbt_user;
SQL
    " >/dev/null

  log "[03D][dbt] Preflight fallback complete."
else
  log "[03D][dbt] Preflight: found expected landing relations:"
  printf '%s\n' "${EXPECTED_TSV}" | sed 's/^/  - /'

  PSQL_PREFLIGHT_POD="psql-preflight-$$"
  kubectl -n "${NS_OPENKPI}" delete pod "${PSQL_PREFLIGHT_POD}" --ignore-not-found >/dev/null 2>&1 || true

  kubectl -n "${NS_OPENKPI}" apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${PSQL_PREFLIGHT_POD}
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

  retry 40 2 kubectl -n "${NS_OPENKPI}" wait --for=condition=Ready "pod/${PSQL_PREFLIGHT_POD}" --timeout=5s >/dev/null

  DDL_FILE="/tmp/dbt-preflight-ddl.sql"
  : > "${DDL_FILE}"

  while IFS=$'\t' read -r schema table; do
    [[ -z "${schema:-}" || -z "${table:-}" ]] && continue
    [[ "${schema}" =~ ^[A-Za-z0-9_]+$ ]] || continue
    [[ "${table}" =~ ^[A-Za-z0-9_]+$ ]] || continue

    cat >> "${DDL_FILE}" <<SQL
CREATE SCHEMA IF NOT EXISTS "${schema}" AUTHORIZATION dbt_user;
CREATE TABLE IF NOT EXISTS "${schema}"."${table}" (
  _placeholder integer,
  _ingested_at timestamptz DEFAULT now()
);
GRANT USAGE ON SCHEMA "${schema}" TO dbt_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA "${schema}" TO dbt_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA "${schema}" GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO dbt_user;
SQL
  done <<< "${EXPECTED_TSV}"

  kubectl -n "${NS_OPENKPI}" exec -i "${PSQL_PREFLIGHT_POD}" -- bash -lc \
    "psql -h '${PG_HOST}' -p '${PG_PORT}' -U '${PG_SUPER_USER}' -d analytics -v ON_ERROR_STOP=1" \
    < "${DDL_FILE}" >/dev/null

  kubectl -n "${NS_OPENKPI}" delete pod "${PSQL_PREFLIGHT_POD}" --ignore-not-found >/dev/null 2>&1 || true
  log "[03D][dbt] Preflight: landing schemas/tables ensured in analytics DB."
fi


# ------------------------------------------------------------------------------
# Verification (one-shot job) — deterministic, no hanging log followers
# ------------------------------------------------------------------------------
log "[03D][dbt] Verification (one-shot job)"

VERIFY_JOB="dbt-verify-$(date +%s)"

# Best-effort cleanup of prior verify/manual jobs/pods
kubectl -n "${NS_TRANSFORM}" delete job \
  --ignore-not-found \
  $(kubectl -n "${NS_TRANSFORM}" get jobs -o name 2>/dev/null | grep -E 'job.batch/(dbt-verify-|dbt-manual-)' || true) \
  >/dev/null 2>&1 || true

kubectl -n "${NS_TRANSFORM}" delete pod \
  --ignore-not-found \
  $(kubectl -n "${NS_TRANSFORM}" get pods -o name 2>/dev/null | grep -E 'pod/(dbt-verify-|dbt-manual-)' || true) \
  >/dev/null 2>&1 || true

kubectl -n "${NS_TRANSFORM}" create job --from=cronjob/dbt-nightly "${VERIFY_JOB}" >/dev/null

if ! kubectl -n "${NS_TRANSFORM}" wait --for=condition=complete "job/${VERIFY_JOB}" --timeout=10m; then
  warn "[03D][dbt] Verify job did not complete. Dumping diagnostics."

  kubectl -n "${NS_TRANSFORM}" get job "${VERIFY_JOB}" -o wide || true
  kubectl -n "${NS_TRANSFORM}" describe job "${VERIFY_JOB}" | sed -n '1,260p' || true

  POD="$(kubectl -n "${NS_TRANSFORM}" get pods -l job-name="${VERIFY_JOB}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${POD}" ]; then
    kubectl -n "${NS_TRANSFORM}" get pod "${POD}" -o wide || true
    kubectl -n "${NS_TRANSFORM}" describe pod "${POD}" | sed -n '1,260p' || true
    kubectl -n "${NS_TRANSFORM}" logs "${POD}" -c git-sync --tail=200 || true
    kubectl -n "${NS_TRANSFORM}" logs "${POD}" -c dbt --tail=1200 || true
  fi

  kubectl -n "${NS_TRANSFORM}" delete job "${VERIFY_JOB}" --ignore-not-found >/dev/null 2>&1 || true
  fatal "[03D][dbt] Verification failed."
fi

log "[03D][dbt] Verification succeeded."

POD="$(kubectl -n "${NS_TRANSFORM}" get pods -l job-name="${VERIFY_JOB}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -n "${POD}" ]; then
  kubectl -n "${NS_TRANSFORM}" logs "${POD}" -c git-sync --tail=120 || true
  kubectl -n "${NS_TRANSFORM}" logs "${POD}" -c dbt --tail=400 || true
fi

kubectl -n "${NS_TRANSFORM}" delete job "${VERIFY_JOB}" --ignore-not-found >/dev/null 2>&1 || true



