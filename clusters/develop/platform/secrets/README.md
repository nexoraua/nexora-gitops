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

### 14. GitHub image pull token (обовʼязковий — `ghcr.io/nexoraua/*` приватні)

Кожен з 3 workloads (`nexora-api`, `nexora-admin`, `nexora-frontend`)
має власний `ExternalSecret/ghcr-pull-secret` у своєму namespace, який
тягне `username` + `password` з одного Vault path і ESO templates
`dockerconfigjson` Secret-у на льоту. Тому в Vault лежать ДВА ключі,
не один blob.

1. Створити **fine-grained PAT** на github.com → Settings → Developer
   settings → Personal access tokens → Fine-grained tokens:
   - Resource owner: `nexoraua`
   - Repository access: All repositories (або тільки `nexora-*`)
   - Permissions: **Packages → Read-only**
   - Expiration: 90 днів (rotation cadence)

2. Seed Vault:
   ```bash
   vault kv put kv/nexora/develop/registry/ghcr \
     username=<твій-github-username> \
     password=<новий-PAT>
   ```

3. Force ESO sync у всіх 3 ns (інакше чекати до 1h refresh):
   ```bash
   for ns in nexora-api nexora-admin nexora-frontend; do
     kubectl -n $ns annotate externalsecret ghcr-pull-secret \
       force-sync=$(date +%s) --overwrite
   done
   ```

> **Rotation:** 1Password нагадування за 7 днів до expiration; новий
> PAT, `vault kv put …` (same path), force-sync. Старий PAT revoke у
> GitHub UI одразу після того як kubelet перетягне новий imagePullSecret
> (по нових pod-ах).

### 15. Admin app runtime config

Admin споживає 3 Secret-и:

- `nexora-admin-runtime` (Vault) — справжні секрети
- `nexora-admin-db-conn` (CNPG, через ESO `kind: SecretStore` з kubernetes provider) — DB connection string з CNPG-managed `nexora-business-develop-app` Secret, ні рядка у Vault
- `ghcr-pull-secret` — див. §14

Vault seed для runtime:

```bash
vault kv put kv/nexora/develop/apps/admin/runtime \
  blind_index_pepper_base64="$(openssl rand -base64 32)" \
  vault_token="<vault-token-з-K8s-auth-role-nexora-admin>"
```

> **Pepper:** генерується ОДИН РАЗ за час життя продукту. Зміна pepper
> інвалідує всі існуючі blind indexes — DB треба перебудувати. Кладеться
> у 1Password vault `Nexora Breakglass` після першої генерації.
>
> **vault_token:** static token — тимчасово до міграції на Vault
> Kubernetes auth (нагадування у follow-up). Згенерувати через
> `vault token create -policy=nexora-app-develop -period=720h` і
> seed-ити сюди.

### 16. API app runtime config

Аналогічно admin, але БЕЗ Authentik client_secret (api валідує JWT, не
користується OIDC code-flow як клієнт). Public OIDC config
(authorities/audiences) живе у `deployment-patch.yaml` env vars.

```bash
vault kv put kv/nexora/develop/apps/api/runtime \
  blind_index_pepper_base64="$(openssl rand -base64 32)" \
  vault_token="<vault-token-K8s-auth-role-nexora-api>"
```

> ⚠️ pepper для api MAЄ збігатись з pepper admin якщо обидва читають
> ті ж blind-indexed таблиці. Краще згенерувати ОДИН pepper і seed-ити
> у обидва path-и (`apps/api/runtime` + `apps/admin/runtime`). Інакше
> один сервіс не зможе шукати по індексах створеним іншим.

### 17. Authentik OIDC client_secret для Nexora Admin

Blueprint `platform/authentik/blueprints/nexora-admin-oidc.yaml`
автоматично створює OAuth2 Provider `nexora-admin` + Application з
fixed `client_id=nexora-admin`. `client_secret` Authentik генерує
автоматично і його треба ОДИН РАЗ скопіювати у Vault після першого
apply:

