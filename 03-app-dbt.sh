#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# MODULE 03D — APP (dbt)
# FILE: 03-app-dbt.sh
#
# Objective:
# - Deploy dbt runner in namespace "transform"
# - Create dedicated analytics DB + dbt_user in shared Postgres (open-kpi)
# - Create CronJob: dbt run + dbt test
# - Allow manual one-shot Job via CronJob template
#
# Notes:
# - local-path StorageClass often uses WaitForFirstConsumer; PVC can remain Pending
#   until a pod mounts it. Tests include a PVC binder pod to force binding.
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/00-env.sh"
# shellcheck source=/dev/null
. "${HERE}/00-lib.sh"

: "${KUBECONFIG:=/root/.kube/config}"
export KUBECONFIG

require_cmd kubectl awk sed tr head base64

NS_TRANSFORM="transform"
NS_OPENKPI="${NS:-open-kpi}"
: "${STORAGE_CLASS:=local-path}"

ENV_FILE="/root/open-kpi.env"
touch "${ENV_FILE}"
chmod 0600 "${ENV_FILE}"

persist_kv_if_missing() {
  local key="$1" val="$2"
  if ! grep -qE "^${key}=" "${ENV_FILE}"; then
    printf '%s=%q\n' "${key}" "${val}" >> "${ENV_FILE}"
  fi
  # shellcheck disable=SC1090
  set -a; . "${ENV_FILE}"; set +a
}

persist_kv_if_missing "DBT_GIT_REPO" "https://github.com/ORG/REPO.git"
persist_kv_if_missing "DBT_CRON_SCHEDULE" "0 2 * * *"
persist_kv_if_missing "DBT_IMAGE" "ghcr.io/dbt-labs/dbt-postgres:1.8.0"

if ! grep -qE "^DBT_DB_PASSWORD=" "${ENV_FILE}"; then
  DBT_DB_PASSWORD_GEN="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)"
  printf 'DBT_DB_PASSWORD=%q\n' "${DBT_DB_PASSWORD_GEN}" >> "${ENV_FILE}"
fi
# shellcheck disable=SC1090
set -a; . "${ENV_FILE}"; set +a

: "${DBT_GIT_REPO:?missing DBT_GIT_REPO}"
: "${DBT_CRON_SCHEDULE:?missing DBT_CRON_SCHEDULE}"
: "${DBT_IMAGE:?missing DBT_IMAGE}"
: "${DBT_DB_PASSWORD:?missing DBT_DB_PASSWORD}"

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

log "[03D][DBT] start (ns=${NS_TRANSFORM}, pg=${PG_HOST}:${PG_PORT}, sc=${STORAGE_CLASS})"
ensure_ns "${NS_TRANSFORM}"

PSQL_POD="psql-admin-$$"
VERIFY_JOB=""
PVC_BINDER_POD="pvc-binder-$$"

