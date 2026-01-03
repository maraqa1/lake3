#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 03-app-airbyte.sh — OpenKPI Module: Airbyte (Helm) — PRODUCTION / REPEATABLE
#
# Goals:
# - Install Airbyte via Helm (pinned)
# - Use INTERNAL chart Postgres (no external DB churn)
# - Use OpenKPI MinIO (external) for storage
# - If chart MinIO deploys anyway, scale it down and force Airbyte to OpenKPI MinIO
# - Deterministic ingress (HTTP or HTTPS depending on TLS_MODE)
# - Deterministic tests
#
# Requires:
# - open-kpi namespace has openkpi-minio svc + openkpi-minio-secret
# - cert-manager + ClusterIssuer exist if TLS_MODE != off
#
# Contract env (from /root/open-kpi.env via 00-env.sh):
# - INGRESS_CLASS
# - TLS_MODE: off | letsencrypt (project standard)
# - CERT_CLUSTER_ISSUER (when TLS_MODE != off)
# - AIRBYTE_HOST
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Find OpenKPI root by walking up until we see 00-env.sh
ROOT="${HERE}"
while [[ "${ROOT}" != "/" && ! -f "${ROOT}/00-env.sh" ]]; do
  ROOT="$(dirname "${ROOT}")"
done
[[ -f "${ROOT}/00-env.sh" ]] || { echo "[FATAL] cannot find 00-env.sh above ${HERE}"; exit 1; }

# shellcheck source=/dev/null
. "${ROOT}/00-env.sh"
# shellcheck source=/dev/null
. "${ROOT}/00-lib.sh"


require_cmd kubectl helm curl base64

: "${INGRESS_CLASS:?missing INGRESS_CLASS}"
: "${TLS_MODE:?missing TLS_MODE}"
: "${AIRBYTE_HOST:?missing AIRBYTE_HOST}"

# ---- module defaults (avoid unbound under set -u) ----
MINIO_NS="${MINIO_NS:-open-kpi}"                 # OpenKPI MinIO namespace
MINIO_SVC="${MINIO_SVC:-openkpi-minio}"          # OpenKPI MinIO service name
MINIO_FQDN="${MINIO_FQDN:-${MINIO_SVC}.${MINIO_NS}.svc.cluster.local}"
# External alias inside airbyte ns (avoid collision with chart airbyte-minio-svc)
MINIO_ALIAS_SVC="${MINIO_ALIAS_SVC:-airbyte-minio-external}"
MINIO_ALIAS_ENDPOINT="http://${MINIO_ALIAS_SVC}:9000"
MINIO_SECRET_NAME="${MINIO_SECRET_NAME:-openkpi-minio-secret}"  # secret in ${MINIO_NS}
MINIO_AK_KEY="${MINIO_AK_KEY:-MINIO_ROOT_USER}"
MINIO_SK_KEY="${MINIO_SK_KEY:-MINIO_ROOT_PASSWORD}"

MINIO_AK="$(kubectl -n "${MINIO_NS}" get secret "${MINIO_SECRET_NAME}" -o jsonpath="{.data.${MINIO_AK_KEY}}" | base64 -d)"
MINIO_SK="$(kubectl -n "${MINIO_NS}" get secret "${MINIO_SECRET_NAME}" -o jsonpath="{.data.${MINIO_SK_KEY}}" | base64 -d)"



# -----------------------
# Pins / Defaults
# -----------------------
AIRBYTE_NS="${AIRBYTE_NS:-airbyte}"
AIRBYTE_RELEASE="${AIRBYTE_RELEASE:-airbyte}"
AIRBYTE_REPO_URL="${AIRBYTE_REPO_URL:-https://airbytehq.github.io/helm-charts}"
AIRBYTE_CHART="${AIRBYTE_CHART:-airbyte/airbyte}"
AIRBYTE_CHART_VERSION="${AIRBYTE_CHART_VERSION:-1.9.1}"

