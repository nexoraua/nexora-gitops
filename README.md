# nexora-gitops

Declarative deployment source of truth for all Nexora Kubernetes clusters,
driven by ArgoCD using the app-of-apps pattern.

## Layout

```text
clusters/
  develop/         Hetzner FSN1 (single cluster, CI workloads)
    apps/          ArgoCD Application manifests (one per addon)
    platform/      Helm values + raw manifests for platform addons
    stateful/      CloudNativePG, RabbitMQ, Dragonfly, Vault clusters
  staging/         Hetzner NBG1 (QA, production-like topology, smaller)
  production/      Hetzner FSN1 primary + NBG1 sync + HEL1 DR
```

Each cluster directory follows the same three-layer split used in the
reference `gamma` cluster:

- **apps/**: thin `Application` manifests pointing at `platform/*` or
  `stateful/*` subdirectories, or at upstream Helm charts. Sync-wave
  annotations order the dependency graph.
- **platform/**: cross-cutting infrastructure addons. ArgoCD
  configuration, Alloy config, network policies, PDBs, Grafana
  dashboards, ExternalSecret manifests, Vault platform glue.
- **stateful/**: workload clusters managed by operators. CloudNativePG
  `Cluster` resources, RabbitMQ `RabbitmqCluster`, Dragonfly `Dragonfly`
  CRs, Authentik `Cluster` + Helm release.

## Separation of concerns: Terraform vs ArgoCD

`nexora-infra` (Terraform) provisions the cluster **and a minimal
bootstrap baseline** that has to exist before ArgoCD can self-manage:

- Hetzner servers, Talos config, kubeconfig.
- `cert-manager` (Helm release + CRDs + Cloudflare API token Secret).
- `traefik` (Helm release + Hetzner LoadBalancer Service annotations).
- `argo-cd` (Helm release + admin password output).

Everything else — including additional `ClusterIssuer` resources,
operators, observability stack, secrets glue, PDBs — lives here and is
reconciled by ArgoCD via `clusters/<cluster>/root.yaml`.

This means the four primitives below are intentionally **not** present
in `clusters/develop/`:

- `apps/cert-manager.yaml`
- `apps/cluster-issuer.yaml`
- `apps/traefik.yaml`
- `platform/cert-manager/`

If you need to change cert-manager or Traefik configuration, edit the
Terraform module under `nexora-infra/modules/k8s-bootstrap/`. If you
need additional `ClusterIssuer`s, add them inside the Terraform module
so they ship with the baseline.

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
- **Traefik** as ingress + cert-manager + Let's Encrypt (installed by
  Terraform).
- **Cilium** as the CNI with transparent encryption (WireGuard-based,
  node-to-node) for in-cluster traffic confidentiality — installed by
  Terraform. Application-layer mTLS / workload identity (SPIFFE/SPIRE
  or a service mesh) is an open future decision; no mesh is deployed.
- **Hetzner Object Storage** (S3 v4 API) + **Hetzner Storage Box**
  (7-year cold archive) — both provisioned in `nexora-infra`, not as
  k8s resources.

AWS EKS migration target — `nexora-docs/adr/infra/0003-cloud-agnostic-stack.md`.

## ArgoCD Applications (develop)

| Application | Wave | Project | Purpose |
| ----------- | ---- | ------- | ------- |
| `argocd-config` | -3 | default | Self-manages ArgoCD CM/RBAC + AppProjects |
| `external-secrets` | -2 | platform | External Secrets Operator |
| `vault` | -1 | apps | Vault HA Raft |
| `cnpg-operator` | -1 | platform | CloudNativePG operator |
| `rabbitmq-operator` | -1 | platform | RabbitMQ Cluster Operator |
| `dragonfly-operator` | -1 | platform | Dragonfly operator |
| `network-policies` | 0 | platform | Default-deny + namespace policies |
| `kube-prometheus-stack` | 1 | observability | Scrape engine → VM remote_write |
| `victoria-metrics` | 0 | observability | Metrics backend (vmcluster + vmalert) |
| `loki` | 0 | observability | Logs backend (Hetzner S3) |
| `tempo` | 0 | observability | Traces backend (Hetzner S3) |
| `alloy` | 1 | observability | Unified OTel collector (DaemonSet) |
| `grafana` | 2 | observability | UI + OIDC to Authentik |
| `authentik-db` | 0 | data | CNPG Cluster for Authentik state |
| `cnpg-business` | 0 | data | Business PostgreSQL Cluster |
| `dragonfly-cache` | 0 | data | Dragonfly CR |
| `rabbitmq-cluster` | 0 | data | RabbitmqCluster CR |
| `authentik` | 2 | apps | Authentik Helm release |
| `vault-config` | 5 | apps | Vault OIDC + policies bootstrap Job |
| `bootstrap-secrets` | 2 | platform | ExternalSecret manifests (Vault → k8s Secrets) |
| `pdbs` | 2 | platform | PodDisruptionBudgets for stateful + monitoring |
| `grafana-dashboards` | 3 | observability | Dashboards as ConfigMaps |

## Bootstrapping a new cluster

1. Provision with Terraform (`nexora-infra`). The module installs:
   - Talos cluster.
   - `cert-manager` + Cloudflare ClusterIssuer.
   - `traefik` Ingress controller (Hetzner LoadBalancer).
   - `argo-cd` with admin password in Terraform output
     `argocd_admin_password`.
2. Verify the baseline is healthy:

   ```bash
   kubectl get pods -n cert-manager
   kubectl get pods -n traefik
   kubectl get pods -n argocd
   kubectl get clusterissuer
   ```

3. Apply the root Application:

   ```bash
   kubectl apply -n argocd -f clusters/develop/root.yaml
   ```

4. Root Application syncs `clusters/develop/apps/*.yaml`. Each leaf
   Application syncs its own sources. Sync-wave annotations keep
   operators ahead of their CRs.
5. Seed bootstrap secrets in Vault — runbook lives in
   `clusters/develop/platform/secrets/README.md` and
   `clusters/develop/platform/vault/README.md`. Without this step,
   `bootstrap-secrets` Application stays in `SecretSyncedError`.

Architectural context — `nexora-docs/adr/infra/`.

## CI

`.github/workflows/lint.yml` runs `yamllint` and `kubeconform` on every
PR + push to `main`. `helm template` rendering is documented as a TODO
in the workflow and intentionally not enabled yet.
