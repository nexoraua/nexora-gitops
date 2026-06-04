#!/usr/bin/env bash
set -euo pipefail

ENVIRONMENTS=(${ENVIRONMENTS:-develop staging production})
VAULT_MOUNT="${VAULT_MOUNT:-kv}"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required." >&2
  exit 127
fi

if ! command -v vault >/dev/null 2>&1; then
  echo "vault CLI is required." >&2
  exit 127
fi

: "${VAULT_ADDR:?Set VAULT_ADDR to the target cluster Vault address.}"
: "${VAULT_TOKEN:?Set VAULT_TOKEN with write access to kv/nexora/<env>/registry/ghcr.}"

gh auth status >/dev/null
vault status >/dev/null

username="${GHCR_USERNAME:-$(gh api user --jq .login)}"
token="${GHCR_TOKEN:-$(gh auth token)}"

for environment in "${ENVIRONMENTS[@]}"; do
  vault kv put "${VAULT_MOUNT}/nexora/${environment}/registry/ghcr" \
    username="$username" \
    password="$token" >/dev/null
  echo "Seeded ${VAULT_MOUNT}/nexora/${environment}/registry/ghcr."
done