# OpenKPI MinIO
OPENKPI_NS="${OPENKPI_NS:-open-kpi}"
OPENKPI_MINIO_SVC="${OPENKPI_MINIO_SVC:-openkpi-minio}"
OPENKPI_MINIO_SECRET="${OPENKPI_MINIO_SECRET:-openkpi-minio-secret}"
AIRBYTE_S3_REGION="${AIRBYTE_S3_REGION:-us-east-1}"


# UI service (stable in this chart line)



# TLS
TLS_ENABLED="false"
URL_SCHEME="http"
if [[ "${TLS_MODE}" != "off" ]]; then
  TLS_ENABLED="true"
  URL_SCHEME="https"
  : "${CERT_CLUSTER_ISSUER:?missing CERT_CLUSTER_ISSUER (TLS_MODE != off)}"
fi

log "[03-airbyte] start (ns=${AIRBYTE_NS} host=${AIRBYTE_HOST} tls=${TLS_MODE} chart=${AIRBYTE_CHART_VERSION})"

# -----------------------
# 0) Namespace + prereqs
# -----------------------
ensure_ns "${AIRBYTE_NS}"

kubectl -n "${OPENKPI_NS}" get svc "${OPENKPI_MINIO_SVC}" >/dev/null 2>&1 \
  || fatal "[03-airbyte] missing svc ${OPENKPI_NS}/${OPENKPI_MINIO_SVC} (run 02-data-plane.sh)"

kubectl -n "${OPENKPI_NS}" get secret "${OPENKPI_MINIO_SECRET}" >/dev/null 2>&1 \
  || fatal "[03-airbyte] missing secret ${OPENKPI_NS}/${OPENKPI_MINIO_SECRET}"

MINIO_AK="$(kubectl -n "${OPENKPI_NS}" get secret "${OPENKPI_MINIO_SECRET}" -o jsonpath='{.data.MINIO_ROOT_USER}' | base64 -d)"
MINIO_SK="$(kubectl -n "${OPENKPI_NS}" get secret "${OPENKPI_MINIO_SECRET}" -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d)"



# -----------------------
# PRE-HELM: clear helm lock (pending install/upgrade/rollback)
# -----------------------
log "[03-airbyte] pre-helm: clear pending helm operation (if any)"

# kill any stuck helm client process on the node (safe no-op if none)
pkill -f "helm .* -n ${AIRBYTE_NS} .*${AIRBYTE_RELEASE}" >/dev/null 2>&1 || true

# if release is pending, rollback to last good revision (or uninstall if no history)
if helm -n "${AIRBYTE_NS}" status "${AIRBYTE_RELEASE}" >/dev/null 2>&1; then
  st="$(helm -n "${AIRBYTE_NS}" status "${AIRBYTE_RELEASE}" -o json 2>/dev/null | jq -r '.info.status' 2>/dev/null || true)"
  if [[ "${st}" =~ ^pending ]]; then
    rev="$(helm -n "${AIRBYTE_NS}" history "${AIRBYTE_RELEASE}" --max 20 2>/dev/null | awk 'NR>1 {print $1}' | tail -n 1 || true)"
    if [[ -n "${rev}" ]]; then
      log "[03-airbyte] helm status=${st}; rollback to revision ${rev}"
      helm -n "${AIRBYTE_NS}" rollback "${AIRBYTE_RELEASE}" "${rev}" --wait --timeout 20m >/dev/null 2>&1 || true
    else
      log "[03-airbyte] helm status=${st}; no history -> uninstall"
      helm -n "${AIRBYTE_NS}" uninstall "${AIRBYTE_RELEASE}" >/dev/null 2>&1 || true
    fi
  fi
fi

# final safety: delete any leftover helm secret locks (only for this release)
kubectl -n "${AIRBYTE_NS}" delete secret -l "owner=helm,name=${AIRBYTE_RELEASE}" --ignore-not-found >/dev/null 2>&1 || true


