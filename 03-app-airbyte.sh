#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# MODULE 03A — APP: AIRBYTE (Helm) — DROP-IN
# FILE: 03-app-airbyte.sh
#
# Version matrix target (authoritative):
# - Airbyte chart: 1.9.1
# - Airbyte app:   2.0.1 (reported by `helm list` as APP VERSION when available)
#
# Notes:
# - Some Helm builds do NOT print "CHART:" in `helm status`. This module parses
#   versions from `helm list` (table) instead (portable).
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/00-env.sh"
# shellcheck source=/dev/null
. "${HERE}/00-lib.sh"

: "${KUBECONFIG:=/root/.kube/config}"
export KUBECONFIG

require_cmd kubectl helm curl

: "${INGRESS_CLASS:?missing INGRESS_CLASS}"
: "${TLS_MODE:?missing TLS_MODE}"
: "${AIRBYTE_HOST:?missing AIRBYTE_HOST}"

AIRBYTE_NS="airbyte"
AIRBYTE_RELEASE="airbyte"
AIRBYTE_REPO_NAME="airbyte"
AIRBYTE_REPO_URL="https://airbytehq.github.io/helm-charts"
AIRBYTE_CHART="airbyte/airbyte"
AIRBYTE_CHART_VERSION="${AIRBYTE_CHART_VERSION:-1.9.1}"
AIRBYTE_APP_VERSION_EXPECTED="${AIRBYTE_APP_VERSION_EXPECTED:-2.0.1}"

# UI is served by the server service for this chart line.
AIRBYTE_UI_SVC_DEFAULT="${AIRBYTE_UI_SVC_DEFAULT:-airbyte-airbyte-server-svc}"
AIRBYTE_UI_SVC_PORT_DEFAULT="${AIRBYTE_UI_SVC_PORT_DEFAULT:-8001}"

# External object storage for Airbyte state/logs (OpenKPI MinIO)
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://openkpi-minio.open-kpi.svc.cluster.local:9000}"
MINIO_SECRET_NS="${MINIO_SECRET_NS:-open-kpi}"
MINIO_SECRET_NAME="${MINIO_SECRET_NAME:-openkpi-minio-secret}"
MINIO_ACCESS_KEY_KEY="${MINIO_ACCESS_KEY_KEY:-MINIO_ROOT_USER}"
MINIO_SECRET_KEY_KEY="${MINIO_SECRET_KEY_KEY:-MINIO_ROOT_PASSWORD}"

TLS_ENABLED="false"
URL_SCHEME="http"
if [[ "${TLS_MODE}" == "per-host-http01" ]]; then
  TLS_ENABLED="true"
  URL_SCHEME="https"
fi

log "[03A][AIRBYTE] start (ns=${AIRBYTE_NS} host=${AIRBYTE_HOST} class=${INGRESS_CLASS} tls=${TLS_MODE} chart=${AIRBYTE_CHART_VERSION})"

ensure_ns "${AIRBYTE_NS}"

# ------------------------------------------------------------------------------
# Sync shared MinIO secret into airbyte namespace (repeatable, no jq)
# ------------------------------------------------------------------------------
kubectl -n "${MINIO_SECRET_NS}" get secret "${MINIO_SECRET_NAME}" >/dev/null

sync_secret_yaml_ns() {
  local src_ns="$1" name="$2" dst_ns="$3"
  kubectl -n "$src_ns" get secret "$name" -o yaml \
    | sed "s/^  namespace: ${src_ns}\$/  namespace: ${dst_ns}/" \
    | sed '/^  uid: /d;/^  resourceVersion: /d;/^  creationTimestamp: /d' \
    | awk '
        BEGIN{skip=0}
        /^  managedFields:/{skip=1; next}
        skip==1 && /^[^ ]/{skip=0}
        skip==0{print}
      ' \
    | kubectl -n "$dst_ns" apply -f - >/dev/null
}

log "[03A][AIRBYTE] sync MinIO secret into ${AIRBYTE_NS}"
sync_secret_yaml_ns "${MINIO_SECRET_NS}" "${MINIO_SECRET_NAME}" "${AIRBYTE_NS}"
kubectl -n "${AIRBYTE_NS}" get secret "${MINIO_SECRET_NAME}" >/dev/null

