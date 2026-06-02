# DR scaffolding — Hetzner NBG1 (Nuremberg)

**State: COLD STANDBY. No parent Application targets this directory.**

NBG1 is the primary DR candidate from the FSN1 active region: low latency,
same DC complex, same Hetzner backbone. NBG1 carries the role of
**sync-replica** for the CNPG business + Authentik clusters (streaming
from FSN1 via the Tailscale tailnet); HEL1 carries the
geographically-distant async-replica role.

Every Deployment / StatefulSet / Cluster lives at `replicas=0` /
`instances=0`. Argo CD does NOT reconcile anything in this directory
until `clusters/production/apps-dr/dr-nbg1.yaml` lands (per ADR-I-0003 —
the commit of that parent Application is the activation flag).

## Region constants

| Knob | Value |
| --- | --- |
| CIDR (cluster) | `10.61.0.0/16` |
| node / svc / pod CIDR | `10.61.1.0/24` / `10.61.8.0/21` / `10.61.16.0/20` |
| Object Storage | `https://nbg1.your-objectstorage.com` |
| Hetzner LB | `nexora-ingress-production-nbg1` |
| Tailscale tag | `tag:k8s,tag:nexora-production-nbg1` |
| Tailscale advertised | `10.61.0.0/16` (own region only) |
| Argo CD destination | `production-nbg1` (registered in FSN1 Argo CD) |
| Vault KV prefix | `kv/nexora/production-nbg1/*` |
| Vault unseal | shared global `alias/nexora-transit-production` |
| AWS Object-Lock bucket | `nexora-cnpg-backups-production-dr` (single global) — NO regional bucket |

Hostnames are uniformly `<service>-nbg1.nxua.dev`:
`auth-nbg1`, `grafana-nbg1`, `vmui-nbg1`, `vault-nbg1`,
`argocd-nbg1`, `hubble-nbg1`, `rabbitmq-nbg1`.

Regional Hetzner buckets:

- `nexora-cnpg-backups-production-nbg1` (business CNPG)
- `nexora-cnpg-backups-authentik-production-nbg1` (Authentik CNPG)
- `nexora-loki-production-nbg1`
- `nexora-tempo-production-nbg1`

## Directory layout

