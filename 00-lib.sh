#!/usr/bin/env bash
set -euo pipefail

fatal(){ echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [FATAL] $*" >&2; exit 1; }
warn(){  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [WARN ] $*" >&2; }

ensure_ns(){
  local ns="$1"
  kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns" >/dev/null
}

retry(){
  local tries="$1" sleep_s="$2"; shift 2
  local i=0
  until "$@"; do
    i=$((i+1))
    [[ "$i" -ge "$tries" ]] && return 1
    sleep "$sleep_s"
  done
}

# ensure namespace exists
ns_ensure() {
  local ns="$1"
  kubectl get ns "${ns}" >/dev/null 2>&1 || kubectl create ns "${ns}" >/dev/null
}
