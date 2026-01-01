#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 02-minio.sh — MinIO (production, contract-compliant, drop-in, idempotent)
#
# Location:
#   OpenKPI/modules/02-data-plane/02-minio.sh
#
# Contract source:
#   /root/open-kpi.env (loaded by ../../00-env.sh)
#
# Contract keys used (minimum):
#   OPENKPI_NS, STORAGE_CLASS, INGRESS_CLASS
#   TLS_MODE=off|letsencrypt
#   TLS_STRATEGY=wildcard|per-app              (required when TLS_MODE!=off)
#   TLS_SECRET_NAME                            (required when TLS_STRATEGY=wildcard)
#   CERT_CLUSTER_ISSUER                        (required when TLS_MODE=letsencrypt and TLS_STRATEGY=per-app)
#   MINIO_EXPOSE=on|off
#   MINIO_HOST                                 (external DNS host, e.g. minio.lake4.opendatalake.com)
#   MINIO_ROOT_USER, MINIO_ROOT_PASSWORD
#   MINIO_ENDPOINT_INTERNAL                    (e.g. http://openkpi-minio.open-kpi.svc.cluster.local:9000)
#   MINIO_REGION
#
# Optional:
#   MINIO_IMAGE, MINIO_STORAGE_SIZE
#   MINIO_TLS_SECRET, MINIO_CERT_NAME, MINIO_INGRESS_NAME
#   MINIO_MC_IMAGE
#   MINIO_BUCKETS (comma-separated)            default: airbyte,airbyte-state,airbyte-storage
#
# Guarantees:
# - Permanent fix for k3s local-path hostPath perms (no manual node commands)
# - StatefulSet enforces writable backend (hostPath fix Job + init chmod/chown + verify-writable)
# - Ingress routes /console -> 9001, / -> 9000 (contract-driven)
# - Bucket bootstrap via mc pod (image tag contract-driven, pull-checked)
# - Tests: rollout, in-cluster readiness, ingress/TLS contract checks
# ==============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/../../00-env.sh"

log "[02-minio] start"

require_cmd kubectl
require_var OPENKPI_NS
require_var STORAGE_CLASS
require_var INGRESS_CLASS

require_var MINIO_EXPOSE
require_var MINIO_HOST
require_var MINIO_ROOT_USER
require_var MINIO_ROOT_PASSWORD
require_var MINIO_ENDPOINT_INTERNAL
require_var MINIO_REGION

if tls_enabled; then
  require_var TLS_STRATEGY
  if [[ "${TLS_STRATEGY}" == "wildcard" ]]; then
    require_var TLS_SECRET_NAME
  else
    require_var CERT_CLUSTER_ISSUER
  fi
fi

NS="${OPENKPI_NS}"

MINIO_SECRET="openkpi-minio-secret"
MINIO_PVC="openkpi-minio-pvc"
MINIO_SVC="openkpi-minio"
MINIO_SVC_CONSOLE="openkpi-minio-console"
MINIO_STS="openkpi-minio"

MINIO_INGRESS_NAME="${MINIO_INGRESS_NAME:-minio-ingress}"
MINIO_TLS_SECRET="${MINIO_TLS_SECRET:-minio-tls}"
MINIO_CERT_NAME="${MINIO_CERT_NAME:-minio-cert}"

MINIO_IMAGE="${MINIO_IMAGE:-minio/minio:RELEASE.2025-07-23T15-54-02Z}"
MINIO_STORAGE_SIZE="${MINIO_STORAGE_SIZE:-50Gi}"

MINIO_MC_IMAGE="${MINIO_MC_IMAGE:-minio/mc:RELEASE.2024-11-05T11-29-45Z}"

MINIO_BUCKETS="${MINIO_BUCKETS:-airbyte,airbyte-state,airbyte-storage}"

kubectl_k get ns "${NS}" >/dev/null 2>&1 || kubectl_k create ns "${NS}" >/dev/null

SCHEME="http"
tls_enabled && SCHEME="https"

# Enforce contract: external host comes from MINIO_HOST only (no derivation).
HOST_MINIO="${MINIO_HOST}"
# ------------------------------------------------------------------------------
# Public URL contract for MinIO runtime env
# - If exposed, advertise the ingress host (users hit this host)
# - If not exposed, keep MINIO_HOST (internal / non-ingress use)
# ------------------------------------------------------------------------------
PUBLIC_MINIO_HOST="${MINIO_HOST}"
if [[ "${MINIO_EXPOSE}" == "on" ]]; then
  PUBLIC_MINIO_HOST="minio.${APP_DOMAIN}"
fi

MINIO_SERVER_URL="${SCHEME}://${PUBLIC_MINIO_HOST}"
MINIO_BROWSER_REDIRECT_URL="${SCHEME}://${PUBLIC_MINIO_HOST}/console"



# ------------------------------------------------------------------------------
# Secret
# ------------------------------------------------------------------------------
cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${MINIO_SECRET}
type: Opaque
stringData:
  MINIO_ROOT_USER: "${MINIO_ROOT_USER}"
  MINIO_ROOT_PASSWORD: "${MINIO_ROOT_PASSWORD}"
YAML

# ------------------------------------------------------------------------------
# PVC
# ------------------------------------------------------------------------------
cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${MINIO_PVC}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: ${MINIO_STORAGE_SIZE}
YAML

