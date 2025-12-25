#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Open KPI — top-level installer orchestrator (GitHub runner)
# File: install.sh
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

timestamp() { date -u +"%Y%m%dT%H%M%SZ"; }

usage() {
  cat <<'EOF'
Usage: ./install.sh [flags]

Flags:
  --core       Run core cluster setup (01-core.sh)
  --data       Run shared data plane (02-data-plane.sh)

  --airbyte    Install Airbyte (03-app-airbyte.sh)
  --n8n        Install n8n (03-app-n8n.sh)
  --zammad     Install Zammad (03-app-zammad.sh)
  --dbt        Install dbt runner + cron (03-app-dbt.sh)

  --portal     Deploy portal API + UI (04-portal-api.sh + 04-portal-ui.sh)

  --all        Run full install (default)
  -h, --help   Show help

Examples:
  ./install.sh
  ./install.sh --core --data --portal
  ./install.sh --airbyte --portal
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
RUN_AIRBYTE=0
RUN_N8N=0
RUN_ZAMMAD=0
RUN_DBT=0
RUN_PORTAL=0
RUN_ALL=1

if [[ $# -gt 0 ]]; then
  RUN_ALL=0
  while [[ $# -gt 0 ]]; do
    case "${1:-}" in
      --all)
        RUN_ALL=1
        ;;
      --core)
        RUN_CORE=1
        ;;
      --data)
        RUN_DATA=1
        ;;
      --airbyte)
        RUN_AIRBYTE=1
        ;;
      --n8n)
        RUN_N8N=1
        ;;
      --zammad)
        RUN_ZAMMAD=1
        ;;
      --dbt)
        RUN_DBT=1
        ;;
      --portal)
        RUN_PORTAL=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
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
  RUN_AIRBYTE=1
  RUN_N8N=1
  RUN_ZAMMAD=1
  RUN_DBT=1
  RUN_PORTAL=1
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
need_file "01-core.sh"
need_file "02-data-plane.sh"
need_file "04-portal-api.sh"
need_file "04-portal-ui.sh"
need_file "05-validate.sh"

if [[ "$RUN_AIRBYTE" -eq 1 ]]; then need_file "03-app-airbyte.sh"; fi
if [[ "$RUN_N8N" -eq 1 ]]; then need_file "03-app-n8n.sh"; fi
if [[ "$RUN_ZAMMAD" -eq 1 ]]; then need_file "03-app-zammad.sh"; fi
if [[ "$RUN_DBT" -eq 1 ]]; then need_file "03-app-dbt.sh"; fi

# Source contract/env (must be source-only per contract)
# shellcheck disable=SC1091
. "$HERE/00-env.sh"

echo "[INSTALL] contract loaded"
echo "[INSTALL] NS=${NS:-}"
echo "[INSTALL] APP_DOMAIN=${APP_DOMAIN:-}"
echo "[INSTALL] TLS_MODE=${TLS_MODE:-}"
echo "[INSTALL] INGRESS_CLASS=${INGRESS_CLASS:-}"
echo "[INSTALL] STORAGE_CLASS=${STORAGE_CLASS:-}"

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

# Ordered execution with safe prerequisites
if [[ "$RUN_CORE" -eq 1 ]]; then
  run_step "core" "01-core.sh"
fi

if [[ "$RUN_DATA" -eq 1 ]]; then
  run_step "data-plane" "02-data-plane.sh"
fi

# Apps
if [[ "$RUN_AIRBYTE" -eq 1 ]]; then
  run_step "airbyte" "03-app-airbyte.sh"
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

# Portal (API + UI)
if [[ "$RUN_PORTAL" -eq 1 ]]; then
  run_step "portal-api" "04-portal-api.sh"
  run_step "portal-ui" "04-portal-ui.sh"
fi

# Validation always runs
run_step "validate" "05-validate.sh"

echo "[INSTALL] complete $(timestamp)"
