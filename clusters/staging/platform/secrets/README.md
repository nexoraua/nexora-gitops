# Bootstrap secrets (staging)

Цей каталог містить `ExternalSecret` маніфести, які матеріалізують
секрети з HashiCorp Vault у Kubernetes `Secret`-и. ArgoCD синхронізує
лише маніфести — реальні значення мають бути попередньо заведені у
Vault руками операторів.

> Без seed-кроків нижче `ExternalSecret`-и зупиняться у стані
> `SecretSyncedError`, а workloads (CNPG, RabbitMQ, Authentik, Grafana,
> Loki, Tempo) не зможуть стартувати.

## Послідовність seed-у

Виконати **перед** першим sync `bootstrap-secrets` Application. Логін у
Vault через OIDC (Authentik → group `infra-admin`) або через root token
у фазі bootstrap; шлях KV v2 — `kv/...` (mount `kv`).

### 1. Cloudflare API token (DNS-01 для cert-manager)

Cert-manager встановлений Terraform-ом (`nexora-infra`), сам Cloudflare
token також seed-иться через Terraform у Secret `cloudflare-api-token`
у namespace `cert-manager`. Тут залишено крок як reminder — нічого
додавати у Vault для cert-manager не треба.

### 2. Vault unseal keys (Shamir 3-of-5 (5 shares total, threshold 3))

Згенеровані під час `vault operator init`. Зберігаються у 1Password
vault `Nexora Breakglass`, розділені між двома `admin-super`
операторами (3 + 2). У git **не комітити**.

### 3. Vault initial root token

Тимчасово зберегти у k8s Secret для bootstrap Job:

```bash
kubectl -n vault-system create secret generic vault-bootstrap-token \
  --from-literal=token=$ROOT_TOKEN
```

Revoke одразу після того, як OIDC bootstrap Job пройшов:

```bash
vault token revoke $ROOT_TOKEN
kubectl -n vault-system delete secret vault-bootstrap-token
```

### 4. CNPG superuser

```bash
vault kv put kv/nexora/staging/cnpg/superuser \
  username=postgres \
  password=$(openssl rand -base64 32)

vault kv put kv/nexora/staging/cnpg/authentik-superuser \
  username=postgres \
  password=$(openssl rand -base64 32)
```

Materialize: `cnpg-superuser` (postgresql ns) та
`cnpg-authentik-superuser` (authentik ns).

> **Rotation:** CNPG operator watch-ить `superuserSecret` і при
> зміні викликає `ALTER ROLE … PASSWORD …`. Процедура: `vault kv put`,
> ESO sync (можна форс-анотацією), CNPG reconciles (≤15 хв). Той же
> шлях що описаний у develop README — без downtime для існуючих сесій.

### 5. CNPG S3 backup credentials (Hetzner Object Storage)

Buckets `nexora-cnpg-backups-staging` та
`nexora-cnpg-backups-authentik-staging`, endpoint
`fsn1.your-objectstorage.com`, S3 v4. Access key створюється у Hetzner
Console (Object Storage → Credentials) — Hetzner Object Storage keys
project-scoped (не per-bucket / per-action, на відміну від AWS IAM).

```bash
vault kv put kv/nexora/staging/cnpg/backup-s3 \
  access-key-id=$HCLOUD_S3_AK \
  secret-access-key=$HCLOUD_S3_SK
```

Materialize: `cnpg-backup-s3` (postgresql + authentik ns).

### 6. RabbitMQ admin password

```bash
vault kv put kv/nexora/staging/rabbitmq/admin \
  username=nexora-admin \
  password=$(openssl rand -base64 32)
```

Materialize: `rabbitmq-credentials` (rabbitmq ns).

> **Rotation:** RabbitMQ Cluster Operator не пропагує password зі
> Secret-у у running broker (читає лише на FIRST boot). Закрите через
> `stateful/rabbitmq/password-sync.yaml` (CronJob кожні 5 хв викликає
> `rabbitmqctl change_password`, idempotent). Процедура та сама як на
> develop — див. develop README.

### 7. Authentik secret_key + bootstrap admin