# -----------------------
# 1) Ensure ExternalName alias to OpenKPI MinIO
# -----------------------
log "[03-airbyte] ensure MinIO alias service: ${AIRBYTE_NS}/${MINIO_ALIAS_SVC} -> ${OPENKPI_MINIO_SVC}.${OPENKPI_NS}.svc.cluster.local"
kubectl -n "${AIRBYTE_NS}" apply -f - <<YAML
apiVersion: v1
kind: Service
metadata:
  name: ${MINIO_ALIAS_SVC}
spec:
  type: ExternalName
  externalName: ${OPENKPI_MINIO_SVC}.${OPENKPI_NS}.svc.cluster.local
YAML

# -----------------------
# 2) Helm install (internal Postgres, attempt to disable chart MinIO)
#    IMPORTANT: do NOT inject AWS_* env via values (avoids $setElementOrder failures)
# -----------------------
helm repo add airbyte "${AIRBYTE_REPO_URL}" >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1 || true

VALUES_FILE="${HERE}/.values-airbyte.prod.yaml"
cat > "${VALUES_FILE}" <<YAML
global:
  deploymentMode: oss

# internal DB ON
postgresql:
  enabled: true

# try both disable styles (chart variants)
minio:
  enabled: false
globalMinio:
  enabled: false

webapp:
  ingress:
    enabled: false
YAML

log "[03-airbyte] helm upgrade --install ${AIRBYTE_CHART} --version ${AIRBYTE_CHART_VERSION}"
helm -n "${AIRBYTE_NS}" upgrade --install "${AIRBYTE_RELEASE}" "${AIRBYTE_CHART}" \
  --version "${AIRBYTE_CHART_VERSION}" \
  -f "${VALUES_FILE}" \
  --wait --timeout 25m

# -----------------------
# 3) Force storage wiring (idempotent, single source)
#    - Create alias svc -> OpenKPI MinIO
#    - Patch chart env+secrets using keys the chart consumes
#    - Scale chart MinIO down
#    - Restart + assert
# -----------------------

# 3A) Alias service (repeatable)
MINIO_ALIAS_SVC="${MINIO_ALIAS_SVC:-airbyte-minio-external}"
MINIO_ALIAS_ENDPOINT="http://${MINIO_ALIAS_SVC}:9000"

log "[03-airbyte] ensure MinIO alias service: ${AIRBYTE_NS}/${MINIO_ALIAS_SVC} -> openkpi-minio.open-kpi.svc.cluster.local"
kubectl -n "${AIRBYTE_NS}" apply -f - <<YAML
apiVersion: v1
kind: Service
metadata:
  name: ${MINIO_ALIAS_SVC}
spec:
  type: ExternalName
  externalName: openkpi-minio.open-kpi.svc.cluster.local
YAML

# 3B) Read OpenKPI MinIO creds (source of truth)
MINIO_AK="$(kubectl -n "${MINIO_NS}" get secret "${MINIO_SECRET_NAME}" -o jsonpath='{.data.MINIO_ROOT_USER}' | base64 -d)"
MINIO_SK="$(kubectl -n "${MINIO_NS}" get secret "${MINIO_SECRET_NAME}" -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d)"

# 3C) Patch chart env ConfigMap to alias endpoint (keys the chart uses)
log "[03-airbyte] patch configmap airbyte-airbyte-env -> endpoint=${MINIO_ALIAS_ENDPOINT}"
kubectl -n "${AIRBYTE_NS}" get configmap airbyte-airbyte-env >/dev/null 2>&1 || fatal "[03-airbyte] missing configmap airbyte-airbyte-env"
kubectl -n "${AIRBYTE_NS}" patch configmap airbyte-airbyte-env --type=merge -p "{
  \"data\":{
    \"MINIO_ENDPOINT\":\"${MINIO_ALIAS_ENDPOINT}\",
    \"S3_ENDPOINT\":\"${MINIO_ALIAS_ENDPOINT}\",
    \"S3_PATH_STYLE_ACCESS\":\"true\",
    \"S3_REGION\":\"${AIRBYTE_S3_REGION}\"
  }
}" >/dev/null

