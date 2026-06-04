#!/usr/bin/env bash
set -euo pipefail

ENVIRONMENT="${1:-${ENVIRONMENT:-}}"
VAULT_MOUNT="${VAULT_MOUNT:-kv}"

if [[ -z "$ENVIRONMENT" ]]; then
  echo "Usage: ENVIRONMENT=<develop|staging|production> $0" >&2
  echo "   or: $0 <develop|staging|production>" >&2
  exit 64
fi

case "$ENVIRONMENT" in
  develop|staging|production) ;;
  *)
    echo "Unsupported environment: ${ENVIRONMENT}" >&2
    exit 64
    ;;
esac

if ! command -v vault >/dev/null 2>&1; then
  echo "vault CLI is required." >&2
  exit 127
fi

: "${VAULT_ADDR:?Set VAULT_ADDR to the target cluster Vault address.}"
: "${VAULT_TOKEN:?Set VAULT_TOKEN with write access to kv/nexora/<env>/apps/*/runtime.}"
: "${NEXORA_DB_CONNECTION_STRING:?Set NEXORA_DB_CONNECTION_STRING.}"

vault status >/dev/null

blind_index_pepper="${NEXORA_BLIND_INDEX_PEPPER_BASE64:-$(openssl rand -base64 32)}"
api_vault_token="${NEXORA_API_VAULT_TOKEN:-${NEXORA_VAULT_TOKEN:-}}"
admin_vault_token="${NEXORA_ADMIN_VAULT_TOKEN:-${NEXORA_VAULT_TOKEN:-}}"

vault kv put "${VAULT_MOUNT}/nexora/${ENVIRONMENT}/apps/api/runtime" \
  connection_string="$NEXORA_DB_CONNECTION_STRING" \
  blind_index_pepper_base64="$blind_index_pepper" \
  vault_token="$api_vault_token" \
  auth_user_authority="${NEXORA_AUTH_USER_AUTHORITY:-}" \
  auth_user_issuer="${NEXORA_AUTH_USER_ISSUER:-}" \
  auth_user_audience="${NEXORA_AUTH_USER_AUDIENCE:-nexora-mobile}" \
  auth_user_require_https_metadata="${NEXORA_AUTH_USER_REQUIRE_HTTPS_METADATA:-true}" \
  auth_admin_authority="${NEXORA_AUTH_ADMIN_AUTHORITY:-}" \
  auth_admin_issuer="${NEXORA_AUTH_ADMIN_ISSUER:-}" \
  auth_admin_audience="${NEXORA_AUTH_ADMIN_AUDIENCE:-nexora-admin}" \
  auth_admin_require_https_metadata="${NEXORA_AUTH_ADMIN_REQUIRE_HTTPS_METADATA:-true}" >/dev/null

vault kv put "${VAULT_MOUNT}/nexora/${ENVIRONMENT}/apps/admin/runtime" \
  connection_string="$NEXORA_DB_CONNECTION_STRING" \
  blind_index_pepper_base64="$blind_index_pepper" \
  vault_token="$admin_vault_token" >/dev/null

echo "Seeded app runtime secrets for ${ENVIRONMENT}."
