#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# OpenKPI – PUBLIC Postgres Access (NO SSH, NO RESTRICTIONS)
# File: OpenKPI/tools/db-access/openkpi-pg-public.sh
#
# Exposes Postgres directly on SERVER_IP:NODEPORT
#
# Usage:
#   open   -> expose DB
#   close  -> remove exposure
#   info   -> print DBeaver connection details
#
# Namespace: open-kpi
# Service:   openkpi-postgres
# ==============================================================================

NS="open-kpi"
BASE_SVC="openkpi-postgres"
PUBLIC_SVC="openkpi-postgres-public"

NODEPORT=31432          # fixed external port
DB_PORT=5432
ENV_FILE="/root/open-kpi.env"

load_env() {
  [[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 1; }
  set -a; source "$ENV_FILE"; set +a
  : "${POSTGRES_DB:?}"
  : "${POSTGRES_USER:?}"
  : "${POSTGRES_PASSWORD:?}"
}

server_ip() {
  ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1
}

open_access() {
  echo "Creating public NodePort service..."

  # copy selector from existing service
  SELECTOR=$(kubectl -n "$NS" get svc "$BASE_SVC" -o jsonpath='{.spec.selector}')

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${PUBLIC_SVC}
  namespace: ${NS}
spec:
  type: NodePort
  selector: ${SELECTOR}
  ports:
    - name: pg
      protocol: TCP
      port: ${DB_PORT}
      targetPort: ${DB_PORT}
      nodePort: ${NODEPORT}
EOF

  kubectl -n "$NS" get svc "$PUBLIC_SVC" -o wide
}

close_access() {
  kubectl -n "$NS" delete svc "$PUBLIC_SVC" --ignore-not-found
  echo "Public access removed"
}

info_access() {
  load_env
  IP="$(server_ip)"

  cat <<EOF
DB IS PUBLICLY ACCESSIBLE

DBeaver connection:

 Host:     ${IP}
 Port:     ${NODEPORT}
 Database: ${POSTGRES_DB}
 User:     ${POSTGRES_USER}
 Password: ${POSTGRES_PASSWORD}
 SSL:      disabled

Kubernetes reference:
 Service: ${PUBLIC_SVC}
 Namespace: ${NS}
 Internal DB port: ${DB_PORT}
EOF
}

case "${1:-}" in
  open)  open_access ;;
  close) close_access ;;
  info)  info_access ;;
  *) echo "Usage: $0 {open|close|info}"; exit 1 ;;
esac