# ------------------------------------------------------------------------------
# Permanent: auto-fix k3s local-path hostPath perms for this PVC (no manual steps)
# Uses a Job (wait for Complete) so the fix is guaranteed before MinIO starts.
# ------------------------------------------------------------------------------
log "[02-minio] hostPath perms: ensure writable backend for ${MINIO_PVC}"

PV_NAME="$(kubectl_k -n "${NS}" get pvc "${MINIO_PVC}" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
if [[ -n "${PV_NAME}" ]]; then
  HP_PATH="$(kubectl_k get pv "${PV_NAME}" -o jsonpath='{.spec.hostPath.path}' 2>/dev/null || true)"
  if [[ -n "${HP_PATH}" ]]; then
    kubectl_k -n "${NS}" delete job minio-hostpath-fix --ignore-not-found >/dev/null 2>&1 || true

    cat <<YAML | kubectl_k -n "${NS}" apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-hostpath-fix
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      hostPID: true
      containers:
      - name: fix
        image: busybox:1.36
        securityContext:
          privileged: true
          runAsUser: 0
        command: ["sh","-c"]
        args:
        - |
          set -e
          TARGET="/host${HP_PATH}"
          echo "Fixing hostPath: ${HP_PATH}"
          mkdir -p "${TARGET}"
          chown -R 1000:1000 "${TARGET}"
          chmod -R ug+rwX "${TARGET}"
          echo "write test as uid=1000"
          su -s /bin/sh -c "touch '${TARGET}/.openkpi_write_test' && rm -f '${TARGET}/.openkpi_write_test'" 1000
          echo OK
        volumeMounts:
        - name: host
          mountPath: /host
      volumes:
      - name: host
        hostPath:
          path: /
YAML

    kubectl_k -n "${NS}" wait --for=condition=complete job/minio-hostpath-fix --timeout=180s \
      || { kubectl_k -n "${NS}" describe job/minio-hostpath-fix || true; kubectl_k -n "${NS}" logs job/minio-hostpath-fix --tail=200 || true; die "hostPath fix job failed"; }

    kubectl_k -n "${NS}" logs job/minio-hostpath-fix --tail=200 || true
    kubectl_k -n "${NS}" delete job minio-hostpath-fix >/dev/null 2>&1 || true
  fi
fi

# ------------------------------------------------------------------------------
# Services
# ------------------------------------------------------------------------------
cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${MINIO_SVC}
spec:
  selector:
    app: ${MINIO_STS}
  ports:
  - name: s3
    port: 9000
    targetPort: 9000
---
apiVersion: v1
kind: Service
metadata:
  name: ${MINIO_SVC_CONSOLE}
spec:
  selector:
    app: ${MINIO_STS}
  ports:
  - name: console
    port: 9001
    targetPort: 9001
YAML

# ------------------------------------------------------------------------------
# StatefulSet (perms enforced; fails fast if cannot fix)
# ------------------------------------------------------------------------------
cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ${MINIO_STS}
spec:
  serviceName: ${MINIO_SVC}
  replicas: 1
  selector:
    matchLabels:
      app: ${MINIO_STS}
  template:
    metadata:
      labels:
        app: ${MINIO_STS}
    spec:
      securityContext:
        fsGroup: 1000
        fsGroupChangePolicy: "OnRootMismatch"
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: ${MINIO_PVC}
      initContainers:
      - name: fix-perms
        image: busybox:1.36
        securityContext:
          runAsUser: 0
        command: ["sh","-c"]
        args:
        - |
          set -e
          mkdir -p /data
          chown -R 1000:1000 /data
          chmod -R ug+rwX /data
        volumeMounts:
        - name: data
          mountPath: /data
      - name: verify-writable
        image: busybox:1.36
        securityContext:
          runAsUser: 1000
          runAsGroup: 1000
        command: ["sh","-c"]
        args:
        - |
          set -e
          touch /data/.openkpi_write_test
          rm -f /data/.openkpi_write_test
          echo OK
        volumeMounts:
        - name: data
          mountPath: /data
      containers:
      - name: minio
        image: ${MINIO_IMAGE}
        args:
        - server
        - /data
        - --address
        - :9000
        - --console-address
        - :9001
        ports:
        - containerPort: 9000
          name: s3
        - containerPort: 9001
          name: console
        env:
        - name: MINIO_ROOT_USER
          valueFrom:
            secretKeyRef:
              name: ${MINIO_SECRET}
              key: MINIO_ROOT_USER
        - name: MINIO_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: ${MINIO_SECRET}
              key: MINIO_ROOT_PASSWORD
        - name: MINIO_REGION
          value: "${MINIO_REGION}"
        - name: MINIO_SERVER_URL
          value: "${MINIO_SERVER_URL}"
        - name: MINIO_BROWSER_REDIRECT_URL
          value: "${MINIO_BROWSER_REDIRECT_URL}"
        securityContext:
          runAsUser: 1000
          runAsGroup: 1000
          allowPrivilegeEscalation: false
        livenessProbe:
          httpGet:
            path: /minio/health/live
            port: 9000
          initialDelaySeconds: 20
          periodSeconds: 20
          timeoutSeconds: 3
          failureThreshold: 6
        readinessProbe:
          httpGet:
            path: /minio/health/ready
            port: 9000
          initialDelaySeconds: 10
          periodSeconds: 10
          timeoutSeconds: 3
          failureThreshold: 12
        volumeMounts:
        - name: data
          mountPath: /data
