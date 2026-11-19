#!/bin/sh
# Writes a compressed snapshot of the redeliver database to /backups and
# removes snapshots beyond the newest $BACKUP_KEEP.
set -eu

db="${DATABASE_PATH:-/data/redeliver.db}"
dir="${BACKUP_DIR:-/backups}"
keep="${BACKUP_KEEP:-14}"

if [ ! -f "$db" ]; then
  echo "backup: $db does not exist" >&2
  exit 1
fi

target="$dir/redeliver-$(date -u +%Y%m%dT%H%M%SZ).db"

# Copying the file while the app is writing to it could produce a corrupt
# copy, and would miss whatever is still in the write-ahead log. ".backup"
# goes through SQLite's online backup API and yields a consistent snapshot
# without stopping the app.
sqlite3 "$db" ".timeout 5000" ".backup '$target'"

check="$(sqlite3 "$target" 'PRAGMA integrity_check;')"
if [ "$check" != "ok" ]; then
  echo "backup: integrity check failed: $check" >&2
  rm -f "$target" "$target-wal" "$target-shm"
  exit 1
fi

gzip -9 "$target"
echo "backup: wrote $target.gz ($(wc -c < "$target.gz") bytes)"

# The timestamp in the name sorts chronologically, so everything after the
# first $keep entries in reverse order is old.
find "$dir" -maxdepth 1 -name 'redeliver-*.db.gz' | sort -r | tail -n "+$((keep + 1))" |
  while read -r old; do
    rm -f "$old"
    echo "backup: removed $old"
  done
