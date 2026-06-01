# DR scaffolding — Hetzner HEL1 (Helsinki)

**State: COLD STANDBY. No Application targets this directory.**

This folder contains manifests sized for an inactive DR region. They are
committed so the day-0 activation diff is bounded (review the deltas
between this region's cold spec and the live FSN1 spec, not a new tree
written from scratch under pressure).

## Trigger to activate (per ADR-I-0003)

Flip on when ANY of:

- Hetzner FSN1 region-wide outage observed >2h, OR
- Monthly active users >50k, OR
- Explicit business decision (board / CTO sign-off).

## Activation steps

1. Provision a Talos cluster in HEL1 via the dedicated Terraform
   workspace (`nexora-infra/environments/production-hel1/`).
2. Add `clusters/production/apps/dr-hel1.yaml` Application pointing at
   `clusters/production/dr-hel1/` and managing the HEL1 cluster as a
   destination (`spec.destination.name: production-hel1`, registered in
   Argo CD as a secondary cluster).
3. Switch replicas in the manifests below from `0` to the production
   values (mirrors `clusters/production/stateful/*` and the Traefik
   `replicaCount: 2`).
4. Bootstrap CNPG streaming replica from the primary
   (`bootstrap.pg_basebackup.source: nexora-business-production`) over
   the cross-region tailnet route advertised by
   `dr-tailscale-router.yaml`.
5. Once replica lag <5s steady-state for 24h, perform a controlled
   failover: re-point Cloudflare DNS (`*.nxua.dev` proxied A) at the
   HEL1 LB, then promote the CNPG replica.

## Cold manifests in this folder

| File | Role at activation |
| ---- | ---- |
| `cnpg-cluster-replica.yaml` | CNPG streaming-replica bootstrap pointing at the FSN1 primary (replicas=0 by default) |
| `dr-tailscale-router.yaml` | HEL1 subnet router advertising the HEL1 CIDR into the tailnet so CNPG replication traverses the tailnet (replicas=0) |
| `dr-traefik-passive.yaml` | Passive Traefik Deployment + LoadBalancer Service (replicas=0); flips to the active edge once Cloudflare DNS is repointed |

## Bucket layout post-activation

- CNPG backups stay in the FSN1 buckets — barman is single-region per
  cluster; the HEL1 replica reads its initial base backup over
  pg_basebackup, then keeps up via streaming replication.
- The AWS S3 DR copy (Object Lock COMPLIANCE) continues to be written
  from the active region's rclone CronJob — there is no need to run a
  second CronJob from HEL1.
