#!/usr/bin/env bash
# Take a base backup with a SHA-256 manifest, verify it, and apply retention to backups and WAL.
source "$(dirname "$0")/lib.sh"
KEEP=${KEEP:-3}

P=$(primary_node); [ -n "$P" ] || die "no primary running"
PP=$(node_port "$P")
DEST="$BACKUPS/base-$(date +%Y%m%dT%H%M%S)"

log "base backup from node $P -> $DEST"
t0=$(now_ms)
pg_basebackup -h 127.0.0.1 -p "$PP" -U replicator -D "$DEST" -Fp -X stream -c fast \
  --manifest-checksums=SHA256 -l "pg-ops-lab $(basename "$DEST")"
took=$(secs_since "$t0")
ok "backup taken in ${took}s ($(du -sh "$DEST" | awk '{print $1}'))"

t0=$(now_ms)
pg_verifybackup -q "$DEST" || die "pg_verifybackup FAILED for $DEST"
ok "pg_verifybackup: every file matches its manifest checksum and the WAL needed to restore is present ($(secs_since "$t0")s)"
sed -n 's/^START WAL LOCATION: .* (file \(.*\))$/     starts at WAL segment \1/p' "$DEST/backup_label"

# Retention: keep the newest $KEEP backups, then drop archived WAL older than the oldest kept one.
ls -d "$BACKUPS"/base-* | sort | awk -v k="$KEEP" '{ a[NR] = $0 } END { for (i = 1; i <= NR - k; i++) print a[i] }' | while read -r old; do
  rm -rf "$old"; warn "retention: removed $(basename "$old")"
done
oldest=$(ls -d "$BACKUPS"/base-* | sort | head -1)
seg=$(sed -n 's/^START WAL LOCATION: .* (file \(.*\))$/\1/p' "$oldest/backup_label")
before=$(ls "$ARCHIVE" | wc -l | tr -d ' ')
pg_archivecleanup "$ARCHIVE" "$seg"
after=$(ls "$ARCHIVE" | wc -l | tr -d ' ')
ok "WAL archive: $before -> $after files (kept everything from $seg on)"

record "Base backup" "take + verify" "${took}s, $(du -sh "$DEST" | awk '{print $1}')"
log "next: scripts/05-pitr-drill.sh"
