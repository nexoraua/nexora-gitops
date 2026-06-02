# `apps-dr/` — DR activation Applications (not auto-reconciled)

This directory holds Argo CD `Application` manifests that wire the cold
DR scaffolding under `clusters/production/dr-nbg1/` and
`clusters/production/dr-hel1/` to live secondary clusters.

**Day-1 state: none of these Applications are applied. Argo CD does not
reconcile this directory.** The files are committed so the day-N
activation diff is bounded and reviewable.

## Why a separate `apps-dr/` directory?

The production app-of-apps root (`clusters/production/root.yaml`) syncs
**only** `clusters/production/apps/` with `directory.recurse: false`.
If a DR Application sat under `apps/`, Argo CD would attempt to
reconcile it the moment it was committed — but at that point:

- the `production-nbg1` / `production-hel1` Argo CD cluster
  destinations don't exist yet,
- the regional Vault KV paths aren't seeded,
- the regional Hetzner Object Storage buckets aren't provisioned,
- the regional Cloudflare DNS records still point at FSN1.

The result would be a noisy `Application` stuck in `Unknown` /
`SyncFailed`, generating false alerts and possibly racing partial
resources into a half-built cluster. Putting the file under
`apps-dr/` instead keeps it git-tracked but invisible to the root
sync until a human runs `kubectl apply -n argocd -f apps-dr/dr-<region>.yaml`.

Per ADR-I-0003, multi-region is OFF by default — the **commit of these
Applications is the activation flag**, not their existence on disk.

## Files

| File | Region | Destination | State |
| ---- | ------ | ----------- | ----- |
| `dr-nbg1.yaml` | Hetzner NBG1 (sync-replica) | `production-nbg1` | Committed, not applied |
| `dr-hel1.yaml` | Hetzner HEL1 (async-replica) | `production-hel1` | Committed, not applied |

Both Applications:

- target `clusters/production/dr-<region>/` with `directory.recurse: true`,
- exclude `_pending-*/**` (OIDC bootstrap Jobs that wait for Authentik)
  and `*activation-runbook.md` / `README.md`,
- use `project: default` and run on `sync-wave: "-5"`,
- ship **without** `syncPolicy.automated` — the first reconcile is a
  manual click in the Argo CD UI so an operator can review the full
  diff before any resource is created in the new cluster.

## Activation steps (high-level)

The full step-by-step runbook lives next to each region's manifests:

- `clusters/production/dr-nbg1/dr-activation-runbook.md`
- `clusters/production/dr-hel1/dr-activation-runbook.md`

In summary:

1. **Terraform** — apply the dedicated workspace
   `nexora-infra/environments/production-<region>/`. This provisions
   the Talos cluster, Hetzner Object Storage buckets, LB
   (`nexora-ingress-production-<region>`), and Tailscale subnet router
   ACLs.
2. **Vault** — seed `kv/nexora/production-<region>/*` paths (one per
   ExternalSecret listed in
   `clusters/production/dr-<region>/platform/secrets/`). The unseal
   key is the shared AWS KMS Transit alias
   `alias/nexora-transit-production` — DR Vaults boot under the same
   root-of-trust as FSN1 on purpose.
3. **Argo CD cluster registration** — from the central FSN1 Argo CD:
   ```
   argocd cluster add <kubecontext> --name production-<region>
   ```
   This creates the `Secret` with
   `argocd.argoproj.io/secret-type=cluster` and `name=production-<region>`
   that `spec.destination.name` in `dr-<region>.yaml` resolves against.
4. **Apply the Application**:
   ```
   kubectl apply -n argocd -f clusters/production/apps-dr/dr-<region>.yaml
   ```
   At this point Argo CD will report the Application as `OutOfSync` —
   that is expected.
5. **Sync once, manually** — review the diff in the Argo CD UI, then
   click *Sync*. Operators (everything in `dr-<region>/operators/`)
   and platform CRDs come up first; CNPG `Cluster` instances stay at
   `instances: 0` until the manifests in the repo are bumped.
6. **Flip replicas** — open a follow-up PR that changes `instances: 0`
   → `instances: 3` on CNPG `Cluster`s, `replicas: 0` → `replicas: 2`
   on Traefik / Tailscale subnet router / Authentik / Vault HA, etc.
   The PR is the single audit trail for "DR region went hot".
7. **DNS flip** — once replica lag is <5s steady-state for 24h and
   smoke tests pass, repoint Cloudflare `*-<region>.nxua.dev` records
   at the new LB and run a controlled CNPG promotion.
8. **(Optional, later)** — enable `syncPolicy.automated` by editing
   `dr-<region>.yaml` to remove the manual gate.

## What this directory does NOT contain

- `dr-<region>.yaml` is **not** an `ApplicationSet`. A single
  `Application` per region keeps the surface minimal and the destination
  registration explicit.
- No secrets, no cluster credentials. Cluster registration is performed
  out-of-band via `argocd cluster add`.
- No Talos / Hetzner Terraform — that lives in
  `nexora-infra/environments/production-<region>/`.

## Rollback

To unwire a DR region after activation:

```
kubectl delete -n argocd application dr-<region>
```

Then `argocd cluster rm production-<region>`. The manifests under
`dr-<region>/` remain in git untouched, ready for re-activation.
