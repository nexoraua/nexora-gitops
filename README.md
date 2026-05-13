# nexora-gitops

Declarative deployment source of truth for all Nexora Kubernetes clusters,
driven by ArgoCD using the app-of-apps pattern.

## Layout

```text
clusters/
  develop/         Hetzner FSN1 (single cluster, CI workloads)
    apps/          ArgoCD Application manifests (one per addon)
    platform/     Helm values + raw manifests for platform addons
    stateful/     CloudNativePG, RabbitMQ, Dragonfly, Vault clusters
  staging/         Hetzner NBG1 (QA, production-like topology, smaller)
  production/      Hetzner FSN1 primary + NBG1 sync + HEL1 DR
```

Each cluster directory follows the same three-layer split used in the
reference `gamma` cluster:

- **apps/**: thin `Application` manifests pointing at `platform/*` or
  `stateful/*` subdirectories, or at upstream Helm charts. Sync-wave
  annotations order the dependency graph.
- **platform/**: cross-cutting infrastructure addons. cert-manager
  issuers, ArgoCD configuration, Traefik values, monitoring stack,
  Alloy, Vault, external-secrets, network policies, PDBs, RBAC.
- **stateful/**: workload clusters managed by operators. CloudNativePG
  `Cluster` resources, RabbitMQ `RabbitmqCluster`, Dragonfly `Dragonfly`
  CRs, Authentik `Cluster` + Helm release.

## Stack alignment

Mirrors the stack documented in `nexora-docs`:

- **CloudNativePG** for PostgreSQL with sync replication FSN1↔NBG1 on
  production.
- **Dragonfly Operator** for Redis-compatible cache.
- **RabbitMQ Cluster Operator** for message bus.
- **HashiCorp Vault HA** (Raft) for secrets KV and Transit (envelope
  encryption); External Secrets Operator with Vault backend.
- **Authentik** as central IdP.
- **VictoriaMetrics cluster** as the primary metrics backend;
  kube-prometheus-stack with 6h retention only as a Lens-compat scrape
  engine; **Grafana Alloy** as the unified OTel collector (DaemonSet)
  forwarding to VictoriaMetrics / Loki / Tempo.
- **Traefik** as ingress + cert-manager + Let's Encrypt.
- **Linkerd** for mTLS service mesh.
- **Hetzner Object Storage** (S3 v4 API) + **Hetzner Storage Box**
  (7-year cold archive) — both provisioned in `nexora-infra`, not as
  k8s resources.

AWS EKS migration target — `nexora-docs/adr/infra/0003-cloud-agnostic-stack.md`.

## Bootstrapping a new cluster

1. Provision with Terraform (`nexora-infra`).
2. ArgoCD is installed by the Terraform module on `argocd.<base-domain>`
   with the admin password in Terraform output `argocd_admin_password`.
3. Apply the root Application:

   ```bash
   kubectl apply -n argocd -f clusters/develop/root.yaml
   ```

4. Root Application syncs `clusters/develop/apps/*.yaml`. Each leaf
   Application syncs its own sources. Sync-wave annotations keep
   operators ahead of their CRs.
5. Bootstrap secrets (Vault unseal keys, Cloudflare API token,
   Authentik secret key, RabbitMQ admin password, CNPG superuser
   password, Hetzner Object Storage access keys) are seeded manually
   into Vault on first launch. External Secrets Operator then
   materialises them as Kubernetes `Secret` resources.

Architectural context — `nexora-docs/adr/infra/`.
