#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# MODULE 03A — APP: AIRBYTE (Helm) — DROP-IN (REPEATABLE)
# FILE: 03-app-airbyte.sh
#
# Targets:
# - Airbyte Helm chart: 1.9.1
# - Airbyte app:       2.0.1
#
# What this module guarantees (idempotent):
# - Installs/Upgrades Airbyte via Helm (pinned chart version)
# - Creates/updates Ingress + Certificate (TLS_MODE=per-host-http01)
# - Forces Airbyte to use OpenKPI MinIO (external) with correct endpoint + region
# - Eliminates duplicate AWS_* env entries (prevents silent shadowing)
# - Bootstraps required buckets (airbyte, airbyte-logs, airbyte-state)
# - Deterministic tests + bounded waits
#
# Notes:
# - Root cause you hit: mc image tag not found + AWS env duplication -> wrong creds -> 403
# - This module avoids nonexistent mc tags, and enforces creds from OpenKPI secret.
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/00-env.sh"
# shellcheck source=/dev/null
. "${HERE}/00-lib.sh"


# ------------------------------------------------------------------------------
# Normalize critical vars (strip inline comments + trim) BEFORE contract checks
# ------------------------------------------------------------------------------
_strip() { printf "%s" "${1%%#*}" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'; }

TLS_MODE="$(_strip "${TLS_MODE:-}")"
INGRESS_CLASS="$(_strip "${INGRESS_CLASS:-}")"
CERT_CLUSTER_ISSUER="$(_strip "${CERT_CLUSTER_ISSUER:-}")"
AIRBYTE_HOST="$(_strip "${AIRBYTE_HOST:-}")"



: "${KUBECONFIG:=/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG

require_cmd kubectl helm curl python3

# ------------------------------------------------------------------------------
# Contract (required)
# ------------------------------------------------------------------------------
: "${INGRESS_CLASS:?missing INGRESS_CLASS}"
: "${TLS_MODE:?missing TLS_MODE}"
: "${AIRBYTE_HOST:?missing AIRBYTE_HOST}"

# ------------------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------------------
AIRBYTE_NS="${AIRBYTE_NS:-airbyte}"
AIRBYTE_RELEASE="${AIRBYTE_RELEASE:-airbyte}"
AIRBYTE_REPO_NAME="${AIRBYTE_REPO_NAME:-airbyte}"
AIRBYTE_REPO_URL="${AIRBYTE_REPO_URL:-https://airbytehq.github.io/helm-charts}"
AIRBYTE_CHART="${AIRBYTE_CHART:-airbyte/airbyte}"
AIRBYTE_CHART_VERSION="${AIRBYTE_CHART_VERSION:-1.9.1}"
AIRBYTE_APP_VERSION_EXPECTED="${AIRBYTE_APP_VERSION_EXPECTED:-2.0.1}"

# Airbyte UI is served by this service for this chart line
AIRBYTE_UI_SVC="${AIRBYTE_UI_SVC:-airbyte-airbyte-server-svc}"
AIRBYTE_UI_PORT="${AIRBYTE_UI_PORT:-8001}"

# OpenKPI MinIO (source of truth)
MINIO_NS="${MINIO_NS:-open-kpi}"
MINIO_SECRET_NAME="${MINIO_SECRET_NAME:-openkpi-minio-secret}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://openkpi-minio.open-kpi.svc.cluster.local:9000}"

# Region (must match MinIO deployment env MINIO_REGION_NAME)
AIRBYTE_S3_REGION="${AIRBYTE_S3_REGION:-us-east-1}"

# Images used by tests/bootstrap
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.5.0}"
MC_IMAGE="${MC_IMAGE:-minio/mc:RELEASE.2024-06-12T14-34-03Z}"

TLS_ENABLED="false"
URL_SCHEME="http"
if [[ "${TLS_MODE}" == "per-host-http01" ]]; then
  TLS_ENABLED="true"
  URL_SCHEME="https"
fi

log "[03A][AIRBYTE] start (ns=${AIRBYTE_NS} host=${AIRBYTE_HOST} tls=${TLS_MODE} chart=${AIRBYTE_CHART_VERSION} app=${AIRBYTE_APP_VERSION_EXPECTED})"

ensure_ns "${AIRBYTE_NS}"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
b64(){ printf '%s' "$1" | base64 -w0; }

