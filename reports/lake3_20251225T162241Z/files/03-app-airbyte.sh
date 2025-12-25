#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# MODULE 03A — APP: AIRBYTE (Helm)
# FILE: 03-app-airbyte.sh
#
# Production + repeatable + GitHub-safe:
# - Idempotent Helm install/upgrade
# - Sync shared MinIO secret into airbyte namespace (no jq required)
# - Configure S3 env via ConfigMap + secretKeyRefs
# - Disable chart ingress; create deterministic Ingress "airbyte"
# - Enforce Ingress-only exposure (convert NodePort -> ClusterIP automatically)
# - Deterministic readiness gate: waits on deployments + sts + pod readiness,
#   and prints targeted diagnostics (pods/events/logs) before failing.
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE}/00-env.sh"
. "${HERE}/00-lib.sh"

: "${KUBECONFIG:=/root/.kube/config}"
export KUBECONFIG

: "${URL_SCHEME:=http}"
: "${INGRESS_CLASS:?missing INGRESS_CLASS}"
: "${TLS_MODE:?missing TLS_MODE}"
: "${AIRBYTE_HOST:?missing AIRBYTE_HOST}"

require_cmd kubectl
require_cmd helm

log "[03A][AIRBYTE] Start"

ensure_ns "airbyte"

helm repo add airbyte https://airbytehq.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

# ------------------------------------------------------------------------------
# Shared MinIO secret sync (repeatable, namespace-scoped)
# ------------------------------------------------------------------------------
MINIO_ENDPOINT="http://openkpi-minio.open-kpi.svc.cluster.local:9000"
MINIO_SECRET_NS="open-kpi"
MINIO_SECRET_NAME="openkpi-minio-secret"
MINIO_ACCESS_KEY_KEY="MINIO_ROOT_USER"
MINIO_SECRET_KEY_KEY="MINIO_ROOT_PASSWORD"

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

sync_secret_yaml_ns "${MINIO_SECRET_NS}" "${MINIO_SECRET_NAME}" "airbyte"
kubectl -n airbyte get secret "${MINIO_SECRET_NAME}" >/dev/null

# ------------------------------------------------------------------------------
# ConfigMap for S3 endpoint settings (repeatable)
# ------------------------------------------------------------------------------
kubectl -n airbyte apply -f - <<YAML
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

# TLS toggle
TLS_ENABLED="false"
if [[ "${TLS_MODE}" == "per-host-http01" ]]; then
  TLS_ENABLED="true"
fi

# ------------------------------------------------------------------------------
# Helm values (disable chart ingress; we own ingress deterministically)
# ------------------------------------------------------------------------------
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

log "[03A][AIRBYTE] Helm upgrade --install"
helm upgrade --install airbyte airbyte/airbyte \
  -n airbyte \
  -f "${VALUES_FILE}" \
  --wait \
  --timeout 20m

# ------------------------------------------------------------------------------
# Enforce Ingress-only exposure (auto-fix NodePorts)
# ------------------------------------------------------------------------------
log "[03A][AIRBYTE] Enforce Ingress-only services (no NodePort)"
NODEPORT_SVCS="$(kubectl -n airbyte get svc --no-headers 2>/dev/null | awk '$3=="NodePort"{print $1}' || true)"
if [[ -n "${NODEPORT_SVCS}" ]]; then
  warn "[03A][AIRBYTE] NodePort services detected; converting to ClusterIP: ${NODEPORT_SVCS}"
  for s in ${NODEPORT_SVCS}; do
    kubectl -n airbyte patch svc "$s" --type=merge -p '{"spec":{"type":"ClusterIP","externalTrafficPolicy":null}}' >/dev/null 2>&1 || true
  done
fi
if kubectl -n airbyte get svc --no-headers 2>/dev/null | awk '$3=="NodePort"{exit 1}'; then
  :
else
  kubectl -n airbyte get svc -o wide || true
  fatal "NodePort service detected in airbyte namespace after remediation"
fi

# ------------------------------------------------------------------------------
# Deterministic ingress owned by this module
#   Discover the webapp service (chart versions vary)
# ------------------------------------------------------------------------------
SVC_NAME="$(kubectl -n airbyte get svc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
  | awk '/webapp/{print; exit}')"
