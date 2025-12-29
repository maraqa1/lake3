#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Open KPI — top-level installer orchestrator (GitHub runner)
# File: install.sh
# ==============================================================================
# Order enforced:
#   00-env.sh (source only)
#   01-core.sh
#   02-data-plane.sh
#   02-A-minio-https.sh
#   03-app-airbyte.sh
#   03A-airbyte-minio-docstore-fix.sh
#   03-app-n8n.sh
#   03-app-zammad.sh          (now includes TLS/ingress enforcement; no 03C fix)
#   03-app-dbt.sh
#   03-app-metabase-prereqs.sh
#   03-app-metabase.sh
#
#   Portal (repeatable, enforced order):
#     04-portal-api-v2.sh
#     04A-api-links.patch.sh
#     04-portal-ui-v1.sh
#     04B-ui-links.patch.sh (optional)
#     04C-ui-rollout-reset.patch.sh (optional; applied automatically if present)
#
#   05-validate.sh
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
timestamp() { date -u +"%Y%m%dT%H%M%SZ"; }

usage() {
  cat <<'EOF'
Usage: ./install.sh [flags]

Flags:
  --core            Run core cluster setup (01-core.sh)
  --data            Run shared data plane (02-data-plane.sh)
  --minio-https     Run MinIO HTTPS module (02-A-minio-https.sh)

  --airbyte         Install Airbyte (03-app-airbyte.sh) + docstore fix (03A-airbyte-minio-docstore-fix.sh)
  --n8n             Install n8n (03-app-n8n.sh)
  --zammad          Install Zammad (03-app-zammad.sh)
  --dbt             Install dbt runner + cron (03-app-dbt.sh)

  --metabase        Ensure prerequisites + install Metabase
                    (03-app-metabase-prereqs.sh + 03-app-metabase.sh)

  --portal          Deploy portal API + patches + UI (+ optional rollout reset)
                    (04-portal-api-v2.sh + 04A-api-links.patch.sh + 04-portal-ui-v1.sh
                     + optional 04B-ui-links.patch.sh + optional 04C-ui-rollout-reset.patch.sh)

  --all             Run full install (default)
  -h, --help        Show help

Examples:
  ./install.sh
  ./install.sh --core --data --minio-https --airbyte
  ./install.sh --metabase
  ./install.sh --portal
EOF
}

mkdir -p /var/log/open-kpi
LOG_FILE="/var/log/open-kpi/install-$(timestamp).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[INSTALL] start $(timestamp)"
echo "[INSTALL] log $LOG_FILE"
echo "[INSTALL] cwd $HERE"

# Flags
RUN_CORE=0
RUN_DATA=0
RUN_MINIO_HTTPS=0
RUN_AIRBYTE=0
RUN_N8N=0
RUN_ZAMMAD=0
RUN_DBT=0
RUN_METABASE=0
RUN_PORTAL=0
RUN_ALL=1

if [[ $# -gt 0 ]]; then
  RUN_ALL=0
  while [[ $# -gt 0 ]]; do
    case "${1:-}" in
      --all) RUN_ALL=1 ;;
      --core) RUN_CORE=1 ;;
      --data) RUN_DATA=1 ;;
      --minio-https) RUN_MINIO_HTTPS=1 ;;
      --airbyte) RUN_AIRBYTE=1 ;;
      --n8n) RUN_N8N=1 ;;
      --zammad) RUN_ZAMMAD=1 ;;
      --dbt) RUN_DBT=1 ;;
      --metabase) RUN_METABASE=1 ;;
      --portal) RUN_PORTAL=1 ;;
      -h|--help) usage; exit 0 ;;
      *)
        echo "[INSTALL][ERR] unknown flag: $1"
        usage
        exit 2
        ;;
    esac
    shift
  done
fi

if [[ "$RUN_ALL" -eq 1 ]]; then
  RUN_CORE=1
  RUN_DATA=1
  RUN_MINIO_HTTPS=1
  RUN_AIRBYTE=1
  RUN_N8N=1
  RUN_ZAMMAD=1
  RUN_DBT=1
  RUN_METABASE=1
  RUN_PORTAL=1
fi

# Dependency tightening
if [[ "$RUN_AIRBYTE" -eq 1 ]]; then
  RUN_DATA=1
  RUN_MINIO_HTTPS=1
fi

if [[ "$RUN_MINIO_HTTPS" -eq 1 ]]; then
  RUN_DATA=1
fi

# n8n needs shared Postgres (data-plane)
if [[ "$RUN_N8N" -eq 1 ]]; then
  RUN_DATA=1
fi

# Zammad needs shared storage + ingress (core at least; data-plane recommended)
if [[ "$RUN_ZAMMAD" -eq 1 ]]; then
  RUN_CORE=1
  RUN_DATA=1
fi

# dbt runner needs shared Postgres/MinIO (data-plane)
if [[ "$RUN_DBT" -eq 1 ]]; then
  RUN_DATA=1
fi

# Metabase needs: core + data-plane
if [[ "$RUN_METABASE" -eq 1 ]]; then
  RUN_CORE=1
  RUN_DATA=1
fi

# Portal expects ingress/cert-manager already handled by core modules
if [[ "$RUN_PORTAL" -eq 1 ]]; then
  RUN_CORE=1
fi

# Validate required module files exist
need_file() {
  local f="$1"
  if [[ ! -f "$HERE/$f" ]]; then
    echo "[INSTALL][ERR] missing file: $HERE/$f"
    exit 2
  fi
}

need_file "00-env.sh"
need_file "00-lib.sh"
need_file "01-core.sh"
need_file "02-data-plane.sh"
need_file "02-A-minio-https.sh"
need_file "05-validate.sh"