```bash
vault kv put kv/nexora/staging/authentik/bootstrap \
  secret_key=$(openssl rand -base64 64) \
  bootstrap_admin_password=$(openssl rand -base64 32) \
  bootstrap_admin_token=$(openssl rand -hex 32)

vault kv put kv/nexora/staging/authentik/postgres \
  username=authentik \
  password=$(openssl rand -base64 32)
```

Materialize: `authentik-bootstrap` + `authentik-postgres-credentials`
(authentik ns). Bootstrap token не використовується для людей — лише
для першого `akadmin` login, відразу скинути після ручного створення
super-admin акаунту.

### 8. Authentik OIDC client credentials для Vault

Створюється через Authentik blueprint
(`clusters/staging/platform/authentik/blueprints/vault.yaml`). Після
того, як Authentik згенерує client_id + client_secret, скопіювати у
Vault KV:

```bash
vault kv put kv/nexora/staging/vault-oidc \
  client_id=$AUTHENTIK_CLIENT_ID \
  client_secret=$AUTHENTIK_CLIENT_SECRET
```

Materialize: `vault-oidc-client` (vault-system ns) — див.
`platform/vault/_pending-authentik-oidc/`.

### 9. Grafana admin password + OIDC

```bash
vault kv put kv/nexora/staging/grafana/admin \
  username=admin \
  password=$(openssl rand -base64 32)

vault kv put kv/nexora/staging/oidc/grafana \
  client_id=$AUTHENTIK_GRAFANA_CLIENT_ID \
  client_secret=$AUTHENTIK_GRAFANA_CLIENT_SECRET
```

Materialize: `grafana-admin` + `grafana-oidc` (monitoring ns).

### 10. ArgoCD OIDC

```bash
vault kv put kv/nexora/staging/oidc/argocd \
  client_id=$AUTHENTIK_ARGOCD_CLIENT_ID \
  client_secret=$AUTHENTIK_ARGOCD_CLIENT_SECRET
```

Materialize: `argocd-oidc` → merged into `argocd-secret` (argocd ns).

### 11. Tailscale auth key

```bash
vault kv put kv/nexora/staging/tailscale \
  auth-key="tskey-auth-..."
```

Materialize: `tailscale-auth` (tailscale ns).

### 12. Alertmanager Telegram destination

Staging алерти йдуть в окремий топік супергрупи "NEXORA development"
(той самий бот, що й develop, але виділений топік щоб не змішувати
шум). Створити топік вручну → скопіювати `message_thread_id`. `chat_id`
залишається груповий (`-100…`).

```bash
vault kv put kv/nexora/staging/alerts/telegram \
  bot_token="<BotFather-token>" \
  chat_id="-1003724666926" \
  topic_id="<staging-topic-id>"
```

Materialize: `alertmanager-config` (monitoring ns) — рендерить повну
`alertmanager.yaml` і підмонтовується у VMAlertmanager через
`configSecret: alertmanager-config`.

## Checklist перед першим `argocd sync bootstrap-secrets`

- [ ] Vault init, unseal, OIDC auth, Kubernetes auth — пройдені (див. `../vault/README.md`).
- [ ] `kv/nexora/staging/cnpg/superuser` записаний.
- [ ] `kv/nexora/staging/cnpg/authentik-superuser` записаний.
- [ ] `kv/nexora/staging/authentik/postgres` записаний.
- [ ] `kv/nexora/staging/cnpg/backup-s3` записаний.
- [ ] `kv/nexora/staging/rabbitmq/admin` записаний.
- [ ] `kv/nexora/staging/authentik/bootstrap` записаний.
- [ ] `kv/nexora/staging/grafana/admin` записаний.
- [ ] `kv/nexora/staging/oidc/grafana` записаний.
- [ ] `kv/nexora/staging/oidc/argocd` записаний.
- [ ] `kv/nexora/staging/tailscale` записаний.
- [ ] `kv/nexora/staging/vault-oidc` (тільки після того, як Authentik
      blueprint згенерував provider).
- [ ] `kv/nexora/staging/alerts/telegram` записаний.
- [ ] Hetzner Object Storage buckets `nexora-cnpg-backups-staging`,
      `nexora-cnpg-backups-authentik-staging` створено.
