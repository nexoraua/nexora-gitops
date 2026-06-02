# DR scaffolding — Hetzner HEL1 (Helsinki)

**State: COLD STANDBY. No `clusters/production/apps-dr/dr-hel1.yaml` parent
Application is applied; nothing in this tree reconciles at day-1.**

This folder mirrors the FSN1 production layout as a cold-standby
**async** replica region (RPO target ≤ 5 min, RTO defined by the
activation runbook below). Every workload manifest in this tree is
either set to `replicas: 0` / `instances: 0` or its parent Application
is intentionally absent, so the day-0 diff between cold spec and live
spec is bounded: at activation we flip replica counts and commit ONE
new parent Application, rather than write a tree from scratch under
pressure.

HEL1 is the geographically-distant secondary DR target; NBG1 is the
primary (low-latency, same DC complex) DR candidate. The two DR
regions are independent — losing either one does not affect the
other or the active FSN1 region.

## Region constants

- Hetzner location: HEL1 (Helsinki)
- Role: async streaming replica of FSN1
- CIDR: `10.62.0.0/16` (nodes `10.62.1.0/24`, services
  `10.62.8.0/21`, pods `10.62.16.0/20`)
- Object Storage endpoint: `https://hel1.your-objectstorage.com`
- Argo CD destination name: `production-hel1`
- Hetzner LB name (when provisioned): `nexora-ingress-production-hel1`
- Tailscale tags: `tag:k8s,tag:nexora-production-hel1`
- Tailscale advertised route: `10.62.0.0/16`
- Hostnames behind Cloudflare:
  - `auth-hel1.nxua.dev` (Authentik)
  - `grafana-hel1.nxua.dev`
  - `vmui-hel1.nxua.dev`
  - `vault-hel1.nxua.dev`
  - `argocd-hel1.nxua.dev` (only if dedicated DR Argo CD runs here)
  - `hubble-hel1.nxua.dev`
  - `rabbitmq-hel1.nxua.dev`
- Hetzner Object Storage buckets:
  - `nexora-cnpg-backups-production-hel1` (business CNPG)
  - `nexora-cnpg-backups-authentik-production-hel1` (authentik CNPG)
  - `nexora-loki-production-hel1` (logs)
  - `nexora-tempo-production-hel1` (traces)
- Vault KV path prefix: `kv/nexora/production-hel1/*`
- CNPG cluster names:
  - `nexora-business-production-hel1`
  - `nexora-authentik-production-hel1`
  - Both replicate from FSN1 via tailnet RW hostnames
    `nexora-business-production-rw.fsn1.tailnet.nxua.ts.net` and
    `nexora-authentik-production-rw.fsn1.tailnet.nxua.ts.net`.

## What this region SHARES with FSN1 (single global source of truth)

- **AWS KMS Transit unseal key**: `alias/nexora-transit-production`
  (eu-central-1). All Vault clusters in the production family use the
  same KMS key on purpose — root-of-trust is global.
- **AWS S3 Object-Lock CNPG buckets**:
  `nexora-cnpg-backups-production-dr` and
  `nexora-cnpg-backups-authentik-production-dr` (single global WORM
  copies). The rclone CronJob that writes to them runs ONLY from the
  active FSN1 region; this DR region does NOT mint its own AWS
  Object-Lock buckets and does NOT run a duplicate rclone CronJob.
- **Cloudflare zone**: `nxua.dev`. Same cert-manager `letsencrypt-prod`
  ClusterIssuer name + DNS-01 solver.

## Trigger to activate (per ADR-I-0003)

Flip on when ANY of:

- Hetzner FSN1 region-wide outage observed > 2h, OR
- Monthly active users > 50k, OR
- Explicit business decision (board / CTO sign-off).

## Activation steps

1. Run the Terraform workspace at
   `nexora-infra/environments/production-hel1/`. Provisions the Talos
   cluster, Hetzner network `nexora-production-hel1` (10.62.0.0/16),
   firewall, LB `nexora-ingress-production-hel1`, IAM role for Vault
   KMS unseal, OAuth keys.
