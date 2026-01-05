# OpenKPI Portal UI — Phase 1 (Aligned)

## Install

From OpenKPI root:

```bash
cd modules/04-portal/portal-ui
./04-portal-ui.sh
```

## Tests

```bash
cd modules/04-portal/portal-ui
./04-portal-ui-tests.sh
```

## Expected URLs (from /root/open-kpi.env)

- UI: `https://${PORTAL_HOST}/`
- API (same host): `https://${PORTAL_HOST}/api/health`
- API summary: `https://${PORTAL_HOST}/api/summary`
- Catalog search: `https://${PORTAL_HOST}/api/catalog/search?q=<term>`
- Catalog tables: `https://${PORTAL_HOST}/api/catalog/tables`

## Troubleshooting (exact commands)

```bash
kubectl -n ${PLATFORM_NS} get deploy,svc,ingress -o wide
kubectl -n ${PLATFORM_NS} describe ingress portal-ingress
kubectl -n ${PLATFORM_NS} describe deploy portal-ui
kubectl -n ${PLATFORM_NS} logs deploy/portal-ui --tail=200
```