YAML

# ------------------------------------------------------------------------------
# Ingress (PRODUCTION): two-host routing (avoids /console subpath issues)
#   S3      -> https://minio.${APP_DOMAIN}          -> svc ${MINIO_SVC}:9000
#   Console -> https://minio-console.${APP_DOMAIN}  -> svc ${MINIO_SVC_CONSOLE}:9001
#   TLS: use DISTINCT secrets in per-app mode to avoid cert-manager conflicts
# ------------------------------------------------------------------------------
if [[ "${MINIO_EXPOSE}" == "on" ]]; then
  log "[02-minio] ingress enabled (MINIO_EXPOSE=on)"

  HOST_MINIO="minio.${APP_DOMAIN}"
  HOST_MINIO_CONSOLE="minio-console.${APP_DOMAIN}"

  # Public URLs advertised by MinIO (critical for console)
  if tls_enabled; then
    MINIO_SERVER_URL_PUBLIC="https://${HOST_MINIO}"
    MINIO_BROWSER_REDIRECT_URL_PUBLIC="https://${HOST_MINIO_CONSOLE}/"
  else
    MINIO_SERVER_URL_PUBLIC="http://${HOST_MINIO}"
    MINIO_BROWSER_REDIRECT_URL_PUBLIC="http://${HOST_MINIO_CONSOLE}/"
  fi

  # Ensure these env vars are SET ONCE (no duplicates)
  # Strategy: jsonpatch remove existing keys (if any) then add exactly one each.
  _patch_env_once() {
    local key="$1" val="$2"
    # remove any existing entries with same name (best-effort)
    local idxs
    idxs="$(kubectl_k -n "${NS}" get sts "${MINIO_STS}" -o json \
      | jq -r --arg k "${key}" '.spec.template.spec.containers[0].env
        | to_entries
        | map(select(.value.name==$k))
        | reverse
        | .[].key' 2>/dev/null || true)"
    if [[ -n "${idxs}" ]]; then
      while read -r i; do
        [[ -n "${i}" ]] || continue
        kubectl_k -n "${NS}" patch sts "${MINIO_STS}" --type='json' \
          -p="[{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/0/env/${i}\"}]" >/dev/null 2>&1 || true
      done <<< "${idxs}"
    fi
    kubectl_k -n "${NS}" patch sts "${MINIO_STS}" --type='json' \
      -p="[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/env/-\",\"value\":{\"name\":\"${key}\",\"value\":\"${val}\"}}]" \
      >/dev/null 2>&1 || true
  }

  require_cmd jq
  _patch_env_once "MINIO_SERVER_URL" "${MINIO_SERVER_URL_PUBLIC}"
  _patch_env_once "MINIO_BROWSER_REDIRECT_URL" "${MINIO_BROWSER_REDIRECT_URL_PUBLIC}"

  # TLS secret selection
  MINIO_TLS_SECRET_S3="${MINIO_TLS_SECRET:-minio-tls}"
  MINIO_TLS_SECRET_CONSOLE="${MINIO_CONSOLE_TLS_SECRET:-minio-console-tls}"

  if tls_enabled; then
    if [[ "${TLS_STRATEGY:-per-app}" == "per-app" ]]; then
      require_var CERT_CLUSTER_ISSUER

      # S3 cert -> minio-tls
      cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: minio-cert
spec:
  secretName: ${MINIO_TLS_SECRET_S3}
  issuerRef:
    kind: ClusterIssuer
    name: ${CERT_CLUSTER_ISSUER}
  dnsNames:
  - ${HOST_MINIO}
YAML

      # Console cert -> minio-console-tls (MUST be distinct)
      cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: minio-console-cert
spec:
  secretName: ${MINIO_TLS_SECRET_CONSOLE}
  issuerRef:
    kind: ClusterIssuer
    name: ${CERT_CLUSTER_ISSUER}
  dnsNames:
  - ${HOST_MINIO_CONSOLE}
YAML

    else
      # wildcard: reuse shared secret for both
      require_var TLS_SECRET_NAME
      MINIO_TLS_SECRET_S3="${TLS_SECRET_NAME}"
      MINIO_TLS_SECRET_CONSOLE="${TLS_SECRET_NAME}"
    fi
  fi

  # Ingresses (separate objects)
  if tls_enabled; then
    cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: minio-ingress
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-http-version: "1.1"
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
  - hosts:
    - ${HOST_MINIO}
    secretName: ${MINIO_TLS_SECRET_S3}
  rules:
  - host: ${HOST_MINIO}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${MINIO_SVC}
            port:
              number: 9000
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: minio-console-ingress
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-http-version: "1.1"
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
  - hosts:
    - ${HOST_MINIO_CONSOLE}
    secretName: ${MINIO_TLS_SECRET_CONSOLE}
  rules:
  - host: ${HOST_MINIO_CONSOLE}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${MINIO_SVC_CONSOLE}
            port:
              number: 9001
