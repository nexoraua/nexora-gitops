# DR activation runbook — Hetzner NBG1 (sync-replica)

**Audience:** on-call SRE + platform engineer with `argocd` admin,
Hetzner Cloud API token, Vault root token (sealed in 1Password), AWS
IAM `nexora-platform-admin`, Cloudflare API token.

**Triggers (per ADR-I-0003):** flip on when ANY of —

- Hetzner FSN1 region-wide outage observed >2h, OR
- Monthly active users >50k, OR
- Explicit business decision (board / CTO sign-off).

**Estimated wall-clock:** 4–6h from `terraform apply` to DNS flip, of
which ~90min is `pg_basebackup` of the business CNPG cluster.

**Roles required:**

- Region NBG1, role **sync-replica** (low latency to FSN1 over the same
  Hetzner backbone — primary DR candidate).
- Cluster CIDR `10.61.0.0/16` (nodes `10.61.1.0/24`, services
  `10.61.8.0/21`, pods `10.61.16.0/20`).

---

## Phase 0 — Pre-flight (T-24h, when feasible)

- [ ] Confirm the FSN1 primary is healthy enough to source a
      `pg_basebackup`. If FSN1 etcd is down, escalate to PITR-from-AWS
      runbook in `docs/runbooks/cnpg-pitr-from-aws.md`.
- [ ] Confirm Hetzner NBG1 has CCX13/CCX23/CPX31 inventory (Hetzner
      cloud status page).
- [ ] Confirm AWS KMS Transit key `alias/nexora-transit-production` is
      enabled and reachable (`aws kms describe-key`).
- [ ] Confirm Cloudflare API token has DNS edit on `nxua.dev`.
- [ ] Tag the active branch in `nexora-gitops`:
      `git tag -a dr-nbg1-pre-activation -m "..." && git push origin --tags`.
- [ ] Open incident channel `#inc-dr-nbg1-activation` and assign:
      Incident Commander, Communications, Scribe.

---

## Phase 1 — Terraform (T-0)

Workspace: `nexora-infra/environments/production-nbg1/`.

- [ ] `tofu init -upgrade`
- [ ] `tofu plan -out=plan.bin` — sanity-check:
  - 3 control-plane CCX13 in `nexora-prod-nbg1-cp-pg` (spread)
  - 3 stateful CCX23 in `nexora-prod-nbg1-db-pg` (spread)
  - 2 system CCX13 in `nexora-prod-nbg1-sys-pg` (spread)
  - 2 worker CPX31 in `nexora-prod-nbg1-wk-pg` (spread)
  - LB `nexora-ingress-production-nbg1` (LB11) in NBG1
  - Hetzner Object Storage buckets:
    - `nexora-cnpg-backups-production-nbg1`
    - `nexora-cnpg-backups-authentik-production-nbg1`
    - `nexora-loki-production-nbg1`
    - `nexora-tempo-production-nbg1`
  - Tailscale subnet router auth key tagged
    `tag:k8s,tag:nexora-production-nbg1` advertising `10.61.0.0/16`
- [ ] `tofu apply plan.bin`
- [ ] Fetch kubeconfig: `tofu output -raw kubeconfig > /tmp/nbg1.kubeconfig`
- [ ] `kubectl --kubeconfig=/tmp/nbg1.kubeconfig get nodes` — expect 10
      nodes `Ready`.
- [ ] `kubectl --kubeconfig=/tmp/nbg1.kubeconfig get pods -A` — Cilium,
      kube-proxy-replacement, hubble-relay all `Running`.

---

## Phase 2 — Vault bring-up + KV seed (T+30min)

The Vault Application is part of `dr-nbg1/stateful/vault/` and will be
synced by Argo CD in Phase 5. Pre-seed the KV paths now so the
`ExternalSecret`s resolve on first sync.

- [ ] **AWS KMS Transit auto-unseal** — DR Vault clusters reuse the
      FSN1 unseal key. Verify the IAM role attached to the NBG1 stateful
      nodepool has `kms:Encrypt`, `kms:Decrypt`, `kms:DescribeKey` on
      `alias/nexora-transit-production`.
- [ ] Once the Vault pod is `Running` (after Phase 5), `vault operator
      init -recovery-shares=5 -recovery-threshold=3` — store the 5
      recovery shares in 1Password vault `nexora-prod-vault-recovery`
      (one share per board member). The unseal happens automatically
      via AWS KMS.
