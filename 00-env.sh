#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 00-env.sh — OpenKPI Platform Contract (single source of truth)
#
# Source of truth: /root/open-kpi.env (or OPENKPI_ENV_FILE override)
#
# Guarantees:
# - If missing, create /root/open-kpi.env with mode 0600.
# - Safe to source multiple times (idempotent).
# - No installs. No helm. No kubectl writes. (kubectl read-only allowed for IP detect)
# - Generate secrets only when missing; never rotate automatically.
# - Persist resolved values back into /root/open-kpi.env (safe upsert).
#
# Canonical variable policy:
# - CERT_CLUSTER_ISSUER is canonical.
# - CLUSTER_ISSUER is a runtime alias for backwards compatibility (NOT persisted).
# - OPENKPI_NS is canonical; NS is a runtime alias for backwards compatibility (NOT persisted).
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
  local f="$1" line key val
  [[ -f "$f" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(_openkpi_trim "$line")"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue

    key="${line%%=*}"
    val="${line#*=}"

    # trim whitespace
    key="$(_openkpi_trim "$key")"
    val="$(_openkpi_trim "$val")"

    # remove surrounding quotes if present
    if [[ "$val" =~ ^\".*\"$ ]]; then
      val="${val:1:${#val}-2}"
      val="${val//\\\"/\"}"
    elif [[ "$val" =~ ^\'.*\'$ ]]; then
      val="${val:1:${#val}-2}"
    fi

    # export safely (no eval)
    printf -v "$key" '%s' "$val"
    export "$key"
  done <"$f"
}


_openkpi_env_write_batch() {
  # Usage: _openkpi_env_write_batch "$file" KEY1 "VAL1" KEY2 "VAL2" ...
  local f="$1"; shift
  local tmp; tmp="$(mktemp)"
  touch "$f"; chmod 0600 "$f" 2>/dev/null || true

  # Build a lookup map in awk from the args, replace existing keys, append missing.
  awk -v argc="$#" '
    function esc(s) { gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); return s }
    BEGIN {
      # args arrive as: KEY VAL KEY VAL ...
      for (i=1; i<=argc; i+=2) {
        k=ARGV[i]; v=ARGV[i+1]
        want[k]=v
        seen[k]=0
      }
      # consume ARGV to prevent awk treating them as files
      for (i=1; i<=argc; i++) ARGV[i]=""
    }
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/ {
      split($0,a,"="); k=a[1]
      sub(/^[[:space:]]*/,"",k)
      if (k in want) {
        print k"=\""esc(want[k])"\""
        seen[k]=1
        next
      }
    }
    { print }
    END {
      for (k in want) if (!seen[k]) print k"=\""esc(want[k])"\""
    }
  ' "$@" "$f" >"$tmp"

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

  # explicit override (if valid)
  if [[ -n "${APP_EXTERNAL_IP_OVERRIDE:-}" ]]; then
    ip="$(_openkpi_trim "${APP_EXTERNAL_IP_OVERRIDE}")"
    _openkpi_is_ipv4 "$ip" && { echo "$ip"; return 0; }
  fi

  # read-only kubectl (if present)
  if _openkpi_have_cmd kubectl; then
    ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
    ip="$(_openkpi_trim "$ip")"
    _openkpi_is_ipv4 "$ip" && { echo "$ip"; return 0; }
  fi

  # hostname -I fallback
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

: "${OPENKPI_NS:=open-kpi}"
: "${PLATFORM_NS:=platform}"

: "${TLS_MODE:=per-host-http01}"          # off|per-host-http01
: "${INGRESS_CLASS:=nginx}"               # traefik|nginx
: "${STORAGE_CLASS:=local-path}"
: "${ACME_EMAIL:=admin@yottalogica.com}"

: "${CERT_CLUSTER_ISSUER:=letsencrypt-http01}"
# runtime alias (do not persist)
CLUSTER_ISSUER="${CERT_CLUSTER_ISSUER}"

: "${KUBE_DNS_IP:=10.43.0.10}"

# ensure defined for set -u safety
: "${APP_EXTERNAL_IP_OVERRIDE:=}"

# ------------------------------------------------------------------------------
# Node/IP-derived nip.io fallback (only if DOMAIN_BASE not provided)
# ------------------------------------------------------------------------------

NODE_IP_DETECTED="$(_openkpi_detect_node_ip)"
if [[ -n "${NODE_IP:-}" ]] && _openkpi_is_ipv4 "${NODE_IP}"; then
  NODE_IP_DETECTED="${NODE_IP}"
fi
NODE_IP="${NODE_IP_DETECTED}"

IP_DASHED=""
[[ -n "${NODE_IP}" ]] && IP_DASHED="$(_openkpi_to_ip_dashed "$NODE_IP")"

# DOMAIN_BASE preferred to be explicitly set in open-kpi.env.
# If missing, derive nip.io fallback.
if [[ -z "${DOMAIN_BASE:-}" ]]; then
  if [[ -n "${IP_DASHED}" ]]; then
    DOMAIN_BASE="${IP_DASHED}.nip.io"
  else
    DOMAIN_BASE=""
  fi
fi

# APP_DOMAIN used to derive per-app hosts.
# For real domains:
#   DOMAIN_BASE=lake1.opendatalake.com
#   APP_DOMAIN=lake1.opendatalake.com
if [[ -z "${APP_DOMAIN:-}" ]]; then
  APP_DOMAIN="${DOMAIN_BASE}"
fi


: "${HOST_BASE:=lake1.opendatalake.com}"   # stable fallback
if [[ -z "${APP_DOMAIN:-}" ]]; then
  APP_DOMAIN="${DOMAIN_BASE:-}"
fi
if [[ -z "${APP_DOMAIN}" ]]; then
  APP_DOMAIN="${HOST_BASE}"
fi
export HOST_BASE APP_DOMAIN


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
# Exports (canonical + runtime compatibility aliases)
# ------------------------------------------------------------------------------

export OPENKPI_ENV_FILE

export OPENKPI_NS PLATFORM_NS
export TLS_MODE INGRESS_CLASS STORAGE_CLASS ACME_EMAIL
export CERT_CLUSTER_ISSUER
export CLUSTER_ISSUER

export APP_EXTERNAL_IP_OVERRIDE NODE_IP IP_DASHED
export DOMAIN_BASE APP_DOMAIN

export AIRBYTE_HOST MINIO_HOST POSTGRES_HOST DBT_HOST N8N_HOST ZAMMAD_HOST PORTAL_HOST

export OPENKPI_PG_DB OPENKPI_PG_USER OPENKPI_PG_PASSWORD
export OPENKPI_MINIO_ROOT_USER OPENKPI_MINIO_ROOT_PASSWORD

export N8N_PASS N8N_ENCRYPTION_KEY
export ZAMMAD_ADMIN_EMAIL ZAMMAD_ADMIN_PASSWORD
export KUBE_DNS_IP

# Back-compat runtime alias (do not persist)
export NS="${OPENKPI_NS}"

# ------------------------------------------------------------------------------
# Persist back to /root/open-kpi.env (safe upsert)
# ------------------------------------------------------------------------------
_openkpi_env_write_batch "$OPENKPI_ENV_FILE" \
  OPENKPI_NS "$OPENKPI_NS" \
  PLATFORM_NS "$PLATFORM_NS" \
  TLS_MODE "$TLS_MODE" \
  INGRESS_CLASS "$INGRESS_CLASS" \
  STORAGE_CLASS "$STORAGE_CLASS" \
  ACME_EMAIL "$ACME_EMAIL" \
  CERT_CLUSTER_ISSUER "$CERT_CLUSTER_ISSUER" \
  APP_EXTERNAL_IP_OVERRIDE "$APP_EXTERNAL_IP_OVERRIDE" \
  NODE_IP "${NODE_IP:-}" \
  IP_DASHED "${IP_DASHED:-}" \
  DOMAIN_BASE "${DOMAIN_BASE:-}" \
  HOST_BASE "${HOST_BASE:-}" \
  APP_DOMAIN "${APP_DOMAIN:-}" \
  AIRBYTE_HOST "${AIRBYTE_HOST:-}" \
  MINIO_HOST "${MINIO_HOST:-}" \
  POSTGRES_HOST "${POSTGRES_HOST:-}" \
  DBT_HOST "${DBT_HOST:-}" \
  N8N_HOST "${N8N_HOST:-}" \
  ZAMMAD_HOST "${ZAMMAD_HOST:-}" \
  PORTAL_HOST "${PORTAL_HOST:-}" \
  OPENKPI_PG_DB "$OPENKPI_PG_DB" \
  OPENKPI_PG_USER "$OPENKPI_PG_USER" \
  OPENKPI_PG_PASSWORD "$OPENKPI_PG_PASSWORD" \
  OPENKPI_MINIO_ROOT_USER "$OPENKPI_MINIO_ROOT_USER" \
  OPENKPI_MINIO_ROOT_PASSWORD "$OPENKPI_MINIO_ROOT_PASSWORD" \
  N8N_PASS "$N8N_PASS" \
  N8N_ENCRYPTION_KEY "$N8N_ENCRYPTION_KEY" \
  ZAMMAD_ADMIN_EMAIL "$ZAMMAD_ADMIN_EMAIL" \
  ZAMMAD_ADMIN_PASSWORD "$ZAMMAD_ADMIN_PASSWORD" \
  KUBE_DNS_IP "$KUBE_DNS_IP"
