#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 00-env.sh — Open KPI Platform Contract (single source of truth)
#
# Rules:
# - Read /root/open-kpi.env if it exists; if missing, create (0600).
# - Safe to source multiple times (idempotent).
# - Never installs packages. Never calls helm.
# - No kubectl writes; optional read-only node IP detection allowed.
# - Generate secrets only when missing; never rotate automatically.
# - Persist resolved values back into /root/open-kpi.env (update safely).
# ==============================================================================

OPENKPI_ENV_FILE="${OPENKPI_ENV_FILE:-/root/open-kpi.env}"
umask 077

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

_openkpi_have_cmd() { command -v "$1" >/dev/null 2>&1; }

_openkpi_trim() {
  # shellcheck disable=SC2001
  echo "${1:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

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

_openkpi_to_ip_dashed() {
  local ip="${1:-}"
  echo "$ip" | tr '.' '-'
}

_openkpi_safe_mkfile_0600() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    : >"$f"
    chmod 0600 "$f" 2>/dev/null || true
  else
    chmod 0600 "$f" 2>/dev/null || true
  fi
}

_openkpi_source_env_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  # only accept KEY=VALUE lines; ignore everything else.
  # shellcheck disable=SC2162
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(_openkpi_trim "$line")"
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    # shellcheck disable=SC1090
    eval "export ${line}"
  done <"$f"
}