2. Register the new cluster in the central Argo CD (running in FSN1)
   as a secondary cluster with name `production-hel1`.
3. Seed Vault KV under `kv/nexora/production-hel1/*` with the regional
   credentials (replicating from FSN1 layout — see
   `platform/secrets/cnpg-superuser.yaml` etc. for the path inventory).
4. Apply `clusters/production/apps-dr/dr-hel1.yaml` parent Application
   pointing at `clusters/production/dr-hel1/`. THIS APPLY IS THE
   ACTIVATION FLAG — until this Application is applied, nothing in
   this tree reconciles. (The file is committed under `apps-dr/`, not
   `apps/`, so the root app-of-apps does not pick it up by accident.)
5. Flip replicas from cold values to production sizing:
   - `dr-tailscale-router.yaml` replicas: 0 → 2
   - `dr-traefik-passive.yaml` replicas: 0 → 2 (this file is the only
     Traefik manifest in the region; bump in the same follow-up PR as
     the Cloudflare DNS cutover)
   - `cnpg-cluster-replica.yaml` instances: 0 → 3 (business)
   - `stateful/authentik/cnpg-cluster-replica.yaml` instances: 0 → 3
   - `stateful/rabbitmq/rabbitmq-cluster.yaml` replicas: 0 → 3
   - `stateful/dragonfly/dragonfly.yaml` replicas: 0 → 3
   - `operators/cluster-autoscaler.yaml` replicaCount stays at 0 until
     worker-pool sizing is validated post-activation
6. CNPG bootstraps streaming replicas from the FSN1 primary via
   `pg_basebackup`+ WAL over the tailnet. Wait until lag < 5 s
   steady-state for 24 h.
7. Controlled failover: repoint Cloudflare DNS `*.nxua.dev` (or the
   specific regional hostnames) at the HEL1 LB, then promote the CNPG
   replicas (set `replica.enabled: false` on both clusters).

## File inventory (post-activation)

### Root of `dr-hel1/`

| File | Role at activation |
| ---- | ---- |
| `cnpg-cluster-replica.yaml` | CNPG streaming-replica bootstrap for the business cluster (instances=0 cold; flip to 3) |
| `dr-tailscale-router.yaml` | HEL1 subnet router advertising `10.62.0.0/16` into the tailnet (replicas=0 cold; flip to 2) |
| `dr-traefik-passive.yaml` | Day-1 passive Traefik Deployment + ClusterIP Service (replicas=0 cold) |

### `operators/`

| File | Notes |
| ---- | ---- |
| `cnpg-operator.yaml` | CloudNativePG operator (Helm); destination `production-hel1` |
| `rabbitmq-operator.yaml` | RabbitMQ Cluster Operator |
| `dragonfly-operator.yaml` | Dragonfly Operator |
| `piraeus-operator.yaml` | LINSTOR CSI operator (CRDs + operator) |
| `cert-manager.yaml` | Multi-source: jetstack chart + regional `platform/cert-manager/` |
| `external-secrets.yaml` | ESO controller (HA, system pool) |
| `hcloud-csi.yaml` | hcloud-volumes StorageClass for Vault dataStorage |
| `metrics-server.yaml` | metrics-server HA (kubelet-insecure-tls Talos default) |
| `cluster-autoscaler.yaml` | Scaffolded with `replicaCount: 0`; HCLOUD_REGION=hel1 |

### `platform/`

