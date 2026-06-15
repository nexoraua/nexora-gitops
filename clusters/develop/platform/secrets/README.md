# Bootstrap secrets (develop)

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

### 2. Vault unseal keys (Shamir 5 of 3)

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
vault kv put kv/nexora/develop/cnpg/superuser \
  username=postgres \
  password=$(openssl rand -base64 32)

vault kv put kv/nexora/develop/cnpg/authentik-superuser \
  username=postgres \
  password=$(openssl rand -base64 32)
```

Materialize: `cnpg-superuser` (postgresql ns) та
`cnpg-authentik-superuser` (authentik ns).

> **Rotation:** CNPG operator watch-ить `superuserSecret` і при
> зміні викликає `ALTER ROLE … PASSWORD …`. Процедура:
> `vault kv put …`, далі ESO sync (примусово —
> `kubectl annotate externalsecret cnpg-superuser force-sync=$(date +%s)
> --overwrite`), далі CNPG reconciles (≤15 хв; можна форснути
> `kubectl annotate cluster nexora-business-develop
> cnpg.io/reconciliationLoop=$(date +%s) --overwrite`). Старий
> пароль одразу інвалідовано (DB ALTER ROLE — без downtime для
> існуючих сесій).

### 5. CNPG S3 backup credentials (Hetzner Object Storage)

Bucket `nexora-cnpg-backups-develop`, endpoint
`fsn1.your-objectstorage.com`, S3 v4. Access key створюється у Hetzner
Console (Object Storage → Credentials) — Hetzner Object Storage keys
project-scoped (не per-bucket / per-action, на відміну від AWS IAM).

```bash
vault kv put kv/nexora/develop/cnpg/backup-s3 \
  access-key-id=$HCLOUD_S3_AK \
  secret-access-key=$HCLOUD_S3_SK
```

Materialize: `cnpg-backup-s3` (postgresql ns) — використовується
`barmanObjectStore` бізнес-кластера.

> Backup `nexora-authentik-develop` (authentik ns) — окремий follow-up,
> ще не налаштований.

### 6. Loki S3 credentials

Bucket `nexora-develop-loki`.

```bash
vault kv put kv/nexora/develop/object-storage/loki \
  access_key_id=$HCLOUD_S3_AK \
  secret_access_key=$HCLOUD_S3_SK
```

Materialize: `loki-s3` (monitoring ns).

### 7. Tempo S3 credentials

Bucket `nexora-develop-tempo`.

```bash
vault kv put kv/nexora/develop/object-storage/tempo \
  access_key_id=$HCLOUD_S3_AK \
  secret_access_key=$HCLOUD_S3_SK
```

Materialize: `tempo-s3` (monitoring ns).

### 8. RabbitMQ admin password

```bash
vault kv put kv/nexora/develop/rabbitmq/admin \
  username=nexora-admin \
  password=$(openssl rand -base64 32)
```

Materialize: `rabbitmq-credentials` (rabbitmq ns) — RabbitMQ Cluster
Operator читає її через `spec.secretBackend.externalSecret.name`.

> **Rotation:** RabbitMQ Cluster Operator читає `default_user.conf` лише
> на FIRST boot — після цього user живе у Mnesia, і зміна Secret-у
> не реконсилиться у running broker. Цей gap закриває
> `stateful/rabbitmq/password-sync.yaml` — CronJob який кожні 5 хв
> викликає `rabbitmqctl change_password` із поточного Secret-у
> (idempotent). Процедура ротації: `vault kv put …`, потім дочекатись
> ESO sync (1 год або примусово `kubectl annotate externalsecret
> rabbitmq-credentials force-sync=$(date +%s) --overwrite`), потім
> CronJob пропагує впродовж 5 хв. Force-NOW:
> `kubectl -n rabbitmq create job rmq-sync-now-$(date +%s) --from=cronjob/rabbitmq-password-sync`.

### 9. Authentik secret_key + bootstrap admin

```bash
vault kv put kv/nexora/develop/authentik/bootstrap \
  secret_key=$(openssl rand -base64 64) \
  bootstrap_admin_password=$(openssl rand -base64 32) \
  bootstrap_admin_token=$(openssl rand -hex 32)

vault kv put kv/nexora/develop/authentik/postgres \
  username=authentik \
  password=$(openssl rand -base64 32)
```

Materialize: `authentik-bootstrap` + `authentik-postgres-credentials`
(authentik ns). Bootstrap token не використовується для людей — лише
для першого `akadmin` login, відразу скинути після ручного створення
super-admin акаунту.

### 10. Authentik OIDC client credentials для Vault

Створюється через Authentik blueprint
(`clusters/develop/platform/authentik/blueprints/vault.yaml`). Після
того, як Authentik згенерує client_id + client_secret, скопіювати у
Vault KV:

```bash
vault kv put kv/nexora/develop/vault-oidc \
  client_id=$AUTHENTIK_CLIENT_ID \
  client_secret=$AUTHENTIK_CLIENT_SECRET
