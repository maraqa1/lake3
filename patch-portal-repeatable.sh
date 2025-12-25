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

# Ensure KUBE_DNS_IP in 00-env.sh
if [[ -f "$ENV_FILE" ]] && ! has '^export KUBE_DNS_IP=' "$ENV_FILE"; then
  printf '\n# Portal/UI: kube-dns ClusterIP (used by nginx resolver)\nexport KUBE_DNS_IP="${KUBE_DNS_IP:-10.43.0.10}"\n' >> "$ENV_FILE"
fi

# Enforce serviceAccountName: portal-api in portal-api Deployment
if ! has 'serviceAccountName:\s*portal-api' "$API_FILE"; then
  perl -0777 -i -pe '
    if ($s !~ /kind:\s*Deployment.*?template:\s*\n.*?\nspec:\s*\n\s*serviceAccountName:/s) {
      $s =~ s/(kind:\s*Deployment.*?template:\s*\n.*?\nspec:\s*\n)/$1      serviceAccountName: portal-api\n/s;
    }
  ' "$API_FILE"
fi

# Patch nginx.conf in 04-portal-ui.sh for late DNS resolution
if ! has 'resolver\s+\$\{KUBE_DNS_IP\}' "$UI_FILE"; then
  perl -0777 -i -pe '
    if ($s =~ /nginx\.conf"\s*:\s*\|\s*\n/s && $s !~ /resolver\s+\$\{KUBE_DNS_IP\}/s) {
      if ($s =~ /nginx\.conf"\s*:\s*\|\s*\n.*?\n\s*http\s*\{\s*\n/s) {
        $s =~ s/(nginx\.conf"\s*:\s*\|\s*\n.*?\n\s*http\s*\{\s*\n)/$1    resolver ${KUBE_DNS_IP} valid=10s ipv6=off;\n/s;
      } elsif ($s =~ /nginx\.conf"\s*:\s*\|\s*\n.*?\n\s*server\s*\{\s*\n/s) {
        $s =~ s/(nginx\.conf"\s*:\s*\|\s*\n.*?\n\s*server\s*\{\s*\n)/$1    resolver ${KUBE_DNS_IP} valid=10s ipv6=off;\n/s;
      }
    }
  ' "$UI_FILE"
fi

if ! has 'set\s+\$portal_api\s+"http://portal-api\.platform\.svc\.cluster\.local:8000"' "$UI_FILE"; then
  perl -0777 -i -pe '
    if ($s =~ /resolver\s+\$\{KUBE_DNS_IP\}[^\n]*\n/s && $s !~ /set\s+\$portal_api\s+"http:\/\/portal-api\.platform\.svc\.cluster\.local:8000"/s) {
      $s =~ s/(resolver\s+\$\{KUBE_DNS_IP\}[^\n]*\n)/$1    set $portal_api "http:\/\/portal-api.platform.svc.cluster.local:8000";\n/s;
    }
  ' "$UI_FILE"
fi

perl -0777 -i -pe '
  $s =~ s/proxy_pass\s+http:\/\/portal-api\.platform\.svc\.cluster\.local:8000\s*;/proxy_pass $portal_api;/g;
  $s =~ s/proxy_pass\s+http:\/\/portal-api\.platform\.svc\.cluster\.local:8000\/\s*;/proxy_pass $portal_api\//g;
  $s =~ s/proxy_pass\s+http:\/\/portal_api\s*;/proxy_pass $portal_api;/g;
  $s =~ s/proxy_pass\s+http:\/\/portal_api\/\s*;/proxy_pass $portal_api\//g;
' "$UI_FILE"

# Append Ingress apply block if missing
if ! has 'kind:\s*Ingress' "$UI_FILE"; then
  cat >>"$UI_FILE" <<'BASH'

# --- repeatable Ingress apply (added by patch-portal-repeatable.sh)
log "[04B][PORTAL-UI] Apply Ingress (repeatable)"
. "${HERE}/00-env.sh"
: "${INGRESS_CLASS:=nginx}"
: "${TLS_MODE:=off}"
: "${APP_DOMAIN:?missing APP_DOMAIN}"
: "${PORTAL_HOST:=portal.${APP_DOMAIN}}"

if [[ "${TLS_MODE}" == "per-host-http01" ]]; then
  PORTAL_TLS_SECRET="${PORTAL_TLS_SECRET:-portal-ui-tls}"
  PORTAL_ISSUER_ANN="cert-manager.io/cluster-issuer: letsencrypt-http01"
  TLS_YAML=$(cat <<EOF
  tls:
    - hosts:
        - ${PORTAL_HOST}
      secretName: ${PORTAL_TLS_SECRET}
EOF
)
else
  PORTAL_ISSUER_ANN=""
  TLS_YAML=""
fi

kubectl -n "${PLATFORM_NS:-platform}" apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: portal-ui
  namespace: ${PLATFORM_NS:-platform}
  labels:
    app: portal-ui
  annotations:
    kubernetes.io/ingress.class: ${INGRESS_CLASS}
$( [[ -n "${PORTAL_ISSUER_ANN}" ]] && printf "    %s\n" "${PORTAL_ISSUER_ANN}" )
spec:
${TLS_YAML}
  rules:
    - host: ${PORTAL_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: portal-ui
                port:
                  number: 80
YAML
BASH
fi

sed -i 's|portal-ui\.platform\.svc\.cluster\.local:8080|portal-ui.platform.svc.cluster.local|g' "$UI_FILE"

echo "Patched files:"
echo " - $API_FILE"
echo " - $UI_FILE"
echo " - $ENV_FILE (if present)"