| Path | Notes |
| ---- | ---- |
| `linstor-config.yaml` | Argo CD Application pointing at the FSN1 LINSTOR manifests (StorageClasses + LinstorCluster) — same shape, regional Talos overrides applied by Terraform |
| `network-policies/default-deny.yaml` | Verbatim copy of FSN1 |
| `network-policies/operator-ingress-deny.yaml` | Verbatim copy |
| `network-policies/platform-ingress-deny.yaml` | Verbatim copy |
| `network-policies/platform-egress-deny.yaml` | Hetzner OS FQDN flipped to `hel1.your-objectstorage.com` |
| `network-policies/stateful-egress.yaml` | Regional OS FQDN + cross-region streaming allow to `10.60.0.0/16:5432` (FSN1 cluster CIDR); AWS S3 CronJob egress intentionally omitted |
| `network-policies/dragonfly-allow.yaml` | Verbatim copy |
| `network-policies/vault-allow.yaml` | Verbatim copy |
| `pdbs/cnpg-pdbs.yaml` | Selectors retargeted to `nexora-business-production-hel1` / `nexora-authentik-production-hel1` |
| `pdbs/rabbitmq-pdbs.yaml` | Verbatim copy |
| `pdbs/dragonfly-pdbs.yaml` | Verbatim copy |
| `pdbs/vault-pdbs.yaml` | Verbatim copy |
| `pdbs/traefik-pdbs.yaml` | Verbatim copy |
| `pdbs/authentik-pdbs.yaml` | Verbatim copy |
| `pdbs/monitoring-pdbs.yaml` | Verbatim copy |
| `secrets/cnpg-superuser.yaml` | Regional Vault paths; adds `cnpg-replication` ExternalSecret for streaming auth |
| `secrets/cnpg-backup-s3.yaml` | Regional Vault path + regional Hetzner Object Storage credentials |
| `secrets/loki-tempo-s3.yaml` | Regional Vault path |
| `secrets/rabbitmq-credentials.yaml` | Regional Vault path |
| `secrets/grafana-admin.yaml` | Regional Vault path |
| `secrets/grafana-oidc.yaml` | OIDC client points at `auth-hel1.nxua.dev` |
| `secrets/argocd-oidc.yaml` | Regional OIDC client, used only if dedicated DR Argo CD runs here |
| `secrets/tailscale-oauth.yaml` | Regional Vault path; tags scoped to `tag:nexora-production-hel1` |
| `secrets/authentik-bootstrap.yaml` | PG host is the regional CNPG service `nexora-authentik-production-hel1-rw` |
| `secrets/cloudflare-access.yaml` | JWT audience tags for `*-hel1.nxua.dev` hosts |
| `secrets/alertmanager-config.yaml` | Slack channels `#nexora-alerts-hel1` (regional default) / `#nexora-alerts-critical` (shared; region carried in alert labels) |
| `argocd/appprojects.yaml` | Verbatim copy (used only if dedicated DR Argo CD runs here) |
| `cert-manager/issuers.yaml` | Same `letsencrypt-prod` + DNS-01 Cloudflare issuers; zone unchanged |
| `traefik/middlewares.yaml` | Verbatim copy (rate limit + secure headers) |
| `vault/external-secrets.yaml` | ClusterSecretStore `vault-kv` pointing at the in-cluster Vault |
| `vault/ingress.yaml` | IngressRoute for `vault-hel1.nxua.dev` + cert-manager Certificate + cloudflare-jwt-assertion Middleware |
| `vault/_pending-authentik-oidc/oidc-bootstrap.yaml` | Region OIDC bootstrap Job — stays under `_pending-` until Authentik OIDC is live on `auth-hel1.nxua.dev` |
| `alloy/configmap.yaml` | Same OTel pipeline; `cluster` log label flipped to `production-hel1` |
| `alloy/rbac.yaml` | Verbatim copy |
| `monitoring/cnpg-backup-alerts.yaml` | Same alert expressions; severity labels carry `region: hel1` |
| `monitoring/dr-sync-alerts.yaml` | Replication-lag rules (RPO ≤ 5 min); AWS S3 sync CronJob alerts intentionally disabled |
| `hubble/ingress.yaml` | IngressRoute for `hubble-hel1.nxua.dev` |

### `stateful/`

