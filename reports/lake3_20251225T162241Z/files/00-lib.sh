#!/usr/bin/env bash
# 00-lib.sh — shared helpers (no side effects on import)
# Bash-only, set -euo pipefail compatible.

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

_ts_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log()  { printf '%s %s\n' "$(_ts_utc)" "[INFO] $*" >&2; }
warn() { printf '%s %s\n' "$(_ts_utc)" "[WARN] $*" >&2; }
fatal(){ printf '%s %s\n' "$(_ts_utc)" "[FATAL] $*" >&2; exit 1; }

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
  kubectl -n "${ns}" rollout status "statefulset/${sts}" --timeout="${timeout}"
}

# ------------------------------------------------------------------------------
# YAML apply helper
# Usage: apply_yaml "<yaml_string>"
# ------------------------------------------------------------------------------

apply_yaml() {
  local yaml="${1:-}"
  [[ -n "${yaml}" ]] || fatal "apply_yaml requires a non-empty YAML string"
  require_cmd kubectl

  # Preserve content exactly; avoid echo -e quirks.
  printf '%s\n' "${yaml}" | kubectl apply -f -
}