```text
dr-nbg1/
├── README.md                                  this file
│
├── operators/                                 Argo CD Application wrappers
│   ├── cnpg-operator.yaml                     replicaCount: 0
│   ├── rabbitmq-operator.yaml                 (kustomize bundle, no replicas knob)
│   ├── dragonfly-operator.yaml                (manifests bundle)
│   ├── piraeus-operator.yaml                  (manifests bundle)
│   ├── cert-manager.yaml                      controller/webhook/cainjector replicaCount=0
│   ├── external-secrets.yaml                  controller/webhook/certCtrl replicaCount=0
│   ├── hcloud-csi.yaml                        controller replicaCount=0
│   ├── metrics-server.yaml                    replicas=0
│   └── cluster-autoscaler.yaml                replicas=0 (stays 0 even on activation)
│
├── platform/
│   ├── linstor-config.yaml                    Argo CD Application -> platform/linstor/
│   ├── linstor/
│   │   ├── cluster.yaml                       LinstorCluster (controller + CSI)
│   │   ├── satellites.yaml                    pool-workers / pool-system / pool-stateful
│   │   └── storageclass.yaml                  linstor-r1 (default) + linstor-r3
│   ├── network-policies/
│   │   ├── default-deny.yaml                  verbatim from FSN1
│   │   ├── operator-ingress-deny.yaml         verbatim
│   │   ├── platform-ingress-deny.yaml         verbatim
│   │   ├── platform-egress-deny.yaml          Hetzner OS endpoint -> NBG1
│   │   ├── stateful-egress.yaml               NBG1 OS + tailnet 10.60.0.0/16 (FSN1) for CNPG streaming
│   │   ├── dragonfly-allow.yaml               verbatim
│   │   └── vault-allow.yaml                   verbatim
│   ├── pdbs/
│   │   ├── cnpg-pdbs.yaml                     selectors -> *-production-nbg1
│   │   ├── rabbitmq-pdbs.yaml                 verbatim
│   │   ├── dragonfly-pdbs.yaml                verbatim
│   │   ├── vault-pdbs.yaml                    verbatim
│   │   ├── traefik-pdbs.yaml                  verbatim
│   │   ├── authentik-pdbs.yaml                verbatim
│   │   └── monitoring-pdbs.yaml               verbatim
│   ├── secrets/                               every ExternalSecret -> kv/nexora/production-nbg1/*
│   │   ├── cnpg-superuser.yaml
│   │   ├── cnpg-backup-s3.yaml
│   │   ├── loki-tempo-s3.yaml
│   │   ├── rabbitmq-credentials.yaml
│   │   ├── grafana-admin.yaml
│   │   ├── grafana-oidc.yaml                  Authentik client -> auth-nbg1.nxua.dev
│   │   ├── argocd-oidc.yaml
│   │   ├── tailscale-oauth.yaml               tag:nexora-production-nbg1
│   │   ├── authentik-bootstrap.yaml           PG host -> *-production-nbg1-rw
│   │   ├── cloudflare-access.yaml             JWT AUD for *-nbg1.nxua.dev
│   │   └── alertmanager-config.yaml           Slack channel #nexora-alerts-nbg1
│   ├── cert-manager/
│   │   └── issuers.yaml                       verbatim letsencrypt-prod/staging on nxua.dev zone
│   ├── traefik/
│   │   └── middlewares.yaml                   verbatim (rate-limit-global, secure-headers)
│   ├── vault/
│   │   ├── external-secrets.yaml              ClusterSecretStore vault-kv -> regional
│   │   ├── ingress.yaml                       host vault-nbg1.nxua.dev
│   │   └── _pending-authentik-oidc/
│   │       └── oidc-bootstrap.yaml            stays here until Authentik OIDC live
│   ├── alloy/
│   │   ├── configmap.yaml                     cluster label production-nbg1
│   │   └── rbac.yaml                          verbatim
│   ├── monitoring/
│   │   ├── cnpg-backup-alerts.yaml            verbatim (matches via labels)
│   │   └── dr-sync-alerts.yaml                streaming-lag alerts vs FSN1 (no S3 sync alerts here)
│   └── hubble/
│       └── ingress.yaml                       host hubble-nbg1.nxua.dev
│
├── stateful/
│   ├── postgresql/                            BUSINESS CNPG replica
│   │   └── (canonical file lives at dr-nbg1/cnpg-cluster-replica.yaml — see below)
│   ├── authentik/
│   │   └── cnpg-cluster-replica.yaml          instances=0; replicates FSN1 authentik PG
│   ├── vault/
│   │   ├── vault.yaml                         ha.replicas=3 in chart, effective 0 (no parent App)
│   │   └── config.yaml                        Argo CD Application -> platform/vault/
│   ├── rabbitmq/
│   │   └── rabbitmq-cluster.yaml              replicas=0; no cross-region federation
│   └── dragonfly/
│       └── dragonfly.yaml                     replicas=0; no cross-region replication
│
├── observability/
│   ├── victoria-metrics.yaml                  Application; single-region VM cluster
│   ├── loki.yaml                              bucket nexora-loki-production-nbg1
│   ├── tempo.yaml                             bucket nexora-tempo-production-nbg1
│   ├── grafana.yaml                           host grafana-nbg1.nxua.dev
│   ├── grafana-dashboards.yaml                shared dashboards from develop tree
│   ├── alloy.yaml                             ApplicationSet daemonset + otlp-gateway
│   ├── monitoring-rules.yaml                  loader for platform/monitoring/
│   └── hubble-ingress.yaml                    loader for platform/hubble/
│
├── auth/
│   ├── authentik.yaml                         host auth-nbg1.nxua.dev, PG -> *-nbg1-rw
│   └── authentik-db.yaml                      loader for stateful/authentik/
│
├── apps/                                      INTENTIONALLY EMPTY day-1
│   (Application manifests for traefik / traefik-config / argocd-config /
│   bootstrap-secrets live in clusters/production/apps-dr/ and are managed
│   by a separate workflow. The parent dr-nbg1.yaml Application also
│   lands in apps-dr/ — never here.)
│
├── cnpg-cluster-replica.yaml                  BUSINESS CNPG replica (nexora-business-production-nbg1)
├── dr-tailscale-router.yaml                   subnet router StatefulSet; replicas=0, advertises 10.61.0.0/16
└── dr-traefik-passive.yaml                    Deployment+Service; replicas=0, type ClusterIP (no LB attach)
```

