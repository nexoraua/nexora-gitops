#!/usr/bin/env bash
set -euo pipefail

GITOPS_REPO="${GITOPS_REPO:-nexoraua/nexora-gitops}"
APP_REPOS=(${APP_REPOS:-nexoraua/nexora-backend nexoraua/nexora-frontend})
KEY_TITLE="${KEY_TITLE:-nexora-cd-gitops-write}"
SECRET_NAME="${SECRET_NAME:-GITOPS_DEPLOY_KEY}"
TOKEN_SECRET_NAME="${TOKEN_SECRET_NAME:-GITOPS_TOKEN}"
KEY_DIR="${KEY_DIR:-$(mktemp -d)}"
KEY_PATH="${KEY_PATH:-${KEY_DIR}/gitops_deploy_key}"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required." >&2
  exit 127
fi

gh auth status >/dev/null

mkdir -p "$KEY_DIR"
rm -f "$KEY_PATH" "$KEY_PATH.pub"
ssh-keygen -q -t ed25519 -N "" -C "$KEY_TITLE" -f "$KEY_PATH"

existing_key_ids="$(gh api "repos/${GITOPS_REPO}/keys" \
  --jq ".[] | select(.title == \"${KEY_TITLE}\") | .id")"

if [[ -n "$existing_key_ids" ]]; then
  while IFS= read -r key_id; do
    [[ -z "$key_id" ]] && continue
    gh api --method DELETE "repos/${GITOPS_REPO}/keys/${key_id}" >/dev/null
  done <<< "$existing_key_ids"
fi

if ! create_output="$(gh api --method POST "repos/${GITOPS_REPO}/keys" \
  -f title="$KEY_TITLE" \
  -f key="$(<"$KEY_PATH.pub")" \
  -F read_only=false 2>&1 >/dev/null)"; then
  token="$(gh auth token)"
  for repo in "${APP_REPOS[@]}"; do
    printf '%s' "$token" | gh secret set "$TOKEN_SECRET_NAME" --repo "$repo" >/dev/null
  done

  echo "Deploy key setup failed for ${GITOPS_REPO}; configured ${TOKEN_SECRET_NAME} fallback."
  echo "gh api output: ${create_output}" >&2
  echo "Updated ${TOKEN_SECRET_NAME} in: ${APP_REPOS[*]}."
  exit 0
fi

for repo in "${APP_REPOS[@]}"; do
  gh secret set "$SECRET_NAME" --repo "$repo" < "$KEY_PATH" >/dev/null
done

echo "Configured write deploy key '${KEY_TITLE}' for ${GITOPS_REPO}."
echo "Updated ${SECRET_NAME} in: ${APP_REPOS[*]}."
