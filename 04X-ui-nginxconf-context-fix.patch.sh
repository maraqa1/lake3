#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "${HERE}/00-env.sh" ]] && . "${HERE}/00-env.sh" || true

need(){ command -v "$1" >/dev/null 2>&1 || { echo "[FATAL] missing: $1" >&2; exit 1; }; }
need kubectl
need curl
need python3

log(){ echo "[04X][PORTAL-UI][NGINXCONF] $*"; }
warn(){ echo "[04X][PORTAL-UI][NGINXCONF][WARN] $*" >&2; }

PLATFORM_NS="${PLATFORM_NS:-platform}"
UI_DEPLOY="${PORTAL_UI_DEPLOY:-portal-ui}"
UI_CM="${PORTAL_UI_CM:-portal-ui-static}"
PORTAL_HOST="${PORTAL_HOST:-}"
TLS_MODE="${TLS_MODE:-per-host-http01}"

# In your current ConfigMap, nginx.conf has:
#   access_log ...;
# at top-level (main context). That is invalid.
# Fix: move access_log into http { }.

log "Patch ConfigMap ${PLATFORM_NS}/${UI_CM} (fix access_log context)"
kubectl -n "${PLATFORM_NS}" get cm "${UI_CM}" -o yaml >/tmp/${UI_CM}.yaml

python3 - <<'PY'
import re, yaml, sys
p = "/tmp/portal-ui-static.yaml"
d = yaml.safe_load(open(p))
ng = d["data"].get("nginx.conf","")

lines = ng.splitlines()

# 1) Remove top-level access_log lines (invalid in main context)
new_lines = []
removed = 0
for ln in lines:
    if re.match(r'^\s*access_log\s+', ln):
        removed += 1
        continue
    new_lines.append(ln)

ng2 = "\n".join(new_lines) + ("\n" if new_lines and not new_lines[-1].endswith("\n") else "")

# 2) Ensure an access_log exists inside http { } (valid context)
# Insert right after "http {" line if not already present anywhere.
if "access_log" not in ng2:
    out = []
    inserted = False
    for ln in ng2.splitlines():
        out.append(ln)
        if (not inserted) and re.match(r'^\s*http\s*\{\s*$', ln):
            out.append("      access_log /tmp/access.log;")
            inserted = True
    ng2 = "\n".join(out) + "\n"

d["data"]["nginx.conf"] = ng2
yaml.safe_dump(d, open(p,"w"), sort_keys=False)
print(f"removed_top_level_access_log_lines={removed}")
PY

kubectl -n "${PLATFORM_NS}" apply -f /tmp/${UI_CM}.yaml

log "Restart UI deployment ${PLATFORM_NS}/${UI_DEPLOY}"
kubectl -n "${PLATFORM_NS}" rollout restart deploy "${UI_DEPLOY}"

log "Wait UI rollout"
kubectl -n "${PLATFORM_NS}" rollout status deploy "${UI_DEPLOY}" --timeout=240s

# --------------------
# Tests
# --------------------
log "TEST 1: Pod Ready"
kubectl -n "${PLATFORM_NS}" get pods -l app="${UI_DEPLOY}" -o wide

log "TEST 2: Service has endpoints"
kubectl -n "${PLATFORM_NS}" get svc "${UI_DEPLOY}" -o wide || true
kubectl -n "${PLATFORM_NS}" get endpoints "${UI_DEPLOY}" -o wide || true

if [[ -n "${PORTAL_HOST}" ]]; then
  SCHEME="http"
  [[ "${TLS_MODE}" == "per-host-http01" ]] && SCHEME="https"

  log "TEST 3: Portal UI HTTP headers"
  curl -skI "${SCHEME}://${PORTAL_HOST}/" | tr -d '\r' | egrep -i 'HTTP/|content-type:' || true
  curl -skI "${SCHEME}://${PORTAL_HOST}/app.js" | tr -d '\r' | egrep -i 'HTTP/|content-type:' || true
  curl -skI "${SCHEME}://${PORTAL_HOST}/styles.css" | tr -d '\r' | egrep -i 'HTTP/|content-type:' || true
fi

log "Done"
