# OpenKPI Portal UI (Phase 1) - Drop-in Module

This module deploys the OpenKPI Portal UI as a static nginx site in Kubernetes.

## What it deploys
- ConfigMap containing `ui.tgz` (tarball of `./ui/`)
- Deployment `portal-ui` (nginx) with initContainer that unpacks `ui.tgz`
- Service `portal-ui:80`
- Ingress `portal-ingress` routing:
  - `/` -> `portal-ui:80`
  - `/api` -> `portal-api:${PORTAL_API_PORT}`

## Contract (env)
Loaded from `/root/open-kpi.env` via `00-env.sh`:
- PLATFORM_NS, INGRESS_CLASS
- PORTAL_HOST, PORTAL_API_SVC, PORTAL_API_PORT
- PORTAL_UI_* identifiers
- TLS_MODE (off | per-host-http01 | wildcard) and PORTAL_TLS_SECRET (if TLS enabled)

## Run
From the module folder:
```bash
./04-portal-ui.sh
./04-portal-ui-tests.sh
```