_openkpi_env_get_existing() {
  # get first occurrence; strip surrounding quotes
  local key="$1" f="$2"
  [[ -f "$f" ]] || return 1
  local v
  v="$(awk -F= -v k="$key" '
    $0 ~ "^[[:space:]]*"k"=" {
      sub("^[[:space:]]*"k"=", "", $0)
      print $0
      exit
    }' "$f" 2>/dev/null || true)"
  v="$(_openkpi_trim "$v")"
  # remove wrapping quotes if present
  if [[ "$v" =~ ^\".*\"$ ]]; then v="${v:1:${#v}-2}"; fi
  if [[ "$v" =~ ^\'.*\'$ ]]; then v="${v:1:${#v}-2}"; fi
  [[ -n "$v" ]] || return 1
  printf '%s' "$v"
}

_openkpi_env_upsert_kv() {
  # Upsert KEY=VALUE into env file, preserving other lines.
  # Values are always written quoted to avoid parsing issues.
  local key="$1" val="$2" f="$3"
  local tmp
  tmp="$(mktemp)"
  if [[ -f "$f" ]]; then
    # Remove existing key lines (all occurrences) then append the new one.
    awk -v k="$key" '
      BEGIN { IGNORECASE=0 }
      $0 ~ "^[[:space:]]*"k"=" { next }
      { print }
    ' "$f" >"$tmp"
  fi

  # Ensure file ends with newline before appending
  printf '%s\n' "${key}=\"${val//\"/\\\"}\"" >>"$tmp"

  # Atomic replace
  cat "$tmp" >"$f"
  rm -f "$tmp"
  chmod 0600 "$f" 2>/dev/null || true
}

_openkpi_rand_b64url() {
  # Generate a URL-safe secret (no rotation). 32 bytes default.
  local nbytes="${1:-32}"
  if _openkpi_have_cmd openssl; then
    openssl rand -base64 "$nbytes" 2>/dev/null | tr -d '\n' | tr '+/' '-_' | tr -d '='
  else
    # fallback without installing anything
    # shellcheck disable=SC2002
    cat /dev/urandom | head -c "$nbytes" | base64 2>/dev/null | tr -d '\n' | tr '+/' '-_' | tr -d '='
  fi
}

_openkpi_detect_node_ip() {
  local ip=""

  # 1) Override
  if [[ -n "${APP_EXTERNAL_IP_OVERRIDE:-}" ]]; then
    ip="$(_openkpi_trim "${APP_EXTERNAL_IP_OVERRIDE}")"
    if _openkpi_is_ipv4 "$ip"; then
      echo "$ip"
      return 0
    fi
  fi

  # 2) kubectl InternalIP (read-only)
  if _openkpi_have_cmd kubectl; then
    # Use first node InternalIP
    ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
    ip="$(_openkpi_trim "$ip")"
    if _openkpi_is_ipv4 "$ip"; then
      echo "$ip"
      return 0
    fi
  fi

  # 3) hostname -I fallback
  if _openkpi_have_cmd hostname; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    ip="$(_openkpi_trim "$ip")"
    if _openkpi_is_ipv4 "$ip"; then
      echo "$ip"
      return 0
    fi
  fi

  # 4) last resort: empty
  echo ""
  return 0
}

# ------------------------------------------------------------------------------
# Ensure env file exists, load it, then resolve missing values
# ------------------------------------------------------------------------------

_openkpi_safe_mkfile_0600 "$OPENKPI_ENV_FILE"
_openkpi_source_env_file "$OPENKPI_ENV_FILE"

# Defaults (do not overwrite existing user values)
: "${NS:=open-kpi}"
: "${TLS_MODE:=per-host-http01}"    # off|per-host-http01
: "${INGRESS_CLASS:=nginx}"         # traefik|nginx
: "${STORAGE_CLASS:=local-path}"    # default local-path
: "${ACME_EMAIL:=admin@yottalogica.com}"

# Detect node IP / dashed form (with override support)
NODE_IP_DETECTED="$(_openkpi_detect_node_ip)"
if [[ -n "${NODE_IP:-}" ]]; then
  # honor existing value; validate lightly
  if _openkpi_is_ipv4 "$NODE_IP"; then
    NODE_IP_DETECTED="$NODE_IP"
  fi
fi
NODE_IP="$NODE_IP_DETECTED"
IP_DASHED=""
if [[ -n "$NODE_IP" ]]; then
  IP_DASHED="$(_openkpi_to_ip_dashed "$NODE_IP")"
fi

# DOMAIN_BASE & APP_DOMAIN
# - If user sets a real domain: use as-is.
# - Else default to ${IP_DASHED}.nip.io (requires NODE_IP).
if [[ -z "${DOMAIN_BASE:-}" ]]; then
  if [[ -n "$IP_DASHED" ]]; then
    DOMAIN_BASE="${IP_DASHED}.nip.io"
  else
    DOMAIN_BASE=""
  fi
fi
if [[ -z "${APP_DOMAIN:-}" ]]; then
  APP_DOMAIN="${DOMAIN_BASE}"
fi

# Per-app hostnames derived from APP_DOMAIN (only if missing)
if [[ -n "${APP_DOMAIN:-}" ]]; then
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

export AIRBYTE_HOST MINIO_HOST POSTGRES_HOST DBT_HOST N8N_HOST ZAMMAD_HOST PORTAL_HOST

# ------------------------------------------------------------------------------
# Secrets contract (generate only if missing; never rotate)
# - Keep this minimal and safe; other modules may define more.
# ------------------------------------------------------------------------------

# Postgres (platform DB)
if [[ -z "${OPENKPI_PG_PASSWORD:-}" ]]; then
  OPENKPI_PG_PASSWORD="$(_openkpi_rand_b64url 32)"
fi

# MinIO root creds (platform object store)
if [[ -z "${OPENKPI_MINIO_ROOT_USER:-}" ]]; then
  OPENKPI_MINIO_ROOT_USER="openkpi"
fi
if [[ -z "${OPENKPI_MINIO_ROOT_PASSWORD:-}" ]]; then
  OPENKPI_MINIO_ROOT_PASSWORD="$(_openkpi_rand_b64url 32)"
fi

# n8n secrets
if [[ -z "${N8N_PASS:-}" ]]; then
  N8N_PASS="$(_openkpi_rand_b64url 24)"
fi
if [[ -z "${N8N_ENCRYPTION_KEY:-}" ]]; then
  N8N_ENCRYPTION_KEY="$(_openkpi_rand_b64url 32)"
fi

# Zammad admin (optional; Zammad module can use these if present)
if [[ -z "${ZAMMAD_ADMIN_EMAIL:-}" ]]; then
  ZAMMAD_ADMIN_EMAIL="admin@${APP_DOMAIN:-local}"
fi
if [[ -z "${ZAMMAD_ADMIN_PASSWORD:-}" ]]; then
  ZAMMAD_ADMIN_PASSWORD="$(_openkpi_rand_b64url 24)"
fi

# ------------------------------------------------------------------------------
# Export contract variables (single source of truth)
# ------------------------------------------------------------------------------

export OPENKPI_ENV_FILE
export NS
export DOMAIN_BASE
export APP_DOMAIN
export ACME_EMAIL
export TLS_MODE
export INGRESS_CLASS
export STORAGE_CLASS
export APP_EXTERNAL_IP_OVERRIDE
export NODE_IP
export IP_DASHED

export AIRBYTE_HOST
export MINIO_HOST
export POSTGRES_HOST
export DBT_HOST
export N8N_HOST
export ZAMMAD_HOST
export PORTAL_HOST

export OPENKPI_PG_PASSWORD
export OPENKPI_MINIO_ROOT_USER
export OPENKPI_MINIO_ROOT_PASSWORD
export N8N_PASS
export N8N_ENCRYPTION_KEY
export ZAMMAD_ADMIN_EMAIL
export ZAMMAD_ADMIN_PASSWORD

# ------------------------------------------------------------------------------
# Persist back to /root/open-kpi.env (safe upsert)
# ------------------------------------------------------------------------------
_openkpi_env_upsert_kv "NS" "$NS" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "TLS_MODE" "$TLS_MODE" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "INGRESS_CLASS" "$INGRESS_CLASS" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "STORAGE_CLASS" "$STORAGE_CLASS" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "ACME_EMAIL" "$ACME_EMAIL" "$OPENKPI_ENV_FILE"

_openkpi_env_upsert_kv "APP_EXTERNAL_IP_OVERRIDE" "${APP_EXTERNAL_IP_OVERRIDE:-}" "$OPENKPI_ENV_FILE"
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

_openkpi_env_upsert_kv "OPENKPI_PG_PASSWORD" "$OPENKPI_PG_PASSWORD" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "OPENKPI_MINIO_ROOT_USER" "$OPENKPI_MINIO_ROOT_USER" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "OPENKPI_MINIO_ROOT_PASSWORD" "$OPENKPI_MINIO_ROOT_PASSWORD" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "N8N_PASS" "$N8N_PASS" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "N8N_ENCRYPTION_KEY" "$N8N_ENCRYPTION_KEY" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "ZAMMAD_ADMIN_EMAIL" "$ZAMMAD_ADMIN_EMAIL" "$OPENKPI_ENV_FILE"
_openkpi_env_upsert_kv "ZAMMAD_ADMIN_PASSWORD" "$ZAMMAD_ADMIN_PASSWORD" "$OPENKPI_ENV_FILE"

# Portal/UI: kube-dns ClusterIP (used by nginx resolver)
export KUBE_DNS_IP="${KUBE_DNS_IP:-10.43.0.10}"
