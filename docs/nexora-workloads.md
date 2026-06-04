# Nexora Workloads CI/CD

This repo is the deployment source of truth for `nexora-api`, `nexora-admin`,
and `nexora-frontend`.

## Flow

- `nexora-backend` builds and pushes private GHCR images:
  - `ghcr.io/nexoraua/nexora-api`
  - `ghcr.io/nexoraua/nexora-admin`
  - `ghcr.io/nexoraua/nexora-migrator`
- `nexora-frontend` builds and pushes:
  - `ghcr.io/nexoraua/nexora-frontend`
- CI updates only the relevant environment overlay:
  - `develop` branch -> `clusters/develop/workloads/*`
  - `main` branch -> `clusters/staging/workloads/*`
  - `v*` tag -> `clusters/production/workloads/*`
- ArgoCD reconciles the desired state. CI never runs `kubectl apply`.

## Runtime Secrets

External Secrets reads these Vault KV paths:

| Environment | Path |
| --- | --- |
| develop | `kv/nexora/develop/registry/ghcr` |
| staging | `kv/nexora/staging/registry/ghcr` |
| production | `kv/nexora/production/registry/ghcr` |
| develop | `kv/nexora/develop/apps/api/runtime` |
| staging | `kv/nexora/staging/apps/api/runtime` |
| production | `kv/nexora/production/apps/api/runtime` |
| develop | `kv/nexora/develop/apps/admin/runtime` |
| staging | `kv/nexora/staging/apps/admin/runtime` |
| production | `kv/nexora/production/apps/admin/runtime` |

Use the repeatable scripts:

```bash
scripts/configure-cd-deploy-key.sh
scripts/seed-ghcr-pull-secret.sh
ENVIRONMENT=staging NEXORA_DB_CONNECTION_STRING='Host=...' scripts/seed-app-runtime-secrets.sh
```

`configure-cd-deploy-key.sh` prefers a write deploy key. If the GitHub
organization disables deploy keys, it configures the `GITOPS_TOKEN` repository
secret fallback in the app repos.