sync_secret_yaml_ns() {
  local src_ns="$1" name="$2" dst_ns="$3"
  kubectl -n "$src_ns" get secret "$name" -o yaml \
    | sed "s/^  namespace: ${src_ns}\$/  namespace: ${dst_ns}/" \
    | sed '/^  uid: /d;/^  resourceVersion: /d;/^  creationTimestamp: /d' \
    | awk 'BEGIN{skip=0} /^  managedFields:/{skip=1; next} skip==1 && /^[^ ]/{skip=0} skip==0{print}' \
    | kubectl -n "$dst_ns" apply -f - >/dev/null
}

# ------------------------------------------------------------------------------
# 1) Validate OpenKPI MinIO exists + creds readable
# ------------------------------------------------------------------------------
kubectl -n "${MINIO_NS}" get svc openkpi-minio >/dev/null 2>&1 || fatal "[03A][AIRBYTE] missing svc ${MINIO_NS}/openkpi-minio (run 02-data-plane.sh first)"
kubectl -n "${MINIO_NS}" get secret "${MINIO_SECRET_NAME}" >/dev/null 2>&1 || fatal "[03A][AIRBYTE] missing secret ${MINIO_NS}/${MINIO_SECRET_NAME}"

MINIO_AK="$(kubectl -n "${MINIO_NS}" get secret "${MINIO_SECRET_NAME}" -o jsonpath='{.data.MINIO_ROOT_USER}' | base64 -d)"
MINIO_SK="$(kubectl -n "${MINIO_NS}" get secret "${MINIO_SECRET_NAME}" -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d)"

# ------------------------------------------------------------------------------
# 2) Sync OpenKPI MinIO secret into airbyte namespace (repeatable)
# ------------------------------------------------------------------------------
log "[03A][AIRBYTE] sync MinIO secret -> ${AIRBYTE_NS}/${MINIO_SECRET_NAME}"
sync_secret_yaml_ns "${MINIO_NS}" "${MINIO_SECRET_NAME}" "${AIRBYTE_NS}"
kubectl -n "${AIRBYTE_NS}" get secret "${MINIO_SECRET_NAME}" >/dev/null

# ------------------------------------------------------------------------------
# 3) Ensure MinIO region matches requested region (informative hard check)
# ------------------------------------------------------------------------------
MINIO_REGION_ACTUAL="$(kubectl -n "${MINIO_NS}" get sts openkpi-minio -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"="}{.value}{"\n"}{end}' 2>/dev/null | awk -F= '$1=="MINIO_REGION_NAME"{print $2; exit}' || true)"
if [[ -n "${MINIO_REGION_ACTUAL}" && "${MINIO_REGION_ACTUAL}" != "${AIRBYTE_S3_REGION}" ]]; then
  fatal "[03A][AIRBYTE] region mismatch: openkpi-minio MINIO_REGION_NAME=${MINIO_REGION_ACTUAL} but AIRBYTE_S3_REGION=${AIRBYTE_S3_REGION}"
fi

# ------------------------------------------------------------------------------
# 4) Bootstrap buckets in OpenKPI MinIO (repeatable)
# ------------------------------------------------------------------------------
log "[03A][AIRBYTE] bootstrap MinIO buckets via mc (repeatable)"
kubectl -n "${AIRBYTE_NS}" delete job mc-airbyte --ignore-not-found >/dev/null 2>&1 || true

kubectl -n "${AIRBYTE_NS}" apply -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: mc-airbyte
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: mc
        image: ${MC_IMAGE}
        env:
        - name: MINIO_USER
          valueFrom:
            secretKeyRef:
              name: ${MINIO_SECRET_NAME}
              key: MINIO_ROOT_USER
        - name: MINIO_PASS
          valueFrom:
            secretKeyRef:
              name: ${MINIO_SECRET_NAME}
              key: MINIO_ROOT_PASSWORD
        command: ["sh","-lc"]
        args:
          - |
            set -euo pipefail
            mc alias set openkpi "${MINIO_ENDPOINT}" "\$MINIO_USER" "\$MINIO_PASS" >/dev/null
            mc mb -p openkpi/airbyte       >/dev/null 2>&1 || true
            mc mb -p openkpi/airbyte-logs  >/dev/null 2>&1 || true
            mc mb -p openkpi/airbyte-state >/dev/null 2>&1 || true
            mc ls openkpi >/dev/null
