#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 00-env.sh — OpenKPI Platform Contract (single source of truth)
#
# Source of truth: /root/open-kpi.env (or OPENKPI_ENV_FILE override)
# - If missing, create 0600.
# - Safe to source multiple times (idempotent).
# - Never installs packages. Never calls helm.
# - No kubectl writes; optional read-only node IP detection allowed.
# - Generate secrets only when missing; never rotate automatically.
# - Persist resolved values back into /root/open-kpi.env (safe upsert).
# ==============================================================================

OPENKPI_ENV_FILE="${OPENKPI_ENV_FILE:-/root/open-kpi.env}"
umask 077

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

_openkpi_have_cmd() { command -v "$1" >/dev/null 2>&1; }

_openkpi_trim() { echo "${1:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

_openkpi_is_ipv4() {
  local ip="${1:-}"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local a b c d
  IFS='.' read -r a b c d <<<"$ip"
  for o in "$a" "$b" "$c" "$d"; do
    [[ "$o" =~ ^[0-9]+$ ]] || return 1
    (( o >= 0 && o <= 255 )) || return 1
  done
  return 0
}

_openkpi_to_ip_dashed() { echo "${1:-}" | tr '.' '-'; }

_openkpi_safe_mkfile_0600() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    : >"$f"
  fi
  chmod 0600 "$f" 2>/dev/null || true
}

_openkpi_source_env_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(_openkpi_trim "$line")"
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    # shellcheck disable=SC1090
    eval "export ${line}"
  done <"$f"
}

_openkpi_env_upsert_kv() {
  local key="$1" val="$2" f="$3"
  local tmp
  tmp="$(mktemp)"
  if [[ -f "$f" ]]; then
    awk -v k="$key" '
      BEGIN { IGNORECASE=0 }
      $0 ~ "^[[:space:]]*"k"=" { next }
      { print }
    ' "$f" >"$tmp"
  fi
  printf '%s\n' "${key}=\"${val//\"/\\\"}\"" >>"$tmp"
  cat "$tmp" >"$f"
  rm -f "$tmp"
  chmod 0600 "$f" 2>/dev/null || true
}

_openkpi_rand_b64url() {
  local nbytes="${1:-32}"
  if _openkpi_have_cmd openssl; then
    openssl rand -base64 "$nbytes" 2>/dev/null | tr -d '\n' | tr '+/' '-_' | tr -d '='
  else
    head -c "$nbytes" /dev/urandom | base64 2>/dev/null | tr -d '\n' | tr '+/' '-_' | tr -d '='
  fi
}

_openkpi_detect_node_ip() {
  local ip=""

  if [[ -n "${APP_EXTERNAL_IP_OVERRIDE:-}" ]]; then
    ip="$(_openkpi_trim "${APP_EXTERNAL_IP_OVERRIDE}")"
    _openkpi_is_ipv4 "$ip" && { echo "$ip"; return 0; }
  fi

  if _openkpi_have_cmd kubectl; then
    ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
    ip="$(_openkpi_trim "$ip")"
    _openkpi_is_ipv4 "$ip" && { echo "$ip"; return 0; }
  fi

  if _openkpi_have_cmd hostname; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    ip="$(_openkpi_trim "$ip")"
    _openkpi_is_ipv4 "$ip" && { echo "$ip"; return 0; }
  fi

  echo ""
}

# ------------------------------------------------------------------------------
# Ensure env file exists, load it, then resolve missing values
# ------------------------------------------------------------------------------

_openkpi_safe_mkfile_0600 "$OPENKPI_ENV_FILE"
_openkpi_source_env_file "$OPENKPI_ENV_FILE"

# ------------------------------------------------------------------------------
# Stable defaults (only if missing)
# ------------------------------------------------------------------------------

: "${OPENKPI_NS:=${NS:-open-kpi}}"
: "${PLATFORM_NS:=platform}"

: "${TLS_MODE:=per-host-http01}"          # off|per-host-http01
: "${INGRESS_CLASS:=nginx}"
: "${STORAGE_CLASS:=local-path}"
: "${ACME_EMAIL:=admin@yottalogica.com}"

: "${CERT_CLUSTER_ISSUER:=letsencrypt-http01}"
: "${CLUSTER_ISSUER:=${CERT_CLUSTER_ISSUER}}"

: "${KUBE_DNS_IP:=10.43.0.10}"

