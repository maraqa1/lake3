#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
API_FILE="${API_FILE:-${ROOT_DIR}/04-portal-api.sh}"
UI_FILE="${UI_FILE:-${ROOT_DIR}/04-portal-ui.sh}"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/00-env.sh}"

ts(){ date -u +"%Y%m%dT%H%M%SZ"; }
backup(){ local f="$1"; [[ -f "$f" ]] || { echo "Missing: $f" >&2; exit 1; }; cp -a "$f" "${f}.bak.$(ts)"; }
has(){ grep -qE "$1" "$2"; }

backup "$API_FILE"
backup "$UI_FILE"
[[ -f "$ENV_FILE" ]] && backup "$ENV_FILE" || true

# -------------------------------------------------------------------
# 00-env.sh: ensure KUBE_DNS_IP exists
# -------------------------------------------------------------------
if [[ -f "$ENV_FILE" ]] && ! has '^[[:space:]]*export[[:space:]]+KUBE_DNS_IP=' "$ENV_FILE"; then
  cat >>"$ENV_FILE" <<'EOF'

# Portal/UI: kube-dns ClusterIP (used by nginx resolver)
export KUBE_DNS_IP="${KUBE_DNS_IP:-10.43.0.10}"
EOF
fi

# -------------------------------------------------------------------
# 04-portal-api.sh: enforce correct SA name (portal-api-sa)
# -------------------------------------------------------------------
if ! has 'serviceAccountName:\s*portal-api-sa' "$API_FILE"; then
  perl -0777 -i -pe '
    # normalize any existing serviceAccountName
    $s =~ s/serviceAccountName:\s*\S+/serviceAccountName: portal-api-sa/g;

    # if still missing inside Deployment template spec, insert it
    if ($s !~ /kind:\s*Deployment.*?template:.*?\n\s*spec:\s*\n\s*serviceAccountName:/s) {
      $s =~ s/(kind:\s*Deployment.*?template:.*?\n\s*spec:\s*\n)/$1      serviceAccountName: portal-api-sa\n/s;
    }
  ' "$API_FILE"
fi

# -------------------------------------------------------------------
# 04-portal-ui.sh: make proxy_pass correct (no :8000, no double ingress)
# - Force proxy_pass to "http://portal-api.__PLATFORM_NS__.svc.cluster.local;"
# - If you added __KUBE_DNS_IP__ placeholder, ensure resolver line exists.
# -------------------------------------------------------------------

# Remove any leftover :8000 upstream rewrites if they exist
perl -0777 -i -pe '
  $s =~ s/portal-api\.platform\.svc\.cluster\.local:8000/portal-api.__PLATFORM_NS__.svc.cluster.local/g;
  $s =~ s/portal-api\.platform\.svc\.cluster\.local/portal-api.__PLATFORM_NS__.svc.cluster.local/g;
' "$UI_FILE"

# Ensure proxy_pass preserves /api prefix (no trailing slash)
# Replace either "...local/;" or "...local:8000...;" etc.
perl -0777 -i -pe '
  $s =~ s/proxy_pass\s+http:\/\/portal-api\.__PLATFORM_NS__\.svc\.cluster\.local\/\s*;/proxy_pass http:\/\/portal-api.__PLATFORM_NS__.svc.cluster.local;/g;
  $s =~ s/proxy_pass\s+http:\/\/portal-api\.__PLATFORM_NS__\.svc\.cluster\.local\s*;/proxy_pass http:\/\/portal-api.__PLATFORM_NS__.svc.cluster.local;/g;
' "$UI_FILE"

# If UI contains __KUBE_DNS_IP__ placeholder but no resolver line, insert it after "http {"
if has '__KUBE_DNS_IP__' "$UI_FILE" && ! has 'resolver\s+__KUBE_DNS_IP__' "$UI_FILE"; then
  perl -0777 -i -pe '
    $s =~ s/(nginx\.conf:\s*\|\s*\n.*?\n\s*http\s*\{\s*\n)/$1      resolver __KUBE_DNS_IP__ valid=10s ipv6=off;\n/s;
  ' "$UI_FILE"
fi

# -------------------------------------------------------------------
# DO NOT append an extra Ingress block.
# The Ingress must remain owned by 04-portal-ui.sh (name: portal).
# -------------------------------------------------------------------

# Remove the dangerous rewrite if it exists (harmless if absent)
sed -i 's|portal-ui\.platform\.svc\.cluster\.local:8080|portal-ui.platform.svc.cluster.local|g' "$UI_FILE" || true

echo "Patched files:"
echo " - $API_FILE"
echo " - $UI_FILE"
[[ -f "$ENV_FILE" ]] && echo " - $ENV_FILE" || true