YAML
  else
    cat <<YAML | kubectl_k -n "${NS}" apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: minio-ingress
spec:
  ingressClassName: ${INGRESS_CLASS}
  rules:
  - host: ${HOST_MINIO}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${MINIO_SVC}
            port:
              number: 9000
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: minio-console-ingress
spec:
  ingressClassName: ${INGRESS_CLASS}
  rules:
  - host: ${HOST_MINIO_CONSOLE}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${MINIO_SVC_CONSOLE}
            port:
              number: 9001
YAML
  fi

  # ---------------------------------------------------------------------------
  # TLS enforcement + black-screen detector (must run here, before rollouts/tests)
  # - Detect IncorrectCertificate (shared secret conflict)
  # - Wait for cert Ready
  # - Validate SAN contains the expected DNS name (not ingress.local)
  # ---------------------------------------------------------------------------
  if tls_enabled && [[ "${TLS_STRATEGY:-per-app}" == "per-app" ]]; then
    log "[02-minio] tls: enforce certificates (s3+console)"

    _wait_cert_ready() {
      local cert="$1"
      kubectl_k -n "${NS}" wait --for=condition=Ready "certificate/${cert}" --timeout=240s >/dev/null 2>&1 || true
      local ready reason msg
      ready="$(kubectl_k -n "${NS}" get "certificate/${cert}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
      reason="$(kubectl_k -n "${NS}" get "certificate/${cert}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || true)"
      msg="$(kubectl_k -n "${NS}" get "certificate/${cert}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || true)"

      if [[ "${ready}" != "True" ]]; then
        echo "[02-minio][TLS][FAIL] certificate/${cert} Ready=${ready:-<none>} Reason=${reason:-<none>}"
        echo "[02-minio][TLS] ${msg:-<no message>}"
        # Hard fix for your observed failure mode:
        # If two Certificates point to same secret, cert-manager marks one IncorrectCertificate.
        if [[ "${reason}" == "IncorrectCertificate" ]]; then
          echo "[02-minio][TLS][FIX] detected IncorrectCertificate; enforcing distinct secrets"
          echo "[02-minio][TLS][FIX] minio-cert -> ${MINIO_TLS_SECRET_S3}  | minio-console-cert -> ${MINIO_TLS_SECRET_CONSOLE}"
          # force re-issue by deleting console cert secret (safe; cert-manager recreates)
          kubectl_k -n "${NS}" delete secret "${MINIO_TLS_SECRET_CONSOLE}" --ignore-not-found >/dev/null 2>&1 || true
          kubectl_k -n "${NS}" delete certificaterequest -l cert-manager.io/certificate-name="minio-console-cert" --ignore-not-found >/dev/null 2>&1 || true
          kubectl_k -n "${NS}" wait --for=condition=Ready "certificate/minio-console-cert" --timeout=240s >/dev/null 2>&1 || true
        else
          die "certificate not Ready: ${cert}"
        fi
      fi
    }

    _san_must_contain() {
      local secret="$1" dns="$2"
      local crt
      crt="$(kubectl_k -n "${NS}" get secret "${secret}" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null || true)"
      [[ -n "${crt}" ]] || die "missing tls.crt in secret ${NS}/${secret}"
      echo "${crt}" | openssl x509 -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:${dns}" \
        || die "SAN mismatch for ${secret}: expected DNS:${dns} (not default ingress.local)"
    }

    _wait_cert_ready "minio-cert"
    _wait_cert_ready "minio-console-cert"
    _san_must_contain "${MINIO_TLS_SECRET_S3}" "${HOST_MINIO}"
    _san_must_contain "${MINIO_TLS_SECRET_CONSOLE}" "${HOST_MINIO_CONSOLE}"
    log "[02-minio] tls: certs OK (s3+console)"
  fi

else
  log "[02-minio] ingress disabled (MINIO_EXPOSE=${MINIO_EXPOSE})"
  kubectl_k -n "${NS}" delete ingress minio-ingress --ignore-not-found >/dev/null 2>&1 || true
  kubectl_k -n "${NS}" delete ingress minio-console-ingress --ignore-not-found >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------------------------
# Rollout + diagnostics
# ------------------------------------------------------------------------------
log "[02-minio] wait statefulset rollout"
if ! kubectl_k -n "${NS}" rollout status statefulset/"${MINIO_STS}" --timeout=240s; then
  log "[02-minio][DIAG] rollout failed"
  kubectl_k -n "${NS}" get pods -o wide | grep -E "(openkpi-minio|openkpi-postgres)" || true
  kubectl_k -n "${NS}" describe pod "${MINIO_STS}-0" || true
  kubectl_k -n "${NS}" logs "${MINIO_STS}-0" -c minio --previous --tail=200 || true
  die "MinIO statefulset rollout failed"
fi

# ------------------------------------------------------------------------------
# In-cluster health smoke (phase-based; Pod has no "Succeeded" condition)
# ------------------------------------------------------------------------------
log "[02-minio] smoke: in-cluster health"

kubectl_k -n "${NS}" delete pod minio-smoke --ignore-not-found >/dev/null 2>&1 || true