YAML

kubectl -n "${AIRBYTE_NS}" wait --for=condition=complete job/mc-airbyte --timeout=180s || {
  kubectl -n "${AIRBYTE_NS}" get pods -l job-name=mc-airbyte -o wide || true
  kubectl -n "${AIRBYTE_NS}" logs -l job-name=mc-airbyte --tail=200 || true
  fatal "[03A][AIRBYTE] bucket bootstrap job failed"
}

# ------------------------------------------------------------------------------
# 5) ConfigMap: S3 settings (repeatable)
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
  S3_REGION: "${AIRBYTE_S3_REGION}"
YAML

# ------------------------------------------------------------------------------
# 6) Helm install/upgrade (pinned)
#    IMPORTANT: we do NOT trust chart defaults for storage creds.
#    We inject OpenKPI secret for server/worker, then post-fix duplicates.
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

worker:
  extraEnvFrom:
    - configMapRef:
        name: airbyte-s3-config
YAML

log "[03A][AIRBYTE] helm upgrade --install (${AIRBYTE_CHART} --version ${AIRBYTE_CHART_VERSION})"
helm upgrade --install "${AIRBYTE_RELEASE}" "${AIRBYTE_CHART}" \
  -n "${AIRBYTE_NS}" \
  --version "${AIRBYTE_CHART_VERSION}" \
  -f "${VALUES_FILE}" \
  --wait --timeout 25m

# ------------------------------------------------------------------------------
# 7) Force airbyte-airbyte-secrets MINIO_* to match OpenKPI (repeatable)
#    (Some Airbyte components read MINIO_* from this chart secret.)
# ------------------------------------------------------------------------------
log "[03A][AIRBYTE] align airbyte-airbyte-secrets AWS/MINIO keys with OpenKPI"
if kubectl -n "${AIRBYTE_NS}" get secret airbyte-airbyte-secrets >/dev/null 2>&1; then
  kubectl -n "${AIRBYTE_NS}" patch secret airbyte-airbyte-secrets --type=merge -p "{
    \"data\":{
      \"MINIO_ACCESS_KEY_ID\":\"$(b64 "${MINIO_AK}")\",
      \"MINIO_SECRET_ACCESS_KEY\":\"$(b64 "${MINIO_SK}")\",
      \"AWS_ACCESS_KEY_ID\":\"$(b64 "${MINIO_AK}")\",
      \"AWS_SECRET_ACCESS_KEY\":\"$(b64 "${MINIO_SK}")\"
    }
  }" >/dev/null
fi

# ------------------------------------------------------------------------------
# 8) Normalize AWS env (remove duplicates; re-add from OpenKPI MinIO secret)
#    - Works even if container names change
#    - Skips missing deployments
#    - Patches all Airbyte components that can touch object storage
# ------------------------------------------------------------------------------
log "[03A][AIRBYTE] normalize AWS env (dedupe; enforce from ${MINIO_SECRET_NAME})"

cat >/tmp/mk_aws_env_patch.py <<'PY'
import json, sys

deploy      = sys.argv[1]
secret_name = sys.argv[2]
ak_key      = sys.argv[3]
sk_key      = sys.argv[4]

data = json.load(sys.stdin)
containers = data["spec"]["template"]["spec"].get("containers", [])

# Prefer the first container that already has AWS vars; else fall back to container[0]
cidx = 0
best = None
for i, c in enumerate(containers):
    env = c.get("env") or []
    names = {e.get("name") for e in env if isinstance(e, dict)}
    if "AWS_ACCESS_KEY_ID" in names or "AWS_SECRET_ACCESS_KEY" in names:
        best = i
        break
if best is not None:
    cidx = best

env = containers[cidx].get("env") or []
targets = {"AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"}

remove_idxs = [i for i, e in enumerate(env) if isinstance(e, dict) and e.get("name") in targets]

ops = []
# Remove all occurrences (reverse index order)
for i in sorted(remove_idxs, reverse=True):
    ops.append({"op": "remove", "path": f"/spec/template/spec/containers/{cidx}/env/{i}"})