- [ ] Enable KV v2 at `kv/`: `vault secrets enable -path=kv -version=2 kv`
- [ ] Seed the paths below from 1Password / AWS Secrets Manager:
  - [ ] `kv/nexora/production-nbg1/cnpg-superuser` — `username`, `password`
  - [ ] `kv/nexora/production-nbg1/cnpg-replication` — `password`
        (must match FSN1's `streaming_replica` password)
  - [ ] `kv/nexora/production-nbg1/cnpg-backup-s3` — `ACCESS_KEY_ID`,
        `SECRET_ACCESS_KEY` (Hetzner Object Storage credentials scoped
        to the NBG1 buckets only)
  - [ ] `kv/nexora/production-nbg1/loki-tempo-s3` — same shape, scoped
        to `nexora-loki-production-nbg1` + `nexora-tempo-production-nbg1`
  - [ ] `kv/nexora/production-nbg1/rabbitmq-credentials` —
        `default_user`, `default_pass`, `erlang_cookie`
  - [ ] `kv/nexora/production-nbg1/grafana-admin` — `admin-user`,
        `admin-password`
  - [ ] `kv/nexora/production-nbg1/grafana-oidc` — `client-id`,
        `client-secret` (Authentik OAuth2 provider pointing at
        `https://auth-nbg1.nxua.dev/application/o/grafana/`)
  - [ ] `kv/nexora/production-nbg1/argocd-oidc` — `client-id`,
        `client-secret`
  - [ ] `kv/nexora/production-nbg1/tailscale-oauth` — `client-id`,
        `client-secret`, tagged for `tag:nexora-production-nbg1`
  - [ ] `kv/nexora/production-nbg1/authentik-bootstrap` — Postgres
        bootstrap user/password, secret key, host
        `nexora-authentik-production-nbg1-rw.authentik.svc`
  - [ ] `kv/nexora/production-nbg1/cloudflare-access` — JWT audience
        tag for `*-nbg1.nxua.dev`
  - [ ] `kv/nexora/production-nbg1/alertmanager-config` — Slack
        webhook for `#nexora-alerts-nbg1`, PagerDuty integration key
  - [ ] `kv/nexora/production-nbg1/vault-oidc` — leave empty; the
        Job under `_pending-authentik-oidc/` will populate it
        after Authentik is reachable on `auth-nbg1.nxua.dev`.

---

## Phase 3 — Argo CD cluster registration (T+1h)

From the central Argo CD instance running in FSN1:

- [ ] `argocd login argocd.nxua.dev --sso`
- [ ] Merge the NBG1 kubeconfig into a working context:
      `KUBECONFIG=$HOME/.kube/config:/tmp/nbg1.kubeconfig kubectl config view --flatten > ~/.kube/merged && mv ~/.kube/merged ~/.kube/config`
- [ ] `kubectl config use-context production-nbg1` (or whatever name
      Talos chose; rename with `kubectl config rename-context`).
- [ ] Register:
      ```
      argocd cluster add production-nbg1 \
        --name production-nbg1 \
        --label cluster=production-nbg1 \
        --label region=nbg1 \
        --label role=dr-sync-replica
      ```
- [ ] Verify the cluster Secret was created:
      ```
      kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=cluster \
        -o jsonpath='{.items[?(@.metadata.name=="cluster-production-nbg1")].metadata.name}'
      ```
- [ ] Confirm in the Argo CD UI: Settings → Clusters → `production-nbg1`
      shows `Successful` connection.

---

## Phase 4 — DNS pre-stage (T+1h15)

We add `*-nbg1.nxua.dev` records pointing at the new LB **without**
removing FSN1 records. This lets cert-manager solve LE HTTP-01 / DNS-01
challenges during Phase 5 even though no production traffic flows yet.

- [ ] Cloudflare: add **proxied A records** with TTL=Auto for:
  - `auth-nbg1.nxua.dev`
  - `grafana-nbg1.nxua.dev`
  - `vmui-nbg1.nxua.dev`
  - `vault-nbg1.nxua.dev`
  - `argocd-nbg1.nxua.dev`
  - `hubble-nbg1.nxua.dev`
  - `rabbitmq-nbg1.nxua.dev`
  pointing at the LB IPv4 from
  `tofu output nexora_ingress_production_nbg1_ipv4`.
- [ ] Confirm DNS-01 zone delegation for `nxua.dev` is unchanged
      (Cloudflare API token used by cert-manager is the same as FSN1).

---

## Phase 5 — Wire the DR Application (T+1h30)

- [ ] Confirm the working tree on `main` is clean and matches the
      tag from Phase 0.
- [ ] **Apply the activation Application** (this is the irreversible
      switch — once applied, Argo CD owns the NBG1 cluster):
      ```
      kubectl --context fsn1 apply -n argocd \
        -f clusters/production/apps-dr/dr-nbg1.yaml
      ```
- [ ] In Argo CD UI: open Application `dr-nbg1`. It will report
      `OutOfSync` and show every resource it intends to create.
- [ ] **Review the diff** carefully. Specifically check:
  - destination cluster shows `production-nbg1` (not
    `https://kubernetes.default.svc` — that would deploy into FSN1).
  - no `Cluster` (CNPG) has `instances` > 0.
  - no `Deployment`/`StatefulSet` has `replicas` > 0 except the
    Helm-managed operators (cnpg-operator, rabbitmq-operator,
    dragonfly-operator, piraeus-operator, cert-manager,
    external-secrets, hcloud-csi, metrics-server).
- [ ] Click **Sync** (sync option `Apply Out of Sync Only`,
      `Prune: false` for the first run).
- [ ] Wait for sync wave -5 → 3 to complete. Common pitfalls:
  - LINSTOR satellites stuck `Init` → check `kubectl logs -n
    piraeus-datastore <satellite-pod>` for `drbd9` module load. Talos
    overrides in `nexora-infra/.../linstor-talos-overrides.yaml` must
    have been applied during Phase 1.
  - cert-manager challenges failing → verify Cloudflare API token in
    `kv/nexora/production-nbg1/cloudflare-access` is correct and the
    `ClusterIssuer` shows `Ready=True`.
  - ExternalSecrets `SecretSyncedError` → re-check Phase 2 KV paths.

---

## Phase 6 — Replica flip (T+3h)

Open a follow-up PR (`feat: activate dr-nbg1 replicas`) and merge:

- [ ] `dr-nbg1/cnpg-cluster-replica.yaml` (business cluster) —
      `spec.instances: 0` → `3`
- [ ] `dr-nbg1/stateful/authentik/cnpg-cluster-replica.yaml` —
      `spec.instances: 0` → `3`
- [ ] `dr-nbg1/stateful/rabbitmq/rabbitmq-cluster.yaml` —
      `spec.replicas: 0` → `3`
- [ ] `dr-nbg1/stateful/dragonfly/dragonfly.yaml` —
      `spec.replicas: 0` → `3`
- [ ] `dr-nbg1/dr-tailscale-router.yaml` — `spec.replicas: 0` → `2`
      (the canonical subnet-router manifest for NBG1; no separate
      `platform/tailscale/` directory exists).
- [ ] `dr-nbg1/dr-traefik-passive.yaml` keeps `replicas: 0` — Traefik
      stays passive until the Phase 7 DNS flip, then the same file is
      bumped to `replicas: 2` in the same follow-up PR as DNS cutover.
- [ ] `dr-nbg1/auth/authentik.yaml` — `server.replicas: 0` → `2`,
      `worker.replicas: 0` → `2`
- [ ] `dr-nbg1/stateful/vault/vault.yaml` — `ha.replicas: 0` → `3`

Wait for `pg_basebackup` to complete on the business CNPG cluster
(~90min for a 50GiB source). Then monitor streaming lag via VMUI:
`cnpg_pg_replication_lag{cluster="nexora-business-production-nbg1"}`.

- [ ] Streaming lag <5s for 1h: PASS.
- [ ] If lag stays >30s: investigate Tailscale path MTU and the
      `stateful-egress` NetworkPolicy egress allowlist for
      `10.60.0.0/16` (FSN1 tailnet CIDR).

---

## Phase 7 — DNS flip + CNPG promotion (T+24h, after 24h steady-state)

This is the irreversible cutover. Run only after:

- Streaming lag <5s for ≥24h continuous, AND
- Smoke tests in Phase 8 pass against `*-nbg1.nxua.dev` URLs, AND
- Business has confirmed the failover window.

- [ ] Quiesce writes on FSN1: scale every Deployment in `business`
      namespace to 0 (use the script `nexora-backend/scripts/quiesce-fsn1.sh`).
- [ ] Wait for streaming lag = 0.
- [ ] Promote NBG1 to primary:
      ```
      kubectl --context production-nbg1 -n postgresql \
        cnpg promote nexora-business-production-nbg1
      ```
- [ ] Same for Authentik:
      ```
      kubectl --context production-nbg1 -n authentik \
        cnpg promote nexora-authentik-production-nbg1
      ```
- [ ] Cloudflare: **change the existing `*.nxua.dev` proxied A records**
      (auth, grafana, vmui, vault, argocd, hubble, rabbitmq, api, app)
      from the FSN1 LB IP to the NBG1 LB IP. Drop the `-nbg1.` variant
      records added in Phase 4 (or keep them as an admin-only alias).
- [ ] In `dr-nbg1/dr-traefik-passive.yaml`, flip the Traefik HelmRelease
      `replicas: 0` → `2` and commit. The same file is the only Traefik
      manifest in the DR region — there is no separate active/passive
      pair; the file name reflects its day-1 state.

---

## Phase 8 — Smoke tests

Run these in order. Each must pass before proceeding to the next.

- [ ] `kubectl --context production-nbg1 get pods -A | grep -v Running`
      returns only `Completed` Jobs.
- [ ] `curl -sS https://vault-nbg1.nxua.dev/v1/sys/health` →
      `initialized: true, sealed: false, standby: false` on the leader.
- [ ] `https://auth-nbg1.nxua.dev` loads the Authentik UI, login as
      bootstrap admin succeeds.
- [ ] `https://argocd-nbg1.nxua.dev` loads, SSO via Authentik works.
- [ ] `https://grafana-nbg1.nxua.dev` loads, NBG1 cluster dashboards
      show data from the regional VictoriaMetrics.
- [ ] `kubectl --context production-nbg1 -n postgresql exec -it
      nexora-business-production-nbg1-1 -- psql -c "SELECT pg_is_in_recovery();"`
      returns `f` (false — promoted to primary).
- [ ] CNPG backup to Hetzner OS succeeded in the last 24h:
      `kubectl -n postgresql get backup -l cnpg.io/cluster=nexora-business-production-nbg1`
      shows a recent `Completed` entry.
- [ ] AWS S3 DR copy is still flowing — the rclone CronJob runs in
      whichever region is currently active. If NBG1 is now active, the
      CronJob source bucket must be flipped to
      `nexora-cnpg-backups-production-nbg1` (the canonical CronJob lives
      at `clusters/production/stateful/postgresql/cnpg-dr-sync.yaml` —
      edit `RCLONE_CONFIG_HETZNER_ENDPOINT` to `https://nbg1.your-objectstorage.com`
      and the `rclone copy` source to
      `hetzner:nexora-cnpg-backups-production-nbg1` in a single PR).
- [ ] Run the end-to-end synthetic from `nexora-backend/tests/synthetic/`:
      `dotnet test --filter Category=DRSmoke -- --baseUrl=https://api.nxua.dev`.

---

## Phase 9 — Steady-state hardening (T+1week)

- [ ] Edit `clusters/production/apps-dr/dr-nbg1.yaml` to enable
      `syncPolicy.automated` (uncomment the block) and commit.
- [ ] Update the `incident-response` PagerDuty escalation to route
      NBG1 alerts to the on-call rotation.
- [ ] Tag `dr-nbg1-active` in git.
- [ ] Schedule a quarterly **DR drill**: temporarily quiesce NBG1,
      verify FSN1 still serves traffic from the warm replica.

---

## Rollback (T+anytime before Phase 7)

If activation must be aborted before the DNS flip:

- [ ] In Argo CD UI: Application `dr-nbg1` → *Delete* (cascade =
      foreground). All Argo-managed resources are removed.
- [ ] `kubectl -n argocd delete -f clusters/production/apps-dr/dr-nbg1.yaml`
- [ ] `argocd cluster rm production-nbg1`
- [ ] Cloudflare: remove the `-nbg1.` DNS records added in Phase 4.
- [ ] `tofu destroy` in `nexora-infra/environments/production-nbg1/`
      (be very careful — confirm the workspace name).
- [ ] Vault paths under `kv/nexora/production-nbg1/*` can stay; they
      cost nothing and shorten the next activation.
- [ ] Reset the git tag: `git tag -d dr-nbg1-pre-activation`.

After Phase 7 (DNS flipped + CNPG promoted), rollback becomes a
**reverse failover** — see `docs/runbooks/dr-reverse-failover.md`.

---

## References

- ADR-I-0003 — Single-region default with cold DR scaffolding.
- ADR-I-0005 — Cross-cloud immutable backups (AWS S3 Object Lock).
- `clusters/production/apps-dr/README.md` — why this Application is
  not in `apps/`.
- `clusters/production/dr-nbg1/README.md` — folder layout reference.