SMOKE_YAML="$(cat <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: minio-smoke
spec:
  restartPolicy: Never
  containers:
  - name: minio-smoke
    image: curlimages/curl:8.10.1
    command: ["sh","-c"]
    env:
    - name: MINIO_EP
      value: "__MINIO_EP__"
    args:
    - |
      set -e
      echo "check: ${MINIO_EP}/minio/health/ready"
      for i in $(seq 1 60); do
        if curl -fsS "${MINIO_EP}/minio/health/ready" >/dev/null; then
          echo "OK"
          exit 0
        fi
        sleep 2
      done
      echo "FAIL"
      exit 1
YAML
)"
SMOKE_YAML="${SMOKE_YAML/__MINIO_EP__/${MINIO_ENDPOINT_INTERNAL}}"
echo "${SMOKE_YAML}" | kubectl_k -n "${NS}" apply -f - >/dev/null

# wait for Pod phase=Succeeded (or fail fast if phase=Failed)
for _ in $(seq 1 180); do
  PHASE="$(kubectl_k -n "${NS}" get pod minio-smoke -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${PHASE}" == "Succeeded" ]]; then
    break
  fi
  if [[ "${PHASE}" == "Failed" ]]; then
    kubectl_k -n "${NS}" describe pod/minio-smoke | sed -n '/Events:/,$p' || true
    kubectl_k -n "${NS}" logs pod/minio-smoke --tail=200 || true
    die "in-cluster smoke failed (phase=Failed)"
  fi
  sleep 1
done

PHASE="$(kubectl_k -n "${NS}" get pod minio-smoke -o jsonpath='{.status.phase}' 2>/dev/null || true)"
if [[ "${PHASE}" != "Succeeded" ]]; then
  kubectl_k -n "${NS}" describe pod/minio-smoke | sed -n '/Events:/,$p' || true
  kubectl_k -n "${NS}" logs pod/minio-smoke --tail=200 || true
  die "in-cluster smoke failed (timeout; phase=${PHASE:-unknown})"
fi

kubectl_k -n "${NS}" logs pod/minio-smoke --tail=200 || true
kubectl_k -n "${NS}" delete pod minio-smoke --ignore-not-found >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# Bucket bootstrap (idempotent) + verification
# - NO host-side BUCKET_LIST (set -u safe)
# - YAML is single-quoted heredoc; we inject tokens after
# - Wait for pod Succeeded (not Ready)
# ------------------------------------------------------------------------------
log "[02-minio] bootstrap: buckets via mc (MINIO_BUCKETS=${MINIO_BUCKETS})"

require_var MINIO_MC_IMAGE

# Fast pull-check (optional but recommended)
if command -v crictl >/dev/null 2>&1; then
  if ! crictl pull "docker.io/${MINIO_MC_IMAGE#docker.io/}" >/dev/null 2>&1; then
    die "minio/mc image pull failed: ${MINIO_MC_IMAGE} (check tag/registry/DNS)"
  fi
fi

kubectl_k -n "${NS}" delete pod/minio-mc --ignore-not-found >/dev/null 2>&1 || true

MC_YAML="$(cat <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: minio-mc
  labels:
    app: minio-mc
spec:
  restartPolicy: Never
  containers:
  - name: mc
    image: __MINIO_MC_IMAGE__
    imagePullPolicy: IfNotPresent
    command: ["sh","-c"]
    env:
    - name: MINIO_BUCKETS
      value: "__MINIO_BUCKETS__"
    - name: MINIO_SVC
      value: "__MINIO_SVC__"
    - name: MINIO_ROOT_USER
      valueFrom:
        secretKeyRef:
          name: __MINIO_SECRET__
          key: MINIO_ROOT_USER
    - name: MINIO_ROOT_PASSWORD
      valueFrom:
        secretKeyRef:
          name: __MINIO_SECRET__
          key: MINIO_ROOT_PASSWORD
    args:
    - |
      set -e
      echo "[mc] alias set local -> http://${MINIO_SVC}:9000"
      mc alias set local "http://${MINIO_SVC}:9000" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"

      echo "[mc] buckets (before):"
      mc ls local || true

      BUCKET_LIST="$(echo "${MINIO_BUCKETS}" | tr ',' ' ')"
      for b in ${BUCKET_LIST}; do
        echo "[mc] ensure bucket: ${b}"
        mc mb --ignore-existing "local/${b}"
      done

      echo "[mc] verify:"
      for b in ${BUCKET_LIST}; do
        mc ls "local/${b}" >/dev/null
      done

      echo "[mc] OK"
YAML
)"

# token injection (host-side, set -u safe)
MC_YAML="${MC_YAML//__MINIO_MC_IMAGE__/${MINIO_MC_IMAGE}}"
MC_YAML="${MC_YAML//__MINIO_BUCKETS__/${MINIO_BUCKETS}}"
MC_YAML="${MC_YAML//__MINIO_SVC__/${MINIO_SVC}}"
MC_YAML="${MC_YAML//__MINIO_SECRET__/${MINIO_SECRET}}"

echo "${MC_YAML}" | kubectl_k -n "${NS}" apply -f - >/dev/null