# Re-add exactly one pair at the end
ops.append({
    "op": "add",
    "path": f"/spec/template/spec/containers/{cidx}/env/-",
    "value": {"name": "AWS_ACCESS_KEY_ID",
              "valueFrom": {"secretKeyRef": {"name": secret_name, "key": ak_key, "optional": False}}}
})
ops.append({
    "op": "add",
    "path": f"/spec/template/spec/containers/{cidx}/env/-",
    "value": {"name": "AWS_SECRET_ACCESS_KEY",
              "valueFrom": {"secretKeyRef": {"name": secret_name, "key": sk_key, "optional": False}}}
})

print(json.dumps(ops))
PY

patch_env () {
  local dep="$1"

  kubectl -n "${AIRBYTE_NS}" get deploy "${dep}" >/dev/null 2>&1 || {
    log "[03A][AIRBYTE] skip env patch (deployment not found): ${dep}"
    return 0
  }

  kubectl -n "${AIRBYTE_NS}" get deploy "${dep}" -o json \
    | python3 /tmp/mk_aws_env_patch.py "${dep}" "${MINIO_SECRET_NAME}" "MINIO_ROOT_USER" "MINIO_ROOT_PASSWORD" \
    >/tmp/"${dep}".aws.patch.json

  kubectl -n "${AIRBYTE_NS}" patch deploy "${dep}" --type=json -p "$(cat /tmp/"${dep}".aws.patch.json)" >/dev/null
  log "[03A][AIRBYTE] patched AWS env: ${dep}"
}

# Patch all likely Airbyte components that read/write S3/MinIO
patch_env airbyte-server
patch_env airbyte-worker
patch_env airbyte-workload-api-server
patch_env airbyte-workload-launcher
patch_env airbyte-api-server

# Restart what exists
kubectl -n "${AIRBYTE_NS}" rollout restart deploy/airbyte-server deploy/airbyte-worker >/dev/null 2>&1 || true
kubectl -n "${AIRBYTE_NS}" rollout status deploy/airbyte-server --timeout=15m
kubectl -n "${AIRBYTE_NS}" rollout status deploy/airbyte-worker --timeout=15m || true

# ------------------------------------------------------------------------------
# 9) Enforce ingress-only exposure (no NodePort/LoadBalancer)
# ------------------------------------------------------------------------------
log "[03A][AIRBYTE] enforce ingress-only services (no NodePort/LoadBalancer)"
EXPOSED_SVCS="$(kubectl -n "${AIRBYTE_NS}" get svc --no-headers 2>/dev/null | awk '$3=="NodePort" || $3=="LoadBalancer"{print $1}' || true)"
if [[ -n "${EXPOSED_SVCS}" ]]; then
  warn "[03A][AIRBYTE] converting exposed services to ClusterIP: ${EXPOSED_SVCS}"
  for s in ${EXPOSED_SVCS}; do
    kubectl -n "${AIRBYTE_NS}" patch svc "$s" --type=merge -p '{"spec":{"type":"ClusterIP","externalTrafficPolicy":null}}' >/dev/null 2>&1 || true
  done
fi
kubectl -n "${AIRBYTE_NS}" get svc --no-headers 2>/dev/null | awk '$3=="NodePort" || $3=="LoadBalancer"{bad=1} END{exit bad}' \
  || fatal "[03A][AIRBYTE] NodePort/LoadBalancer service remains after remediation"




# ------------------------------------------------------------------------------
# 10) Ingress + TLS Certificate (deterministic ownership)
# ------------------------------------------------------------------------------

kubectl -n "${AIRBYTE_NS}" apply --dry-run=client -f - >/dev/null <<'YAML'
apiVersion: v1
kind: List
items: []
YAML


kubectl -n "${AIRBYTE_NS}" get svc "${AIRBYTE_UI_SVC}" >/dev/null 2>&1 || {
  kubectl -n "${AIRBYTE_NS}" get svc -o wide || true
  fatal "[03A][AIRBYTE] cannot find expected UI service ${AIRBYTE_UI_SVC}"
}

log "[03A][AIRBYTE] apply ingress airbyte -> ${AIRBYTE_UI_SVC}:${AIRBYTE_UI_PORT}"

