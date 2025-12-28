#!/usr/bin/env bash
set -euo pipefail

NS="${PLATFORM_NS:-platform}"

kubectl -n "$NS" delete pods -l app=portal-ui --force --grace-period=0 || true
kubectl -n "$NS" rollout status deployment portal-ui --timeout=180s
