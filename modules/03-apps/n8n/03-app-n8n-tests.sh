#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${HERE}/../../../00-env.sh"

require_cmd kubectl

NS="${N8N_NS:-n8n}"
POD="n8n-smoke"

kubectl -n "${NS}" get deploy n8n >/dev/null
kubectl -n "${NS}" rollout status deploy/n8n --timeout=300s
kubectl -n "${NS}" get svc n8n >/dev/null

# clean previous
kubectl -n "${NS}" delete pod "${POD}" --ignore-not-found >/dev/null 2>&1 || true

# create pod (NON-interactive)
cat <<YAML | kubectl -n "${NS}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
spec:
  restartPolicy: Never
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: ["sh","-lc"]
      args:
        - |
          set -euo pipefail
          # wait for DNS + service routing to settle
          for i in 1 2 3 4 5 6 7 8 9 10; do
            curl -fsS -m 5 http://n8n.${NS}.svc.cluster.local/ >/dev/null && exit 0
            sleep 2
          done
          echo "n8n smoke failed"
          exit 1
YAML

# wait until it runs (or fails fast)
if ! kubectl -n "${NS}" wait --for=condition=Ready pod/"${POD}" --timeout=120s >/dev/null 2>&1; then
  kubectl -n "${NS}" get pod "${POD}" -o wide || true
  kubectl -n "${NS}" describe pod "${POD}" | sed -n '1,220p' || true
  kubectl -n "${NS}" logs "${POD}" -c curl --tail=200 || true
  kubectl -n "${NS}" delete pod "${POD}" --ignore-not-found >/dev/null 2>&1 || true
  exit 1
fi

# collect logs (success path)
kubectl -n "${NS}" logs "${POD}" -c curl --tail=200 >/dev/null 2>&1 || true
kubectl -n "${NS}" delete pod "${POD}" --ignore-not-found >/dev/null 2>&1 || true

log "[03-n8n][tests] OK"
