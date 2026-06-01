# DR scaffolding — Hetzner NBG1 (Nuremberg)

**State: COLD STANDBY. No Application targets this directory.**

NBG1 is the primary DR candidate from the FSN1 active region (low
latency, same DC complex, same Hetzner network backbone). HEL1 is the
geographically-distant secondary DR target.

Activation criteria, sequence, and bucket layout are identical to
`../dr-hel1/README.md` — see that file. Differences:

- NBG1 cluster CIDR: `10.62.0.0/16`
- NBG1 buckets: `nexora-cnpg-backups-production-nbg1`,
  `nexora-production-loki-nbg1`, `nexora-production-tempo-nbg1`
- NBG1 LB name (when provisioned): `nexora-ingress-production-nbg1`
- Object Storage endpoint: `nbg1.your-objectstorage.com`

Activation = add `clusters/production/apps/dr-nbg1.yaml` Application
pointing at `clusters/production/dr-nbg1/` and registering an NBG1
secondary cluster in Argo CD.
