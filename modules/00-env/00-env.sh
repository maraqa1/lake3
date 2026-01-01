#!/usr/bin/env bash
set -euo pipefail

OPENKPI_ENV_FILE="${OPENKPI_ENV_FILE:-/root/open-kpi.env}"

_ts(){ date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log(){ echo "$(_ts) [00-env] $*"; }
die(){ echo "$(_ts) [00-env][FATAL] $*" >&2; exit 1; }

require_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }
require_var(){ [[ -n "${!1:-}" ]] || die "Missing required env var: $1"; }
tls_enabled(){ [[ "${TLS_MODE:-off}" != "off" ]]; }

_openkpi_have(){ command -v "$1" >/dev/null 2>&1; }

_openkpi_apt_ensure(){
  [[ "$(id -u)" -eq 0 ]] || return 0
  local pkgs=("$@")
  DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >/dev/null 2>&1 || true
}

_openkpi_pick_kubeconfig() {
  if [[ -n "${KUBECONFIG:-}" && -f "${KUBECONFIG}" ]]; then echo "${KUBECONFIG}"; return 0; fi
  if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then echo /etc/rancher/k3s/k3s.yaml; return 0; fi
  if [[ -f /root/.kube/config ]]; then echo /root/.kube/config; return 0; fi
  return 1
}

_openkpi_ensure_k3s_kubeconfig(){
  _openkpi_have k3s || return 0
  mkdir -p /etc/rancher/k3s
  if [[ ! -f /etc/rancher/k3s/k3s.yaml ]]; then
    k3s kubectl config view --raw > /etc/rancher/k3s/k3s.yaml
    chmod 600 /etc/rancher/k3s/k3s.yaml
  fi
}

_openkpi_ensure_kubectl(){
  _openkpi_have kubectl && return 0
  if _openkpi_have k3s; then
    cat > /usr/local/bin/kubectl <<'KUB'
#!/usr/bin/env bash
exec k3s kubectl "$@"
KUB
    chmod +x /usr/local/bin/kubectl
    return 0
  fi
  return 1
}

_openkpi_ensure_helm(){
  _openkpi_have helm && return 0
  [[ "$(id -u)" -eq 0 ]] || return 1

  _openkpi_apt_ensure curl ca-certificates tar gzip >/dev/null 2>&1 || true
  _openkpi_have curl || return 1

  local ver="v3.17.1"
  local os="linux"
  local arch="amd64"
  local url="https://get.helm.sh/helm-${ver}-${os}-${arch}.tar.gz"
  local tmp="/tmp/helm.tgz"

  curl -fsSL "${url}" -o "${tmp}"
  tar -xzf "${tmp}" -C /tmp
  install -m 0755 "/tmp/${os}-${arch}/helm" /usr/local/bin/helm
  rm -rf "${tmp}" "/tmp/${os}-${arch}"
}

# ------------------------------------------------------------------------------
# Load contract
# ------------------------------------------------------------------------------
[[ -f "${OPENKPI_ENV_FILE}" ]] || die "Missing env contract: ${OPENKPI_ENV_FILE}"
set -a
# shellcheck source=/dev/null
. "${OPENKPI_ENV_FILE}"
set +a

# ------------------------------------------------------------------------------
# Canonical aliases (backward compat)
# ------------------------------------------------------------------------------
if [[ -n "${CLUSTER_ISSUER:-}" && -z "${CERT_CLUSTER_ISSUER:-}" ]]; then export CERT_CLUSTER_ISSUER="${CLUSTER_ISSUER}"; fi
if [[ -n "${CERT_CLUSTER_ISSUER:-}" && -z "${CLUSTER_ISSUER:-}" ]]; then export CLUSTER_ISSUER="${CERT_CLUSTER_ISSUER}"; fi

if [[ -n "${OPENKPI_NS:-}" && -z "${NS:-}" ]]; then export NS="${OPENKPI_NS}"; fi
if [[ -n "${NS:-}" && -z "${OPENKPI_NS:-}" ]]; then export OPENKPI_NS="${NS}"; fi

# ------------------------------------------------------------------------------
# Mandatory baseline keys
# ------------------------------------------------------------------------------
require_var STORAGE_CLASS
require_var INGRESS_CLASS
require_var APP_DOMAIN
require_var OPENKPI_NS
require_var TLS_MODE


