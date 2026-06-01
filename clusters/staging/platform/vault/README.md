# Vault platform configuration (staging)

Vault itself is deployed via `clusters/staging/apps/vault.yaml` (Helm
chart). On staging Vault runs with `ha.raft.enabled=true` but
`replicas: 1` — the storage backend matches production but the cluster
is a sandbox and data loss is tolerated. This directory wires the UI,
ingress, OIDC auth via Authentik (when bootstrapped), the ESO
`ClusterSecretStore`, and Kubernetes auth for pods.

## Files

| File | Role |
| ---- | ---- |
| `ingress.yaml` | Traefik `IngressRoute` for `vault.staging.nxua.dev`, cert-manager `Certificate`, Cloudflare JWT validation middleware |
| `external-secrets.yaml` | `ClusterSecretStore` pointing at Vault KV |
| `_pending-authentik-oidc/oidc-bootstrap.yaml` | One-time bootstrap `Job` that configures OIDC auth method, Kubernetes auth method, policies (`infra-admin`, `infra-readonly`, `nexora-api`, `nexora-admin`), and the Transit engine. Activated once the Authentik OIDC provider for Vault is in place. |

## Bootstrap sequence

The Job is idempotent — re-running it does not destroy anything — but
it depends on a short-lived root token. Run it once, verify, revoke
the root token, then keep the manifest applied so ArgoCD self-heals
any drift in policies and roles.

1. Provision the cluster with Terraform (`nexora-infra`).
2. Apply Argo CD root Application (`clusters/staging/root.yaml`).
3. Initialise Vault and capture Shamir keys:
   ```bash
   kubectl -n vault-system exec -ti vault-0 -- vault operator init
   ```
   Store the 5 unseal keys and the initial root token in 1Password
   `Nexora Breakglass` (split between two `admin-super` operators).
4. Unseal the Vault replica with 3 of the 5 Shamir keys:
   ```bash
   kubectl -n vault-system exec -ti vault-0 -- vault operator unseal
   ```
5. Apply the Authentik blueprint for Vault (committed in
   `clusters/staging/platform/authentik/blueprints/vault.yaml` — picked
   up automatically by Authentik). Copy the generated `client_secret`
   from the Authentik admin UI into Vault KV:
   ```bash
   vault kv put kv/nexora/staging/vault-oidc \
     client_id=$AUTHENTIK_CLIENT_ID \
     client_secret=$AUTHENTIK_CLIENT_SECRET
   ```
6. Drop the initial root token into a short-lived Secret:
   ```bash
   kubectl -n vault-system create secret generic vault-bootstrap-token \
     --from-literal=token=$ROOT_TOKEN
   ```
7. Move `_pending-authentik-oidc/oidc-bootstrap.yaml` into this
   directory and let Argo CD sync `vault-config` (sync-wave 4). The Job
   writes OIDC config, policies, kubernetes auth roles, and the Transit
   engine.
8. Revoke the root token, delete the bootstrap Secret:
   ```bash
   vault token revoke $ROOT_TOKEN
   kubectl -n vault-system delete secret vault-bootstrap-token
   ```

## Access patterns

| User | Path | Auth |
| ---- | ---- | ---- |
| Ops engineer (UI) | `https://vault.staging.nxua.dev/ui` → CF Access (group `infra-ops`, WARP) → Vault OIDC → Authentik → policy `infra-admin` or `infra-readonly` | OIDC |
| External Secrets Operator | in-cluster `http://vault.vault-system.svc:8200` | Kubernetes ServiceAccount → role `external-secrets` → policy `infra-readonly` |
| Backend app pod | same | role `nexora-api` → policy `nexora-api` (KV read for own paths + Transit encrypt/decrypt) |
| Admin app pod | same | role `nexora-admin` → policy `nexora-admin` |

## Cloudflare Access policy

The UI is fronted by Cloudflare Access. Terraform creates the
application and policy in `nexora-infra/modules/cloudflare/access.tf`.
Policy:

- Allow if `groups` (from Authentik OIDC source) contains `infra-ops`
  **and** WARP client is enrolled.
- Allow `infra-readonly` from any device (read access is low risk).
- Session 24h.

Cloudflare Tunnel is the only ingress path; the Hetzner Load Balancer
is exposed only on the Cloudflare egress CIDRs.

## Transit keys

The bootstrap Job creates two Transit keys:

- `nexora-pii-staging` — envelope encryption for PII columns in
  CloudNativePG (passport, ІПН, IBAN, full name, contacts) and for
  PII blobs in Hetzner Object Storage.
- `nexora-backups-staging` — WAL and base backup encryption for
  CloudNativePG → Hetzner Object Storage.

Both keys rotate quarterly via a Quartz job (`KmsKeyRotationJob`,
documented in `nexora-docs/adr/backend/0014-cryptography-and-pii-encryption.md`).
