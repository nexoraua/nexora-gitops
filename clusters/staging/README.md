# Staging cluster (Hetzner NBG1)

Production-like topology in a smaller envelope: full operator stack
(CloudNativePG, Dragonfly, RabbitMQ, Vault, Authentik, monitoring),
but single-region without cross-region sync.

Bootstrap steps after `terraform apply` on `environments/staging` in
`nexora-infra`:

1. Apply the root Application: `kubectl apply -n argocd -f clusters/staging/root.yaml`.
2. Seed Vault unseal keys and bootstrap secrets (Cloudflare API token,
   CNPG superuser, RabbitMQ admin, Authentik secret key, Hetzner Object
   Storage access keys) into Vault KV.

Manifests follow the `clusters/develop/` shape with the following
differences:

- `replicas: 3` for RabbitMQ, Vault, CloudNativePG primary cluster.
- `replicas: 2` for Dragonfly with snapshot persistence.
- Loki retention `336h` (14d) instead of `168h`.
- Tempo retention `336h` (14d).
- Storage sizes 2-3x develop.
- Pod-security `restricted` (instead of `baseline`).

This is currently a placeholder. Copy `clusters/develop/{apps,platform,stateful}`
and adjust values when staging cluster is provisioned.
