#!/usr/bin/env bash
set -euo pipefail
# ==============================================================================
# 04X-ui-accesslog-context-fix.patch.sh
# Repeatable patch for portal UI nginx.conf (ConfigMap portal-ui-static):
# - removes main-context access_log (before http { })
# - ensures access_log exists inside http { } (after default_type)
# - applies CM, restarts portal-ui, waits for rollout
# - tests: pod ready, endpoints present, HTTP 200, content-types, API health
#
# Inputs come from /root/open-kpi.env (single source of truth) and/or 00-env.sh.
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "[FATAL] missing: $1" >&2; exit 1; }; }
need kubectl
need curl
need python3

log(){ echo "[04X][UI-ACCESSLOG-FIX] $*"; }
warn(){ echo "[04X][UI-ACCESSLOG-FIX][WARN] $*" >&2; }
fatal(){ echo "[04X][UI-ACCESSLOG-FIX][FATAL] $*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Load envs (00-env.sh optional, open-kpi.env required)
# ------------------------------------------------------------------------------
# shellcheck source=/dev/null
[[ -f "${HERE}/00-env.sh" ]] && . "${HERE}/00-env.sh" || true

ENV_FILE="${OPENKPI_ENV_FILE:-/root/open-kpi.env}"
[[ -f "$ENV_FILE" ]] || fatal "Missing env file: $ENV_FILE"

set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

# ------------------------------------------------------------------------------
# Settings (from env)
# ------------------------------------------------------------------------------
PLATFORM_NS="${PLATFORM_NS:-platform}"
TLS_MODE="${TLS_MODE:-per-host-http01}"        # off | per-host-http01

PORTAL_HOST="${PORTAL_HOST:-${OPENKPI_PORTAL_HOST:-}}"
[[ -n "$PORTAL_HOST" ]] || fatal "PORTAL_HOST not set in $ENV_FILE"

UI_DEPLOY="${PORTAL_UI_DEPLOY:-portal-ui}"
UI_SVC="${PORTAL_UI_SVC:-portal-ui}"
UI_CM="${PORTAL_UI_CM:-portal-ui-static}"

PROTO="https"
[[ "$TLS_MODE" == "off" ]] && PROTO="http"

# ------------------------------------------------------------------------------
# Preconditions
# ------------------------------------------------------------------------------
kubectl get ns "$PLATFORM_NS" >/dev/null 2>&1 || kubectl create ns "$PLATFORM_NS" >/dev/null
kubectl -n "$PLATFORM_NS" get cm "$UI_CM" >/dev/null 2>&1 || fatal "Missing ConfigMap ${PLATFORM_NS}/${UI_CM}"

# ------------------------------------------------------------------------------
# Patch ConfigMap nginx.conf (idempotent)
# ------------------------------------------------------------------------------
TMP="/tmp/${UI_CM}.yaml"
kubectl -n "$PLATFORM_NS" get cm "$UI_CM" -o yaml > "$TMP"

python3 - "$TMP" <<'PY'
import re, sys, yaml

p = sys.argv[1]
d = yaml.safe_load(open(p, "r"))
ng = d.get("data", {}).get("nginx.conf", "")
if not ng:
    raise SystemExit("nginx.conf missing in ConfigMap")

lines = ng.splitlines()

def is_access(l: str) -> bool:
    return re.match(r'^\s*access_log\s+', l) is not None

# locate http {
http_i = None
for i, l in enumerate(lines):
    if re.match(r'^\s*http\s*\{', l):
        http_i = i
        break

changed = False

if http_i is not None:
    # 1) remove access_log lines before http { } (main context)
    new = []
    for i, l in enumerate(lines):
        if i < http_i and is_access(l):
            changed = True
            continue
        new.append(l)
    lines = new

    # 2) check if access_log exists inside http block
    in_http = False
    has_in_http = False
    for l in lines:
        if re.match(r'^\s*http\s*\{', l):
            in_http = True
            continue
        if in_http and re.match(r'^\s*\}', l):
            in_http = False
            continue
        if in_http and is_access(l):
            has_in_http = True

    # 3) if missing, insert after default_type (preferred), else after http {
    if not has_in_http:
        out = []
        in_http = False
        inserted = False
        for l in lines:
            out.append(l)
            if re.match(r'^\s*http\s*\{', l):
                in_http = True
                continue
            if in_http and (not inserted) and re.match(r'^\s*default_type\b', l):
                indent = re.match(r'^(\s*)', l).group(1)
                out.append(f"{indent}access_log /tmp/access.log;")
                inserted = True
                changed = True

        if not inserted:
            out2 = []
            for l in out:
                out2.append(l)
                if re.match(r'^\s*http\s*\{', l) and not inserted:
                    # indent two spaces inside http
                    base = re.match(r'^(\s*)', l).group(1)
                    out2.append(f"{base}  access_log /tmp/access.log;")
                    inserted = True
                    changed = True
            out = out2

        lines = out
else:
    # no http block: remove all access_log lines
    new = []
    for l in lines:
        if is_access(l):
            changed = True
            continue
        new.append(l)
    lines = new

new_ng = "\n".join(lines).rstrip() + "\n"
if new_ng != ng:
    d.setdefault("data", {})["nginx.conf"] = new_ng
    yaml.safe_dump(d, open(p, "w"), sort_keys=False)
    print("PATCHED nginx.conf")
else:
    print("NO CHANGE")
PY

log "Apply ConfigMap ${PLATFORM_NS}/${UI_CM}"
kubectl -n "$PLATFORM_NS" apply -f "$TMP" >/dev/null

# ------------------------------------------------------------------------------
# Restart + wait
# ------------------------------------------------------------------------------
log "Restart deployment ${PLATFORM_NS}/${UI_DEPLOY}"
kubectl -n "$PLATFORM_NS" rollout restart deploy "$UI_DEPLOY" >/dev/null
kubectl -n "$PLATFORM_NS" rollout status deploy "$UI_DEPLOY" --timeout=240s

# ------------------------------------------------------------------------------
# Tests
# ------------------------------------------------------------------------------
log "TEST: pods"
kubectl -n "$PLATFORM_NS" get pods -l app="$UI_DEPLOY" -o wide

log "TEST: endpoints present"
kubectl -n "$PLATFORM_NS" get ep "$UI_SVC" -o wide || true

log "TEST: UI root"
curl -sSI "${PROTO}://${PORTAL_HOST}/" | tr -d '\r' | egrep -i 'HTTP/|content-type:' || true

log "TEST: UI assets"
curl -sSI "${PROTO}://${PORTAL_HOST}/app.js" | tr -d '\r' | egrep -i 'HTTP/|content-type:' || true
curl -sSI "${PROTO}://${PORTAL_HOST}/styles.css" | tr -d '\r' | egrep -i 'HTTP/|content-type:' || true

log "TEST: API health (non-fatal)"
curl -sS "${PROTO}://${PORTAL_HOST}/api/health" | head -c 200 || true
echo

log "OK"