if [[ "${TLS_ENABLED}" == "true" ]]; then
  : "${CERT_CLUSTER_ISSUER:?missing CERT_CLUSTER_ISSUER}"

  kubectl -n "${AIRBYTE_NS}" apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: airbyte
  namespace: ${AIRBYTE_NS}
  labels:
    app.kubernetes.io/name: airbyte
    app.kubernetes.io/part-of: openkpi
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
    - hosts:
        - ${AIRBYTE_HOST}
      secretName: airbyte-tls
  rules:
    - host: ${AIRBYTE_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${AIRBYTE_UI_SVC}
                port:
                  number: ${AIRBYTE_UI_PORT}
YAML

  kubectl -n "${AIRBYTE_NS}" apply -f - <<YAML
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: airbyte-tls
  namespace: ${AIRBYTE_NS}
  labels:
    app.kubernetes.io/name: airbyte
    app.kubernetes.io/part-of: openkpi
spec:
  secretName: airbyte-tls
  privateKey:
    rotationPolicy: Never
  issuerRef:
    kind: ClusterIssuer
    name: ${CERT_CLUSTER_ISSUER}
  dnsNames:
    - ${AIRBYTE_HOST}
YAML

  log "[03A][AIRBYTE] wait Certificate Ready"
  kubectl -n "${AIRBYTE_NS}" wait --for=condition=Ready certificate/airbyte-tls --timeout=900s || {
    kubectl -n "${AIRBYTE_NS}" describe certificate airbyte-tls | sed -n '1,260p' || true
    kubectl -n "${AIRBYTE_NS}" get order,challenge -o wide 2>/dev/null || true
    fatal "[03A][AIRBYTE] certificate not Ready"
  }

else
  kubectl -n "${AIRBYTE_NS}" apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: airbyte
  namespace: ${AIRBYTE_NS}
  labels:
    app.kubernetes.io/name: airbyte
    app.kubernetes.io/part-of: openkpi
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
                name: ${AIRBYTE_UI_SVC}
                port:
                  number: ${AIRBYTE_UI_PORT}
YAML
fi


# ------------------------------------------------------------------------------
# 11) Readiness gate (bounded)
# ------------------------------------------------------------------------------
log "[03A][AIRBYTE] readiness gate"
for d in $(kubectl -n "${AIRBYTE_NS}" get deploy -o name 2>/dev/null); do
  kubectl -n "${AIRBYTE_NS}" rollout status "$d" --timeout=20m || true
done
for s in $(kubectl -n "${AIRBYTE_NS}" get sts -o name 2>/dev/null); do
  kubectl -n "${AIRBYTE_NS}" rollout status "$s" --timeout=20m || true
done

NOT_READY="$(kubectl -n "${AIRBYTE_NS}" get pods -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' \
  | awk '$2!="True"{print $1}' || true)"
if [[ -n "${NOT_READY}" ]]; then
  kubectl -n "${AIRBYTE_NS}" get pods -o wide || true
  kubectl -n "${AIRBYTE_NS}" get events --sort-by=.lastTimestamp | tail -n 200 || true
  fatal "[03A][AIRBYTE] Running pods not Ready: ${NOT_READY}"
fi

# ------------------------------------------------------------------------------
# 12) Tests (deterministic)
# ------------------------------------------------------------------------------
log "[03A][AIRBYTE][TEST] begin"

log "[03A][AIRBYTE][TEST][T01] helm release present + pinned chart/app versions"
ROW_JSON="$(helm -n "${AIRBYTE_NS}" list --filter '^airbyte$' -o json 2>/dev/null || true)"
echo "${ROW_JSON}" | grep -q '"name":"airbyte"' || fatal "[03A][AIRBYTE][TEST][T01] release airbyte not found"
CHART_JSON="$(printf '%s' "${ROW_JSON}" | sed -n 's/.*"chart":"\([^"]*\)".*/\1/p' | head -n1)"
APPVER_JSON="$(printf '%s' "${ROW_JSON}" | sed -n 's/.*"app_version":"\([^"]*\)".*/\1/p' | head -n1)"
[[ "${CHART_JSON}" == "airbyte-${AIRBYTE_CHART_VERSION}" ]] || fatal "[03A][AIRBYTE][TEST][T01] expected chart airbyte-${AIRBYTE_CHART_VERSION}, got: ${CHART_JSON}"
[[ "${APPVER_JSON}" == "${AIRBYTE_APP_VERSION_EXPECTED}" ]]  || fatal "[03A][AIRBYTE][TEST][T01] expected app ${AIRBYTE_APP_VERSION_EXPECTED}, got: ${APPVER_JSON}"

log "[03A][AIRBYTE][TEST][T02] in-cluster HTTP to UI service"
kubectl -n "${AIRBYTE_NS}" delete pod airbyte-curl --ignore-not-found >/dev/null 2>&1 || true
kubectl -n "${AIRBYTE_NS}" run airbyte-curl --rm -i --restart=Never \
  --image="${CURL_IMAGE}" --command -- sh -lc \
  "curl -fsS -m 10 http://${AIRBYTE_UI_SVC}.${AIRBYTE_NS}.svc.cluster.local:${AIRBYTE_UI_PORT}/ >/dev/null" \
  >/dev/null 2>&1 || fatal "[03A][AIRBYTE][TEST][T02] UI service not responding in-cluster"

log "[03A][AIRBYTE][TEST][T03] external ingress reachable (accept redirect/auth)"
retry 18 10 bash -lc "curl -k -sS -o /dev/null -m 15 -w '%{http_code}' ${URL_SCHEME}://${AIRBYTE_HOST}/ | egrep -q '^(200|302|307|308|401|403)$'" \
  || fatal "[03A][AIRBYTE][TEST][T03] ingress not reachable: ${URL_SCHEME}://${AIRBYTE_HOST}/"

log "[03A][AIRBYTE][TEST][T04] S3 region + endpoint config present"
kubectl -n "${AIRBYTE_NS}" get cm airbyte-s3-config -o jsonpath='{.data.S3_ENDPOINT}{"\n"}{.data.S3_REGION}{"\n"}' | grep -q "${MINIO_ENDPOINT}" \
  || fatal "[03A][AIRBYTE][TEST][T04] ConfigMap S3_ENDPOINT mismatch"
kubectl -n "${AIRBYTE_NS}" get cm airbyte-s3-config -o jsonpath='{.data.S3_REGION}{"\n"}' | grep -qx "${AIRBYTE_S3_REGION}" \
  || fatal "[03A][AIRBYTE][TEST][T04] ConfigMap S3_REGION mismatch"

log "[03A][AIRBYTE][TEST][T05] server/worker have exactly one AWS key pair"
DUP_S="$(kubectl -n "${AIRBYTE_NS}" get deploy airbyte-server -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}' \
  | egrep -c '^AWS_ACCESS_KEY_ID$|^AWS_SECRET_ACCESS_KEY$' || true)"
DUP_W="$(kubectl -n "${AIRBYTE_NS}" get deploy airbyte-worker -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}' \
  | egrep -c '^AWS_ACCESS_KEY_ID$|^AWS_SECRET_ACCESS_KEY$' || true)"
[[ "${DUP_S}" -eq 2 ]] || fatal "[03A][AIRBYTE][TEST][T05] server AWS_* env count expected 2, got ${DUP_S}"
[[ "${DUP_W}" -eq 2 ]] || fatal "[03A][AIRBYTE][TEST][T05] worker AWS_* env count expected 2, got ${DUP_W}"

log "[03A][AIRBYTE][TEST][T06] no MinIO/S3 auth errors in logs (403/InvalidAccessKeyId)"
if kubectl -n "${AIRBYTE_NS}" logs deploy/airbyte-server --tail=300 \
  | egrep -qi 'InvalidAccessKeyId|Access Key Id|Status Code: 403|AccessDenied|AuthorizationHeaderMalformed|InvalidRegion|S3Exception'; then
  kubectl -n "${AIRBYTE_NS}" logs deploy/airbyte-server --tail=200 | tail -n 120 || true
  fatal "[03A][AIRBYTE][TEST][T06] detected S3/MinIO auth/region errors"
fi

log "[03A][AIRBYTE][TEST][T07] MinIO bucket presence via mc"
kubectl -n "${AIRBYTE_NS}" run mc-proof --rm -i --restart=Never --image="${MC_IMAGE}" --command -- sh -lc "
  set -euo pipefail
  mc alias set openkpi '${MINIO_ENDPOINT}' '${MINIO_AK}' '${MINIO_SK}' >/dev/null
  mc ls openkpi/airbyte >/dev/null
  mc ls openkpi/airbyte-logs >/dev/null
  mc ls openkpi/airbyte-state >/dev/null
  echo OK
" >/dev/null 2>&1 || fatal "[03A][AIRBYTE][TEST][T07] mc bucket proof failed"

log "[03A][AIRBYTE][TEST] PASS"
echo "[03A][AIRBYTE] READY ${URL_SCHEME}://${AIRBYTE_HOST}/"
