# DR activation runbook — Hetzner HEL1 (async-replica)

**Audience:** on-call SRE + platform engineer with `argocd` admin,
Hetzner Cloud API token, Vault root token (sealed in 1Password), AWS
IAM `nexora-platform-admin`, Cloudflare API token.

**Triggers (per ADR-I-0003):** activate HEL1 when —

- NBG1 is already active or compromised (HEL1 is the geographically
  distant secondary), OR
- A full Hetzner-DE outage (FSN1 + NBG1 both unreachable) is observed
  for >30min, OR
- Regulatory / data-residency requirement demands EU-North.

HEL1's normal posture is **async-replica** — higher latency to FSN1
(~40ms one-way) than NBG1 (~10ms), so streaming-replica lag will be
larger and `pg_basebackup` will take longer. Sync replication from FSN1
is NOT enabled to HEL1 by default; it stays asynchronous so FSN1 write
latency is not held hostage by transcontinental RTT.

**Estimated wall-clock:** 5–7h from `terraform apply` to DNS flip, of
which ~2h is `pg_basebackup` of the business CNPG cluster.

**Roles required:**

- Region HEL1, role **async-replica** (geographically distant —
  secondary DR target).
- Cluster CIDR `10.62.0.0/16` (nodes `10.62.1.0/24`, services
  `10.62.8.0/21`, pods `10.62.16.0/20`).

---

## Phase 0 — Pre-flight (T-24h, when feasible)

- [ ] Confirm the active primary (FSN1 or NBG1) is healthy enough to
      source a `pg_basebackup`. If both are down, escalate to
      PITR-from-AWS runbook (`docs/runbooks/cnpg-pitr-from-aws.md`) and
      bootstrap HEL1 from the AWS Object Lock copy instead.
- [ ] Confirm Hetzner HEL1 has CCX13/CCX23/CPX31 inventory.
- [ ] Confirm AWS KMS Transit key `alias/nexora-transit-production` is
      enabled and reachable (`aws kms describe-key`).
- [ ] Confirm Cloudflare API token has DNS edit on `nxua.dev`.
- [ ] Tag the active branch in `nexora-gitops`:
      `git tag -a dr-hel1-pre-activation -m "..." && git push origin --tags`.
- [ ] Open incident channel `#inc-dr-hel1-activation` and assign:
      Incident Commander, Communications, Scribe.

---

## Phase 1 — Terraform (T-0)

Workspace: `nexora-infra/environments/production-hel1/`.

- [ ] `tofu init -upgrade`
- [ ] `tofu plan -out=plan.bin` — sanity-check:
  - 3 control-plane CCX13 in `nexora-prod-hel1-cp-pg` (spread)
  - 3 stateful CCX23 in `nexora-prod-hel1-db-pg` (spread)
  - 2 system CCX13 in `nexora-prod-hel1-sys-pg` (spread)
  - 2 worker CPX31 in `nexora-prod-hel1-wk-pg` (spread)
  - LB `nexora-ingress-production-hel1` (LB11) in HEL1
  - Hetzner Object Storage buckets:
    - `nexora-cnpg-backups-production-hel1`
    - `nexora-cnpg-backups-authentik-production-hel1`
    - `nexora-loki-production-hel1`
    - `nexora-tempo-production-hel1`
  - Tailscale subnet router auth key tagged
    `tag:k8s,tag:nexora-production-hel1` advertising `10.62.0.0/16`
- [ ] `tofu apply plan.bin`
- [ ] Fetch kubeconfig: `tofu output -raw kubeconfig > /tmp/hel1.kubeconfig`
- [ ] `kubectl --kubeconfig=/tmp/hel1.kubeconfig get nodes` — expect 10
      nodes `Ready`.
- [ ] `kubectl --kubeconfig=/tmp/hel1.kubeconfig get pods -A` — Cilium,
      kube-proxy-replacement, hubble-relay all `Running`.

---

## Phase 2 — Vault bring-up + KV seed (T+30min)

The Vault Application is part of `dr-hel1/stateful/vault/` and will be
synced by Argo CD in Phase 5. Pre-seed the KV paths now so the
`ExternalSecret`s resolve on first sync.

- [ ] **AWS KMS Transit auto-unseal** — DR Vault clusters reuse the
      FSN1 unseal key. Verify the IAM role attached to the HEL1
      stateful nodepool has `kms:Encrypt`, `kms:Decrypt`,
      `kms:DescribeKey` on `alias/nexora-transit-production`.
