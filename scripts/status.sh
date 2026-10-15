#!/usr/bin/env bash
# One-screen view of the lab: node roles, timelines, replication, slots, archiver, backups.
source "$(dirname "$0")/lib.sh"

printf '%-8s %-6s %-9s %-8s %s\n' NODE PORT STATE ROLE TIMELINE
for n in a b restore; do
  port=$(node_port $n)
  [ -d "$(node_dir $n)" ] || { printf '%-8s %-6s %s\n' "$n" "$port" "-"; continue; }
  if is_up "$port"; then
    role=$([ "$(in_recovery "$port")" = t ] && echo standby || echo primary)
    printf '%-8s %-6s %-9s %-8s %s\n' "$n" "$port" up "$role" "$(timeline "$port")"
  else
    printf '%-8s %-6s %s\n' "$n" "$port" down
  fi
done

P=$(primary_node)
[ -n "$P" ] || exit 0
PP=$(node_port "$P")
echo; echo "replication from node $P:"
q "$PP" -d postgres -F ' | ' -c "select application_name, state, sync_state,
  coalesce(replay_lag::text, '0') as replay_lag from pg_stat_replication" | sed 's/^/  /'
echo "slots:"
q "$PP" -d postgres -F ' | ' -c "select slot_name, active,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as wal_held from pg_replication_slots" | sed 's/^/  /'
echo "archiver:"
q "$PP" -d postgres -F ' | ' -c "select 'archived ' || archived_count, 'failed ' || failed_count,
  'last ' || coalesce(last_archived_wal, '-') from pg_stat_archiver" | sed 's/^/  /'
echo "  archive size $(du -sh "$ARCHIVE" | awk '{print $1}')"
echo "backups:"
ls -d "$BACKUPS"/base-* 2>/dev/null | while read -r b; do echo "  $(basename "$b")  $(du -sh "$b" | awk '{print $1}')"; done