if ! kubectl_k -n "${NS}" wait --for=jsonpath='{.status.phase}'=Succeeded pod/minio-mc --timeout=180s >/dev/null 2>&1; then
  log "[02-minio][DIAG] minio-mc did not complete"
  kubectl_k -n "${NS}" get pod minio-mc -o wide || true
  kubectl_k -n "${NS}" describe pod minio-mc | sed -n '/Events:/,$p' || true
  kubectl_k -n "${NS}" logs minio-mc -c mc --tail=300 || true
  die "bucket bootstrap failed (minio-mc)"
fi

kubectl_k -n "${NS}" logs minio-mc -c mc --tail=300 || true
kubectl_k -n "${NS}" delete pod/minio-mc --ignore-not-found >/dev/null 2>&1 || true

log "[02-minio] buckets OK"

# ------------------------------------------------------------------------------
# Network contract tests (HTTPS when enabled)
# ------------------------------------------------------------------------------
log "[02-minio] tests: network contract"

if [[ "${MINIO_EXPOSE}" == "on" ]]; then
  TLS_SECRET="$(kubectl_k -n "${NS}" get ingress "${MINIO_INGRESS_NAME}" -o jsonpath='{.spec.tls[0].secretName}' 2>/dev/null || true)"
  CLASS="$(kubectl_k -n "${NS}" get ingress "${MINIO_INGRESS_NAME}" -o jsonpath='{.spec.ingressClassName}' 2>/dev/null || true)"
  HOST="$(kubectl_k -n "${NS}" get ingress "${MINIO_INGRESS_NAME}" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)"
  log "[02-minio] contract: host=${HOST} class=${CLASS} tls_secret=${TLS_SECRET:-none}"

  [[ "${CLASS}" == "${INGRESS_CLASS}" ]] || die "Ingress class mismatch (${CLASS} != ${INGRESS_CLASS})"
  [[ "${HOST}" == "${HOST_MINIO}" ]] || die "Ingress host mismatch (${HOST} != ${HOST_MINIO})"

  if tls_enabled; then
    [[ -n "${TLS_SECRET}" ]] || die "TLS enabled but ingress has no tls.secretName"
  fi
fi

# Best-effort external checks (only if curl exists on node)
if [[ "${MINIO_EXPOSE}" == "on" ]] && command -v curl >/dev/null 2>&1; then
  log "[02-minio] smoke: external endpoint (best-effort)"
  curl -kfsS "${MINIO_SERVER_URL}/minio/health/ready" >/dev/null 2>&1 || true
  curl -kfsS "${MINIO_SERVER_URL}/console/" >/dev/null 2>&1 || true
fi

log "[02-minio] done"

# ==============================================================================
# MinIO Console Black-Screen Diagnostic (HTTPS)
# - Confirms HTML loads
# - Extracts JS/CSS asset URLs and checks HTTP codes
# - Checks console API endpoint behavior
# ==============================================================================

set -euo pipefail
HOST_CONSOLE="minio-console.${APP_DOMAIN}"   # use minio.${APP_DOMAIN} if still on /console
BASE="https://${HOST_CONSOLE}"

ts(){ date -u +"%Y-%m-%dT%H:%M:%SZ"; }
ok(){ echo "$(ts) [OK]  $*"; }
bad(){ echo "$(ts) [FAIL] $*" >&2; exit 1; }
warn(){ echo "$(ts) [WARN] $*" >&2; }

need(){ command -v "$1" >/dev/null 2>&1 || bad "missing command: $1"; }
need curl
need openssl
need sed
need grep
need head

ok "target=${BASE}"

# 1) TLS/SNI
CERT_OUT="$(echo | openssl s_client -servername "${HOST_CONSOLE}" -connect "${HOST_CONSOLE}:443" 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates 2>/dev/null || true)"
[[ -n "${CERT_OUT}" ]] || bad "TLS handshake failed: ${HOST_CONSOLE}:443"
echo "${CERT_OUT}" | grep -qi "Let's Encrypt" && ok "issuer=Let's Encrypt" || warn "issuer not Let's Encrypt"

# 2) HTML
HTML_CODE="$(curl -sk -o /tmp/minio_console.html -w "%{http_code}" "${BASE}/" || true)"
[[ "${HTML_CODE}" =~ ^(200|302|307)$ ]] || bad "console HTML failed: ${BASE}/ -> ${HTML_CODE}"
ok "console HTML status=${HTML_CODE}"

# 3) Asset extraction: scripts + css
# Extract absolute/relative src/href, normalize to full URLs
ASSETS="$(
  sed -n 's/.*src="\([^"]*\)".*/\1/p; s/.*href="\([^"]*\.css[^"]*\)".*/\1/p' /tmp/minio_console.html \
  | sed 's/&amp;/\&/g' \
  | sed '/^$/d' \
  | head -n 30
)"

if [[ -z "${ASSETS}" ]]; then
  warn "no assets extracted (HTML may be minimal or JS-inlined)"