# ------------------------------------------------------------------------------
# ConfigMap: S3 settings (repeatable)
# ------------------------------------------------------------------------------
kubectl -n "${AIRBYTE_NS}" apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: airbyte-s3-config
data:
  S3_ENDPOINT: "${MINIO_ENDPOINT}"
  S3_PATH_STYLE_ACCESS: "true"
  S3_BUCKET_NAME: "airbyte"
  S3_BUCKET_LOG: "airbyte-logs"
  S3_BUCKET_STATE: "airbyte-state"
  S3_REGION: "us-east-1"
YAML

# ------------------------------------------------------------------------------
# HOTFIX: Airbyte S3 creds env de-dup (repeatable)
# - Removes duplicate AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY entries
# - Forces creds to come from airbyte-airbyte-secrets (the MinIO used by Airbyte chart)
# ------------------------------------------------------------------------------

airbyte_fix_minio_creds() {
  local AIRBYTE_NS="${AIRBYTE_NS:-airbyte}"

  cat >/tmp/mk_aws_env_patch.py <<'PY'
import json, sys
deploy = sys.argv[1]
data = json.load(sys.stdin)
containers = data["spec"]["template"]["spec"]["containers"]

# Prefer container named like deploy; fallback to first
cidx = 0
for i, c in enumerate(containers):
    if c.get("name") == deploy:
        cidx = i
        break

env = containers[cidx].get("env", []) or []
targets = {"AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"}
remove_idxs = [i for i, e in enumerate(env) if e.get("name") in targets]

ops = []
for i in sorted(remove_idxs, reverse=True):
    ops.append({"op": "remove", "path": f"/spec/template/spec/containers/{cidx}/env/{i}"})

ops.append({
  "op": "add",
  "path": f"/spec/template/spec/containers/{cidx}/env/-",
  "value": {"name": "AWS_ACCESS_KEY_ID", "valueFrom": {"secretKeyRef": {"name": "airbyte-airbyte-secrets", "key": "MINIO_ACCESS_KEY_ID"}}}
})
ops.append({
  "op": "add",
  "path": f"/spec/template/spec/containers/{cidx}/env/-",
  "value": {"name": "AWS_SECRET_ACCESS_KEY", "valueFrom": {"secretKeyRef": {"name": "airbyte-airbyte-secrets", "key": "MINIO_SECRET_ACCESS_KEY"}}}
})

print(json.dumps(ops))
PY

  apply_patch () {
    local deploy="$1"
    kubectl -n "${AIRBYTE_NS}" get deploy "${deploy}" -o json \
      | python3 /tmp/mk_aws_env_patch.py "${deploy}" >"/tmp/${deploy}-aws-env.patch.json"
    kubectl -n "${AIRBYTE_NS}" patch deploy "${deploy}" --type=json \
      -p "$(cat "/tmp/${deploy}-aws-env.patch.json")" >/dev/null
  }

  apply_patch airbyte-server
  apply_patch airbyte-worker

  kubectl -n "${AIRBYTE_NS}" rollout restart deploy/airbyte-server deploy/airbyte-worker >/dev/null
  kubectl -n "${AIRBYTE_NS}" rollout status deploy/airbyte-server --timeout=240s
  kubectl -n "${AIRBYTE_NS}" rollout status deploy/airbyte-worker --timeout=240s || true

  # Fail module if 403 persists
  if kubectl -n "${AIRBYTE_NS}" logs deploy/airbyte-server --tail=200 \
    | egrep -qi 'Access Key Id|InvalidAccessKeyId|AccessDenied|S3Exception|403'; then
    fatal "[03A][AIRBYTE][HOTFIX] MinIO/S3 auth still failing after env normalization"
  fi
}




# ------------------------------------------------------------------------------
# Helm install/upgrade (pinned version)
# ------------------------------------------------------------------------------
helm repo add "${AIRBYTE_REPO_NAME}" "${AIRBYTE_REPO_URL}" >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1 || true

VALUES_FILE="${HERE}/.values-airbyte.yaml"
cat > "${VALUES_FILE}" <<YAML
global:
  deploymentMode: oss

webapp:
  ingress:
    enabled: false