cleanup_all() {
  kubectl -n "${NS_OPENKPI}" delete pod "${PSQL_POD}" --ignore-not-found >/dev/null 2>&1 || true
  [[ -n "${VERIFY_JOB}" ]] && kubectl -n "${NS_TRANSFORM}" delete job "${VERIFY_JOB}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${NS_TRANSFORM}" delete pod "${PVC_BINDER_POD}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${NS_TRANSFORM}" delete pod dbt-curl --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup_all EXIT

log "[03D][DBT] ensure admin pod for psql"
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

retry 60 2 kubectl -n "${NS_OPENKPI}" wait --for=condition=Ready "pod/${PSQL_POD}" --timeout=5s >/dev/null

log "[03D][DBT] ensure Postgres objects: role=dbt_user, db=analytics"
SQL=$(cat <<'EOSQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dbt_user') THEN
    CREATE ROLE dbt_user LOGIN PASSWORD '__DBT_PASS__';
  END IF;
END
$$;

SELECT format('CREATE DATABASE %I OWNER %I', 'analytics', 'dbt_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'analytics')
\gexec

ALTER DATABASE analytics OWNER TO dbt_user;
ALTER ROLE dbt_user SET search_path TO public;
EOSQL
)
SQL="${SQL/__DBT_PASS__/${DBT_DB_PASSWORD}}"

kubectl -n "${NS_OPENKPI}" exec -i "${PSQL_POD}" -- bash -lc \
  "psql -h '${PG_HOST}' -p '${PG_PORT}' -U '${PG_SUPER_USER}' -d postgres -v ON_ERROR_STOP=1" \
  <<<"${SQL}" >/dev/null

log "[03D][DBT] apply secret: transform/dbt-secret"
kubectl -n "${NS_TRANSFORM}" create secret generic dbt-secret \
  --from-literal=DB_HOST="${PG_HOST}" \
  --from-literal=DB_PORT="${PG_PORT}" \
  --from-literal=DB_NAME="analytics" \
  --from-literal=DB_USER="dbt_user" \
  --from-literal=DB_PASSWORD="${DBT_DB_PASSWORD}" \
  --from-literal=DBT_GIT_REPO="${DBT_GIT_REPO}" \
  --from-literal=DBT_IMAGE="${DBT_IMAGE}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "[03D][DBT] ensure pvc: transform/dbt-workdir-pvc"
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

log "[03D][DBT] apply cronjob: transform/dbt-nightly (schedule=${DBT_CRON_SCHEDULE})"
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
            - name: GIT_TERMINAL_PROMPT
              value: "0"
            - name: GIT_ASKPASS
              value: "/bin/true"
            command: ["sh","-lc"]
            args:
              - |
                set -euo pipefail
                REPO="$(printf '%s' "${DBT_GIT_REPO}" | tr -d '\r')"
                echo "[git-sync] repo=${REPO}"
                mkdir -p /workspace
                rm -rf /workspace/repo
                git clone --depth 1 "${REPO}" /workspace/repo
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

# ------------------------------------------------------------------------------
# Tests (production-level)
# ------------------------------------------------------------------------------
norm_ws() { printf '%s' "$1" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//'; }

log "[03D][DBT][TEST] begin"

log "[03D][DBT][TEST][T01] kubectl connectivity"
kubectl version >/dev/null 2>&1 || fatal "[03D][DBT][TEST][T01] kubectl cannot reach cluster"

log "[03D][DBT][TEST][T02] required objects exist: secret + pvc + cronjob"
kubectl -n "${NS_TRANSFORM}" get secret dbt-secret >/dev/null 2>&1 || fatal "[03D][DBT][TEST][T02] missing secret transform/dbt-secret"
kubectl -n "${NS_TRANSFORM}" get pvc dbt-workdir-pvc >/dev/null 2>&1 || fatal "[03D][DBT][TEST][T02] missing pvc transform/dbt-workdir-pvc"
kubectl -n "${NS_TRANSFORM}" get cronjob dbt-nightly >/dev/null 2>&1 || fatal "[03D][DBT][TEST][T02] missing cronjob transform/dbt-nightly"

log "[03D][DBT][TEST][T03] PVC bound (handle WaitForFirstConsumer by mounting once)"
PVC_PHASE="$(kubectl -n "${NS_TRANSFORM}" get pvc dbt-workdir-pvc -o jsonpath='{.status.phase}' 2>/dev/null || true)"
if [[ "${PVC_PHASE}" != "Bound" ]]; then
  kubectl -n "${NS_TRANSFORM}" delete pod "${PVC_BINDER_POD}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${NS_TRANSFORM}" apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${PVC_BINDER_POD}
spec:
  restartPolicy: Never
  volumes:
  - name: workdir
    persistentVolumeClaim:
      claimName: dbt-workdir-pvc
  containers:
  - name: busybox
    image: busybox:1.36
    command: ["sh","-lc","set -e; echo ok >/workdir/.bind-test; sleep 5"]
    volumeMounts:
    - name: workdir
      mountPath: /workdir
YAML
  retry 60 2 bash -lc "kubectl -n '${NS_TRANSFORM}' get pvc dbt-workdir-pvc -o jsonpath='{.status.phase}' | grep -qx Bound" || {
    kubectl -n "${NS_TRANSFORM}" get pvc dbt-workdir-pvc -o wide || true
    kubectl -n "${NS_TRANSFORM}" describe pvc dbt-workdir-pvc | sed -n '1,220p' || true
    kubectl -n "${NS_TRANSFORM}" get events --sort-by=.lastTimestamp | tail -n 120 || true
    fatal "[03D][DBT][TEST][T03] pvc not Bound"
  }
  kubectl -n "${NS_TRANSFORM}" delete pod "${PVC_BINDER_POD}" --ignore-not-found >/dev/null 2>&1 || true
fi

log "[03D][DBT][TEST][T04] Postgres objects: role=dbt_user, db=analytics"
kubectl -n "${NS_OPENKPI}" exec -i "${PSQL_POD}" -- bash -lc \
  "psql -h '${PG_HOST}' -p '${PG_PORT}' -U '${PG_SUPER_USER}' -d postgres -v ON_ERROR_STOP=1 -tAc \"SELECT 1 FROM pg_roles WHERE rolname='dbt_user'\"" \
  | tr -d ' \n' | grep -qx 1 || fatal "[03D][DBT][TEST][T04] role dbt_user missing"

kubectl -n "${NS_OPENKPI}" exec -i "${PSQL_POD}" -- bash -lc \
  "psql -h '${PG_HOST}' -p '${PG_PORT}' -U '${PG_SUPER_USER}' -d postgres -v ON_ERROR_STOP=1 -tAc \"SELECT 1 FROM pg_database WHERE datname='analytics'\"" \
  | tr -d ' \n' | grep -qx 1 || fatal "[03D][DBT][TEST][T04] database analytics missing"

log "[03D][DBT][TEST][T05] CronJob schedule matches contract (whitespace-normalized)"
FOUND_SCHED_RAW="$(kubectl -n "${NS_TRANSFORM}" get cronjob dbt-nightly -o jsonpath='{.spec.schedule}' 2>/dev/null || true)"
FOUND_SCHED="$(norm_ws "${FOUND_SCHED_RAW}")"
EXPECT_SCHED="$(norm_ws "${DBT_CRON_SCHEDULE}")"
[[ "${FOUND_SCHED}" == "${EXPECT_SCHED}" ]] || fatal "[03D][DBT][TEST][T05] cron schedule mismatch"

log "[03D][DBT][TEST][T06] Smoke run (resilient): create Job and poll status up to 20m"
kubectl -n "${NS_TRANSFORM}" delete job --ignore-not-found \
  $(kubectl -n "${NS_TRANSFORM}" get jobs -o name 2>/dev/null | grep -E 'job.batch/dbt-verify-' || true) \
  >/dev/null 2>&1 || true

VERIFY_JOB="dbt-verify-$(date +%s)"
kubectl -n "${NS_TRANSFORM}" create job --from=cronjob/dbt-nightly "${VERIFY_JOB}" >/dev/null

# Poll loop avoids a single long-lived apiserver watch (more tolerant to transient resets).
# Success condition: status.succeeded >= 1
# Failure condition: status.failed >= 1
DEADLINE=$(( $(date +%s) + 1200 ))  # 20m
while true; do
  now="$(date +%s)"
  if (( now > DEADLINE )); then
    warn "[03D][DBT][TEST][T06] timeout waiting for job/${VERIFY_JOB}"
    break
  fi

  # tolerate transient API errors (including connection resets)
  SUC="$(kubectl -n "${NS_TRANSFORM}" get job "${VERIFY_JOB}" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
  FAI="$(kubectl -n "${NS_TRANSFORM}" get job "${VERIFY_JOB}" -o jsonpath='{.status.failed}' 2>/dev/null || true)"

  [[ -z "${SUC}" ]] && SUC="0"
  [[ -z "${FAI}" ]] && FAI="0"

  if [[ "${SUC}" =~ ^[0-9]+$ ]] && (( SUC >= 1 )); then
    break
  fi
  if [[ "${FAI}" =~ ^[0-9]+$ ]] && (( FAI >= 1 )); then
    break
  fi

  sleep 5
done

SUC_FINAL="$(kubectl -n "${NS_TRANSFORM}" get job "${VERIFY_JOB}" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
FAI_FINAL="$(kubectl -n "${NS_TRANSFORM}" get job "${VERIFY_JOB}" -o jsonpath='{.status.failed}' 2>/dev/null || true)"
[[ -z "${SUC_FINAL}" ]] && SUC_FINAL="0"
[[ -z "${FAI_FINAL}" ]] && FAI_FINAL="0"

if [[ "${SUC_FINAL}" =~ ^[0-9]+$ ]] && (( SUC_FINAL >= 1 )); then
  :
else
  warn "[03D][DBT][TEST][T06] smoke run failed or timed out; diagnostics:"
  kubectl -n "${NS_TRANSFORM}" get job "${VERIFY_JOB}" -o wide || true
  kubectl -n "${NS_TRANSFORM}" describe job "${VERIFY_JOB}" | sed -n '1,260p' || true
  POD="$(kubectl -n "${NS_TRANSFORM}" get pods -l job-name="${VERIFY_JOB}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${POD}" ]]; then
    kubectl -n "${NS_TRANSFORM}" describe pod "${POD}" | sed -n '1,260p' || true
    kubectl -n "${NS_TRANSFORM}" logs "${POD}" -c git-sync --tail=200 || true
    kubectl -n "${NS_TRANSFORM}" logs "${POD}" -c dbt --tail=400 || true
  fi
  fatal "[03D][DBT][TEST][T06] smoke run failed"
fi

log "[03D][DBT][TEST] PASS"
echo "[03D][dbt] Installed CronJob: transform/dbt-nightly"
echo "[03D][dbt] Manual run:"
echo "kubectl -n transform create job --from=cronjob/dbt-nightly dbt-manual-\$(date +%s)"
log "[03D][DBT] done"
