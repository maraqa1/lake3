#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# OpenKPI — install.sh (orchestrator)
# - Repeatable: safe to re-run; modules should be idempotent
# - Uses /root/open-kpi.env via ./00-env.sh (single source of truth)
# - Supports partial runs via flags
#
# Expected module files in repo root:
#   00-env.sh
#   00-lib.sh
#   01-core.sh
#   02-data-plane.sh
#   02-A-minio-https.sh              (optional; only if you use MinIO TLS)
#   03-app-airbyte.sh
#   03A-airbyte-minio-docstore-fix.sh (optional; if needed)
#   03-app-n8n.sh
#   03-app-zammad.sh
#   03-app-dbt.sh
#   03-app-metabase-prereqs.sh       (optional; if present)
#   03-app-metabase.sh               (optional; if present)
#   04-run-portal-fresh.sh           (portal API + patches + UI + UI patches)
#   05-validate.sh                   (optional; if present)
#
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
. "${HERE}/00-env.sh"
# shellcheck source=/dev/null
. "${HERE}/00-lib.sh"

require_cmd bash
require_cmd kubectl
require_cmd curl
require_cmd git

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage:
  ./install.sh [flags]

Flags (run subsets):
  --all             Run full install (default if no flags)
  --core            01-core.sh
  --data            02-data-plane.sh
  --minio-https      02-A-minio-https.sh (if present)
  --airbyte         03-app-airbyte.sh
  --airbyte-fix      03A-airbyte-minio-docstore-fix.sh (if present)
  --n8n             03-app-n8n.sh
  --zammad          03-app-zammad.sh
  --dbt             03-app-dbt.sh
  --metabase        03-app-metabase-prereqs.sh (if present) + 03-app-metabase.sh (if present)
  --portal          04-run-portal-fresh.sh
  --validate        05-validate.sh (if present)

Utility:
  -h, --help        Show this help

Examples:
  ./install.sh --all
  ./install.sh --core --data --airbyte --portal
  ./install.sh --portal
EOF
}

run_step() {
  local name="$1"
  local file="${HERE}/$2"

  if [[ ! -f "$file" ]]; then
    log "[INSTALL][$name] SKIP (missing): $2"
    return 0
  fi

  log "[INSTALL][$name] RUN: $2"
  chmod +x "$file" 2>/dev/null || true
  bash "$file"
}

# ------------------------------------------------------------------------------
# Parse args
# ------------------------------------------------------------------------------
DO_ALL=0
DO_CORE=0
DO_DATA=0
DO_MINIO_HTTPS=0
DO_AIRBYTE=0
DO_AIRBYTE_FIX=0
DO_N8N=0
DO_ZAMMAD=0
DO_DBT=0
DO_METABASE=0
DO_PORTAL=0
DO_VALIDATE=0

if [[ $# -eq 0 ]]; then
  DO_ALL=1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) DO_ALL=1 ;;
    --core) DO_CORE=1 ;;
    --data) DO_DATA=1 ;;
    --minio-https) DO_MINIO_HTTPS=1 ;;
    --airbyte) DO_AIRBYTE=1 ;;
    --airbyte-fix) DO_AIRBYTE_FIX=1 ;;
    --n8n) DO_N8N=1 ;;
    --zammad) DO_ZAMMAD=1 ;;
    --dbt) DO_DBT=1 ;;
    --metabase) DO_METABASE=1 ;;
    --portal) DO_PORTAL=1 ;;
    --validate) DO_VALIDATE=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "[FATAL] unknown flag: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

if [[ $DO_ALL -eq 1 ]]; then
  DO_CORE=1
  DO_DATA=1
  DO_MINIO_HTTPS=1
  DO_AIRBYTE=1
  DO_AIRBYTE_FIX=1
  DO_N8N=1
  DO_ZAMMAD=1
  DO_DBT=1
  DO_METABASE=1
  DO_PORTAL=1
  DO_VALIDATE=1
fi

# ------------------------------------------------------------------------------
# Pre-flight sanity: env contract
# ------------------------------------------------------------------------------
# 00-env.sh should load /root/open-kpi.env; enforce presence of PORTAL_HOST for portal runs.
if [[ ! -f /root/open-kpi.env ]]; then
  fatal "missing /root/open-kpi.env (required). Copy it to the VM before running install.sh"
fi

# If portal is requested, ensure PORTAL_HOST exists (derived or explicit).
if [[ $DO_PORTAL -eq 1 ]]; then
  # shellcheck source=/dev/null
  set -a; . /root/open-kpi.env; set +a
  [[ -n "${PORTAL_HOST:-}" ]] || fatal "PORTAL_HOST missing in /root/open-kpi.env (required for portal)"
fi

# ------------------------------------------------------------------------------
# Execution order (dependencies)
# ------------------------------------------------------------------------------
# Core -> Data plane -> (optional MinIO HTTPS) -> Apps -> Portal -> Validate

[[ $DO_CORE -eq 1 ]] && run_step "core" "01-core.sh"
[[ $DO_DATA -eq 1 ]] && run_step "data-plane" "02-data-plane.sh"

# Optional: MinIO TLS/Ingress hardening (only if file exists and flag enabled)
if [[ $DO_MINIO_HTTPS -eq 1 ]]; then
  run_step "minio-https" "02-A-minio-https.sh"
fi

# Apps (order is safe; they should be independent but assume data-plane exists)
[[ $DO_AIRBYTE -eq 1 ]] && run_step "airbyte" "03-app-airbyte.sh"
[[ $DO_AIRBYTE_FIX -eq 1 ]] && run_step "airbyte-fix" "03A-airbyte-minio-docstore-fix.sh"

[[ $DO_N8N -eq 1 ]] && run_step "n8n" "03-app-n8n.sh"
[[ $DO_ZAMMAD -eq 1 ]] && run_step "zammad" "03-app-zammad.sh"
[[ $DO_DBT -eq 1 ]] && run_step "dbt" "03-app-dbt.sh"

if [[ $DO_METABASE -eq 1 ]]; then
  run_step "metabase-prereqs" "03-app-metabase-prereqs.sh"
  run_step "metabase" "03-app-metabase.sh"
fi

# Portal (portal API + API patches + UI + UI patches) in one repeatable runner
[[ $DO_PORTAL -eq 1 ]] && run_step "portal" "04-run-portal-fresh.sh"

# Validate (optional)
if [[ $DO_VALIDATE -eq 1 ]]; then
  run_step "validate" "05-validate.sh"
fi

log "[INSTALL] done"