server:
  extraEnvFrom:
    - configMapRef:
        name: airbyte-s3-config
  extraEnv:
    - name: AWS_ACCESS_KEY_ID
      valueFrom:
        secretKeyRef:
          name: "${MINIO_SECRET_NAME}"
          key: "${MINIO_ACCESS_KEY_KEY}"
          optional: false
    - name: AWS_SECRET_ACCESS_KEY
      valueFrom:
        secretKeyRef:
          name: "${MINIO_SECRET_NAME}"
          key: "${MINIO_SECRET_KEY_KEY}"
          optional: false

worker:
  extraEnvFrom:
    - configMapRef:
        name: airbyte-s3-config
  extraEnv:
    - name: AWS_ACCESS_KEY_ID
      valueFrom:
        secretKeyRef:
          name: "${MINIO_SECRET_NAME}"
          key: "${MINIO_ACCESS_KEY_KEY}"
          optional: false
    - name: AWS_SECRET_ACCESS_KEY
      valueFrom:
        secretKeyRef:
          name: "${MINIO_SECRET_NAME}"
          key: "${MINIO_SECRET_KEY_KEY}"
          optional: false
YAML

log "[03A][AIRBYTE] helm upgrade --install (${AIRBYTE_CHART} --version ${AIRBYTE_CHART_VERSION})"
helm upgrade --install "${AIRBYTE_RELEASE}" "${AIRBYTE_CHART}" \
  -n "${AIRBYTE_NS}" \
  --version "${AIRBYTE_CHART_VERSION}" \
  -f "${VALUES_FILE}" \
  --wait --timeout 25m

# ------------------------------------------------------------------------------
# Enforce Ingress-only exposure: no NodePort / LoadBalancer in airbyte namespace
# ------------------------------------------------------------------------------
log "[03A][AIRBYTE] enforce ingress-only services (no NodePort/LoadBalancer)"
EXPOSED_SVCS="$(kubectl -n "${AIRBYTE_NS}" get svc --no-headers 2>/dev/null | awk '$3=="NodePort" || $3=="LoadBalancer"{print $1}' || true)"
if [[ -n "${EXPOSED_SVCS}" ]]; then
  warn "[03A][AIRBYTE] exposed services detected; converting to ClusterIP: ${EXPOSED_SVCS}"
  for s in ${EXPOSED_SVCS}; do
    kubectl -n "${AIRBYTE_NS}" patch svc "$s" --type=merge -p '{"spec":{"type":"ClusterIP","externalTrafficPolicy":null}}' >/dev/null 2>&1 || true
  done
fi
if kubectl -n "${AIRBYTE_NS}" get svc --no-headers 2>/dev/null | awk '$3=="NodePort" || $3=="LoadBalancer"{exit 1}'; then
  :
else
  kubectl -n "${AIRBYTE_NS}" get svc -o wide || true
  fatal "[03A][AIRBYTE] NodePort/LoadBalancer service remains after remediation"
fi

# ------------------------------------------------------------------------------
# Deterministic ingress (owned by this module)
# ------------------------------------------------------------------------------
UI_SVC="${AIRBYTE_UI_SVC_DEFAULT}"
UI_PORT="${AIRBYTE_UI_SVC_PORT_DEFAULT}"

kubectl -n "${AIRBYTE_NS}" get svc "${UI_SVC}" >/dev/null 2>&1 || {
  kubectl -n "${AIRBYTE_NS}" get svc -o wide || true
  fatal "[03A][AIRBYTE] cannot find expected UI service ${AIRBYTE_NS}/${UI_SVC}"
}

