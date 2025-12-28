#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 03C-ZAMMAD-HTTPS-FIX.sh — Repeatable Zammad HTTPS + Ingress de-dup fix
#
# What it enforces (idempotent):
# - Single Ingress for zammad with:
#     spec.ingressClassName = ${INGRESS_CLASS}
#     spec.tls -> secretName=zammad-tls for host ${ZAMMAD_HOST} (when TLS_MODE=per-host-http01)
# - Deterministic cert-manager Certificate zammad-tls -> secret zammad-tls
# - Removes cert-manager "shim" annotations from the Ingress to prevent extra solver ingress
# - Deletes any lingering *acme*/*solver* ingresses for the same host
#
# Requires: 00-env.sh + 00-lib.sh in same folder
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/00-env.sh"
# shellcheck source=/dev/null
. "${HERE}/00-lib.sh"

require_cmd kubectl

APP_NS="tickets"
ING_NAME="zammad"
CERT_NAME="zammad-tls"
TLS_SECRET="zammad-tls"

: "${TLS_MODE:?missing TLS_MODE}"
: "${INGRESS_CLASS:?missing INGRESS_CLASS}"
: "${ZAMMAD_HOST:?missing ZAMMAD_HOST}"

# issuer created by 01-core.sh
: "${LETSENCRYPT_ISSUER:=letsencrypt-http01}"

log "[03C][ZAMMAD][FIX] start (ns=${APP_NS}, host=${ZAMMAD_HOST}, class=${INGRESS_CLASS}, tls_mode=${TLS_MODE})"

# ------------------------------------------------------------------------------
# 1) Ensure the main Ingress exists and targets the right class + host
#    (If chart created it, we only patch; we do not re-create helm resources here.)
# ------------------------------------------------------------------------------
if ! kubectl -n "${APP_NS}" get ingress "${ING_NAME}" >/dev/null 2>&1; then
  fatal "[03C][ZAMMAD][FIX] ingress/${ING_NAME} not found in ns/${APP_NS}. Install Zammad first (03-app-zammad.sh)."
fi

# Always enforce ingress class on spec (preferred, deterministic)
kubectl -n "${APP_NS}" patch ingress "${ING_NAME}" --type=merge \
  -p "{\"spec\":{\"ingressClassName\":\"${INGRESS_CLASS}\"}}" >/dev/null

# Always enforce the correct host in rule[0] (guard against chart-example.local)
# If chart uses multiple rules, we still enforce rule[0] which is what you check.
kubectl -n "${APP_NS}" patch ingress "${ING_NAME}" --type=json \
  -p="[
    {\"op\":\"replace\",\"path\":\"/spec/rules/0/host\",\"value\":\"${ZAMMAD_HOST}\"}
  ]" >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 2) If TLS is on: ensure Certificate -> secret, and ensure Ingress TLS references it
# ------------------------------------------------------------------------------
if [[ "${TLS_MODE}" == "per-host-http01" ]]; then
  log "[03C][ZAMMAD][FIX] ensure Certificate/${CERT_NAME} -> secret/${TLS_SECRET} using ClusterIssuer/${LETSENCRYPT_ISSUER}"

  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${CERT_NAME}
  namespace: ${APP_NS}
spec:
  secretName: ${TLS_SECRET}
  issuerRef:
    kind: ClusterIssuer
    name: ${LETSENCRYPT_ISSUER}
  dnsNames:
    - ${ZAMMAD_HOST}
EOF

  # Ensure ingress tls block is exactly what we want (idempotent merge)
  kubectl -n "${APP_NS}" patch ingress "${ING_NAME}" --type=merge \
    -p "{\"spec\":{\"tls\":[{\"hosts\":[\"${ZAMMAD_HOST}\"],\"secretName\":\"${TLS_SECRET}\"}]}}" >/dev/null
else
  log "[03C][ZAMMAD][FIX] TLS_MODE=${TLS_MODE} -> ensure no TLS on ingress"
  kubectl -n "${APP_NS}" patch ingress "${ING_NAME}" --type=merge \
    -p '{"spec":{"tls":[]}}' >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------------------------
