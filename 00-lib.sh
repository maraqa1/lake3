#!/usr/bin/env bash
# 00-lib.sh — shared helpers (no side effects on import)
# Bash-only, set -euo pipefail compatible.

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

_ts_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log()   { printf '%s %s\n' "$(_ts_utc)" "[INFO] $*" >&2; }
warn()  { printf '%s %s\n' "$(_ts_utc)" "[WARN] $*" >&2; }
fatal() { printf '%s %s\n' "$(_ts_utc)" "[FATAL] $*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Preconditions
# ------------------------------------------------------------------------------

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || fatal "Missing required command: $cmd"
  done
}

# ------------------------------------------------------------------------------
# Retry
# Usage: retry <attempts> <delay_seconds> <cmd...>
# Example: retry 10 3 kubectl -n "$NS" get pods
# ------------------------------------------------------------------------------

retry() {
  local attempts delay
  attempts="${1:-}"; delay="${2:-}"
  shift 2 || true

  [[ -n "${attempts}" && -n "${delay}" ]] || fatal "retry requires: <attempts> <delay> <cmd...>"
  [[ "${attempts}" =~ ^[0-9]+$ ]] || fatal "retry attempts must be an integer"
  [[ "${delay}" =~ ^[0-9]+$ ]] || fatal "retry delay must be an integer (seconds)"
  [[ $# -ge 1 ]] || fatal "retry requires a command"

  local n=1
  while true; do
    if "$@"; then
      return 0
    fi
    if (( n >= attempts )); then
      warn "Retry failed after ${attempts} attempts: $*"
      return 1
    fi
    warn "Retry ${n}/${attempts} failed; sleeping ${delay}s: $*"
    sleep "${delay}"
    ((n++))
  done
}

# ------------------------------------------------------------------------------
# Kubernetes helpers
# ------------------------------------------------------------------------------

ensure_ns() {
  local ns="${1:-}"
  [[ -n "${ns}" ]] || fatal "ensure_ns requires <namespace>"
  require_cmd kubectl

  if kubectl get ns "${ns}" >/dev/null 2>&1; then
    return 0
  fi
  kubectl create ns "${ns}" >/dev/null
}

k_exists() {
  # Usage: k_exists <ns> <kind> <name>
  local ns="${1:-}" kind="${2:-}" name="${3:-}"
  [[ -n "${ns}" && -n "${kind}" && -n "${name}" ]] || fatal "k_exists requires <ns> <kind> <name>"
  require_cmd kubectl
  kubectl -n "${ns}" get "${kind}" "${name}" >/dev/null 2>&1
}

k_first_name_by_label() {
  # Usage: k_first_name_by_label <ns> <kind> <label_selector>
  local ns="${1:-}" kind="${2:-}" sel="${3:-}"
  [[ -n "${ns}" && -n "${kind}" && -n "${sel}" ]] || fatal "k_first_name_by_label requires <ns> <kind> <label_selector>"
  require_cmd kubectl
  kubectl -n "${ns}" get "${kind}" -l "${sel}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

kubectl_wait_deploy() {
  local ns="${1:-}" deploy="${2:-}" timeout="${3:-}"
  [[ -n "${ns}" && -n "${deploy}" && -n "${timeout}" ]] || fatal "kubectl_wait_deploy requires <ns> <deploy> <timeout>"
  require_cmd kubectl
  kubectl -n "${ns}" rollout status "deploy/${deploy}" --timeout="${timeout}"
}

kubectl_wait_sts() {
  local ns="${1:-}" sts="${2:-}" timeout="${3:-}"
  [[ -n "${ns}" && -n "${sts}" && -n "${timeout}" ]] || fatal "kubectl_wait_sts requires <ns> <sts> <timeout>"
  require_cmd kubectl
  kubectl -n "${ns}" rollout status "sts/${sts}" --timeout="${timeout}"
}

kubectl_rollout_restart_deploy() {
  # Usage: kubectl_rollout_restart_deploy <ns> <deploy> <timeout>
  local ns="${1:-}" deploy="${2:-}" timeout="${3:-}"
  [[ -n "${ns}" && -n "${deploy}" && -n "${timeout}" ]] || fatal "kubectl_rollout_restart_deploy requires <ns> <deploy> <timeout>"
  require_cmd kubectl
  kubectl -n "${ns}" rollout restart "deploy/${deploy}" >/dev/null
  kubectl -n "${ns}" rollout status "deploy/${deploy}" --timeout="${timeout}"
}

kubectl_delete_pods_by_selector() {
  # Usage: kubectl_delete_pods_by_selector <ns> <label_selector>
  local ns="${1:-}" sel="${2:-}"
  [[ -n "${ns}" && -n "${sel}" ]] || fatal "kubectl_delete_pods_by_selector requires <ns> <label_selector>"
  require_cmd kubectl
  kubectl -n "${ns}" delete pod -l "${sel}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

kubectl_delete_pods_by_job() {
  # Usage: kubectl_delete_pods_by_job <ns> <job_name>
  local ns="${1:-}" job="${2:-}"
  [[ -n "${ns}" && -n "${job}" ]] || fatal "kubectl_delete_pods_by_job requires <ns> <job_name>"
  require_cmd kubectl
  kubectl_delete_pods_by_selector "${ns}" "job-name=${job}"
}

# ------------------------------------------------------------------------------
# YAML apply helper
# Usage: apply_yaml "<yaml_string>"
# ------------------------------------------------------------------------------

apply_yaml() {
  local yaml="${1:-}"
  [[ -n "${yaml}" ]] || fatal "apply_yaml requires a non-empty YAML string"
  require_cmd kubectl
  printf '%s\n' "${yaml}" | kubectl apply -f -
}
