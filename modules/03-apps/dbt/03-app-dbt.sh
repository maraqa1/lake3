#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# MODULE 03D — APP (dbt)  [PRODUCTION / CONTRACT-BASED / IDEMPOTENT]
# FILE: 03-app-dbt.sh
#
# Objective:
# - Deploy dbt runner in namespace "transform"
# - Ensure dedicated analytics DB + dbt_user in shared Postgres (open-kpi)
# - Deterministic dbt profile resolution (repo expects profile "his_demo" by default)
# - Create:
#   1) CronJob: dbt run + dbt test (nightly by default)
#   2) One-shot Job (manual trigger instructions)
# - Preflight:
#   - Scan repo for SQL refs "analytics"."SCHEMA"."TABLE" and ensure they exist
#   - If none found, enforce fallback landing table analytics.his_demo.his_raw with required columns
#
# Hard rules:
# - Source 00-env.sh and 00-lib.sh
# - Kubernetes-native (kubectl apply only)
# - No ingress exposure
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Find OpenKPI root by walking up until we see 00-env.sh
ROOT="${HERE}"
while [[ "${ROOT}" != "/" && ! -f "${ROOT}/00-env.sh" ]]; do
  ROOT="$(dirname "${ROOT}")"
done
[[ -f "${ROOT}/00-env.sh" ]] || { echo "[FATAL] cannot find 00-env.sh above ${HERE}"; exit 1; }
[[ -f "${ROOT}/00-lib.sh" ]] || { echo "[FATAL] cannot find 00-lib.sh above ${HERE}"; exit 1; }

# shellcheck source=/dev/null
. "${ROOT}/00-env.sh"
# shellcheck source=/dev/null
. "${ROOT}/00-lib.sh"

: "${KUBECONFIG:=/root/.kube/config}"
export KUBECONFIG

require_cmd kubectl
require_cmd awk
require_cmd sed
require_cmd tr
require_cmd head
require_cmd base64
require_cmd grep
require_cmd sort
require_cmd xargs
require_cmd find
require_cmd seq

# ------------------------------------------------------------------------------
# trap chaining (do not clobber EXIT traps)
# ------------------------------------------------------------------------------
trap_add() {
  local cmd="$1"
  local sig="${2:-EXIT}"
  local existing=""
  existing="$(trap -p "${sig}" | sed -E "s/^trap -- '(.*)' ${sig}$/\1/")" || true
  if [[ -n "${existing}" ]]; then
    trap "${existing}; ${cmd}" "${sig}"
  else
    trap "${cmd}" "${sig}"
  fi
}

# ------------------------------------------------------------------------------
# Namespaces + knobs
# ------------------------------------------------------------------------------
NS_TRANSFORM="${TRANSFORM_NS:-transform}"
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
  local ns="$1" secret="$2" field="$3"
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
# Ensure transform namespace
# ------------------------------------------------------------------------------
ensure_ns "${NS_TRANSFORM}"

# ------------------------------------------------------------------------------
# Ensure analytics DB + dbt_user in shared Postgres (idempotent + password enforced)
# ------------------------------------------------------------------------------
if [[ "${DBT_MANAGE_DB_OBJECTS}" == "true" ]]; then
  log "[03D][dbt] Ensuring Postgres objects: db=analytics, role=dbt_user (password enforced)"

  PSQL_ADMIN_POD="psql-admin-$$"
  cleanup_psql_admin() { kubectl -n "${NS_OPENKPI}" delete pod "${PSQL_ADMIN_POD}" --ignore-not-found >/dev/null 2>&1 || true; }
  trap_add "cleanup_psql_admin" EXIT

  kubectl -n "${NS_OPENKPI}" apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${PSQL_ADMIN_POD}
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

  retry 40 2 kubectl -n "${NS_OPENKPI}" wait --for=condition=Ready "pod/${PSQL_ADMIN_POD}" --timeout=5s >/dev/null

  kubectl -n "${NS_OPENKPI}" exec -i "${PSQL_ADMIN_POD}" -- bash -lc "
    set -euo pipefail
    psql -h '${PG_HOST}' -p '${PG_PORT}' -U '${PG_SUPER_USER}' -d postgres -v ON_ERROR_STOP=1 -v dbt_pass='${DBT_DB_PASSWORD}' <<'SQL'
SELECT 'CREATE ROLE dbt_user LOGIN PASSWORD ' || quote_literal(:'dbt_pass') || ';'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='dbt_user')
\\gexec

ALTER ROLE dbt_user WITH LOGIN PASSWORD :'dbt_pass';

