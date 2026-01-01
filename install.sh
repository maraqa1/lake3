#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ts(){ date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log(){ echo "$(ts) [INSTALL] $*"; }

run_step(){
  local name="$1"; shift
  local script="$1"; shift
  log "start: ${name}"
  ( cd "${HERE}" && bash "${script}" )
  while [[ "$#" -gt 0 ]]; do
    local t="$1"; shift
    log "tests: ${name}"
    ( cd "${HERE}" && bash "${t}" )
  done
  log "done: ${name}"
}

run_step "00-env" "modules/00-env/00-env.sh" "modules/00-env/tests.sh"
run_step "01-core" "modules/01-core/01-core.sh" "modules/01-core/tests.sh"
run_step "02-postgres" "modules/02-data-plane/02-postgres.sh" "modules/02-data-plane/tests-postgres.sh"
run_step "02-minio" "modules/02-data-plane/02-minio.sh" "modules/02-data-plane/tests-minio.sh"
#run_step "02-minio-https" "modules/02-data-plane/02-minio-https.sh"
run_step "03-airbyte" "modules/03-apps/airbyte/03-app-airbyte.sh" "modules/03-apps/airbyte/03-app-airbyte-tests.sh"
run_step "03-metabase" "modules/03-apps/metabase/03-app-metabase.sh" "modules/03-apps/metabase/03-app-metabase-tests.sh"
run_step "03-n8n" "modules/03-apps/n8n/03-app-n8n.sh" "modules/03-apps/n8n/03-app-n8n-tests.sh"
run_step "03-zammad" "modules/03-apps/zammad/03-app-zammad.sh" "modules/03-apps/zammad/03-app-zammad-tests.sh"
run_step "03-dbt" "modules/03-apps/dbt/03-app-dbt.sh" "modules/03-apps/dbt/03-app-dbt-tests.sh"
run_step "04-portal-api" "modules/04-portal/04-portal-api.sh" "modules/04-portal/tests-api.sh"
run_step "04A-api-patch" "modules/04-portal/04A-api-links.patch.sh"
run_step "04-portal-ui" "modules/04-portal/04-portal-ui.sh" "modules/04-portal/tests-ui.sh"
run_step "04C-ui-reset" "modules/04-portal/04C-ui-rollout-reset.patch.sh"
run_step "04B-ui-patch" "modules/04-portal/04B-ui-links.patch.sh"
run_step "05-validate" "modules/05-validate/05-validate.sh"