# 3D) Patch chart secret with the keys the chart reads
# IMPORTANT: Airbyte chart commonly reads MINIO_ACCESS_KEY_ID / MINIO_SECRET_ACCESS_KEY
log "[03-airbyte] patch secret airbyte-airbyte-secrets -> MINIO_ACCESS_KEY_ID/MINIO_SECRET_ACCESS_KEY"
kubectl -n "${AIRBYTE_NS}" get secret airbyte-airbyte-secrets >/dev/null 2>&1 || fatal "[03-airbyte] missing secret airbyte-airbyte-secrets"
kubectl -n "${AIRBYTE_NS}" patch secret airbyte-airbyte-secrets --type=merge -p "{
  \"data\":{
    \"MINIO_ACCESS_KEY_ID\":\"$(printf '%s' "${MINIO_AK}" | base64 -w0)\",
    \"MINIO_SECRET_ACCESS_KEY\":\"$(printf '%s' "${MINIO_SK}" | base64 -w0)\"
  }
}" >/dev/null

# 3E) Disable chart MinIO runtime (do NOT delete PVCs)
if kubectl -n "${AIRBYTE_NS}" get sts airbyte-minio >/dev/null 2>&1; then
  log "[03-airbyte] chart MinIO detected. scale sts/airbyte-minio -> 0"
  kubectl -n "${AIRBYTE_NS}" scale sts/airbyte-minio --replicas=0 >/dev/null 2>&1 || true
fi

# 3F) Restart to reload ConfigMap/Secret
log "[03-airbyte] rollout restart (server/worker/workload/cron/builder)"
kubectl -n "${AIRBYTE_NS}" rollout restart \
  deploy/airbyte-server \
  deploy/airbyte-worker \
  deploy/airbyte-workload-api-server \
  deploy/airbyte-workload-launcher \
  deploy/airbyte-cron \
  deploy/airbyte-connector-builder-server >/dev/null 2>&1 || true

kubectl -n "${AIRBYTE_NS}" rollout status deploy/airbyte-server --timeout=20m
kubectl -n "${AIRBYTE_NS}" rollout status deploy/airbyte-worker --timeout=20m || true
kubectl -n "${AIRBYTE_NS}" rollout status deploy/airbyte-workload-api-server --timeout=20m || true
kubectl -n "${AIRBYTE_NS}" rollout status deploy/airbyte-workload-launcher --timeout=20m || true

# 3G) Hard assert: env points to alias endpoint (prevents silent drift)
got="$(kubectl -n "${AIRBYTE_NS}" get cm airbyte-airbyte-env -o jsonpath='{.data.MINIO_ENDPOINT}' 2>/dev/null || true)"
[[ "${got}" == "${MINIO_ALIAS_ENDPOINT}" ]] || fatal "[03-airbyte] MINIO_ENDPOINT drift: expected ${MINIO_ALIAS_ENDPOINT}, got ${got}"


# -----------------------
# 4) If chart MinIO still exists, scale it down (do not delete PVCs)
# -----------------------
if kubectl -n "${AIRBYTE_NS}" get sts airbyte-minio >/dev/null 2>&1; then
  log "[03-airbyte] chart MinIO detected (sts/airbyte-minio). scaling to 0 to enforce OpenKPI MinIO"
  kubectl -n "${AIRBYTE_NS}" scale sts/airbyte-minio --replicas=0 >/dev/null 2>&1 || true
fi