else
  ok "checking assets (first 30)"
  while read -r a; do
    [[ -z "${a}" ]] && continue
    if [[ "${a}" =~ ^https?:// ]]; then
      URL="${a}"
    elif [[ "${a}" =~ ^/ ]]; then
      URL="${BASE}${a}"
    else
      URL="${BASE}/${a}"
    fi
    CODE="$(curl -sk -o /dev/null -w "%{http_code}" "${URL}" || true)"
    if [[ "${CODE}" == "200" ]]; then
      ok "asset 200 ${URL}"
    else
      warn "asset ${CODE} ${URL}"
    fi
  done <<< "${ASSETS}"
fi

# 4) Console API probes (non-auth endpoints often return 200/401; 404 is bad)
API1_CODE="$(curl -sk -o /dev/null -w "%{http_code}" "${BASE}/api/v1/session" || true)"
API2_CODE="$(curl -sk -o /dev/null -w "%{http_code}" "${BASE}/api/v1/login" || true)"
ok "api session=${API1_CODE} login=${API2_CODE}"
if [[ "${API1_CODE}" == "404" || "${API2_CODE}" == "404" ]]; then
  warn "console API paths returning 404 -> ingress path/host rewrite problem (classic black screen)"
fi

ok "console black-screen diagnostics complete"


# ==============================================================================
# OpenKPI HTTPS Network Contract Test Block (MinIO) — TWO HOSTS (PRODUCTION)
# Contract inputs (from /root/open-kpi.env via 00-env.sh):
#   APP_DOMAIN, INGRESS_CLASS, TLS_MODE, TLS_STRATEGY, TLS_SECRET_NAME, CERT_CLUSTER_ISSUER
# MinIO contract:
#   NS=open-kpi
#   S3_ING=minio-ingress              HOST_S3=minio.${APP_DOMAIN}             TLS=minio-tls (or wildcard secret)
#   CON_ING=minio-console-ingress     HOST_CON=minio-console.${APP_DOMAIN}    TLS=minio-console-tls (or wildcard secret)
# Expected routing:
#   https://minio.${APP_DOMAIN}/minio/health/ready   -> svc openkpi-minio:9000
#   https://minio-console.${APP_DOMAIN}/             -> svc openkpi-minio-console:9001
# ==============================================================================

set -euo pipefail

NS="open-kpi"

S3_ING="minio-ingress"
CON_ING="minio-console-ingress"

HOST_S3="minio.${APP_DOMAIN}"
HOST_CON="minio-console.${APP_DOMAIN}"

TLS_S3_DEFAULT="minio-tls"
TLS_CON_DEFAULT="minio-console-tls"

SVC_S3="openkpi-minio"
SVC_CON="openkpi-minio-console"

ts(){ date -u +"%Y-%m-%dT%H:%M:%SZ"; }
ok(){ echo "$(ts) [OK]  $*"; }
bad(){ echo "$(ts) [FAIL] $*" >&2; exit 1; }
warn(){ echo "$(ts) [WARN] $*" >&2; }

need(){ command -v "$1" >/dev/null 2>&1 || bad "missing command: $1"; }
need kubectl
need curl
need openssl
need grep

echo "$(ts) [INFO] S3 host=${HOST_S3} ingress=${NS}/${S3_ING} svc=${SVC_S3}:9000"
echo "$(ts) [INFO] CON host=${HOST_CON} ingress=${NS}/${CON_ING} svc=${SVC_CON}:9001"

# ------------------------------------------------------------------------------
# 1) DNS
# ------------------------------------------------------------------------------
getent hosts "${HOST_S3}" >/dev/null 2>&1 && ok "DNS resolves ${HOST_S3}" || warn "DNS not resolving ${HOST_S3}"
getent hosts "${HOST_CON}" >/dev/null 2>&1 && ok "DNS resolves ${HOST_CON}" || warn "DNS not resolving ${HOST_CON}"

# ------------------------------------------------------------------------------
# 2) TLS cert sanity (SNI)
# ------------------------------------------------------------------------------
cert_one(){
  local h="$1"
  local out
  out="$(echo | openssl s_client -servername "${h}" -connect "${h}:443" 2>/dev/null \
    | openssl x509 -noout -subject -issuer -dates 2>/dev/null || true)"
  [[ -n "${out}" ]] || bad "TLS handshake/cert fetch failed for ${h}:443"
  echo "${out}"
}
echo "$(cert_one "${HOST_S3}")"
echo "$(cert_one "${HOST_CON}")"
ok "TLS handshakes OK"

# ------------------------------------------------------------------------------
# 3) Ingress contract validation (host/class/tls/paths)
# ------------------------------------------------------------------------------
kubectl -n "${NS}" get ingress "${S3_ING}" >/dev/null 2>&1 || bad "missing ingress ${NS}/${S3_ING}"
kubectl -n "${NS}" get ingress "${CON_ING}" >/dev/null 2>&1 || bad "missing ingress ${NS}/${CON_ING}"

class_check(){
  local ing="$1"
  local class
  class="$(kubectl -n "${NS}" get ingress "${ing}" -o jsonpath='{.spec.ingressClassName}' 2>/dev/null || true)"
  [[ -n "${class}" ]] || bad "ingressClassName missing on ${NS}/${ing}"
  [[ "${class}" == "${INGRESS_CLASS}" ]] || bad "${NS}/${ing} ingressClassName=${class} expected ${INGRESS_CLASS}"
}
class_check "${S3_ING}"
class_check "${CON_ING}"
ok "Ingress class OK"

host_check(){
  local ing="$1" expect="$2"
  local h
  h="$(kubectl -n "${NS}" get ingress "${ing}" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)"
  [[ "${h}" == "${expect}" ]] || bad "${NS}/${ing} host=${h} expected ${expect}"
}
host_check "${S3_ING}" "${HOST_S3}"
host_check "${CON_ING}" "${HOST_CON}"
ok "Ingress hosts OK"

# TLS secret checks: allow wildcard override
tls_secret_check(){
  local ing="$1" fallback="$2"
  local sec
  sec="$(kubectl -n "${NS}" get ingress "${ing}" -o jsonpath='{.spec.tls[0].secretName}' 2>/dev/null || true)"
  [[ -n "${sec}" ]] || bad "TLS secret missing on ${NS}/${ing}"
  if [[ "${TLS_STRATEGY:-per-app}" == "wildcard" ]]; then
    [[ "${sec}" == "${TLS_SECRET_NAME}" ]] || bad "${NS}/${ing} tlsSecret=${sec} expected wildcard ${TLS_SECRET_NAME}"
  else
    [[ "${sec}" == "${fallback}" ]] || warn "${NS}/${ing} tlsSecret=${sec} expected ${fallback} (per-app)"
  fi
}
tls_enabled && tls_secret_check "${S3_ING}" "${TLS_S3_DEFAULT}"
tls_enabled && tls_secret_check "${CON_ING}" "${TLS_CON_DEFAULT}"
tls_enabled && ok "Ingress TLS secrets OK" || ok "TLS_MODE=off (skipping tls secret checks)"

# Backend checks (yaml grep is fine here; keep deterministic)
S3_YAML="$(kubectl -n "${NS}" get ingress "${S3_ING}" -o yaml)"
echo "${S3_YAML}" | grep -q "name: ${SVC_S3}" || bad "S3 ingress backend missing svc ${SVC_S3}"
echo "${S3_YAML}" | grep -q "number: 9000" || bad "S3 ingress backend missing port 9000"

CON_YAML="$(kubectl -n "${NS}" get ingress "${CON_ING}" -o yaml)"
echo "${CON_YAML}" | grep -q "name: ${SVC_CON}" || bad "Console ingress backend missing svc ${SVC_CON}"
echo "${CON_YAML}" | grep -q "number: 9001" || bad "Console ingress backend missing port 9001"

ok "Ingress backend routing OK"

# ------------------------------------------------------------------------------
# 4) Service endpoints
# ------------------------------------------------------------------------------
kubectl -n "${NS}" get svc "${SVC_S3}" "${SVC_CON}" >/dev/null 2>&1 || bad "missing service(s)"
EP_S3="$(kubectl -n "${NS}" get endpoints "${SVC_S3}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
EP_CON="$(kubectl -n "${NS}" get endpoints "${SVC_CON}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
[[ -n "${EP_S3}" ]] || bad "no endpoints for ${NS}/${SVC_S3}"
[[ -n "${EP_CON}" ]] || bad "no endpoints for ${NS}/${SVC_CON}"
ok "Service endpoints OK (s3=${EP_S3}, console=${EP_CON})"

# ------------------------------------------------------------------------------
# 5) HTTPS functional tests
# ------------------------------------------------------------------------------
HTTP_S3="$(curl -sk -o /dev/null -w "%{http_code}" "https://${HOST_S3}/minio/health/ready" || true)"
[[ "${HTTP_S3}" == "200" ]] || bad "HTTPS S3 health failed: https://${HOST_S3}/minio/health/ready -> ${HTTP_S3}"
ok "HTTPS S3 health OK (200)"

HTTP_CON="$(curl -sk -o /dev/null -w "%{http_code}" "https://${HOST_CON}/" || true)"
case "${HTTP_CON}" in
  200|302|307) ok "HTTPS console OK (${HTTP_CON})" ;;
  *) bad "HTTPS console failed: https://${HOST_CON}/ -> ${HTTP_CON}" ;;
