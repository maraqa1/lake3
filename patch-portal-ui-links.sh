#!/usr/bin/env bash
set -euo pipefail

need(){ command -v "$1" >/dev/null 2>&1 || { echo "[FATAL] missing: $1" >&2; exit 1; }; }
need kubectl
need python3

NS="${PLATFORM_NS:-platform}"
CM="${PORTAL_UI_CM:-portal-ui-static}"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"

# -------------------------------------------------------------------
# Discover ingress hosts (best-effort). Returns https://<host> or "".
# -------------------------------------------------------------------
ing_host() {
  local ns="$1" name="$2"
  local h=""
  h="$(kubectl -n "$ns" get ingress "$name" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)"
  [[ -n "$h" ]] && echo "https://$h" || echo ""
}

# Common names in your stack (adjust only if your ingress names differ)
AIRBYTE_URL="$(ing_host airbyte airbyte)"
METABASE_URL="$(ing_host analytics metabase)"
N8N_URL="$(ing_host n8n n8n)"
ZAMMAD_URL="$(ing_host tickets zammad)"

# MinIO can be either OpenKPI MinIO or Airbyte MinIO. Prefer OpenKPI.
MINIO_URL="$(ing_host open-kpi minio)"
[[ -z "$MINIO_URL" ]] && MINIO_URL="$(ing_host airbyte airbyte-minio)"
[[ -z "$MINIO_URL" ]] && MINIO_URL="$(ing_host open-kpi openkpi-minio)"

echo "[patch][ui-links] Detected:"
echo "  AIRBYTE : ${AIRBYTE_URL:-<none>}"
echo "  MINIO  : ${MINIO_URL:-<none>}"
echo "  METABASE: ${METABASE_URL:-<none>}"
echo "  N8N    : ${N8N_URL:-<none>}"
echo "  ZAMMAD : ${ZAMMAD_URL:-<none>}"

# -------------------------------------------------------------------
# Patch ConfigMap data.app.js
# - Inject FALLBACK_LINKS (only once)
# - Override openHref resolution: summary.links.* first, then FALLBACK_LINKS.*
# -------------------------------------------------------------------
TMP="$(mktemp)"
kubectl -n "$NS" get cm "$CM" -o json > "$TMP"

python3 - <<PY
import json, re, os, sys

p = "$TMP"
d = json.load(open(p))
data = d.get("data", {})
js = data.get("app.js", "")

if not js:
    print("[FATAL] ConfigMap has no data.app.js", file=sys.stderr)
    sys.exit(1)

# Build fallback map
fallback = {
  "airbyte": os.environ.get("AIRBYTE_URL",""),
  "minio": os.environ.get("MINIO_URL",""),
  "metabase": os.environ.get("METABASE_URL",""),
  "n8n": os.environ.get("N8N_URL",""),
  "zammad": os.environ.get("ZAMMAD_URL",""),
}

inject = "const FALLBACK_LINKS = " + json.dumps(fallback, separators=(",",":")) + ";\n"

# 1) inject FALLBACK_LINKS after API_SUMMARY line (idempotent)
if "const FALLBACK_LINKS" not in js:
    js = re.sub(r'(const API_SUMMARY\s*=\s*[\'"][^\'"]+[\'"]\s*;\s*\n)',
                r'\\1' + inject,
                js, count=1)

# 2) patch deriveApps() openHref fallback
# Replace: openHref: summary?.links?.airbyte || ''
# With:    openHref: (summary?.links?.airbyte || FALLBACK_LINKS.airbyte || '')
def rep(js, key):
    pattern = r'(openHref:\s*summary\?\.\s*links\?\.\s*' + re.escape(key) + r'\s*\|\|\s*[\'"]{2})'
    # if present, replace the whole RHS safely by rewriting the openHref assignment
    js2 = re.sub(r'openHref:\s*summary\?\.\s*links\?\.\s*' + re.escape(key) + r'\s*\|\|\s*[\'"]{2}',
                 f'openHref: (summary?.links?.{key} || FALLBACK_LINKS.{key} || "")',
                 js)
    return js2

for k in ["airbyte","minio","metabase","n8n","zammad"]:
    js = rep(js, k)

data["app.js"] = js
d["data"] = data
print(json.dumps(d))
PY \
AIRBYTE_URL="${AIRBYTE_URL}" \
MINIO_URL="${MINIO_URL}" \
METABASE_URL="${METABASE_URL}" \
N8N_URL="${N8N_URL}" \
ZAMMAD_URL="${ZAMMAD_URL}" \
| kubectl -n "$NS" apply -f -

# Restart UI to pick up new ConfigMap content
kubectl -n "$NS" rollout restart deployment portal-ui >/dev/null
kubectl -n "$NS" rollout status deployment portal-ui --timeout=180s

echo "[patch][ui-links] Done"