# -----------------------
# 5) Restart Airbyte components to reload patched secret/configmap
# -----------------------
log "[03-airbyte] rollout restart (server/worker/workload/cron/builder)"
kubectl -n "${AIRBYTE_NS}" rollout restart deploy/airbyte-server deploy/airbyte-worker \
  deploy/airbyte-workload-api-server deploy/airbyte-workload-launcher \
  deploy/airbyte-cron deploy/airbyte-connector-builder-server >/dev/null 2>&1 || true

kubectl -n "${AIRBYTE_NS}" rollout status deploy/airbyte-server --timeout=20m
kubectl -n "${AIRBYTE_NS}" rollout status deploy/airbyte-worker --timeout=20m
kubectl -n "${AIRBYTE_NS}" rollout status deploy/airbyte-workload-api-server --timeout=20m
kubectl -n "${AIRBYTE_NS}" rollout status deploy/airbyte-workload-launcher --timeout=20m


# ------------------------------------------------------------------
# Resolve UI service for ingress (chart variants differ)
# Prefer webapp service if present; else fall back to server service.
# ------------------------------------------------------------------
AIRBYTE_UI_SVC=""
AIRBYTE_UI_PORT=""

if kubectl -n "${AIRBYTE_NS}" get svc airbyte-airbyte-webapp-svc >/dev/null 2>&1; then
  AIRBYTE_UI_SVC="airbyte-airbyte-webapp-svc"
  AIRBYTE_UI_PORT="80"
elif kubectl -n "${AIRBYTE_NS}" get svc airbyte-webapp-svc >/dev/null 2>&1; then
  AIRBYTE_UI_SVC="airbyte-webapp-svc"
  AIRBYTE_UI_PORT="80"
elif kubectl -n "${AIRBYTE_NS}" get svc airbyte-airbyte-server-svc >/dev/null 2>&1; then
  AIRBYTE_UI_SVC="airbyte-airbyte-server-svc"
  AIRBYTE_UI_PORT="8001"
elif kubectl -n "${AIRBYTE_NS}" get svc airbyte-server-svc >/dev/null 2>&1; then
  AIRBYTE_UI_SVC="airbyte-server-svc"
  AIRBYTE_UI_PORT="8001"
else
  kubectl -n "${AIRBYTE_NS}" get svc -o wide || true
  fatal "[03-airbyte] cannot resolve UI service (no webapp or server svc found)"
fi

log "[03-airbyte] UI service resolved: ${AIRBYTE_UI_SVC}:${AIRBYTE_UI_PORT}"


# -----------------------
# 6) Ingress (+ Certificate if TLS)
# -----------------------

# Resolve UI service for ingress (chart variants differ)
AIRBYTE_UI_SVC=""
AIRBYTE_UI_PORT=""

if kubectl -n "${AIRBYTE_NS}" get svc airbyte-airbyte-webapp-svc >/dev/null 2>&1; then
  AIRBYTE_UI_SVC="airbyte-airbyte-webapp-svc"
  AIRBYTE_UI_PORT="80"
elif kubectl -n "${AIRBYTE_NS}" get svc airbyte-webapp-svc >/dev/null 2>&1; then
  AIRBYTE_UI_SVC="airbyte-webapp-svc"
  AIRBYTE_UI_PORT="80"
elif kubectl -n "${AIRBYTE_NS}" get svc airbyte-airbyte-server-svc >/dev/null 2>&1; then
  AIRBYTE_UI_SVC="airbyte-airbyte-server-svc"
  AIRBYTE_UI_PORT="8001"
elif kubectl -n "${AIRBYTE_NS}" get svc airbyte-server-svc >/dev/null 2>&1; then
  AIRBYTE_UI_SVC="airbyte-server-svc"
  AIRBYTE_UI_PORT="8001"
else
  kubectl -n "${AIRBYTE_NS}" get svc -o wide || true
  fatal "[03-airbyte] cannot resolve UI service (no webapp or server svc found)"
fi

log "[03-airbyte] apply ingress host=${AIRBYTE_HOST} -> ${AIRBYTE_UI_SVC}:${AIRBYTE_UI_PORT}"

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
                name: ${AIRBYTE_UI_SVC}
                port:
                  number: ${AIRBYTE_UI_PORT}
