# Vault platform configuration (develop)

Vault HA itself is deployed via `clusters/develop/apps/vault.yaml` (Helm
chart). This directory contains everything that wires the UI, ingress,
OIDC auth via Authentik, ESO `ClusterSecretStore`, and Kubernetes auth
for pods.

## Files

| File | Role |
| ---- | ---- |
| `ingress.yaml` | Traefik `IngressRoute` for `vault.develop.nxua.dev`, cert-manager `Certificate`, Cloudflare JWT validation middleware |
| `external-secrets.yaml` | `ClusterSecretStore` pointing at Vault KV + initial `ExternalSecret` for the Authentik OIDC client credentials |
| `oidc-bootstrap.yaml` | One-time bootstrap `Job` that configures OIDC auth method, Kubernetes auth method, policies (`infra-admin`, `infra-readonly`, `nexora-api`, `nexora-admin`), and the Transit engine |

## Bootstrap sequence

The Job is idempotent — re-running it does not destroy anything — but
it depends on a short-lived root token. Run it once, verify, revoke
the root token, then keep the manifest applied so ArgoCD self-heals
any drift in policies and roles.

1. Provision the cluster with Terraform (`nexora-infra`).
2. Apply Argo CD root Application (`clusters/develop/root.yaml`).
3. Initialise Vault and capture Shamir keys:
   ```bash
   kubectl -n vault-system exec -ti vault-0 -- vault operator init
   ```
   Store the 5 unseal keys and the initial root token in 1Password
   `Nexora Breakglass` (split between two `admin-super` operators).
4. Unseal each Vault replica with 3 of the 5 Shamir keys:
   ```bash
   kubectl -n vault-system exec -ti vault-{0,1,2} -- vault operator unseal
   ```
5. Apply the Authentik blueprint for Vault (committed in
   `clusters/develop/platform/authentik/blueprints/vault.yaml` — picked
   up automatically by Authentik). Copy the generated `client_secret`
   from the Authentik admin UI into Vault KV:
   ```bash
   vault kv put kv/nexora/develop/vault-oidc \
     client_id=$AUTHENTIK_CLIENT_ID \
     client_secret=$AUTHENTIK_CLIENT_SECRET
   ```
6. Drop the initial root token into a short-lived Secret:
   ```bash
   kubectl -n vault-system create secret generic vault-bootstrap-token \
     --from-literal=token=$ROOT_TOKEN
   ```
7. Argo CD will sync `vault-config` and run the OIDC bootstrap Job
   (sync-wave 5). The Job writes OIDC config, policies, kubernetes
   auth roles, and the Transit engine.
8. Revoke the root token, delete the bootstrap Secret:
   ```bash
   vault token revoke $ROOT_TOKEN
   kubectl -n vault-system delete secret vault-bootstrap-token
   ```

## Access patterns

| User | Path | Auth |
| ---- | ---- | ---- |
| Ops engineer (UI) | `https://vault.develop.nxua.dev/ui` → CF Access (group `infra-ops`, WARP) → Vault OIDC → Authentik → policy `infra-admin` or `infra-readonly` | OIDC |
| External Secrets Operator | in-cluster `https://vault.vault-system.svc:8200` | Kubernetes ServiceAccount → role `external-secrets` → policy `infra-readonly` |
| Backend app pod | same | role `nexora-api` → policy `nexora-api` (KV read for own paths + Transit encrypt/decrypt) |
| Admin app pod | same | role `nexora-admin` → policy `nexora-admin` |

## Cloudflare Access policy

The UI is fronted by Cloudflare Access. Terraform creates the
application and policy in `nexora-infra/modules/cloudflare/access.tf`
(planned). Policy:

- Allow if `groups` (from Authentik OIDC source) contains `infra-ops`
  **and** WARP client is enrolled.
- Allow `infra-readonly` from any device (read access is low risk).
- Session 24h.

Cloudflare Tunnel is the only ingress path; Hetzner Load Balancer is
exposed only on the Cloudflare egress CIDRs.

## Transit keys

The bootstrap Job creates two Transit keys:

- `nexora-pii-develop` — envelope encryption for PII columns in
  CloudNativePG (passport, ІПН, IBAN, full name, contacts) and for
  PII blobs in Hetzner Object Storage.
- `nexora-backups-develop` — WAL and base backup encryption for
  CloudNativePG → Hetzner Object Storage → Hetzner Storage Box.

Both keys rotate quarterly via a Quartz job (`KmsKeyRotationJob`,
documented in `nexora-docs/adr/backend/0014-cryptography-and-pii-encryption.md`).
