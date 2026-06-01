# Bootstrap secrets (production)

This directory contains `ExternalSecret` manifests that materialize
production secrets from HashiCorp Vault into Kubernetes `Secret`s. Argo
CD only syncs the manifests — every value listed below must be
pre-seeded in Vault by ops before the first `bootstrap-secrets`
Application sync, or the depending workloads stop at `SecretSyncedError`.

## Seed checklist

Run **before** the first sync of `bootstrap-secrets`. Authenticate to
Vault via OIDC (Authentik group `infra-admin`) or with the initial root
token during the day-0 bootstrap window.

### 1. CNPG superusers (split per cluster)

```bash
vault kv put kv/nexora/production/cnpg/superuser \
  username=postgres password=$(openssl rand -base64 32)

vault kv put kv/nexora/production/cnpg/authentik-superuser \
  username=postgres password=$(openssl rand -base64 32)

vault kv put kv/nexora/production/authentik/postgres \
  username=authentik password=$(openssl rand -base64 32)
```

### 2. Hetzner Object Storage backup credentials

Hetzner Object Storage keys are project-scoped — the same key reaches
both `nexora-cnpg-backups-production` and
`nexora-cnpg-backups-authentik-production`.

```bash
vault kv put kv/nexora/production/cnpg/backup-s3 \
  access-key-id=$HCLOUD_S3_AK \
  secret-access-key=$HCLOUD_S3_SK
```

### 3. AWS DR replicator (ADR-I-0005)

IAM user `nexora-cnpg-dr-replicator` in account 727990091861 with the
tight policy described in `aws-dr-replicator.yaml` (PutObject +
PutObjectRetention + PutObjectLegalHold only, no Delete).

```bash
vault kv put kv/nexora/production/aws/dr-replicator \
  access_key_id=$AWS_AK \
  secret_access_key=$AWS_SK
```

### 4. AWS KMS key ARNs (operational reference)

```bash
vault kv put kv/nexora/production/aws/kms-key-arns \
  backups=alias/nexora-backups-production \
  pii=alias/nexora-pii-production \
  transit=alias/nexora-transit-production
```

### 5. Authentik bootstrap

```bash
vault kv put kv/nexora/production/authentik/bootstrap \
  secret_key=$(openssl rand -base64 64) \
  bootstrap_admin_password=$(openssl rand -base64 32) \
  bootstrap_admin_token=$(openssl rand -hex 32)
```

### 6. RabbitMQ admin

```bash
vault kv put kv/nexora/production/rabbitmq/admin \
  username=nexora-admin password=$(openssl rand -base64 32)
```

### 7. Grafana admin + OIDC

```bash
vault kv put kv/nexora/production/grafana/admin \
  username=admin password=$(openssl rand -base64 32)

# After Authentik blueprint creates the grafana provider:
vault kv put kv/nexora/production/oidc/grafana \
  client_id=$AUTHENTIK_GRAFANA_CLIENT_ID \
  client_secret=$AUTHENTIK_GRAFANA_CLIENT_SECRET
```

### 8. ArgoCD OIDC

```bash
vault kv put kv/nexora/production/oidc/argocd \
  client_id=$AUTHENTIK_ARGOCD_CLIENT_ID \
  client_secret=$AUTHENTIK_ARGOCD_CLIENT_SECRET
```

### 9. Authentik OIDC client for Vault UI

```bash
vault kv put kv/nexora/production/vault-oidc \
  client_id=$AUTHENTIK_VAULT_CLIENT_ID \
  client_secret=$AUTHENTIK_VAULT_CLIENT_SECRET
```

### 10. Loki + Tempo object-storage credentials

```bash
vault kv put kv/nexora/production/object-storage/loki \
  access_key_id=$HCLOUD_S3_AK \
  secret_access_key=$HCLOUD_S3_SK

vault kv put kv/nexora/production/object-storage/tempo \
  access_key_id=$HCLOUD_S3_AK \
  secret_access_key=$HCLOUD_S3_SK
```

### 11. Tailscale subnet-router auth key

Reusable, non-ephemeral, pre-authorized, tags
`tag:k8s,tag:nexora-production`:

```bash
vault kv put kv/nexora/production/tailscale \
  auth-key=tskey-auth-...
```

### 12. Cloudflare Access (Vault + Hubble + ArgoCD UIs)

```bash
vault kv put kv/nexora/production/cloudflare-access \
  aud=$CF_ACCESS_AUD \
  team-domain=nexora.cloudflareaccess.com
```

### 13. Alertmanager destinations

```bash
vault kv put kv/nexora/production/alerts/slack \
  webhook_url=https://hooks.slack.com/services/...

vault kv put kv/nexora/production/alerts/pagerduty \
  integration_key=<events-api-v2-routing-key>
```

### 14. GHCR pull secret (only if private images required)

```bash
docker_config=$(echo -n '{"auths":{"ghcr.io":{"username":"nexora-ci","password":"'$GH_PAT'","auth":"'$(echo -n nexora-ci:$GH_PAT | base64)'"}}}' | base64 -w 0)
vault kv put kv/nexora/production/registry/ghcr .dockerconfigjson=$docker_config
```

## Buckets to provision before first sync

- `nexora-cnpg-backups-production` (Hetzner FSN1)
- `nexora-cnpg-backups-authentik-production` (Hetzner FSN1)
- `nexora-cnpg-backups-production-dr` (AWS S3 eu-central-1, Object Lock
  COMPLIANCE 35d default retention, SSE-KMS alias/nexora-backups-production)
- `nexora-cnpg-backups-authentik-production-dr` (same — AWS)
- `nexora-production-loki` (Hetzner FSN1)
- `nexora-production-tempo` (Hetzner FSN1)

Terraform under `nexora-infra/environments/production/` provisions the
Hetzner side and the AWS S3 + KMS side together.