log "[03A][AIRBYTE] apply ingress airbyte -> ${UI_SVC}:${UI_PORT}"
if [[ "${TLS_ENABLED}" == "true" ]]; then
  kubectl -n "${AIRBYTE_NS}" apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: airbyte
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
    - hosts: [${AIRBYTE_HOST}]
      secretName: airbyte-tls
  rules:
    - host: ${AIRBYTE_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${UI_SVC}
                port:
                  number: ${UI_PORT}
YAML
else
  kubectl -n "${AIRBYTE_NS}" apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: airbyte
spec:
  ingressClassName: ${INGRESS_CLASS}
  rules:
    - host: ${AIRBYTE_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${UI_SVC}
                port:
                  number: ${UI_PORT}
YAML
fi

# ------------------------------------------------------------------------------
# TLS: explicit Certificate (deterministic), wait for Ready
# ------------------------------------------------------------------------------
if [[ "${TLS_ENABLED}" == "true" ]]; then
  log "[03A][AIRBYTE] apply Certificate airbyte-cert -> secret airbyte-tls"
  kubectl -n "${AIRBYTE_NS}" apply -f - <<YAML
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: airbyte-cert
spec:
  secretName: airbyte-tls
  privateKey:
    rotationPolicy: Never
  issuerRef:
    kind: ClusterIssuer
    name: letsencrypt-http01
  dnsNames:
    - ${AIRBYTE_HOST}
YAML

  log "[03A][AIRBYTE] wait for Certificate Ready (airbyte-cert)"
  retry 90 10 bash -lc "kubectl -n '${AIRBYTE_NS}' get certificate airbyte-cert >/dev/null 2>&1"
  retry 90 10 bash -lc "kubectl -n '${AIRBYTE_NS}' get certificate airbyte-cert -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True" || {
    kubectl -n "${AIRBYTE_NS}" describe certificate airbyte-cert | sed -n '1,260p' || true
    kubectl -n "${AIRBYTE_NS}" get order,challenge -o wide 2>/dev/null || true
    fatal "[03A][AIRBYTE] certificate not Ready"
  }
fi

# ------------------------------------------------------------------------------
# Readiness gate
# ------------------------------------------------------------------------------
log "[03A][AIRBYTE] readiness gate (rollouts + Running pods Ready=True)"
for d in $(kubectl -n "${AIRBYTE_NS}" get deploy -o name 2>/dev/null); do
  kubectl -n "${AIRBYTE_NS}" rollout status "$d" --timeout=20m || true
done
for s in $(kubectl -n "${AIRBYTE_NS}" get sts -o name 2>/dev/null); do
  kubectl -n "${AIRBYTE_NS}" rollout status "$s" --timeout=20m || true
done

NOT_READY="$(kubectl -n "${AIRBYTE_NS}" get pods -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' \
  | awk '$2!="True"{print $1}' || true)"

if [[ -n "${NOT_READY}" ]]; then
  warn "[03A][AIRBYTE] Running pods not Ready: ${NOT_READY}"
  kubectl -n "${AIRBYTE_NS}" get pods -o wide || true
  kubectl -n "${AIRBYTE_NS}" get deploy,sts -o wide || true
  kubectl -n "${AIRBYTE_NS}" get events --sort-by=.lastTimestamp | tail -n 200 || true
  c=0
  for p in ${NOT_READY}; do
    c=$((c+1))
    kubectl -n "${AIRBYTE_NS}" describe pod "$p" | sed -n '1,260p' || true
    kubectl -n "${AIRBYTE_NS}" logs "$p" --all-containers --tail=250 || true
    [[ $c -ge 3 ]] && break
  done
  fatal "[03A][AIRBYTE] pods not ready"
fi

# ------------------------------------------------------------------------------
# Tests (production-level, deterministic, bounded)
# ------------------------------------------------------------------------------

log "[03A][AIRBYTE][TEST] begin"

# Strict prerequisites for this section
AIRBYTE_NS="${AIRBYTE_NS:-airbyte}"
: "${UI_SVC:?missing UI_SVC (expected Airbyte UI service name)}"
: "${UI_PORT:?missing UI_PORT (expected Airbyte UI service port)}"
TLS_ENABLED="${TLS_ENABLED:-false}"
: "${MINIO_SECRET_NAME:?missing MINIO_SECRET_NAME}"
: "${MINIO_ACCESS_KEY_KEY:?missing MINIO_ACCESS_KEY_KEY}"
: "${MINIO_SECRET_KEY_KEY:?missing MINIO_SECRET_KEY_KEY}"
: "${AIRBYTE_HOST:?missing AIRBYTE_HOST}"
: "${URL_SCHEME:=http}"

log "[03A][AIRBYTE][TEST][T01] kubectl connectivity"
kubectl version >/dev/null 2>&1 || fatal "[03A][AIRBYTE][TEST][T01] kubectl cannot reach cluster"

log "[03A][AIRBYTE][TEST][T02] helm release present + pinned chart/app versions (helm list -o json)"
ROW_JSON="$(helm -n "${AIRBYTE_NS}" list --filter '^airbyte$' -o json 2>/dev/null || true)"
echo "${ROW_JSON}" | grep -q '"name":"airbyte"' || fatal "[03A][AIRBYTE][TEST][T02] release airbyte not found"

CHART_JSON="$(printf '%s' "${ROW_JSON}" | sed -n 's/.*"chart":"\([^"]*\)".*/\1/p' | head -n1)"
APPVER_JSON="$(printf '%s' "${ROW_JSON}" | sed -n 's/.*"app_version":"\([^"]*\)".*/\1/p' | head -n1)"

[[ -n "${CHART_JSON}" ]]  || fatal "[03A][AIRBYTE][TEST][T02] could not parse chart from helm JSON"
[[ -n "${APPVER_JSON}" ]] || fatal "[03A][AIRBYTE][TEST][T02] could not parse app_version from helm JSON"

[[ "${CHART_JSON}" == "airbyte-1.9.1" ]] || fatal "[03A][AIRBYTE][TEST][T02] expected chart airbyte-1.9.1, got: ${CHART_JSON}"
[[ "${APPVER_JSON}" == "2.0.1" ]]        || fatal "[03A][AIRBYTE][TEST][T02] expected app 2.0.1, got: ${APPVER_JSON}"

log "[03A][AIRBYTE][TEST][T03] core services exist (UI + server)"
kubectl -n "${AIRBYTE_NS}" get svc "${UI_SVC}" >/dev/null 2>&1 || fatal "[03A][AIRBYTE][TEST][T03] missing UI service: ${UI_SVC}"
kubectl -n "${AIRBYTE_NS}" get svc -o name | grep -q '/airbyte-airbyte-server-svc$' || fatal "[03A][AIRBYTE][TEST][T03] missing server service: airbyte-airbyte-server-svc"

log "[03A][AIRBYTE][TEST][T04] no NodePort/LoadBalancer exposure"
kubectl -n "${AIRBYTE_NS}" get svc --no-headers 2>/dev/null | awk '$3=="NodePort" || $3=="LoadBalancer"{bad=1} END{exit bad}' \
  || fatal "[03A][AIRBYTE][TEST][T04] exposed service present in ${AIRBYTE_NS}"

log "[03A][AIRBYTE][TEST][T05] EndpointSlice exists for UI service"
kubectl -n "${AIRBYTE_NS}" get endpointslice -l kubernetes.io/service-name="${UI_SVC}" >/dev/null 2>&1 \
  || fatal "[03A][AIRBYTE][TEST][T05] endpointslice missing for ${UI_SVC}"

log "[03A][AIRBYTE][TEST][T06] ingress exists + host matches + backend service matches"
kubectl -n "${AIRBYTE_NS}" get ingress airbyte >/dev/null 2>&1 || fatal "[03A][AIRBYTE][TEST][T06] ingress airbyte missing"
kubectl -n "${AIRBYTE_NS}" get ingress airbyte -o jsonpath='{.spec.rules[0].host}' | grep -qx "${AIRBYTE_HOST}" \
  || fatal "[03A][AIRBYTE][TEST][T06] ingress host mismatch (expected ${AIRBYTE_HOST})"
kubectl -n "${AIRBYTE_NS}" get ingress airbyte -o jsonpath='{.spec.rules[0].http.paths[0].backend.service.name}' | grep -qx "${UI_SVC}" \
  || fatal "[03A][AIRBYTE][TEST][T06] ingress backend service mismatch (expected ${UI_SVC})"

if [[ "${TLS_ENABLED}" == "true" ]]; then
  log "[03A][AIRBYTE][TEST][T07] TLS: Certificate Ready + secret exists"
  kubectl -n "${AIRBYTE_NS}" get certificate airbyte-cert >/dev/null 2>&1 || fatal "[03A][AIRBYTE][TEST][T07] certificate missing (airbyte-cert)"
  kubectl -n "${AIRBYTE_NS}" get secret airbyte-tls >/dev/null 2>&1 || fatal "[03A][AIRBYTE][TEST][T07] TLS secret missing (airbyte-tls)"
  kubectl -n "${AIRBYTE_NS}" get certificate airbyte-cert -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q True \
    || fatal "[03A][AIRBYTE][TEST][T07] certificate not Ready (airbyte-cert)"
fi

log "[03A][AIRBYTE][TEST][T08] in-cluster HTTP check to UI service (ephemeral curl)"
kubectl -n "${AIRBYTE_NS}" delete pod airbyte-curl --ignore-not-found >/dev/null 2>&1 || true
kubectl -n "${AIRBYTE_NS}" run airbyte-curl --rm -i --restart=Never \
  --image=curlimages/curl:8.5.0 \
  --command -- sh -lc "curl -fsS -m 10 http://${UI_SVC}.${AIRBYTE_NS}.svc.cluster.local:${UI_PORT}/ >/dev/null" \
  >/dev/null 2>&1 || fatal "[03A][AIRBYTE][TEST][T08] UI service not responding in-cluster"

log "[03A][AIRBYTE][TEST][T09] external URL reachable via ingress (bounded, accept redirect/auth)"
retry 18 10 bash -lc "curl -k -sS -o /dev/null -m 15 -w '%{http_code}' ${URL_SCHEME}://${AIRBYTE_HOST}/ | egrep -q '^(200|302|307|308|401|403)$'" || {
  kubectl -n "${AIRBYTE_NS}" get ingress airbyte -o wide || true
  kubectl -n ingress-nginx get pods -o wide 2>/dev/null || true
  kubectl -n kube-system get pods -o wide 2>/dev/null || true
  fatal "[03A][AIRBYTE][TEST][T09] ingress not reachable: ${URL_SCHEME}://${AIRBYTE_HOST}/"
}

log "[03A][AIRBYTE][TEST][T10] S3 config objects exist (configmap + secret keys present)"
kubectl -n "${AIRBYTE_NS}" get cm airbyte-s3-config >/dev/null 2>&1 \
  || fatal "[03A][AIRBYTE][TEST][T10] missing ConfigMap airbyte-s3-config"

kubectl -n "${AIRBYTE_NS}" get secret "${MINIO_SECRET_NAME}" -o jsonpath="{.data.${MINIO_ACCESS_KEY_KEY}}" 2>/dev/null | grep -q . \
  || fatal "[03A][AIRBYTE][TEST][T10] missing secret key ${MINIO_ACCESS_KEY_KEY} in ${MINIO_SECRET_NAME}"
kubectl -n "${AIRBYTE_NS}" get secret "${MINIO_SECRET_NAME}" -o jsonpath="{.data.${MINIO_SECRET_KEY_KEY}}" 2>/dev/null | grep -q . \
  || fatal "[03A][AIRBYTE][TEST][T10] missing secret key ${MINIO_SECRET_KEY_KEY} in ${MINIO_SECRET_NAME}"

log "[03A][AIRBYTE][TEST][T11] S3 env wired into server/worker (runtime env check)"
SERVER_DEPLOY="$(kubectl -n "${AIRBYTE_NS}" get deploy -o name | awk '/airbyte-server/{print; exit}')"
WORKER_DEPLOY="$(kubectl -n "${AIRBYTE_NS}" get deploy -o name | awk '/airbyte-worker/{print; exit}')"
[[ -n "${SERVER_DEPLOY}" ]] || fatal "[03A][AIRBYTE][TEST][T11] cannot find server deployment"
[[ -n "${WORKER_DEPLOY}" ]] || fatal "[03A][AIRBYTE][TEST][T11] cannot find worker deployment"

kubectl -n "${AIRBYTE_NS}" get "${SERVER_DEPLOY}" -o yaml | egrep -q 'name: S3_ENDPOINT|name: AWS_ACCESS_KEY_ID|name: AWS_SECRET_ACCESS_KEY' \
  || fatal "[03A][AIRBYTE][TEST][T11] server env missing S3/AWS vars"
kubectl -n "${AIRBYTE_NS}" get "${WORKER_DEPLOY}" -o yaml | egrep -q 'name: S3_ENDPOINT|name: AWS_ACCESS_KEY_ID|name: AWS_SECRET_ACCESS_KEY' \
  || fatal "[03A][AIRBYTE][TEST][T11] worker env missing S3/AWS vars"

log "[03A][AIRBYTE][TEST][T11.5] ensure no duplicate AWS creds env entries (post-hotfix expectation: exactly 1 pair)"
DUP_S="$(kubectl -n "${AIRBYTE_NS}" get deploy airbyte-server -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}' \
  | egrep -c '^AWS_ACCESS_KEY_ID$|^AWS_SECRET_ACCESS_KEY$' || true)"
DUP_W="$(kubectl -n "${AIRBYTE_NS}" get deploy airbyte-worker -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}' \
  | egrep -c '^AWS_ACCESS_KEY_ID$|^AWS_SECRET_ACCESS_KEY$' || true)"
[[ "${DUP_S}" -eq 2 ]] || fatal "[03A][AIRBYTE][TEST][T11.5] server has duplicate/missing AWS_* env entries (expected 2 total, got ${DUP_S})"
[[ "${DUP_W}" -eq 2 ]] || fatal "[03A][AIRBYTE][TEST][T11.5] worker has duplicate/missing AWS_* env entries (expected 2 total, got ${DUP_W})"

log "[03A][AIRBYTE][TEST][T11.6] confirm AWS_* env sources are the intended secret (airbyte-airbyte-secrets)"
SRV_SRC="$(kubectl -n "${AIRBYTE_NS}" get deploy airbyte-server -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="AWS_ACCESS_KEY_ID")]}{.valueFrom.secretKeyRef.name}{"\n"}{end}')"
SRV_SEC="$(kubectl -n "${AIRBYTE_NS}" get deploy airbyte-server -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="AWS_SECRET_ACCESS_KEY")]}{.valueFrom.secretKeyRef.name}{"\n"}{end}')"
WRK_SRC="$(kubectl -n "${AIRBYTE_NS}" get deploy airbyte-worker -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="AWS_ACCESS_KEY_ID")]}{.valueFrom.secretKeyRef.name}{"\n"}{end}')"
WRK_SEC="$(kubectl -n "${AIRBYTE_NS}" get deploy airbyte-worker -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="AWS_SECRET_ACCESS_KEY")]}{.valueFrom.secretKeyRef.name}{"\n"}{end}')"

echo "${SRV_SRC}" | grep -qx 'airbyte-airbyte-secrets' || fatal "[03A][AIRBYTE][TEST][T11.6] server AWS_ACCESS_KEY_ID not sourced from airbyte-airbyte-secrets"
echo "${SRV_SEC}" | grep -qx 'airbyte-airbyte-secrets' || fatal "[03A][AIRBYTE][TEST][T11.6] server AWS_SECRET_ACCESS_KEY not sourced from airbyte-airbyte-secrets"
echo "${WRK_SRC}" | grep -qx 'airbyte-airbyte-secrets' || fatal "[03A][AIRBYTE][TEST][T11.6] worker AWS_ACCESS_KEY_ID not sourced from airbyte-airbyte-secrets"
echo "${WRK_SEC}" | grep -qx 'airbyte-airbyte-secrets' || fatal "[03A][AIRBYTE][TEST][T11.6] worker AWS_SECRET_ACCESS_KEY not sourced from airbyte-airbyte-secrets"

log "[03A][AIRBYTE][TEST][T11.7] server logs should not show MinIO/S3 auth failures (403/InvalidAccessKeyId)"
if kubectl -n "${AIRBYTE_NS}" logs deploy/airbyte-server --tail=250 \
  | egrep -qi 'Access Key Id|InvalidAccessKeyId|AccessDenied|S3Exception|403'; then
  kubectl -n "${AIRBYTE_NS}" logs deploy/airbyte-server --tail=250 | tail -n 120 || true
  fatal "[03A][AIRBYTE][TEST][T11.7] detected MinIO/S3 auth errors in server logs"
fi

log "[03A][AIRBYTE][TEST][T12] restarts sanity (no crashlooping core pods)"
BAD="$(kubectl -n "${AIRBYTE_NS}" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].restartCount}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null \
  | awk '$2 ~ /^[0-9]+$/ && $2>10 {print $1}' || true)"
if [[ -n "${BAD}" ]]; then
  kubectl -n "${AIRBYTE_NS}" get pods -o wide || true
  fatal "[03A][AIRBYTE][TEST][T12] high restartCount detected: ${BAD}"
fi

log "[03A][AIRBYTE][TEST] PASS"
echo "[03A][AIRBYTE] READY ${URL_SCHEME}://${AIRBYTE_HOST}/"