esac

# ------------------------------------------------------------------------------
# 6) MinIO env redirect contract (must match public URLs now)
# ------------------------------------------------------------------------------
POD="$(kubectl -n "${NS}" get pod -l app=openkpi-minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "${POD}" ]] || bad "cannot find minio pod (label app=openkpi-minio)"
ENV_OUT="$(kubectl -n "${NS}" exec "${POD}" -- sh -c 'printenv | egrep "MINIO_SERVER_URL|MINIO_BROWSER_REDIRECT_URL" || true' 2>/dev/null || true)"
echo "${ENV_OUT}"

if tls_enabled; then
  echo "${ENV_OUT}" | grep -q "MINIO_SERVER_URL=https://${HOST_S3}" || warn "MINIO_SERVER_URL not https://${HOST_S3}"
  echo "${ENV_OUT}" | grep -q "MINIO_BROWSER_REDIRECT_URL=https://${HOST_CON}" || warn "MINIO_BROWSER_REDIRECT_URL not https://${HOST_CON}"
else
  echo "${ENV_OUT}" | grep -q "MINIO_SERVER_URL=http://${HOST_S3}" || warn "MINIO_SERVER_URL not http://${HOST_S3}"
  echo "${ENV_OUT}" | grep -q "MINIO_BROWSER_REDIRECT_URL=http://${HOST_CON}" || warn "MINIO_BROWSER_REDIRECT_URL not http://${HOST_CON}"
fi
ok "MinIO env redirect checks completed"

ok "HTTPS network contract tests completed (two-host)"
