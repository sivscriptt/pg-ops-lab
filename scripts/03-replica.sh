#!/usr/bin/env bash
# Build a streaming hot standby from the current primary, using a physical replication slot.
source "$(dirname "$0")/lib.sh"

P=$(primary_node); [ -n "$P" ] || die "no primary running"
S=$(other_node "$P")
PP=$(node_port "$P"); SP=$(node_port "$S")
[ -d "$(node_dir "$S")" ] && die "$(node_dir "$S") already exists"

ensure_slot "$PP" "node_$S"
log "pg_basebackup node $P -> node $S (slot node_$S, WAL streamed during the copy)"
t0=$(now_ms)
pg_basebackup -h 127.0.0.1 -p "$PP" -U replicator -D "$(node_dir "$S")" \
  -X stream -S "node_$S" -c fast
configure_standby "$S" "$P"
start_node "$S"
ok "node $S up on port $SP as a hot standby, built in $(secs_since "$t0")s"

streaming() { [ "$(q "$PP" -d postgres -c "select count(*) from pg_stat_replication where application_name = 'node_$S' and state = 'streaming'")" = 1 ]; }
wait_until 30 streaming \
  || die "node $S is not streaming"
q "$PP" -d postgres -F ' | ' -c "select application_name, state, sync_state, client_addr from pg_stat_replication" | sed 's/^/     /'

q "$PP" -c "select core.transfer(2, 3, 1.00)" >/dev/null
ms=$(wait_caught_up "$PP" "$SP")
ok "a committed transfer was visible on node $S after ${ms}ms"

if q "$SP" -c "select core.transfer(2, 3, 1.00)" >/dev/null 2>&1; then
  die "node $S accepted a write"
fi
ok "node $S rejects writes (read-only)"
integrity "$SP" >/dev/null || die "integrity check failed on standby"
ok "integrity checks pass on the standby"

record "Replica build" "catch-up after one commit" "${ms} ms"
log "next: scripts/04-backup.sh"