---
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
    name: ${CERT_CLUSTER_ISSUER}
  dnsNames:
    - ${AIRBYTE_HOST}
YAML

  log "[03-airbyte] wait certificate Ready"
  retry 90 10 bash -lc "kubectl -n '${AIRBYTE_NS}' get certificate airbyte-cert -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True" || {
    kubectl -n "${AIRBYTE_NS}" describe certificate airbyte-cert | sed -n '1,220p' || true
    kubectl -n "${AIRBYTE_NS}" get order,challenge -o wide 2>/dev/null || true
    fatal "[03-airbyte] certificate not Ready"
  }
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
                name: ${AIRBYTE_UI_SVC}
                port:
                  number: ${AIRBYTE_UI_PORT}
YAML
fi


# -----------------------
# 7) Deterministic tests
# -----------------------
log "[03-airbyte][TEST] T01: core deployments exist"
kubectl -n "${AIRBYTE_NS}" get deploy airbyte-server airbyte-worker airbyte-workload-api-server airbyte-workload-launcher >/dev/null

log "[03-airbyte][TEST] T02: config points to OpenKPI MinIO alias"
kubectl -n "${AIRBYTE_NS}" get cm airbyte-airbyte-env -o jsonpath='{.data.MINIO_ENDPOINT}{"\n"}' | grep -q "${MINIO_ALIAS_SVC}" \
  || fatal "[03-airbyte][TEST] MINIO_ENDPOINT not pointing to ${MINIO_ALIAS_SVC}"

log "[03-airbyte][TEST] T03: chart MinIO (if present) is scaled down"
if kubectl -n "${AIRBYTE_NS}" get sts airbyte-minio >/dev/null 2>&1; then
  REPL="$(kubectl -n "${AIRBYTE_NS}" get sts airbyte-minio -o jsonpath='{.spec.replicas}')"
  [[ "${REPL}" == "0" ]] || fatal "[03-airbyte][TEST] sts/airbyte-minio replicas=${REPL} (expected 0)"
fi

log "[03-airbyte][TEST] T04: ingress reachable"

URL="${URL_SCHEME}://${AIRBYTE_HOST}/"

retry 18 10 bash -lc '
  set -euo pipefail
  url="'"${URL}"'"

  code="$(curl -k -sS -L -o /dev/null -m 20 -w "%{http_code}" "$url" || true)"
  echo "$code" | egrep -q "^(200|302|307|308|401|403)$" && exit 0

  host="'"${AIRBYTE_HOST}"'"
  ns="'"${AIRBYTE_NS}"'"

  kubectl -n "$ns" get ingress airbyte -o wide 2>/dev/null || true
  kubectl -n "$ns" get svc -o wide 2>/dev/null | egrep -i "webapp|server|airbyte" || true
  kubectl -n "$ns" get endpoints -o wide 2>/dev/null | egrep -i "webapp|server|airbyte" || true

  exit 1
' || fatal "[03-airbyte][TEST] ingress not reachable: ${URL}"

log "[03-airbyte] READY ${URL}"
# ==============================================================================
# SECTION 08 — Portal Integration Contract (Airbyte -> Portal API)
# ==============================================================================

PORTAL_NS="${PORTAL_NS:-portal}"
PORTAL_API_SA="${PORTAL_API_SA:-portal-api}"
PORTAL_AIRBYTE_CM="${PORTAL_AIRBYTE_CM:-portal-airbyte}"

AIRBYTE_PORTAL_SVC="${AIRBYTE_PORTAL_SVC:-airbyte-portal-api}"
AIRBYTE_PORTAL_PORT="${AIRBYTE_PORTAL_PORT:-8001}"

AIRBYTE_UI_EXTERNAL="${AIRBYTE_UI_EXTERNAL:-${URL_SCHEME}://${AIRBYTE_HOST}/}"