1. Authentik UI → Providers → `nexora-admin` → Edit
2. Поле "Client Secret" — кнопка "Copy"
3. Seed:
   ```bash
   vault kv put kv/nexora/develop/oidc/nexora-admin \
     client_secret=<скопійоване-значення>
   ```
4. Force-sync admin runtime:
   ```bash
   kubectl -n nexora-admin annotate externalsecret nexora-admin-runtime \
     force-sync=$(date +%s) --overwrite
   ```

> **Rotation:** Authentik UI → Edit → Rotate Client Secret → новий
> `vault kv put` + force-sync. Тримати active session на admin під час
> rotation (новий secret підмінюється на льоту через ESO refresh).

### 18. ArgoCD OIDC client_secret

ArgoCD OAuth2 Provider `argocd` створено вручну через Authentik UI
(client_id `a361e21ee244ed5a8851c1ff2e41c2a8` зафіксований у
`argocd-oidc.yaml` blueprint, але provider сам існував раніше).
ExternalSecret `clusters/develop/platform/secrets/argocd-oidc.yaml`
очікує `client_id` + `client_secret` у Vault path:

```bash
vault kv put kv/nexora/develop/oidc/argocd \
  client_id=<from-authentik-ui> \
  client_secret=<from-authentik-ui>
```

Авто-extract: `nexora-infra/scripts/extract-oidc-from-authentik.sh`
парсить Authentik DB і пише ці значення у
`secrets/develop-oidc-clients.json`; потім
`scripts/seed-vault-from-env.sh --only oidc` seed-ить у Vault.

Force-sync після оновлення:
```bash
kubectl -n argocd annotate externalsecret argocd-oidc \
  force-sync=$(date +%s) --overwrite
```

### 19. Grafana OIDC client_secret

Аналогічно §18 для Grafana provider:

```bash
vault kv put kv/nexora/develop/oidc/grafana \
  client_id=<from-authentik-ui> \
  client_secret=<from-authentik-ui>

kubectl -n monitoring annotate externalsecret grafana-oidc \
  force-sync=$(date +%s) --overwrite
```

### 20. Tailscale subnet router OAuth credentials

In-cluster Tailscale subnet router pod автентифікується через
OAuth client (Tailscale Admin Console → Settings → OAuth clients →
"Create OAuth client", scopes: `devices:write`, ACL tags: `tag:k8s`,
`tag:nexora-develop`):

```bash
vault kv put kv/nexora/develop/tailscale \
  client_id="<oauth-client-id>" \
  client_secret="<oauth-client-secret>"
```

> **Не плутати** з `TAILSCALE_AUTH_KEY` (one-shot auth key для
> bootstrap самого node-а — окремий механізм, не зберігається у Vault).
>
> **Rotation:** Tailscale Admin Console → OAuth clients → revoke old,
> create new → `vault kv put` + force-sync subnet router pod (delete
> pod → re-pull token).

### 21. Vault Raft snapshot token + S3 credentials

Vault snapshot CronJob (`platform/vault/snapshot-cronjob.yaml`)
використовує periodic token + Hetzner OS bucket для off-cluster
backup-ів.

**Token creation** (after Vault is bootstrapped):

```bash
# Створи policy. /sys/storage/raft/snapshot — sudo-protected path: знаття
# снапшоту вимагає І read, І sudo. Лише read → CronJob дістає HTTP 403
# (алерт VaultSnapshotCronJobMissing гасне, але бекапи не знімаються).
vault policy write vault-snapshot - <<EOF
path "sys/storage/raft/snapshot" { capabilities = ["read", "sudo"] }
EOF

# Periodic token (TTL 30d, renewable, prefixed для розпізнавання)
TOKEN=$(vault token create \
  -policy=vault-snapshot \
  -period=720h \
  -display-name=vault-raft-snapshot-develop \
  -format=json | jq -r .auth.client_token)

vault kv put kv/nexora/develop/vault/snapshot-token token="$TOKEN"
```

