#!/usr/bin/env bash
set -euo pipefail
# ==============================================================================
# 04X-ui-nginxconf-fix.patch.sh
# Fix nginx.conf main-context invalid directives (access_log) in portal-ui ConfigMap.
# Repeatable on fresh VM / fresh cluster.
#
# What it does:
# - Ensures platform namespace exists
# - Reads portal-ui-static ConfigMap
# - If nginx.conf contains 'access_log' in main context, removes it
# - Ensures access_log exists inside 'http { }' block (or skips if no http block)
# - Applies ConfigMap
# - Restarts portal-ui deployment and waits for rollout
# - Tests: pod ready, / returns 200, static assets served, api health reachable
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "${HERE}/00-env.sh" ]] && . "${HERE}/00-env.sh" || true

need(){ command -v "$1" >/dev/null 2>&1 || { echo "[FATAL] missing: $1" >&2; exit 1; }; }
need kubectl
need curl
need python3

log(){ echo "[04X][UI-NGINXCONF-FIX] $*"; }
warn(){ echo "[04X][UI-NGINXCONF-FIX][WARN] $*" >&2; }
fatal(){ echo "[04X][UI-NGINXCONF-FIX][FATAL] $*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Defaults (override in 00-env.sh)
# ------------------------------------------------------------------------------
PLATFORM_NS="${PLATFORM_NS:-platform}"
PORTAL_HOST="${PORTAL_HOST:-portal.lake3.opendatalake.com}"
TLS_MODE="${TLS_MODE:-per-host-http01}" # off | per-host-http01

UI_DEPLOY="${PORTAL_UI_DEPLOY:-portal-ui}"
UI_CM="${PORTAL_UI_CM:-portal-ui-static}"

API_SVC="${PORTAL_API_SVC:-portal-api}"

PROTO="https"
if [[ "${TLS_MODE}" == "off" ]]; then
  PROTO="http"
fi

# ------------------------------------------------------------------------------
# Ensure namespace
# ------------------------------------------------------------------------------
kubectl get ns "${PLATFORM_NS}" >/dev/null 2>&1 || kubectl create ns "${PLATFORM_NS}" >/dev/null

# ------------------------------------------------------------------------------
# Pre-checks
# ------------------------------------------------------------------------------
if ! kubectl -n "${PLATFORM_NS}" get cm "${UI_CM}" >/dev/null 2>&1; then
  fatal "ConfigMap ${PLATFORM_NS}/${UI_CM} not found. Run 04-portal-ui first."
fi

# ------------------------------------------------------------------------------
# Patch ConfigMap (idempotent)
# ------------------------------------------------------------------------------
TMP="/tmp/${UI_CM}.yaml"
kubectl -n "${PLATFORM_NS}" get cm "${UI_CM}" -o yaml > "${TMP}"

python3 - <<'PY'
import re, yaml, sys

p = sys.argv[1]
d = yaml.safe_load(open(p))
ng = d.get("data", {}).get("nginx.conf", "")
if not ng:
    print("NO nginx.conf found; nothing to patch")
    sys.exit(0)

lines = ng.splitlines()

# Detect access_log at main context (before 'http {')
http_idx = None
for i, l in enumerate(lines):
    if re.match(r'^\s*http\s*\{', l):
        http_idx = i
        break

def is_access_log_line(l):
    return re.match(r'^\s*access_log\s+', l) is not None

changed = False

# Remove main-context access_log (only those BEFORE http block, if http exists)
if http_idx is not None:
    new = []
    removed = 0
    for i, l in enumerate(lines):
        if i < http_idx and is_access_log_line(l):
            removed += 1
            changed = True
            continue
        new.append(l)
    lines = new

    # Ensure access_log exists inside http block (after default_type if possible)
    # If already present anywhere inside http, do nothing.
    in_http = False
    has_http_access = False
    for l in lines:
        if re.match(r'^\s*http\s*\{', l): in_http = True
        if in_http and is_access_log_line(l): has_http_access = True
        if in_http and re.match(r'^\s*\}', l): in_http = False

    if not has_http_access:
        out = []
        inserted = False
        in_http = False
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
        # If no default_type found, insert right after 'http {' line
        if in_http and not inserted:
            # second pass insert after http {
            out2=[]
            for i,l in enumerate(out):
                out2.append(l)
                if re.match(r'^\s*http\s*\{', l) and not inserted:
                    indent = re.match(r'^(\s*)', l).group(1) + "  "
                    out2.append(f"{indent}access_log /tmp/access.log;")
                    inserted = True
                    changed = True
            out = out2
        lines = out

else:
    # No http block found; safest action is to remove access_log lines entirely
    new = []
    removed = 0
    for l in lines:
        if is_access_log_line(l):
            removed += 1
            changed = True
            continue
        new.append(l)
    lines = new

new_ng = "\n".join(lines).rstrip() + "\n"

if new_ng != ng:
    d["data"]["nginx.conf"] = new_ng
    yaml.safe_dump(d, open(p, "w"), sort_keys=False)
    print("PATCHED nginx.conf")
else:
    print("NO CHANGE")
PY "${TMP}"

log "Apply patched ConfigMap: ${PLATFORM_NS}/${UI_CM}"
kubectl -n "${PLATFORM_NS}" apply -f "${TMP}" >/dev/null

# ------------------------------------------------------------------------------
# Restart deployment + wait
# ------------------------------------------------------------------------------
log "Restart deployment: ${PLATFORM_NS}/${UI_DEPLOY}"
kubectl -n "${PLATFORM_NS}" rollout restart deployment "${UI_DEPLOY}" >/dev/null
kubectl -n "${PLATFORM_NS}" rollout status deployment "${UI_DEPLOY}" --timeout=240s

# ------------------------------------------------------------------------------
# Tests
# ------------------------------------------------------------------------------
log "TEST: pods running/ready"
kubectl -n "${PLATFORM_NS}" get pods -l app="${UI_DEPLOY}" -o wide

log "TEST: UI root returns HTTP"
curl -sSI "${PROTO}://${PORTAL_HOST}/" | tr -d '\r' | egrep -i 'HTTP/|content-type:' || true

log "TEST: UI assets served with correct content-type"
curl -sSI "${PROTO}://${PORTAL_HOST}/app.js" | tr -d '\r' | egrep -i 'HTTP/|content-type:' || true
curl -sSI "${PROTO}://${PORTAL_HOST}/styles.css" | tr -d '\r' | egrep -i 'HTTP/|content-type:' || true

log "TEST: API health reachable"
curl -sS "${PROTO}://${PORTAL_HOST}/api/health" | head -c 200 || true
echo

log "OK"
