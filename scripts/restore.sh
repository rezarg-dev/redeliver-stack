#!/usr/bin/env bash
# Replaces the database with a snapshot made by "make backup".
#
#   ./scripts/restore.sh backups/redeliver-20260101T120000Z.db.gz
#
# Set RESTORE_YES=1 to skip the confirmation prompt.
set -euo pipefail
cd "$(dirname "$0")/.."

file="${1:-}"
if [[ -z "$file" || ! -f "$file" ]]; then
  echo "Usage: ./scripts/restore.sh backups/<snapshot>.db.gz" >&2
  exit 1
fi

# "docker compose run -v" needs an absolute path.
case "$file" in
  /*) snapshot="$file" ;;
  *) snapshot="$PWD/$file" ;;
esac

if [[ "${RESTORE_YES:-}" != "1" ]]; then
  echo "This replaces the current database with $file."
  echo "Everything received since that snapshot will be lost."
  read -r -p "Continue? [y/N] " answer
  [[ "$answer" == [yY] ]] || exit 1
fi

# The app must not have the database open while the file is swapped.
docker compose stop app

# shellcheck disable=SC2016  # the script below runs inside the container
docker compose run --rm --no-deps --entrypoint sh \
  --volume "$snapshot:/snapshot.db.gz:ro" backup -c '
    set -eu
    gunzip -c /snapshot.db.gz > /data/restore.tmp
    check="$(sqlite3 /data/restore.tmp "PRAGMA integrity_check;")"
    if [ "$check" != "ok" ]; then
      echo "restore: snapshot is damaged: $check" >&2
      rm -f /data/restore.tmp /data/restore.tmp-wal /data/restore.tmp-shm
      exit 1
    fi
    # Leftover WAL files belong to the old database and must not be applied
    # to the restored one.
    rm -f /data/redeliver.db-wal /data/redeliver.db-shm /data/restore.tmp-wal /data/restore.tmp-shm
    mv /data/restore.tmp /data/redeliver.db
    # The app runs as the "node" user (uid 1000).
    chown 1000:1000 /data/redeliver.db
  '

docker compose start app
echo "restored $file"