# ensure defined for set -u safety
: "${APP_EXTERNAL_IP_OVERRIDE:=}"

# ------------------------------------------------------------------------------
# Node/IP-derived domain fallback (only if DOMAIN_BASE not provided)
# ------------------------------------------------------------------------------

NODE_IP_DETECTED="$(_openkpi_detect_node_ip)"
if [[ -n "${NODE_IP:-}" ]] && _openkpi_is_ipv4 "${NODE_IP}"; then
  NODE_IP_DETECTED="${NODE_IP}"
fi
NODE_IP="${NODE_IP_DETECTED}"
IP_DASHED=""
[[ -n "${NODE_IP}" ]] && IP_DASHED="$(_openkpi_to_ip_dashed "$NODE_IP")"

# DOMAIN_BASE: either explicitly set in open-kpi.env (preferred),
# or derived from nip.io fallback (only if not set).
if [[ -z "${DOMAIN_BASE:-}" ]]; then
  if [[ -n "${IP_DASHED}" ]]; then
    DOMAIN_BASE="${IP_DASHED}.nip.io"
  else
    DOMAIN_BASE=""
  fi
fi

# APP_DOMAIN: base used to derive per-app hosts.
# If you use real domains, set DOMAIN_BASE=lake1.opendatalake.com and APP_DOMAIN=lake1.opendatalake.com
if [[ -z "${APP_DOMAIN:-}" ]]; then
  APP_DOMAIN="${DOMAIN_BASE}"
fi

# ------------------------------------------------------------------------------
# Per-app public hosts (only if missing)
# ------------------------------------------------------------------------------

if [[ -n "${APP_DOMAIN}" ]]; then
  : "${AIRBYTE_HOST:=airbyte.${APP_DOMAIN}}"
  : "${MINIO_HOST:=minio.${APP_DOMAIN}}"
  : "${POSTGRES_HOST:=postgres.${APP_DOMAIN}}"
  : "${DBT_HOST:=dbt.${APP_DOMAIN}}"
  : "${N8N_HOST:=n8n.${APP_DOMAIN}}"
  : "${ZAMMAD_HOST:=zammad.${APP_DOMAIN}}"
  : "${PORTAL_HOST:=portal.${APP_DOMAIN}}"
else
  : "${AIRBYTE_HOST:=}"
  : "${MINIO_HOST:=}"
  : "${POSTGRES_HOST:=}"
  : "${DBT_HOST:=}"
  : "${N8N_HOST:=}"
  : "${ZAMMAD_HOST:=}"
  : "${PORTAL_HOST:=}"
fi

# ------------------------------------------------------------------------------
# Canonical core credentials (generate only when missing)
# ------------------------------------------------------------------------------

: "${OPENKPI_PG_DB:=openkpi}"
: "${OPENKPI_PG_USER:=openkpi_admin}"
if [[ -z "${OPENKPI_PG_PASSWORD:-}" ]]; then
  OPENKPI_PG_PASSWORD="$(_openkpi_rand_b64url 32)"
fi

: "${OPENKPI_MINIO_ROOT_USER:=minioadmin}"
if [[ -z "${OPENKPI_MINIO_ROOT_PASSWORD:-}" ]]; then
  OPENKPI_MINIO_ROOT_PASSWORD="$(_openkpi_rand_b64url 32)"
fi

# n8n
if [[ -z "${N8N_PASS:-}" ]]; then
  N8N_PASS="$(_openkpi_rand_b64url 24)"
fi
if [[ -z "${N8N_ENCRYPTION_KEY:-}" ]]; then
  N8N_ENCRYPTION_KEY="$(_openkpi_rand_b64url 32)"
fi

# Zammad
if [[ -z "${ZAMMAD_ADMIN_EMAIL:-}" ]]; then
  ZAMMAD_ADMIN_EMAIL="admin@${APP_DOMAIN:-local}"
fi
if [[ -z "${ZAMMAD_ADMIN_PASSWORD:-}" ]]; then
  ZAMMAD_ADMIN_PASSWORD="$(_openkpi_rand_b64url 24)"
fi

# ------------------------------------------------------------------------------
# Exports (canonical + backwards compatibility)
# ------------------------------------------------------------------------------

export OPENKPI_ENV_FILE

