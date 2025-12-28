#!/usr/bin/env bash
set -euo pipefail

NS="${PLATFORM_NS:-platform}"
CM="portal-api-code"

kubectl -n "$NS" get cm "$CM" -o yaml | \
awk '
/summary *= *{/ && !done {
  print;
  print "    \"links\": {";
  print "      \"airbyte\": \"https://airbyte.lake3.opendatalake.com\",";
  print "      \"metabase\": \"https://metabase.lake3.opendatalake.com\",";
  print "      \"n8n\": \"https://n8n.lake3.opendatalake.com\",";
  print "      \"zammad\": \"https://zammad.lake3.opendatalake.com\",";
  print "      \"minio\": \"\"";
  print "    },";
  done=1;
  next
}
{print}
' | kubectl -n "$NS" apply -f -

kubectl -n "$NS" rollout restart deployment portal-api
kubectl -n "$NS" rollout status deployment portal-api --timeout=180s
