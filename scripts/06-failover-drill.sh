#!/usr/bin/env bash
# Unplanned failover drill.
#   1. Transfer load on the primary (async replication by default, --sync for synchronous).
#   2. Crash the primary (pg_ctl stop -m immediate, the same as pulling the power).
#   3. Promote the standby and time it. Clients using a multi-host connection string follow it.
#   4. Start the crashed node in isolation and count exactly which commits never reached the standby.
#   5. pg_rewind the old primary and rejoin it as a standby of the new one.
# Run it again and the roles swap back.
source "$(dirname "$0")/lib.sh"
MODE=async; [ "${1:-}" = --sync ] && MODE=sync
LOAD_SECS=${LOAD_SECS:-30}

P=$(primary_node); S=$(standby_node)
[ -n "$P" ] && [ -n "$S" ] || die "need a running primary and standby (scripts/status.sh)"
PP=$(node_port "$P"); SP=$(node_port "$S")
DSN="host=127.0.0.1,127.0.0.1 port=$PORT_A,$PORT_B dbname=bank user=postgres target_session_attrs=read-write connect_timeout=2"
is_up "$PORT_RESTORE" && { stop_node restore fast; warn "stopped the PITR restore instance to free memory"; }

if [ "$MODE" = sync ]; then
  q "$PP" -d postgres -c "alter system set synchronous_standby_names = 'node_$S'" -c "select pg_reload_conf()" >/dev/null
else
  q "$PP" -d postgres -c "alter system reset synchronous_standby_names" -c "select pg_reload_conf()" >/dev/null
fi
sleep 1
ok "node $P primary, node $S standby, replication $(q "$PP" -d postgres -c "select sync_state from pg_stat_replication where application_name = 'node_$S'")"
echo "     app connection string: $DSN"
echo "     app is talking to port $(psql -X -A -t "$DSN" -c "select inet_server_port()")"

# ---- 1-2: load, then crash ----------------------------------------------------------------
log "transfer load on node $P for ${LOAD_SECS}s ($MODE)"
start_load "$PP" "$LOAD_SECS" "$LOGS/failover-load.txt"
sleep 15
LAG=$(q "$SP" -d postgres -c "select pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())")
log "CRASH: node $P killed (pg_ctl stop -m immediate). Standby replay backlog at that moment: ${LAG} bytes"
t0=$(now_ms)
stop_node "$P" immediate
wait "$LOADPID" || true

# ---- 3: promote ---------------------------------------------------------------------------
pg_ctl -D "$(node_dir "$S")" promote -w >/dev/null
wait_until 60 "is_primary $SP" || die "node $S did not promote"
FAILOVER=$(secs_since "$t0")
ok "node $S promoted to primary in ${FAILOVER}s (timeline $(timeline "$SP"))"
echo "     app is now talking to port $(psql -X -A -t "$DSN" -c "select inet_server_port()")"
integrity "$SP" || die "integrity failed on the new primary"

# ---- 4: exact data loss -------------------------------------------------------------------
# Bring the crashed node up alone (socket only, no archiving) so nothing can reach it,
# and compare what it committed with what the new primary has.
start_node "$P" "-c listen_addresses='' -c archive_mode=off"
OLD=$(q "$PP" -c "select count(*) from core.ledger")
NEW=$(q "$SP" -c "select count(*) from core.ledger")
LOST=$(( (OLD - NEW) / 2 ))
echo "     ledger rows: crashed node $OLD, new primary $NEW"
if [ "$LOST" = 0 ]; then ok "RPO 0: no committed transfer was lost"
else warn "$LOST committed transfers existed only on the crashed node ($MODE replication)"; fi
q "$PP" -d postgres -c "alter system reset synchronous_standby_names" >/dev/null
stop_node "$P" fast

# ---- 5: rejoin ----------------------------------------------------------------------------
log "pg_rewind node $P onto node $S's timeline"
t1=$(now_ms)
ensure_slot "$SP" "node_$P"
pg_rewind -D "$(node_dir "$P")" \
  --source-server="host=127.0.0.1 port=$SP user=postgres dbname=postgres passfile=$PGPASSFILE" 2>&1 \
  | grep -E 'servers diverged|rewinding|no rewind required|Done' | sed 's/^/     /'
configure_standby "$P" "$S"
start_node "$P"
following() { [ "$(q "$SP" -d postgres -c "select count(*) from pg_stat_replication where application_name = 'node_$P' and state = 'streaming'")" = 1 ]; }
wait_until 60 following || die "node $P did not rejoin"
ms=$(wait_caught_up "$SP" "$PP")
ok "node $P rejoined as a standby of node $S in $(secs_since "$t1")s, caught up ${ms}ms after"

TPS=$(load_tps "$LOGS/failover-load.txt"); LAT=$(load_latency "$LOGS/failover-load.txt")
record "Failover ($MODE)" "promote time" "${FAILOVER}s"
record "Failover ($MODE)" "transfers lost" "$LOST"
record "Failover ($MODE)" "load before crash" "${TPS:-?} TPS, ${LAT:-?} ms avg commit latency"
record "Failover ($MODE)" "rejoin with pg_rewind" "$(secs_since "$t1")s"
echo
"$LAB_ROOT/scripts/status.sh"