: "${MINIO_EXPOSE:=on}"
: "${MINIO_REGION:=us-east-1}"
: "${MINIO_ENDPOINT_INTERNAL:=http://openkpi-minio.${OPENKPI_NS}.svc.cluster.local:9000}"
export MINIO_EXPOSE MINIO_REGION MINIO_ENDPOINT_INTERNAL

# ------------------------------------------------------------------------------
# Legacy TLS_MODE normalization -> canonical
# ------------------------------------------------------------------------------
case "${TLS_MODE:-off}" in
  per-host-http01)
    export TLS_MODE="letsencrypt"
    export TLS_STRATEGY="${TLS_STRATEGY:-per-app}"
    ;;
  wildcard-http01)
    export TLS_MODE="letsencrypt"
    export TLS_STRATEGY="${TLS_STRATEGY:-wildcard}"
    ;;
  on|true|enabled)
    export TLS_MODE="letsencrypt"
    export TLS_STRATEGY="${TLS_STRATEGY:-per-app}"
    ;;
  off|false|disabled)
    export TLS_MODE="off"
    ;;
esac

# ------------------------------------------------------------------------------
# Defaults for newly introduced contract keys (backward compatible)
# ------------------------------------------------------------------------------
: "${TLS_STRATEGY:=per-app}"          # used when TLS_MODE gets normalized to letsencrypt
: "${MINIO_EXPOSE:=on}"              # default expose MinIO (matches current behavior)
: "${MINIO_REGION:=us-east-1}"       # MinIO default region
# internal endpoint default (service DNS)
: "${MINIO_ENDPOINT_INTERNAL:=http://openkpi-minio.${OPENKPI_NS}.svc.cluster.local:9000}"

export TLS_STRATEGY MINIO_EXPOSE MINIO_REGION MINIO_ENDPOINT_INTERNAL


# ------------------------------------------------------------------------------
# Validate TLS_MODE
# ------------------------------------------------------------------------------
case "${TLS_MODE}" in
  off|letsencrypt) ;;
  *) die "TLS_MODE must be off|letsencrypt (got: ${TLS_MODE})" ;;
esac

# ------------------------------------------------------------------------------
# Self-healing bootstrap
# ------------------------------------------------------------------------------
if ! _openkpi_have kubectl; then
  _openkpi_ensure_kubectl || die "kubectl missing and k3s not found. Install k3s first."
fi

OPENKPI_KUBECONFIG="$(_openkpi_pick_kubeconfig || true)"
if [[ -z "${OPENKPI_KUBECONFIG}" ]]; then
  _openkpi_ensure_k3s_kubeconfig || true
  OPENKPI_KUBECONFIG="$(_openkpi_pick_kubeconfig || true)"
fi
[[ -n "${OPENKPI_KUBECONFIG:-}" && -f "${OPENKPI_KUBECONFIG}" ]] || die "kubeconfig not found. Expected /etc/rancher/k3s/k3s.yaml"

export OPENKPI_KUBECONFIG
export KUBECONFIG="${OPENKPI_KUBECONFIG}"

if ! _openkpi_have helm; then
  _openkpi_ensure_helm || die "helm missing and could not be installed to /usr/local/bin (need root + curl)."
fi

kubectl_k(){ kubectl --kubeconfig="${OPENKPI_KUBECONFIG}" "$@"; }
helm_k(){ helm --kubeconfig="${OPENKPI_KUBECONFIG}" "$@"; }

kubectl_k get nodes >/dev/null 2>&1 || die "Cluster unreachable via ${OPENKPI_KUBECONFIG}"

# ------------------------------------------------------------------------------
# TLS contract validation
# ------------------------------------------------------------------------------
if tls_enabled; then
  require_var CERT_CLUSTER_ISSUER
  require_var TLS_STRATEGY
  case "${TLS_STRATEGY}" in
    wildcard|per-app) ;;
    *) die "TLS_STRATEGY must be wildcard|per-app (got: ${TLS_STRATEGY})" ;;
  esac
  if [[ "${TLS_STRATEGY}" == "wildcard" ]]; then
    require_var TLS_SECRET_NAME
    kubectl_k -n "${OPENKPI_NS}" get secret "${TLS_SECRET_NAME}" >/dev/null 2>&1 \
      || die "Wildcard TLS secret missing: ${OPENKPI_NS}/${TLS_SECRET_NAME}"
  fi
fi

log "OK (env loaded, kubeconfig ready, kubectl+helm ready)"
