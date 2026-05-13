# Production cluster (Hetzner FSN1 primary + NBG1 sync + HEL1 DR)

Production-grade multi-region setup. Differences from `staging`:

- **CloudNativePG `nexora-business-prod`** — sync replication FSN1↔NBG1
  (synchronous_commit=remote_apply), async standby HEL1.
  Separate clusters `nexora-authentik-prod`, `nexora-quartz-prod` for
  data isolation.
- **Dragonfly** — multi-region replica setup (3+3 with PodAntiAffinity
  per region).
- **RabbitMQ** — 3-node HA cluster with mirrored queues + federation
  link FSN1↔NBG1.
- **Vault** — HA Raft (3 replicas, PodAntiAffinity per region);
  auto-unseal via cloud KMS where available, otherwise Shamir 5-of-3
  with disciplined unseal runbook.
- **VictoriaMetrics** — vmstorage 3× with `replicationFactor=2`.
- **Object Lock Compliance mode** on `nexora-kyc-prod` and
  `nexora-audit-prod` Hetzner buckets (7-year retention).
- **Pod-security `restricted`** everywhere.
- **Argo Rollouts canary** on `Nexora.Api` and `Nexora.Admin`:
  5% → 25% → 100% with auto-rollback on VM error rate / p95 latency.
- **NetworkPolicies default-deny + Cilium ClusterMesh** for
  cross-region pod-to-pod over Hetzner vSwitch.

This is currently a placeholder. Copy from `clusters/staging/` once
that is fully wired, and apply the diffs above.

DR site `clusters/production/apps/dr/` keeps Authentik and VM cold
standby manifests with `replicas: 0`; failover runbook scales them up
and switches Cloudflare DNS — see ADR-I-0001 and ADR-I-0002 in
`nexora-docs`.
