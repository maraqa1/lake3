#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/../../../00-env.sh"

log "[03-dbt] start"

require_cmd kubectl

require_var TRANSFORM_NS
require_var DBT_IMAGE
require_var DBT_GIT_REPO
require_var DBT_CRON_SCHEDULE
require_var DBT_PROFILE_NAME
require_var DBT_TARGET_NAME

require_var DBT_DB_HOST
require_var DBT_DB_PORT
require_var DBT_DB_NAME
require_var DBT_DB_USER
require_var DBT_DB_PASSWORD

NS="${TRANSFORM_NS}"

kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}"

# Secret for dbt connection
cat <<YAML | kubectl -n "${NS}" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: dbt-secret
type: Opaque
stringData:
  DBT_DB_HOST: "${DBT_DB_HOST}"
  DBT_DB_PORT: "${DBT_DB_PORT}"
  DBT_DB_NAME: "${DBT_DB_NAME}"
  DBT_DB_USER: "${DBT_DB_USER}"
  DBT_DB_PASSWORD: "${DBT_DB_PASSWORD}"
YAML

# ConfigMap: profiles.yml (dbt-postgres)
cat <<YAML | kubectl -n "${NS}" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: dbt-profiles
data:
  profiles.yml: |
    ${DBT_PROFILE_NAME}:
      target: ${DBT_TARGET_NAME}
      outputs:
        ${DBT_TARGET_NAME}:
          type: postgres
          host: {{ env_var('DBT_DB_HOST') }}
          port: {{ env_var('DBT_DB_PORT') | int }}
          user: {{ env_var('DBT_DB_USER') }}
          password: {{ env_var('DBT_DB_PASSWORD') }}
          dbname: {{ env_var('DBT_DB_NAME') }}
          schema: analytics
          threads: 4
          keepalives_idle: 0
          connect_timeout: 10
YAML

# CronJob: clone repo and run dbt
cat <<'YAML' | envsubst | kubectl -n "${NS}" apply -f -
apiVersion: batch/v1
kind: CronJob
metadata:
  name: dbt-run
spec:
  schedule: "${DBT_CRON_SCHEDULE}"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: dbt
              image: ${DBT_IMAGE}
              imagePullPolicy: IfNotPresent
              envFrom:
                - secretRef:
                    name: dbt-secret
              env:
                - name: DBT_PROFILES_DIR
                  value: /dbt
                - name: DBT_GIT_REPO
                  value: ${DBT_GIT_REPO}
              command: ["/bin/bash","-lc"]
              args:
                - |
                  set -euo pipefail
                  apk add --no-cache git >/dev/null 2>&1 || true
                  rm -rf /work && mkdir -p /work
                  git clone --depth 1 "${DBT_GIT_REPO}" /work/repo
                  cp -r /dbt /tmp/dbt
                  mkdir -p /tmp/dbt
                  cp /dbt/profiles.yml /tmp/dbt/profiles.yml
                  cd /work/repo
                  dbt --version
                  dbt deps --profiles-dir /tmp/dbt
                  dbt debug --profiles-dir /tmp/dbt --target ${DBT_TARGET_NAME}
                  dbt run --profiles-dir /tmp/dbt --target ${DBT_TARGET_NAME}
              volumeMounts:
                - name: profiles
                  mountPath: /dbt
          volumes:
            - name: profiles
              configMap:
                name: dbt-profiles
YAML

log "[03-dbt] done"