- [ ] Once the Vault pod is `Running` (after Phase 5), `vault operator
      init -recovery-shares=5 -recovery-threshold=3` — store the 5
      recovery shares in 1Password vault `nexora-prod-vault-recovery`.
      The unseal happens automatically via AWS KMS.
- [ ] Enable KV v2 at `kv/`: `vault secrets enable -path=kv -version=2 kv`
- [ ] Seed the paths below from 1Password / AWS Secrets Manager:
  - [ ] `kv/nexora/production-hel1/cnpg-superuser` — `username`, `password`
  - [ ] `kv/nexora/production-hel1/cnpg-replication` — `password`
        (must match the upstream primary's `streaming_replica`
        password)
  - [ ] `kv/nexora/production-hel1/cnpg-backup-s3` — `ACCESS_KEY_ID`,
        `SECRET_ACCESS_KEY` (Hetzner Object Storage credentials scoped
        to the HEL1 buckets only)
  - [ ] `kv/nexora/production-hel1/loki-tempo-s3` — same shape, scoped
        to `nexora-loki-production-hel1` + `nexora-tempo-production-hel1`
  - [ ] `kv/nexora/production-hel1/rabbitmq-credentials` —
        `default_user`, `default_pass`, `erlang_cookie`
  - [ ] `kv/nexora/production-hel1/grafana-admin` — `admin-user`,
        `admin-password`
  - [ ] `kv/nexora/production-hel1/grafana-oidc` — `client-id`,
        `client-secret` (Authentik OAuth2 provider pointing at
        `https://auth-hel1.nxua.dev/application/o/grafana/`)
  - [ ] `kv/nexora/production-hel1/argocd-oidc` — `client-id`,
        `client-secret`
  - [ ] `kv/nexora/production-hel1/tailscale-oauth` — `client-id`,
        `client-secret`, tagged for `tag:nexora-production-hel1`
  - [ ] `kv/nexora/production-hel1/authentik-bootstrap` — Postgres
        bootstrap user/password, secret key, host
        `nexora-authentik-production-hel1-rw.authentik.svc`
  - [ ] `kv/nexora/production-hel1/cloudflare-access` — JWT audience
        tag for `*-hel1.nxua.dev`
  - [ ] `kv/nexora/production-hel1/alertmanager-config` — Slack
        webhook for `#nexora-alerts-hel1`, PagerDuty integration key
  - [ ] `kv/nexora/production-hel1/vault-oidc` — leave empty; the
        Job under `_pending-authentik-oidc/` will populate it
        after Authentik is reachable on `auth-hel1.nxua.dev`.

---

## Phase 3 — Argo CD cluster registration (T+1h)

From the central Argo CD instance (FSN1, or NBG1 if FSN1 is the failed
region):

- [ ] `argocd login argocd.nxua.dev --sso`
- [ ] Merge the HEL1 kubeconfig into a working context.
- [ ] Register:
      ```
      argocd cluster add production-hel1 \
        --name production-hel1 \
        --label cluster=production-hel1 \
        --label region=hel1 \
        --label role=dr-async-replica
      ```
- [ ] Verify the cluster Secret was created:
      ```
      kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=cluster \
        -o jsonpath='{.items[?(@.metadata.name=="cluster-production-hel1")].metadata.name}'
      ```
- [ ] Confirm in Argo CD UI: Settings → Clusters → `production-hel1`
      shows `Successful`.

---

## Phase 4 — DNS pre-stage (T+1h15)

Add `*-hel1.nxua.dev` records pointing at the new LB **without**
removing the active region's records.

- [ ] Cloudflare: add **proxied A records** with TTL=Auto for:
  - `auth-hel1.nxua.dev`
  - `grafana-hel1.nxua.dev`
  - `vmui-hel1.nxua.dev`
  - `vault-hel1.nxua.dev`
  - `argocd-hel1.nxua.dev`
  - `hubble-hel1.nxua.dev`
  - `rabbitmq-hel1.nxua.dev`
  pointing at the LB IPv4 from
  `tofu output nexora_ingress_production_hel1_ipv4`.
- [ ] Confirm DNS-01 zone delegation for `nxua.dev` is unchanged.

---

## Phase 5 — Wire the DR Application (T+1h30)

- [ ] Confirm the working tree on `main` is clean and matches the
      tag from Phase 0.
- [ ] **Apply the activation Application** (irreversible — once
      applied, Argo CD owns the HEL1 cluster):
      ```
      kubectl --context fsn1 apply -n argocd \
        -f clusters/production/apps-dr/dr-hel1.yaml
      ```