# 3) Remove cert-manager "shim" annotations from the Ingress to avoid solver ingress
#    (Certificate resource is now the single source of truth)
# ------------------------------------------------------------------------------
log "[03C][ZAMMAD][FIX] remove cert-manager shim annotations from ingress/${ING_NAME}"
kubectl -n "${APP_NS}" annotate ingress "${ING_NAME}" \
  kubernetes.io/ingress.class- \
  cert-manager.io/cluster-issuer- \
  cert-manager.io/issuer- \
  cert-manager.io/common-name- \
  acme.cert-manager.io/http01-edit-in-place- \
  >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 4) Delete any extra solver ingresses pointing at the same host (repeatable)
# ------------------------------------------------------------------------------
log "[03C][ZAMMAD][FIX] delete duplicate solver ingresses for host ${ZAMMAD_HOST}"
# List ingresses in tickets that match the host and are not the main ingress name.
mapfile -t DUP_INGS < <(
  kubectl -n "${APP_NS}" get ingress -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.rules[*]}{.host}{" "}{end}{"\n"}{end}' \
    | awk -v h="${ZAMMAD_HOST}" -v keep="${ING_NAME}" '
        $0 ~ h {print $1}
      ' \
    | grep -v "^${ING_NAME}$" \
    | sort -u
)

if [[ "${#DUP_INGS[@]}" -gt 0 ]]; then
  for ing in "${DUP_INGS[@]}"; do
    # only delete obvious solver/shim artifacts; leave other deliberate ingresses alone
    if [[ "${ing}" == *"acme"* || "${ing}" == *"solver"* ]]; then
      kubectl -n "${APP_NS}" delete ingress "${ing}" --ignore-not-found >/dev/null 2>&1 || true
    fi
  done
fi

# ------------------------------------------------------------------------------
# 5) Wait and verify (hard checks)
# ------------------------------------------------------------------------------
log "[03C][ZAMMAD][FIX] verify ingress host + class"
ACTUAL_HOST="$(kubectl -n "${APP_NS}" get ingress "${ING_NAME}" -o jsonpath='{.spec.rules[0].host}')"
[[ "${ACTUAL_HOST}" == "${ZAMMAD_HOST}" ]] || fatal "Ingress host mismatch: ${ACTUAL_HOST} != ${ZAMMAD_HOST}"

ACTUAL_CLASS="$(kubectl -n "${APP_NS}" get ingress "${ING_NAME}" -o jsonpath='{.spec.ingressClassName}')"
[[ "${ACTUAL_CLASS}" == "${INGRESS_CLASS}" ]] || fatal "Ingress class mismatch: ${ACTUAL_CLASS} != ${INGRESS_CLASS}"

if [[ "${TLS_MODE}" == "per-host-http01" ]]; then
  log "[03C][ZAMMAD][FIX] wait for Certificate Ready and secret present"
  kubectl -n "${APP_NS}" wait --for=condition=Ready "certificate/${CERT_NAME}" --timeout=15m
  kubectl -n "${APP_NS}" get secret "${TLS_SECRET}" >/dev/null
fi

log "[03C][ZAMMAD][FIX] ensure only one ingress for this host remains"
# if any non-main ingress still uses the host, fail
leftovers="$(
  kubectl -n "${APP_NS}" get ingress -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.rules[*]}{.host}{" "}{end}{"\n"}{end}' \
    | awk -v h="${ZAMMAD_HOST}" -v keep="${ING_NAME}" '$0 ~ h && $1 != keep {print $1}' \
    | sort -u \
    | tr '\n' ' '
)"
[[ -z "${leftovers// }" ]] || fatal "Duplicate ingresses still exist for host ${ZAMMAD_HOST}: ${leftovers}"

SCHEME="http"
[[ "${TLS_MODE}" == "per-host-http01" ]] && SCHEME="https"
log "[03C][ZAMMAD][FIX] READY: ${SCHEME}://${ZAMMAD_HOST}/"