> The CNPG **business** replica is kept at the root of `dr-nbg1/` as
> `cnpg-cluster-replica.yaml` to avoid churn on the file already committed.
> Argo CD readers should treat it as if it lived at
> `stateful/postgresql/cnpg-cluster-replica.yaml` — same shape, same
> activation rules.

## What stays at the COLD baseline

| Component | Cold value | Activation value |
| --- | --- | --- |
| Tailscale subnet router (`dr-tailscale-router.yaml`) | `replicas: 0` | `replicas: 2` |
| Traefik passive edge (`dr-traefik-passive.yaml`) | `replicas: 0`, Service `ClusterIP` | `replicas: 2`, Service `LoadBalancer` + annotation `nexora-ingress-production-nbg1` |
| CNPG business replica (`cnpg-cluster-replica.yaml`) | `instances: 0` | `instances: 3` (sync replica of FSN1) |
| CNPG authentik replica (`stateful/authentik/...`) | `instances: 0` | `instances: 3` |
| RabbitMQ cluster | `replicas: 0` | `replicas: 3` |
| Dragonfly cache | `replicas: 0` | `replicas: 3` |
| Vault HA (`stateful/vault/vault.yaml`) | no parent App = 0 | `ha.replicas: 3` once App lands |
| Operators (cnpg / cert-manager / ESO / metrics-server) | `replicaCount: 0` | `replicaCount: 2` |
| cluster-autoscaler | `replicaCount: 0` | stays 0 until NBG1 worker sizing validated |
| Stateless platform (Grafana / Loki / Tempo / Authentik / Alloy) | no parent App = effective 0 | chart defaults once App lands |

## What is INTENTIONALLY ABSENT day-1

- `clusters/production/apps-dr/dr-nbg1.yaml` — the parent Application
  that targets this directory. Its commit is the activation flag.
- Per-region AWS S3 Object-Lock DR bucket — the WORM bucket
  `nexora-cnpg-backups-production-dr` is a single global target; only the
  FSN1 active region runs the rclone CronJob that writes to it.
- Argo CD itself in the DR cluster — central Argo CD stays in FSN1 and
  reconciles `production-nbg1` as a registered destination (avoids split-
  brain reconciliation, per ADR-I-0003).
- vault-config.yaml KV seed Job for `vault-oidc` — stays under
  `_pending-authentik-oidc/` until Authentik OIDC is live on
  `auth-nbg1.nxua.dev`.

## Activation runbook

1. **Terraform** — bring up Talos + Hetzner LB + Tailscale + Hetzner OS
   buckets via `nexora-infra/environments/production-nbg1/`.
2. **Register cluster** — add `production-nbg1` as a destination in the
   FSN1 Argo CD (Secret with cluster-credentials kind in the `argocd`
   namespace).
3. **Seed Vault** — populate `kv/nexora/production-nbg1/*` (CNPG creds,
   S3 keys, OIDC clients, Tailscale auth key, Cloudflare Access JWT
   audience). The Vault unseal key is the SAME global Transit key
   `alias/nexora-transit-production` as FSN1.
4. **Commit `clusters/production/apps-dr/dr-nbg1.yaml`** — parent
   Application that sweeps this directory. Argo CD starts reconciling
   the operators, platform, and stateful manifests.
5. **Flip replicas** — patch the cold values listed above to their
   activation targets. CNPG streaming replicas come up by basebackup'ing
   from `*-production-rw.fsn1.tailnet.nxua.ts.net`.
6. **DNS repoint** — flip Cloudflare DNS for the regional hostnames to
   the new Hetzner LB IP (`nexora-ingress-production-nbg1`).

See `clusters/production/dr-hel1/README.md` for the geographically-
distant async-replica DR target.