SELECT format('CREATE DATABASE %I OWNER %I', 'analytics', 'dbt_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='analytics')
\\gexec

ALTER DATABASE analytics OWNER TO dbt_user;
ALTER ROLE dbt_user SET search_path TO public;
SQL
  " >/dev/null
fi

# ------------------------------------------------------------------------------
# Apply dbt secret in transform namespace (canonical destination only)
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

log "[03D][dbt] Applying CronJob dbt-nightly (schedule=${DBT_CRON_SCHEDULE})"

kubectl -n "${NS_TRANSFORM}" delete cronjob dbt-nightly --ignore-not-found >/dev/null 2>&1 || true

kubectl -n "${NS_TRANSFORM}" apply -f - <<YAML
apiVersion: batch/v1
kind: CronJob
metadata:
  name: dbt-nightly
  namespace: ${NS_TRANSFORM}
spec:
  schedule: "${DBT_CRON_SCHEDULE}"
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
              command:
                - sh
                - -lc
              args:
                - |
                  set -euo pipefail
                  mkdir -p /workspace
                  rm -rf /workspace/repo
                  git clone --depth 1 "\${DBT_GIT_REPO}" /workspace/repo
              volumeMounts:
                - name: workdir
                  mountPath: /workspace
          containers:
            - name: dbt
              image: ${DBT_IMAGE}
              env:
                - name: DB_HOST
                  valueFrom:
                    secretKeyRef:
                      name: dbt-secret
                      key: DB_HOST
                - name: DB_PORT
                  valueFrom:
                    secretKeyRef:
                      name: dbt-secret
                      key: DB_PORT
                - name: DB_NAME
                  valueFrom:
                    secretKeyRef:
                      name: dbt-secret
                      key: DB_NAME
                - name: DB_USER
                  valueFrom:
                    secretKeyRef:
                      name: dbt-secret
                      key: DB_USER
                - name: DB_PASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: dbt-secret
                      key: DB_PASSWORD
                - name: DBT_PROFILE_NAME
                  valueFrom:
                    secretKeyRef:
                      name: dbt-secret
                      key: DBT_PROFILE_NAME
                - name: DBT_TARGET_NAME
                  valueFrom:
                    secretKeyRef:
                      name: dbt-secret
                      key: DBT_TARGET_NAME
              workingDir: /workspace/repo
              command:
                - bash
                - -lc
              args:
                - |
                  set -euo pipefail

                  case "\${DB_PORT}" in
                    ''|*[!0-9]*)
                      echo "FATAL: DB_PORT must be numeric, got: '\${DB_PORT}'"
                      exit 1
                      ;;
                  esac

                  mkdir -p /workspace/profiles

                  # Write profiles.yml WITHOUT heredocs (prevents indentation/termination issues)
                  {
                    printf '%s\n' "\${DBT_PROFILE_NAME}:"
                    printf '%s\n' "  outputs:"
                    printf '%s\n' "    \${DBT_TARGET_NAME}:"
                    printf '%s\n' "      type: postgres"
                    printf '%s\n' "      host: \${DB_HOST}"
                    printf '%s\n' "      port: \${DB_PORT}"
                    printf '%s\n' "      user: \${DB_USER}"
                    printf '%s\n' "      password: \${DB_PASSWORD}"
                    printf '%s\n' "      dbname: \${DB_NAME}"
                    printf '%s\n' "      schema: analytics"
                    printf '%s\n' "      threads: 4"
                    printf '%s\n' "      keepalives_idle: 0"
                    printf '%s\n' "  target: \${DBT_TARGET_NAME}"
                  } > /workspace/profiles/profiles.yml

                  export DBT_PROFILES_DIR=/workspace/profiles
                  mkdir -p /workspace/repo/target /workspace/repo/logs

                  EXPECTED_PROFILE="\$(awk -F': *' '/^profile:/{print \$2; exit}' dbt_project.yml 2>/dev/null || true)"
                  EXPECTED_PROFILE="$(printf '%s' "${EXPECTED_PROFILE:-}" | tr -d '"' | tr -d "'" | xargs || true)"
                  if [ -n "\${EXPECTED_PROFILE}" ] && [ "\${EXPECTED_PROFILE}" != "\${DBT_PROFILE_NAME}" ]; then
                    echo "FATAL: dbt_project.yml expects profile '\${EXPECTED_PROFILE}', but contract is '\${DBT_PROFILE_NAME}'"
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

retry 10 1 kubectl -n "${NS_TRANSFORM}" get cronjob dbt-nightly >/dev/null

echo "[03D][dbt] Installed CronJob: ${NS_TRANSFORM}/dbt-nightly"
echo "[03D][dbt] Manual run (one-shot Job) command:"
echo "kubectl -n ${NS_TRANSFORM} create job --from=cronjob/dbt-nightly dbt-manual-\$(date +%s)"
# ------------------------------------------------------------------------------
# Preflight: create expected landing schemas/tables referenced by the dbt project
# - Scan repo SQL for: "analytics"."SCHEMA"."TABLE"
# - Ensure missing schema/table in Postgres analytics DB
# - No interactive kubectl attach (prevents hanging)
# ------------------------------------------------------------------------------
log "[03D][dbt] Preflight: creating expected landing relations (from repo SQL refs)"