| Path | Notes |
| ---- | ---- |
| `authentik/cnpg-cluster-replica.yaml` | Streaming replica of `nexora-authentik-production` — `nexora-authentik-production-hel1` (instances=0 cold) |
| `vault/vault.yaml` | Vault HA chart (ha.replicas: 3); reuses the global Vault unseal KMS key |
| `vault/config.yaml` | Argo CD Application wrapping `platform/vault/` (ClusterSecretStore + Ingress + pending OIDC) |
| `rabbitmq/rabbitmq-cluster.yaml` | RabbitmqCluster (replicas=0 cold) — no cross-region federation |
| `dragonfly/dragonfly.yaml` | Dragonfly (replicas=0 cold) — recreated empty on activation |

The business CNPG replica `cnpg-cluster-replica.yaml` lives at the
ROOT of `dr-hel1/`, not under `stateful/postgresql/`, to avoid churn on
the file that was committed first.

### `observability/`

| File | Notes |
| ---- | ---- |
| `victoria-metrics.yaml` | vmcluster (replicationFactor=2, vmstorage 3) on linstor-r1 |
| `loki.yaml` | SimpleScalable Loki against `nexora-loki-production-hel1` |
| `tempo.yaml` | tempo-distributed against `nexora-tempo-production-hel1` |
| `grafana.yaml` | Ingress `grafana-hel1.nxua.dev`, OIDC against `auth-hel1.nxua.dev` |
| `grafana-dashboards.yaml` | Reuses `clusters/develop/platform/grafana-dashboards/` JSON |
| `alloy.yaml` | DaemonSet + StatefulSet OTLP gateway; points at regional `platform/alloy/` |
| `monitoring-rules.yaml` | Wraps `platform/monitoring/` |
| `hubble-ingress.yaml` | Wraps `platform/hubble/` |

### `auth/`

| File | Notes |
| ---- | ---- |
| `authentik.yaml` | Helm chart; ingress `auth-hel1.nxua.dev`, PG `nexora-authentik-production-hel1-rw` |
| `authentik-db.yaml` | Argo CD Application wrapping `stateful/authentik/` |

### `apps/`

Intentionally absent. The parent `clusters/production/apps-dr/dr-hel1.yaml`
Application targets the whole `clusters/production/dr-hel1/` tree with
`directory.recurse: true`, so every `Application`/`ApplicationSet` under
`operators/`, `observability/`, `platform/`, `stateful/`, and `auth/` is
picked up directly — no wrapper layer is needed (matches the NBG1 shape).

## Bucket layout post-activation

- Regional CNPG backups go to Hetzner Object Storage in HEL1
  (`nexora-cnpg-backups-production-hel1` + the authentik bucket). Until
  the CNPG cluster is promoted (`replica.enabled: false`), these
  buckets stay empty — CNPG does not run base backups from a replica.
- The single global AWS S3 Object-Lock COMPLIANCE bucket
  (`nexora-cnpg-backups-production-dr`) keeps receiving the
  authoritative immutable copy from the active region's rclone
  CronJob. No second CronJob runs from HEL1.
- Loki / Tempo buckets receive THIS region's logs/traces (no
  cross-region object replication day-1; Grafana queries each region's
  Loki gateway / Tempo query-frontend independently).

## Intentionally absent at day-1 (skip list)

- `clusters/production/apps-dr/dr-hel1.yaml` parent Application — it
  is committed but NOT applied at day-1; applying it is the activation
  flag (the root app-of-apps under `apps/` does not pick up files
  under `apps-dr/`).
- ArgoCD Helm install in this cluster — the central Argo CD in FSN1
  reconciles `production-hel1` as a secondary destination.
- AWS Object-Lock bucket `nexora-cnpg-backups-production-hel1-dr` —
  the AWS COMPLIANCE bucket is global per dataset.
- AWS S3 cross-region rclone CronJob — runs only in the active region.
- `platform/linstor/talos-overrides.yaml` is pulled into the Talos
  machineConfig via Terraform (`nexora-infra/environments/production-hel1/`),
  not applied by Argo CD here.
- Cross-region RabbitMQ federation / Dragonfly replication.
- `develop` / `staging` config drift — DR is a production-only feature.