**S3 credentials** (one Hetzner OS project key, also used by CNPG —
acknowledged blast-radius gap):

```bash
vault kv put kv/nexora/develop/vault/snapshots-s3 \
  ACCESS_KEY_ID="$HCLOUD_S3_ACCESS_KEY" \
  SECRET_ACCESS_KEY="$HCLOUD_S3_SECRET_KEY"
```

**Bucket setup** (Hetzner Console — pre-create):
- Name: `nexora-vault-snapshots-develop`
- Lifecycle policy: 30d retention (delete objects older than 30d)
- Optional: enable Object Lock GOVERNANCE for compliance (Hetzner
  implementation is weak — див. ADR-I-0005)

Перший snapshot після setup має зʼявитися протягом 6h (cron `0 */6 * * *`).
Перевірка: `aws --endpoint-url https://fsn1.your-objectstorage.com s3 ls s3://nexora-vault-snapshots-develop/`.

## .env-first workflow

Усі секції вище можна виконати одним викликом замість manual `vault kv put` ланцюга:

```bash
# 1. Заповнити .env / .json файли у nexora-infra/secrets/ (див. secrets/README.md)
# 2. Один pass для всіх секретів:
cd /Users/mykoladorofii/workspace/nexora/nexora-infra
scripts/seed-vault-from-env.sh --dry-run     # перевірити що буде
scripts/seed-vault-from-env.sh               # apply
scripts/verify-vault-vs-env.sh               # diff vault vs local
```

OIDC client_secret-и (§10, §17, §18, §19) — окремий flow після того
як Authentik blueprint apply пройшов:

```bash
# Витягнути client_secret-и з Authentik DB у local JSON
scripts/extract-oidc-from-authentik.sh
# Seed у Vault
scripts/seed-vault-from-env.sh --only oidc
# Force-sync відповідні ExternalSecrets
for ns_app in "argocd argocd-oidc" "monitoring grafana-oidc" "nexora-admin nexora-admin-runtime"; do
  set -- $ns_app
  kubectl -n "$1" annotate externalsecret "$2" force-sync=$(date +%s) --overwrite
done
```

Transit keys (§22-imported during DR):

```bash
# Після того як oidc-bootstrap.yaml Job створив транзит ключі (exportable=true):
scripts/export-transit-keys.sh
# Тоді .env файл копіюється на off-laptop encrypted medium як DR insurance.
```

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
- [ ] `kv/nexora/develop/registry/ghcr` записаний (GitHub fine-grained PAT з Packages Read).
- [ ] `kv/nexora/develop/apps/admin/runtime` записаний (pepper + vault_token).
- [ ] `kv/nexora/develop/apps/api/runtime` записаний (pepper + vault_token, той самий pepper що в admin якщо ділять blind indexes).
- [ ] `kv/nexora/develop/oidc/nexora-admin` записаний (після того як Authentik blueprint nexora-admin-oidc згенерував provider, скопіювати client_secret з UI).
- [ ] `kv/nexora/develop/oidc/argocd` записаний (Authentik provider `argocd` — див. §18).
- [ ] `kv/nexora/develop/oidc/grafana` записаний (Authentik provider `grafana` — див. §19).
- [ ] `kv/nexora/develop/tailscale` записаний (Tailscale OAuth client — див. §20).
- [ ] `kv/nexora/develop/vault/snapshot-token` записаний (periodic Vault token для raft snapshot CronJob — див. §21).
- [ ] `kv/nexora/develop/vault/snapshots-s3` записаний (Hetzner OS креди для snapshot bucket — той самий keypair що cnpg/backup-s3).
- [ ] Hetzner Object Storage buckets створено: `nexora-cnpg-backups-develop`, `nexora-cnpg-backups-authentik-develop`, `nexora-vault-snapshots-develop`, `nexora-develop-loki`, `nexora-develop-tempo`.
