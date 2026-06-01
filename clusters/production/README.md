# Production cluster (Hetzner FSN1)

Single-region day-1 (per ADR-I-0003). NBG1 + HEL1 manifests are
scaffolded under `dr-nbg1/` and `dr-hel1/` but no Application targets
them.

## Region + addressing

- Region: Hetzner FSN1 (Falkenstein)
- Base domain: `nxua.dev`
- Network CIDR: `10.60.0.0/16` (nodes `10.60.1.0/24`, services
  `10.60.8.0/21`, pods `10.60.16.0/20`)
- CNI: Cilium 1.19.1 with WireGuard transparent encryption
- Private cluster endpoint: Tailscale subnet router (2 replicas)
  advertising `10.60.0.0/16`
- Firewall allowed IPs: `127.0.0.1/32` (public Internet has zero
  cluster-API ingress; all admin access via Tailscale)

## Node pools + placement groups

| Pool | Instance | Count | Placement group | Taints | Purpose |
| ---- | -------- | ----- | --------------- | ------ | ------- |
| control-plane | CCX13 | 3 | `nexora-prod-cp-pg` (spread) | `node-role.kubernetes.io/control-plane:NoSchedule` | etcd Raft quorum |
| stateful | CCX23 | 3 | `nexora-prod-db-pg` (spread) | `nodepool=database:NoSchedule` | CNPG 3-instance sync replicas + LINSTOR satellites (replicationFactor=3) |
| system | CCX13 | 2 | `nexora-prod-sys-pg` (spread) | `nodepool=system:NoSchedule` | Traefik, ArgoCD, cert-manager, ESO, Vault leader pods, monitoring control plane |
| workers | CPX31 | 2 | `nexora-prod-wk-pg` (spread) | none | General workload tier; cluster-autoscaler scaffolded with replicas=0 |

## Layout

```text
clusters/production/
  root.yaml                            # ArgoCD app-of-apps root
  apps/                                # one Application per workload
  platform/
    argocd/                            # AppProjects (platform, data, observability, apps)
    linstor/                           # LinstorCluster + satellites + r1/r3 StorageClasses
    network-policies/                  # default-deny + Cilium toFQDNs allowlists
    pdbs/                              # PodDisruptionBudgets
    secrets/                           # ExternalSecret manifests (Vault -> K8s)
    vault/                             # ClusterSecretStore + Vault UI ingress
    cert-manager/                      # ClusterIssuers
    traefik/                           # Middlewares (rate limit, secure headers)
    tailscale/                         # Subnet router StatefulSet (2 replicas)
    alloy/                             # Alloy config + RBAC + OTLP gateway Service
    monitoring/                        # VMRules
    hubble/                            # Hubble UI ingress
  stateful/
    postgresql/                        # CNPG business (3 instances, linstor-r3, sync repl)
                                       # + cross-cloud DR sync CronJob (ADR-I-0005)
    authentik/                         # CNPG authentik (3 instances, linstor-r3, sync repl)
                                       # + cross-cloud DR sync CronJob
    rabbitmq/                          # 3-broker quorum-queue cluster (linstor-r1)
    dragonfly/                         # 3-replica emulated-cluster cache (linstor-r1)
  dr-nbg1/                             # COLD SCAFFOLDING — no Application targets it
  dr-hel1/                             # COLD SCAFFOLDING — no Application targets it
```

## Immutable backup DR (ADR-I-0005)

barman writes a MUTABLE copy to Hetzner Object Storage (the primary
PITR window, 30d). Two rclone CronJobs mirror new objects to AWS S3 in
eu-central-1 with **Object Lock COMPLIANCE 35d + SSE-KMS** using
`alias/nexora-backups-production`. The AWS copy is the trustworthy WORM
artifact — Hetzner Object Lock GOVERNANCE mode is too weak for fintech
durability (a delete_object without BypassGovernanceRetention still
succeeds).

| Source bucket (Hetzner, mutable, 30d) | DR bucket (AWS, COMPLIANCE 35d, SSE-KMS) | Sync schedule |
| ------------------------------------- | --------------------------------------- | ------------- |
| `nexora-cnpg-backups-production` | `nexora-cnpg-backups-production-dr` | `0 5 * * *` |
| `nexora-cnpg-backups-authentik-production` | `nexora-cnpg-backups-authentik-production-dr` | `30 5 * * *` |

Manifests: `stateful/postgresql/cnpg-dr-sync.yaml`,
`stateful/authentik/cnpg-dr-sync.yaml`. Alerts: VMRule
`cnpg-dr-sync-alerts` in `platform/monitoring/dr-sync-alerts.yaml`.

## Multi-region scaffolding

DR manifests under `dr-nbg1/` and `dr-hel1/` are sized as cold standby:

- CNPG streaming-replica `Cluster` with `instances: 0`
- Tailscale subnet router StatefulSet with `replicas: 0`
- Passive Traefik Deployment + ClusterIP Service with `replicas: 0`

No `clusters/production/apps/dr-{nbg1,hel1}.yaml` exists, so Argo CD
does not reconcile these directories at day-1. Activation requires:

1. New Terraform workspace under `nexora-infra/environments/` to
   provision the target region's Talos cluster + Object Storage buckets.
2. Add the corresponding `apps/dr-<region>.yaml` Application that
   targets the new cluster (registered in Argo CD as a secondary
   destination).
3. Flip the `replicas` fields in this folder from `0` to the production
   value.

See `dr-hel1/README.md` and `dr-nbg1/README.md` for the full
activation runbook and ADR-I-0003 triggers.

## Bootstrap order

1. `kubectl apply -n argocd -f clusters/production/root.yaml`
2. Vault: init, Shamir unseal (3 of 5), migrate to AWS KMS auto-unseal,
   seed every KV path listed in `platform/secrets/README.md`.
3. The root Application syncs every wave automatically; the OIDC
   bootstrap Job moves out of `platform/vault/_pending-authentik-oidc/`
   once Authentik's `vault-oidc` provider is created and its
   credentials are in `kv/nexora/production/vault-oidc`.