SCAN_POD="dbt-srcscan-$$"
cleanup_scan_pod() { kubectl -n "${NS_TRANSFORM}" delete pod "${SCAN_POD}" --ignore-not-found >/dev/null 2>&1 || true; }
trap_add "cleanup_scan_pod" EXIT

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

        # BusyBox-safe extractor:
        # 1) find .sql files
        # 2) grep occurrences of: "analytics"."SCHEMA"."TABLE"
        # 3) normalize -> SCHEMA<TAB>TABLE
        find . -type f -name "*.sql" -print0 \
          | xargs -0 -r grep -RohE '"analytics"\."[A-Za-z0-9_]+"\."[A-Za-z0-9_]+"' \
          | sed -E 's/^"analytics"\."//; s/"$//; s/"\."/\t/' \
          | sort -u || true
YAML

for _ in $(seq 1 180); do
  PHASE="$(kubectl -n "${NS_TRANSFORM}" get pod "${SCAN_POD}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "${PHASE}" == "Succeeded" || "${PHASE}" == "Failed" ]] && break
  sleep 1
done

if [[ "${PHASE}" == "Failed" ]]; then
  warn "[03D][dbt] SQL scan pod failed; dumping logs"
  kubectl -n "${NS_TRANSFORM}" logs "${SCAN_POD}" --tail=200 || true
fi

EXPECTED_TSV="$(kubectl -n "${NS_TRANSFORM}" logs "${SCAN_POD}" 2>/dev/null || true)"
EXPECTED_TSV="$(printf '%s\n' "${EXPECTED_TSV}" \
  | sed '/^[[:space:]]*$/d' \
  | grep -E '^[A-Za-z0-9_]+\t[A-Za-z0-9_]+$' \
  | sort -u || true)"

if [[ -z "${EXPECTED_TSV}" ]]; then
  warn "[03D][dbt] Preflight: no \"analytics\".\"schema\".\"table\" references found in repo SQL."
  log  "[03D][dbt] Preflight fallback: ensure analytics.his_demo.his_raw exists (hard dependency) + required columns"

  PREFLIGHT_POD="psql-preflight-fallback-$$"
  cleanup_preflight_pod() { kubectl -n "${NS_OPENKPI}" delete pod "${PREFLIGHT_POD}" --ignore-not-found >/dev/null 2>&1 || true; }
  trap_add "cleanup_preflight_pod" EXIT

  kubectl -n "${NS_OPENKPI}" apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${PREFLIGHT_POD}
  labels:
    app: psql-preflight-fallback
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

  retry 40 2 kubectl -n "${NS_OPENKPI}" wait --for=condition=Ready "pod/${PREFLIGHT_POD}" --timeout=5s >/dev/null

  kubectl -n "${NS_OPENKPI}" exec -i "${PREFLIGHT_POD}" -- bash -lc "
    set -euo pipefail
    psql -h '${PG_HOST}' -p '${PG_PORT}' -U '${PG_SUPER_USER}' -d analytics -v ON_ERROR_STOP=1 <<'SQL'
CREATE SCHEMA IF NOT EXISTS \"his_demo\" AUTHORIZATION dbt_user;

CREATE TABLE IF NOT EXISTS \"his_demo\".\"his_raw\" (
  _airbyte_raw_id text,
  _airbyte_extracted_at timestamptz,
  _airbyte_meta jsonb,
  _airbyte_data jsonb
);

ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS _airbyte_raw_id text;
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS _airbyte_extracted_at timestamptz;
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS _airbyte_meta jsonb;
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS _airbyte_data jsonb;
ALTER TABLE \"his_demo\".\"his_raw\" ADD COLUMN IF NOT EXISTS _airbyte_emitted_at timestamptz;

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
  cleanup_psql_preflight() { kubectl -n "${NS_OPENKPI}" delete pod "${PSQL_PREFLIGHT_POD}" --ignore-not-found >/dev/null 2>&1 || true; }
  trap_add "cleanup_psql_preflight" EXIT

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

  log "[03D][dbt] Preflight: landing schemas/tables ensured in analytics DB."
fi

# ------------------------------------------------------------------------------
# Verification (one-shot job) — deterministic, no hanging log followers
# ------------------------------------------------------------------------------
log "[03D][dbt] Verification (one-shot job)"

VERIFY_JOB="dbt-verify-$(date +%s)"

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
  if [[ -n "${POD}" ]]; then
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
if [[ -n "${POD}" ]]; then
  kubectl -n "${NS_TRANSFORM}" logs "${POD}" -c git-sync --tail=120 || true
  kubectl -n "${NS_TRANSFORM}" logs "${POD}" -c dbt --tail=400 || true
fi

kubectl -n "${NS_TRANSFORM}" delete job "${VERIFY_JOB}" --ignore-not-found >/dev/null 2>&1 || true
