#!/bin/sh
# Docker secrets are mounted as files, but redeliver reads its admin token
# from the ADMIN_TOKEN environment variable. This wrapper bridges the two:
# if ADMIN_TOKEN_FILE is set, its content becomes ADMIN_TOKEN. The token then
# only exists inside the process and never shows up in "docker inspect".
set -eu

if [ -n "${ADMIN_TOKEN_FILE:-}" ]; then
  if [ ! -r "$ADMIN_TOKEN_FILE" ]; then
    echo "entrypoint: cannot read ADMIN_TOKEN_FILE ($ADMIN_TOKEN_FILE)" >&2
    exit 1
  fi
  ADMIN_TOKEN="$(cat "$ADMIN_TOKEN_FILE")"
  export ADMIN_TOKEN
fi

exec "$@"
