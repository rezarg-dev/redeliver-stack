#!/usr/bin/env bash
# Prepares a fresh checkout: creates .env and generates the secrets.
# Safe to run again, existing files are never overwritten.
set -euo pipefail
cd "$(dirname "$0")/.."

random_string() {
  # 32 random bytes, base64 without the characters that are awkward in
  # shells and URLs.
  openssl rand -base64 32 | tr -d '/+=\n'
}

create_secret() {
  local file="secrets/$1"
  if [[ -s "$file" ]]; then
    echo "kept     $file"
    return
  fi
  random_string > "$file"
  # Compose mounts file secrets with the permissions they have on the host,
  # and the containers read them as unprivileged users with different ids.
  # So the files are world-readable, and the directory is what keeps other
  # users on this machine out.
  chmod 644 "$file"
  echo "created  $file"
}

mkdir -p secrets
chmod 700 secrets

create_secret admin_token

if [[ -f .env ]]; then
  echo "kept     .env"
else
  cp .env.example .env
  echo "created  .env"
fi