- [ ] In Argo CD UI: open Application `dr-hel1`. It will report
      `OutOfSync` and show every resource it intends to create.
- [ ] **Review the diff** carefully:
  - destination cluster shows `production-hel1`.
  - no `Cluster` (CNPG) has `instances` > 0.
  - no `Deployment`/`StatefulSet` has `replicas` > 0 except the
    Helm-managed operators.
- [ ] Click **Sync** (`Apply Out of Sync Only`, `Prune: false` for the
      first run).
- [ ] Wait for sync wave -5 → 3 to complete. Watch for the same
      pitfalls as NBG1 (LINSTOR DRBD load, cert-manager challenges,
      ExternalSecrets resolution).

---

## Phase 6 — Replica flip (T+3h30)

Open a follow-up PR (`feat: activate dr-hel1 replicas`) and merge:

- [ ] `dr-hel1/cnpg-cluster-replica.yaml` (business cluster) —
      `spec.instances: 0` → `3`
- [ ] `dr-hel1/stateful/authentik/cnpg-cluster-replica.yaml` —
      `spec.instances: 0` → `3`
- [ ] `dr-hel1/stateful/rabbitmq/rabbitmq-cluster.yaml` —
      `spec.replicas: 0` → `3`
- [ ] `dr-hel1/stateful/dragonfly/dragonfly.yaml` —
      `spec.replicas: 0` → `3`
- [ ] `dr-hel1/dr-tailscale-router.yaml` — `spec.replicas: 0` → `2`
      (the canonical subnet-router manifest for HEL1; no separate
      `platform/tailscale/` directory exists).
- [ ] `dr-hel1/dr-traefik-passive.yaml` keeps `replicas: 0` — Traefik
      stays passive until the Phase 7 DNS flip, then the same file is
      bumped to `replicas: 2` in the same follow-up PR as DNS cutover.
- [ ] `dr-hel1/auth/authentik.yaml` — `server.replicas: 0` → `2`,
      `worker.replicas: 0` → `2`
- [ ] `dr-hel1/stateful/vault/vault.yaml` — `ha.replicas: 0` → `3`

`pg_basebackup` over the longer-latency Tailscale path between HEL1
and FSN1 (~40ms RTT, ~150 Mbit/s sustained) takes ~2h for a 50GiB
source. Then monitor:
`cnpg_pg_replication_lag{cluster="nexora-business-production-hel1"}`.

- [ ] Streaming lag <30s for 1h: PASS (async expected to be higher
      than NBG1's <5s target).
- [ ] If lag stays >5min sustained: investigate Tailscale path
      (HEL1 ↔ FSN1 direct route should be ≤45ms RTT). The
      `stateful-egress` NetworkPolicy must allow egress to the active
      region's tailnet CIDR (`10.60.0.0/16` for FSN1, or
      `10.61.0.0/16` if NBG1 is the upstream).

---

## Phase 7 — DNS flip + CNPG promotion (T+24h+, after 24h steady-state)

This is the irreversible cutover. Run only after:

- Streaming lag <30s for ≥24h continuous, AND
- Smoke tests in Phase 8 pass against `*-hel1.nxua.dev` URLs, AND
- Business has confirmed the failover window.

If HEL1 is the third hop (FSN1 down → NBG1 active → NBG1 down → HEL1
active), the promotion source switches to whichever region was last
upstream. Update the `externalClusters.host` in
`cnpg-cluster-replica.yaml` accordingly **before** Phase 5 — the
default scaffolding assumes FSN1 as the source.

- [ ] Quiesce writes on the current primary.
- [ ] Wait for streaming lag = 0.
- [ ] Promote HEL1 to primary:
      ```
      kubectl --context production-hel1 -n postgresql \
        cnpg promote nexora-business-production-hel1
      ```
- [ ] Same for Authentik:
      ```
      kubectl --context production-hel1 -n authentik \
        cnpg promote nexora-authentik-production-hel1
      ```
- [ ] Cloudflare: **change the existing `*.nxua.dev` proxied A records**
      from the previous active region's LB IP to the HEL1 LB IP. Drop
      the `-hel1.` variant records added in Phase 4 (or keep them as an
      admin-only alias).
- [ ] In `dr-hel1/dr-traefik-passive.yaml`, flip the Traefik HelmRelease
      `replicas: 0` → `2` and commit. The same file is the only Traefik
      manifest in the DR region — there is no separate active/passive
      pair; the file name reflects its day-1 state.

---

## Phase 8 — Smoke tests

Run these in order. Each must pass before proceeding to the next.