log "[03-airbyte][portal] resolve Airbyte API deployment selector"

kubectl -n "${AIRBYTE_NS}" get deploy airbyte-server >/dev/null 2>&1 || fatal "[03-airbyte][portal] airbyte-server deployment missing"

SEL_YAML="$(kubectl -n "${AIRBYTE_NS}" get deploy airbyte-server -o go-template='{{range $k,$v := .spec.selector.matchLabels}}{{printf "    %s: %s\n" $k $v}}{{end}}')"
[[ -n "${SEL_YAML}" ]] || fatal "[03-airbyte][portal] failed to derive selector labels"

log "[03-airbyte][portal] ensure stable service ${AIRBYTE_PORTAL_SVC}"

kubectl -n "${AIRBYTE_NS}" apply -f - <<YAML
apiVersion: v1
kind: Service
metadata:
  name: ${AIRBYTE_PORTAL_SVC}
spec:
  type: ClusterIP
  selector:
${SEL_YAML}
  ports:
    - name: http
      port: ${AIRBYTE_PORTAL_PORT}
      targetPort: ${AIRBYTE_PORTAL_PORT}
YAML

AIRBYTE_API_BASE_CLUSTER="http://${AIRBYTE_PORTAL_SVC}.${AIRBYTE_NS}.svc.cluster.local:${AIRBYTE_PORTAL_PORT}"

ensure_ns "${PORTAL_NS}"

log "[03-airbyte][portal] publish portal contract configmap"

kubectl -n "${PORTAL_NS}" apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${PORTAL_AIRBYTE_CM}
data:
  AIRBYTE_NAMESPACE: "${AIRBYTE_NS}"
  AIRBYTE_RELEASE: "${AIRBYTE_RELEASE}"
  AIRBYTE_API_BASE: "${AIRBYTE_API_BASE_CLUSTER}"
  AIRBYTE_UI_BASE: "${AIRBYTE_UI_EXTERNAL}"
  AIRBYTE_STORAGE_ENDPOINT: "${MINIO_ALIAS_ENDPOINT}"
  AIRBYTE_S3_REGION: "${AIRBYTE_S3_REGION}"
YAML

kubectl -n "${PORTAL_NS}" get sa "${PORTAL_API_SA}" >/dev/null 2>&1 || kubectl -n "${PORTAL_NS}" create sa "${PORTAL_API_SA}" >/dev/null

log "[03-airbyte][portal] apply RBAC for portal api"

kubectl -n "${AIRBYTE_NS}" apply -f - <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: portal-airbyte-read
rules:
  - apiGroups: [""]
    resources: ["pods","services","endpoints","events"]
    verbs: ["get","list","watch"]
  - apiGroups: ["apps"]
    resources: ["deployments","replicasets","statefulsets"]
    verbs: ["get","list","watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: portal-airbyte-read
subjects:
  - kind: ServiceAccount
    name: ${PORTAL_API_SA}
    namespace: ${PORTAL_NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: portal-airbyte-read
YAML

log "[03-airbyte][portal][TEST] stable service present"
kubectl -n "${AIRBYTE_NS}" get svc "${AIRBYTE_PORTAL_SVC}" >/dev/null

log "[03-airbyte][portal][TEST] portal configmap present"
kubectl -n "${PORTAL_NS}" get cm "${PORTAL_AIRBYTE_CM}" >/dev/null

log "[03-airbyte][portal][TEST] Airbyte health endpoint reachable"
kubectl -n "${AIRBYTE_NS}" run airbyte-portal-healthcheck \
  --image=curlimages/curl:8.5.0 \
  --restart=Never --rm -i --quiet \
  --command -- sh -lc "curl -fsS --max-time 10 '${AIRBYTE_API_BASE_CLUSTER}/api/v1/health' >/dev/null"

log "[03-airbyte][portal] READY"
