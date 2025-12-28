#!/usr/bin/env bash
set -euo pipefail

NS="${PLATFORM_NS:-platform}"
CM="portal-ui-static"

kubectl -n "$NS" get cm "$CM" -o yaml > /tmp/ui.yaml

# remove invalid directive
sed -i '/access_log .*;/d' /tmp/ui.yaml

# ensure access_log exists inside http {}
sed -i '/http {/a\ \ \ \ access_log /tmp/access.log;' /tmp/ui.yaml

kubectl -n "$NS" apply -f /tmp/ui.yaml

kubectl -n "$NS" rollout restart deployment portal-ui
kubectl -n "$NS" rollout status deployment portal-ui --timeout=180s
