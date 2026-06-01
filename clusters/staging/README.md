# Staging cluster (Hetzner FSN1)

Single-region sandbox cluster on Hetzner Falkenstein (FSN1). Mirrors
the develop GitOps shape — full operator stack (CloudNativePG,
Dragonfly, RabbitMQ, Vault, Authentik, monitoring, Traefik) — but with
single-replica sizing and shorter retention. The goal is to exercise
the production toolchain (chart versions, Helm values, ArgoCD waves,
NetworkPolicies, ESO+Vault) at the lowest possible cost; data loss in
this environment is tolerated.

## Topology

- Region: Hetzner FSN1 (Falkenstein).
- Base domain: `staging.nxua.dev` (Cloudflare zone `nxua.dev`,
  proxied wildcard `*.staging.nxua.dev` -> Traefik Hetzner LB).
- CIDR: `10.50.0.0/16` (nodes `10.50.1.0/24`, services `10.50.8.0/21`,
  pods `10.50.16.0/20`).
- CNI: Cilium 1.19.1 with WireGuard transparent encryption.
- Node pools (one node per pool):
  - `control-plane-1` cx32 — control-plane.
  - `system-1` CPX21 (tainted nodepool=system) — Vault, Traefik,
    cert-manager, LINSTOR controller, tailscale subnet router.
  - `stateful-1` CPX31 (tainted nodepool=database) — CNPG instances,
    Dragonfly, RabbitMQ, monitoring vmstorage / Loki / Tempo,
    LINSTOR satellite.
  - `worker-1` CPX21 (untainted) — generic workloads.
- Private cluster endpoint: via Tailscale subnet router advertising
  `10.50.0.0/16`. Firewall allows only `127.0.0.1/32` on the public
  control-plane endpoint.

## Per-workload sizing (vs develop)

| Workload | Develop | Staging |
| --- | --- | --- |
| CNPG business | 2 instances, 20Gi data + 5Gi WAL | **1** instance, **10Gi** data + **2Gi** WAL |
| CNPG authentik | 1 instance, 10Gi | 1 instance, **5Gi** |
| RabbitMQ | 1, 10Gi | 1, **5Gi** |
| Dragonfly | 1, 5Gi snapshot, maxmemory 768mb | 1, **2Gi** snapshot, **maxmemory 384mb** |
| Vault | HA raft, **3 replicas**, 10Gi | HA raft, **1 replica**, **5Gi** |
| VictoriaMetrics | vmstorage 1, 20Gi, retention **13mo** | vmstorage 1, 20Gi, retention **1mo** |
| Loki | 20Gi | **10Gi**, retention 7d |
| Tempo | 20Gi, retention 7d | **10Gi**, retention **3d** |
| Grafana | 5Gi | **2Gi** |
| Authentik server/worker | 1+1 | 1+1 (smaller resource caps) |
| Traefik | 1 replica, lb11 | 1 replica, lb11 |

Backup retention: 7 days (vs 30d on develop / production).

## Bootstrap

After `terraform apply` on `environments/staging` in `nexora-infra`:

1. Apply the root Application:
   ```bash
   kubectl apply -n argocd -f clusters/staging/root.yaml
   ```
2. Initialise Vault and seed bootstrap secrets — see
   `platform/secrets/README.md` for the full runbook.
3. Apply the Authentik blueprint to register Vault as an OIDC client,
   copy the generated `client_id` / `client_secret` into Vault KV, then
   move `platform/vault/_pending-authentik-oidc/oidc-bootstrap.yaml`
   into `platform/vault/` to enable Vault OIDC.

## DO NOT modify outside this directory

This tree is independent of `clusters/develop/` and
`clusters/production/`. Promotion from develop happens by hand-crafted
PR (chart version bumps + sizing review) — never by `cp -r`.