if [[ -z "${SVC_NAME}" ]]; then
  # fallback: service that exposes port 80
  SVC_NAME="$(kubectl -n airbyte get svc -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.ports[*]}{.port}{" "}{end}{"\n"}{end}' \
    | awk '$2 ~ /(^| )80( |$)/ {print $1; exit}')"
fi
[[ -n "${SVC_NAME}" ]] || { kubectl -n airbyte get svc -o wide || true; fatal "Cannot determine Airbyte webapp service"; }

SVC_PORT="$(kubectl -n airbyte get svc "${SVC_NAME}" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
[[ -n "${SVC_PORT}" ]] || fatal "Cannot determine port for service airbyte/${SVC_NAME}"

log "[03A][AIRBYTE] Apply deterministic Ingress (airbyte) -> svc ${SVC_NAME}:${SVC_PORT}"
if [[ "${TLS_ENABLED}" == "true" ]]; then
  kubectl -n airbyte apply -f - <<YAML
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
                name: ${SVC_NAME}
                port:
                  number: ${SVC_PORT}
YAML
else
  kubectl -n airbyte apply -f - <<YAML
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
                name: ${SVC_NAME}
                port:
                  number: ${SVC_PORT}
YAML
fi

# ------------------------------------------------------------------------------
# Readiness gating with deterministic diagnostics
# ------------------------------------------------------------------------------
# REPLACE your readiness gate block with this (it is repeatable and ignores Completed/Succeeded pods)

log "[03A][AIRBYTE] Readiness gate (deployments/statefulsets/pods)"

# Rollouts (best-effort; pod readiness is authoritative)
for d in $(kubectl -n airbyte get deploy -o name 2>/dev/null); do
  kubectl -n airbyte rollout status "$d" --timeout=15m || true
done
for s in $(kubectl -n airbyte get sts -o name 2>/dev/null); do
  kubectl -n airbyte rollout status "$s" --timeout=15m || true
done


# Authoritative: only Running pods must be Ready=True
NOT_READY="$(kubectl -n airbyte get pods -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' \
  | awk '$2!="True"{print $1}' || true)"

if [[ -n "${NOT_READY}" ]]; then
  warn "[03A][AIRBYTE] Running pods not Ready: ${NOT_READY}"
  kubectl -n airbyte get pods -o wide || true
  kubectl -n airbyte get deploy,sts -o wide || true

  # Only show recent readiness-related events (avoid historical noise)
  kubectl -n airbyte get events --sort-by=.lastTimestamp \
    | egrep -i 'Unhealthy|BackOff|Failed|Readiness|Liveness|probe' \
    | tail -n 200 || true

  # Describe + logs (bounded)
  c=0
  for p in ${NOT_READY}; do
    c=$((c+1))
    kubectl -n airbyte describe pod "$p" | sed -n '1,240p' || true
    kubectl -n airbyte logs "$p" --all-containers --tail=250 || true
    [[ $c -ge 3 ]] && break
  done

  # One deterministic remediation: restart core deployments once
  warn "[03A][AIRBYTE] Remediation: rollout restart core deployments"
  kubectl -n airbyte rollout restart \
    deploy/airbyte-server deploy/airbyte-worker deploy/airbyte-workload-launcher >/dev/null 2>&1 || true

  kubectl -n airbyte rollout status deploy/airbyte-server --timeout=10m || true
  kubectl -n airbyte rollout status deploy/airbyte-worker --timeout=10m || true
  kubectl -n airbyte rollout status deploy/airbyte-workload-launcher --timeout=10m || true

  NOT_READY2="$(kubectl -n airbyte get pods -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' \
    | awk '$2!="True"{print $1}' || true)"

  if [[ -n "${NOT_READY2}" ]]; then
    kubectl -n airbyte get pods -o wide || true
    kubectl -n airbyte get events --sort-by=.lastTimestamp \
      | egrep -i 'Unhealthy|BackOff|Failed|Readiness|Liveness|probe' \
      | tail -n 200 || true
    fatal "Airbyte pods not ready"
  fi
fi


echo "[03A][AIRBYTE] READY ${URL_SCHEME}://${AIRBYTE_HOST}/"