- [ ] `kubectl --context production-hel1 get pods -A | grep -v Running`
      returns only `Completed` Jobs.
- [ ] `curl -sS https://vault-hel1.nxua.dev/v1/sys/health` →
      `initialized: true, sealed: false, standby: false` on the leader.
- [ ] `https://auth-hel1.nxua.dev` loads, login as bootstrap admin
      succeeds.
- [ ] `https://argocd-hel1.nxua.dev` loads, SSO via Authentik works.
- [ ] `https://grafana-hel1.nxua.dev` loads, HEL1 cluster dashboards
      show data from the regional VictoriaMetrics.
- [ ] `kubectl --context production-hel1 -n postgresql exec -it
      nexora-business-production-hel1-1 -- psql -c "SELECT pg_is_in_recovery();"`
      returns `f` (false — promoted to primary).
- [ ] CNPG backup to Hetzner OS succeeded in the last 24h:
      `kubectl -n postgresql get backup -l cnpg.io/cluster=nexora-business-production-hel1`
      shows a recent `Completed` entry.
- [ ] AWS S3 DR copy CronJob source bucket flipped to
      `nexora-cnpg-backups-production-hel1` if HEL1 is now the active
      writer (the canonical CronJob lives at
      `clusters/production/stateful/postgresql/cnpg-dr-sync.yaml` —
      edit `RCLONE_CONFIG_HETZNER_ENDPOINT` to
      `https://hel1.your-objectstorage.com` and the `rclone copy`
      source to `hetzner:nexora-cnpg-backups-production-hel1` in a
      single PR).
- [ ] Run the end-to-end synthetic from `nexora-backend/tests/synthetic/`:
      `dotnet test --filter Category=DRSmoke -- --baseUrl=https://api.nxua.dev`.

---

## Phase 9 — Steady-state hardening (T+1week)

- [ ] Edit `clusters/production/apps-dr/dr-hel1.yaml` to enable
      `syncPolicy.automated` (uncomment the block) and commit.
- [ ] Update the `incident-response` PagerDuty escalation to route
      HEL1 alerts to the on-call rotation.
- [ ] Tag `dr-hel1-active` in git.
- [ ] Schedule a quarterly **DR drill**.

---

## Rollback (T+anytime before Phase 7)

If activation must be aborted before the DNS flip:

- [ ] In Argo CD UI: Application `dr-hel1` → *Delete* (cascade =
      foreground). All Argo-managed resources are removed.
- [ ] `kubectl -n argocd delete -f clusters/production/apps-dr/dr-hel1.yaml`
- [ ] `argocd cluster rm production-hel1`
- [ ] Cloudflare: remove the `-hel1.` DNS records added in Phase 4.
- [ ] `tofu destroy` in `nexora-infra/environments/production-hel1/`
      (be very careful — confirm the workspace name).
- [ ] Vault paths under `kv/nexora/production-hel1/*` can stay; they
      cost nothing and shorten the next activation.
- [ ] Reset the git tag: `git tag -d dr-hel1-pre-activation`.

After Phase 7 (DNS flipped + CNPG promoted), rollback becomes a
**reverse failover** — see `docs/runbooks/dr-reverse-failover.md`.

---

## HEL1-specific notes

- **Async, not sync.** Do not enable
  `synchronous_replication.method: any` on the HEL1 replica. The
  transcontinental RTT would stall every FSN1 commit. HEL1's RPO is
  bounded by streaming lag, not by `synchronous_commit`.
- **Subnet routing.** HEL1 advertises only `10.62.0.0/16` into the
  tailnet. Cross-region reachability to FSN1 (`10.60.0.0/16`) and NBG1
  (`10.61.0.0/16`) is provided by each region's subnet router peering
  through Tailscale ACLs — not by HEL1 advertising the other CIDRs.
- **Three-region failover order.** If both FSN1 and NBG1 are down, HEL1
  is bootstrapped from the AWS Object Lock copy via
  `cnpg-pitr-from-aws.md`. The runbook above assumes streaming-replica
  bootstrap from an alive upstream — adjust Phase 5/6 accordingly.

---

## References

- ADR-I-0003 — Single-region default with cold DR scaffolding.
- ADR-I-0005 — Cross-cloud immutable backups (AWS S3 Object Lock).
- `clusters/production/apps-dr/README.md` — why this Application is
  not in `apps/`.
- `clusters/production/dr-hel1/README.md` — folder layout reference.
- `clusters/production/dr-nbg1/dr-activation-runbook.md` — sister
  runbook; HEL1 differs primarily in async replication semantics and
  longer pg_basebackup window.