```

Materialize: `vault-oidc-client` (vault-system ns) — див.
`platform/vault/external-secrets.yaml`.

### 11. Grafana admin password

```bash
vault kv put kv/nexora/develop/grafana/admin \
  username=admin \
  password=$(openssl rand -base64 32)
```

Materialize: `grafana-admin` (monitoring ns).

### 12. Alertmanager Telegram destination

Develop alерти йдуть в одного Telegram-бота, у супергрупу "NEXORA
development", у виділений топік. Тут бот, група і топік мають бути
створені вручну до seed-у (BotFather, додати бота адміном у групу,
скопіювати `chat.id` і `message_thread_id`).

```bash
vault kv put kv/nexora/develop/alerts/telegram \
  bot_token="<BotFather-token>" \
  chat_id="-1003724666926" \
  topic_id="40"
```

Materialize: `alertmanager-config` (monitoring ns) — рендерить повну
`alertmanager.yaml` і підмонтовується у VMAlertmanager через
`configSecret: alertmanager-config`.

### 13. Authentik Google OAuth source credentials

Google OAuth Client ID + Secret для federation source у Authentik
(показує "Login with Google" на `auth.develop.nxua.dev`). Креди
створюються вручну у Google Cloud Console:

1. Project + OAuth consent screen ("Nexora (develop)", domain `nxua.dev`,
   scopes `openid`+`email`+`profile`)
2. Credentials → OAuth 2.0 Client ID, type **Web application**
3. Authorized redirect URI: `https://auth.develop.nxua.dev/source/oauth/callback/google/`
   (літерально `/google/` у кінці — має match slug у blueprint)

Seed у Vault:

```bash
vault kv put kv/nexora/develop/authentik/google-oauth \
  client_id="<google-oauth-client-id>" \
  client_secret="<google-oauth-client-secret>"
```

Materialize: `authentik-google-oauth` (authentik ns) — споживається
Authentik worker pod через `global.envFrom` (`apps/authentik.yaml`);
blueprint `platform/authentik/blueprints/google-oauth.yaml` посилається
на `!Env GOOGLE_OAUTH_CLIENT_ID/SECRET` під час apply.

> **Egress dependency:** OAuth Source `provider_type=google` валідується
> через discovery doc (`accounts.google.com/.well-known/openid-configuration`)
> і fetch-ить JWKS/userinfo. Allowlist цих FQDN-ів у
> `platform/network-policies/platform-egress-deny.yaml` (блок
> `authentik/egress-allowlist`): `accounts.google.com`,
> `oauth2.googleapis.com`, `www.googleapis.com`. Без цього apply падає
> у `Network is unreachable` і `BlueprintInstance.status = error`.

### 14. GitHub image pull token (опційно, якщо private registry)

```bash
docker_config=$(echo -n '{"auths":{"ghcr.io":{"username":"nexora-ci","password":"'$GH_PAT'","auth":"'$(echo -n nexora-ci:$GH_PAT | base64)'"}}}' | base64 -w 0)

vault kv put kv/nexora/develop/registry/ghcr \
  .dockerconfigjson=$docker_config
```

Materialize додати окремим `ExternalSecret`, коли з'явиться приватний
image (на старті Nexora образи публічні / Hetzner registry).

## Checklist перед першим `argocd sync bootstrap-secrets`

- [ ] Vault init, unseal, OIDC auth, Kubernetes auth — пройдені (див. `../vault/README.md`).
- [ ] `kv/nexora/develop/cnpg/superuser` записаний.
- [ ] `kv/nexora/develop/cnpg/authentik-superuser` записаний.
- [ ] `kv/nexora/develop/authentik/postgres` записаний.
- [ ] `kv/nexora/develop/cnpg/backup-s3` записаний.
- [ ] `kv/nexora/develop/object-storage/loki` записаний.
- [ ] `kv/nexora/develop/object-storage/tempo` записаний.
- [ ] `kv/nexora/develop/rabbitmq/admin` записаний.
- [ ] `kv/nexora/develop/authentik/bootstrap` записаний.
- [ ] `kv/nexora/develop/grafana/admin` записаний.
- [ ] `kv/nexora/develop/vault-oidc` (тільки після того, як Authentik
      blueprint згенерував provider).
- [ ] `kv/nexora/develop/alerts/telegram` записаний.
- [ ] `kv/nexora/develop/authentik/google-oauth` записаний (після створення OAuth Client ID у Google Cloud Console).
- [ ] Hetzner Object Storage buckets `nexora-develop-cnpg-backups`,
      `nexora-develop-loki`, `nexora-develop-tempo` створено.