if [[ "$RUN_AIRBYTE" -eq 1 ]]; then
  need_file "03-app-airbyte.sh"
  need_file "03A-airbyte-minio-docstore-fix.sh"
fi
if [[ "$RUN_N8N" -eq 1 ]]; then need_file "03-app-n8n.sh"; fi
if [[ "$RUN_ZAMMAD" -eq 1 ]]; then need_file "03-app-zammad.sh"; fi
if [[ "$RUN_DBT" -eq 1 ]]; then need_file "03-app-dbt.sh"; fi
if [[ "$RUN_METABASE" -eq 1 ]]; then
  need_file "03-app-metabase-prereqs.sh"
  need_file "03-app-metabase.sh"
fi

# Portal files (v2 API + patches + v1 UI)
if [[ "$RUN_PORTAL" -eq 1 ]]; then
  need_file "04-portal-api-v2.sh"
  need_file "04A-api-links.patch.sh"
  need_file "04-portal-ui-v1.sh"
  # 04B-ui-links.patch.sh is optional
  # 04C-ui-rollout-reset.patch.sh is optional
fi

# Source contract/env (must be source-only per contract)
# shellcheck disable=SC1091
. "$HERE/00-env.sh"

echo "[INSTALL] contract loaded"
echo "[INSTALL] NS=${NS:-}"
echo "[INSTALL] APP_DOMAIN=${APP_DOMAIN:-}"
echo "[INSTALL] TLS_MODE=${TLS_MODE:-}"
echo "[INSTALL] INGRESS_CLASS=${INGRESS_CLASS:-}"
echo "[INSTALL] STORAGE_CLASS=${STORAGE_CLASS:-}"
echo "[INSTALL] PORTAL_HOST=${PORTAL_HOST:-}"

run_step() {
  local name="$1"
  local script="$2"

  echo "------------------------------------------------------------------------------"
  echo "[INSTALL] step $name => $script"
  echo "[INSTALL] ts $(timestamp)"
  echo "------------------------------------------------------------------------------"

  chmod +x "$HERE/$script" || true
  "$HERE/$script"

  echo "[INSTALL] done $name"
}

# Ordered execution
if [[ "$RUN_CORE" -eq 1 ]]; then
  run_step "core" "01-core.sh"
fi

if [[ "$RUN_DATA" -eq 1 ]]; then
  run_step "data-plane" "02-data-plane.sh"
fi

if [[ "$RUN_MINIO_HTTPS" -eq 1 ]]; then
  run_step "minio-https" "02-A-minio-https.sh"
fi

# Apps
if [[ "$RUN_AIRBYTE" -eq 1 ]]; then
  run_step "airbyte" "03-app-airbyte.sh"
  run_step "airbyte-minio-docstore-fix" "03A-airbyte-minio-docstore-fix.sh"
fi

if [[ "$RUN_N8N" -eq 1 ]]; then
  run_step "n8n" "03-app-n8n.sh"
fi

if [[ "$RUN_ZAMMAD" -eq 1 ]]; then
  run_step "zammad" "03-app-zammad.sh"
fi

if [[ "$RUN_DBT" -eq 1 ]]; then
  run_step "dbt" "03-app-dbt.sh"
fi

if [[ "$RUN_METABASE" -eq 1 ]]; then
  run_step "metabase-prereqs" "03-app-metabase-prereqs.sh"
  run_step "metabase" "03-app-metabase.sh"
fi

# Portal (API v2 -> patch -> UI v1 -> optional patches) [repeatable]
if [[ "$RUN_PORTAL" -eq 1 ]]; then
  run_step "portal-api-v2" "04-portal-api-v2.sh"
  echo "[INSTALL][PORTAL] wait portal-api rollout"
  kubectl -n platform rollout status deployment portal-api --timeout=240s

  run_step "portal-api-links-patch" "04A-api-links.patch.sh" || true

  run_step "portal-ui-v1" "04-portal-ui-v1.sh"
  echo "[INSTALL][PORTAL] wait portal-ui rollout"
  kubectl -n platform rollout status deployment portal-ui --timeout=240s

  if [[ -f "${HERE}/04C-ui-rollout-reset.patch.sh" ]]; then
    run_step "portal-ui-rollout-reset" "04C-ui-rollout-reset.patch.sh" || true
    echo "[INSTALL][PORTAL] wait portal-ui rollout (post reset)"
    kubectl -n platform rollout status deployment portal-ui --timeout=240s
  else
    echo "[INSTALL][PORTAL] 04C-ui-rollout-reset.patch.sh not present; skipping"
  fi

  if [[ -f "${HERE}/04B-ui-links.patch.sh" ]]; then
    run_step "portal-ui-links-patch" "04B-ui-links.patch.sh" || true
  else
    echo "[INSTALL][PORTAL] 04B-ui-links.patch.sh not present; skipping"
  fi

  echo "[INSTALL][PORTAL] quick checks (no jq)"
  if [[ -n "${PORTAL_HOST:-}" ]]; then
    curl -sk "https://${PORTAL_HOST}/api/summary?v=1" | head -c 300; echo
    curl -skI "https://${PORTAL_HOST}/app.js" | tr -d '\r' | egrep -i 'HTTP/|content-type:' || true
    curl -skI "https://${PORTAL_HOST}/styles.css" | tr -d '\r' | egrep -i 'HTTP/|content-type:' || true
  fi
fi

# Validation always runs
run_step "validate" "05-validate.sh"

echo "[INSTALL] complete $(timestamp)"