export OPENKPI_NS PLATFORM_NS
export TLS_MODE INGRESS_CLASS STORAGE_CLASS ACME_EMAIL
export CLUSTER_ISSUER CERT_CLUSTER_ISSUER
export APP_EXTERNAL_IP_OVERRIDE NODE_IP IP_DASHED
export DOMAIN_BASE APP_DOMAIN
export AIRBYTE_HOST MINIO_HOST POSTGRES_HOST DBT_HOST N8N_HOST ZAMMAD_HOST PORTAL_HOST
export OPENKPI_PG_DB OPENKPI_PG_USER OPENKPI_PG_PASSWORD
export OPENKPI_MINIO_ROOT_USER OPENKPI_MINIO_ROOT_PASSWORD
export N8N_PASS N8N_ENCRYPTION_KEY
export ZAMMAD_ADMIN_EMAIL ZAMMAD_ADMIN_PASSWORD
export KUBE_DNS_IP

# Back-compat
export NS="${NS:-${OPENKPI_NS}}"
export CERT_CLUSTER_ISSUER="${CERT_CLUSTER_ISSUER:-${CLUSTER_ISSUER}}"

# ------------------------------------------------------------------------------
# Persist back to /root/open-kpi.env (safe upsert)
# ------------------------------------------------------------------------------

_openkpi_env_upsert_kv "OPENKPI_NS" "$OPENKPI_NS" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "PLATFORM_NS" "$PLATFORM_NS" "$OPENKPI_ENV_FILE"

_openkpi_env_upsert_kv "TLS_MODE" "$TLS_MODE" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "INGRESS_CLASS" "$INGRESS_CLASS" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "STORAGE_CLASS" "$STORAGE_CLASS" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "ACME_EMAIL" "$ACME_EMAIL" "$OPENKPI_ENV_FILE"

_openkpi_env_upsert_kv "CLUSTER_ISSUER" "$CLUSTER_ISSUER" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "CERT_CLUSTER_ISSUER" "$CERT_CLUSTER_ISSUER" "$OPENKPI_ENV_FILE"

_openkpi_env_upsert_kv "APP_EXTERNAL_IP_OVERRIDE" "$APP_EXTERNAL_IP_OVERRIDE" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "NODE_IP" "${NODE_IP:-}" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "IP_DASHED" "${IP_DASHED:-}" "$OPENKPI_ENV_FILE"

_openkpi_env_upsert_kv "DOMAIN_BASE" "${DOMAIN_BASE:-}" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "APP_DOMAIN" "${APP_DOMAIN:-}" "$OPENKPI_ENV_FILE"

_openkpi_env_upsert_kv "AIRBYTE_HOST" "${AIRBYTE_HOST:-}" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "MINIO_HOST" "${MINIO_HOST:-}" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "POSTGRES_HOST" "${POSTGRES_HOST:-}" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "DBT_HOST" "${DBT_HOST:-}" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "N8N_HOST" "${N8N_HOST:-}" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "ZAMMAD_HOST" "${ZAMMAD_HOST:-}" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "PORTAL_HOST" "${PORTAL_HOST:-}" "$OPENKPI_ENV_FILE"

_openkpi_env_upsert_kv "OPENKPI_PG_DB" "$OPENKPI_PG_DB" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "OPENKPI_PG_USER" "$OPENKPI_PG_USER" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "OPENKPI_PG_PASSWORD" "$OPENKPI_PG_PASSWORD" "$OPENKPI_ENV_FILE"

_openkpi_env_upsert_kv "OPENKPI_MINIO_ROOT_USER" "$OPENKPI_MINIO_ROOT_USER" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "OPENKPI_MINIO_ROOT_PASSWORD" "$OPENKPI_MINIO_ROOT_PASSWORD" "$OPENKPI_ENV_FILE"

_openkpi_env_upsert_kv "N8N_PASS" "$N8N_PASS" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "N8N_ENCRYPTION_KEY" "$N8N_ENCRYPTION_KEY" "$OPENKPI_ENV_FILE"

_openkpi_env_upsert_kv "ZAMMAD_ADMIN_EMAIL" "$ZAMMAD_ADMIN_EMAIL" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "ZAMMAD_ADMIN_PASSWORD" "$ZAMMAD_ADMIN_PASSWORD" "$OPENKPI_ENV_FILE"

_openkpi_env_upsert_kv "KUBE_DNS_IP" "$KUBE_DNS_IP" "$OPENKPI_ENV_FILE"
