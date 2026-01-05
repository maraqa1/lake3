# OpenKPI Portal API (Phase 1)

This module deploys the Portal API backend that powers the Portal UI.

## Endpoints (Phase 1)
- `GET /api/health`
- `GET /api/services`
- `GET /api/k8s/summary`

All services are always represented (even if unavailable).

## Deploy
From the OpenKPI repo:
```bash
cd modules/04-portal/portal-api
./04-portal-api.sh
./04-portal-api-tests.sh
```
