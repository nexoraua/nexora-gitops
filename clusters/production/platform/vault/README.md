# Vault platform configuration (production)

Vault HA itself is deployed via `clusters/production/apps/vault.yaml`
(Helm chart, 3 Raft replicas with hcloud-volumes Raft storage). This
directory contains everything that wires the UI, ingress, OIDC auth via
Authentik, ESO `ClusterSecretStore`, and Kubernetes auth for pods.

## Files

| File | Role |
| ---- | ---- |
| `ingress.yaml` | Traefik `IngressRoute` for `vault.nxua.dev`, cert-manager `Certificate`, Cloudflare JWT validation middleware |
| `external-secrets.yaml` | `ClusterSecretStore` pointing at Vault KV |
| `_pending-authentik-oidc/oidc-bootstrap.yaml` | One-time bootstrap `Job` that configures OIDC auth method, Kubernetes auth method, policies (`infra-admin`, `infra-readonly`, `nexora-api`, `nexora-admin`), and the Transit engine (kept under `_pending-` until the Authentik OIDC blueprint produces creds and `kv/nexora/production/vault-oidc` is seeded) |

## Bootstrap sequence

1. Provision the cluster with Terraform (`nexora-infra`).
2. Apply Argo CD root Application (`clusters/production/root.yaml`).
3. Initialise Vault and capture Shamir keys:
   ```bash
   kubectl -n vault-system exec -ti vault-0 -- vault operator init
   ```
   Store the 5 unseal keys and the initial root token in 1Password
   `Nexora Breakglass` (split between two `admin-super` operators —
   3 keys + 2 keys, no overlap).
4. Unseal each Vault replica with 3 of the 5 Shamir keys:
   ```bash
   kubectl -n vault-system exec -ti vault-{0,1,2} -- vault operator unseal
   ```
5. **Migrate to AWS KMS auto-unseal** (ADR-I-0005). The Helm release
   already carries the `seal "awskms"` stanza; run the migration once
   so subsequent restarts auto-unseal:
   ```bash
   vault operator unseal -migrate <shamir-share-1>
   vault operator unseal -migrate <shamir-share-2>
   vault operator unseal -migrate <shamir-share-3>
   ```
   After migration the Shamir shares stay valid for break-glass recovery
   (re-init scenario).
6. Apply the Authentik blueprint for Vault (committed in
   `clusters/production/platform/authentik/blueprints/vault.yaml` —
   picked up automatically by Authentik). Copy the generated
   `client_id` + `client_secret` from the Authentik admin UI into
   Vault KV:
   ```bash
   vault kv put kv/nexora/production/vault-oidc \
     client_id=$AUTHENTIK_CLIENT_ID \
     client_secret=$AUTHENTIK_CLIENT_SECRET
   ```
7. Move `_pending-authentik-oidc/oidc-bootstrap.yaml` out of the
   `_pending-` prefix so Argo CD picks it up. Drop the initial root
   token into a short-lived Secret:
   ```bash
   kubectl -n vault-system create secret generic vault-bootstrap-token \
     --from-literal=token=$ROOT_TOKEN
   ```
8. The OIDC bootstrap Job runs at sync-wave 5 (PostSync hook), writes
   OIDC config, policies, kubernetes auth roles, and the Transit
   engine.
9. Revoke the root token, delete the bootstrap Secret:
   ```bash
   vault token revoke $ROOT_TOKEN
   kubectl -n vault-system delete secret vault-bootstrap-token
   ```

## Access patterns

| User | Path | Auth |
| ---- | ---- | ---- |
| Ops engineer (UI) | `https://vault.nxua.dev/ui` -> CF Access (group `infra-ops`, WARP) -> Vault OIDC -> Authentik -> policy `infra-admin` or `infra-readonly` | OIDC |
| External Secrets Operator | in-cluster `http://vault.vault-system.svc:8200` | Kubernetes ServiceAccount -> role `external-secrets` -> policy `infra-readonly` |
| Backend app pod | same | role `nexora-api` -> policy `nexora-api` (KV read for own paths + Transit encrypt/decrypt) |
| Admin app pod | same | role `nexora-admin` -> policy `nexora-admin` |

## Cloudflare Access policy

The UI is fronted by Cloudflare Access. Terraform creates the
application and policy in `nexora-infra/modules/cloudflare/access.tf`.

- Allow if `groups` (from Authentik OIDC source) contains `infra-ops`
  **and** WARP client is enrolled.
- Allow `infra-readonly` from any device that passes WARP enrolment
  (read-only access still requires the corporate device posture).
- Session 8h (production tightens vs develop's 24h).

## Transit keys

The bootstrap Job creates two Transit keys (used at the application
layer for column-level PII encryption; these are SEPARATE from the
KMS-side `alias/nexora-transit-production` that gates Vault auto-unseal):

- `nexora-pii-production` — envelope encryption for PII columns in
  CloudNativePG (passport, IPN, IBAN, full name, contacts) and for
  PII blobs in Hetzner Object Storage.
- `nexora-backups-production` — WAL and base backup encryption for
  CloudNativePG -> Hetzner Object Storage -> AWS S3 immutable DR copy.

Both keys rotate quarterly via a Quartz job (`KmsKeyRotationJob`,
documented in `nexora-docs/adr/backend/0014-cryptography-and-pii-encryption.md`).
