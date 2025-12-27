#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../00-env.sh"
source "${HERE}/../00-lib.sh"

TARGET_MODULE="01-core.sh"

hr(){ echo "-----------------------------------------------------------------------"; }
sec(){ hr; echo "## $*"; hr; }
PASS(){ echo "PASS $*"; }
FAIL(){ echo "FAIL $*"; }

TOTAL=0; PASSED=0; FAILED=0; FAILED_REQUIRED=0

run_test() {
  local tag="$1"; shift
  local desc="$1"; shift
  local required="$1"; shift
  TOTAL=$((TOTAL+1))
  if "$@"; then
    PASSED=$((PASSED+1))
    PASS "[$tag] $desc"
    return 0
  else
    FAILED=$((FAILED+1))
    [[ "$required" == "1" ]] && FAILED_REQUIRED=$((FAILED_REQUIRED+1))
    FAIL "[$tag] $desc"
    return 1
  fi
}

diag_core() {
  kubectl get ns || true
  kubectl get nodes -o wide || true
  kubectl get sc || true
  kubectl get pods -A -o wide | tail -n 80 || true
  kubectl get events -A --sort-by=.lastTimestamp | tail -n 80 || true
}

diag_ns() {
  kubectl get ns "$1" || true
  kubectl -n "$1" get all -o wide || true
  kubectl -n "$1" get pvc -o wide || true
  kubectl -n "$1" get events --sort-by=.lastTimestamp | tail -n 80 || true
}

need(){ command -v "$1" >/dev/null 2>&1; }

: "${NS:=open-kpi}"
OPENKPI_NS="${NS}"
PLATFORM_NS="${PLATFORM_NS:-platform}"
INGRESS_NS="${INGRESS_NS:-ingress-nginx}"
TLS_MODE="${TLS_MODE:-off}"

sec "Module Test Runner"
echo "Target module: ${TARGET_MODULE}"
echo "NS(open-kpi):   ${OPENKPI_NS}"
echo "Platform NS:    ${PLATFORM_NS}"
echo "Ingress NS:     ${INGRESS_NS}"
echo "TLS mode:       ${TLS_MODE}"
hr

# --- baseline tests always ---
set +e
run_test "T00-CORE-001" "kubectl reachable" 1 kubectl version --short >/dev/null 2>&1 || diag_core
run_test "T00-CORE-002" "open-kpi namespace exists" 1 kubectl get ns "${OPENKPI_NS}" >/dev/null 2>&1 || diag_ns "${OPENKPI_NS}"
set -e

sec "Summary"
echo "Total:  $TOTAL"
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo "ReqFail:$FAILED_REQUIRED"
hr
if [[ "$FAILED_REQUIRED" -eq 0 ]]; then exit 0; else exit 1; fi
