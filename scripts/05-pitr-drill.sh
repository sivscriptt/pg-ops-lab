#!/usr/bin/env bash
# Point-in-time recovery drill.
#   1. Run transfer load on the primary.
#   2. Mid-load, someone runs UPDATE core.accounts SET balance = 0 with no WHERE clause.
#   3. Find the bad transaction in the archived WAL with pg_waldump (no statement logging needed).
#   4. Restore the latest base backup to a scratch instance, stopping just before that transaction.
#   5. Prove the restore lost nothing committed before the incident.
#   6. Repair the primary in place by rebuilding balances from the ledger, and cross-check
#      against the restored copy. Pass --no-repair to leave the primary broken for inspection.
source "$(dirname "$0")/lib.sh"
REPAIR=1; [ "${1:-}" = --no-repair ] && REPAIR=0
LOAD_SECS=${LOAD_SECS:-40}

P=$(primary_node); [ -n "$P" ] || die "no primary running"
PP=$(node_port "$P"); RP=$PORT_RESTORE; RDIR=$(node_dir restore)
BASE=$(ls -d "$BACKUPS"/base-* 2>/dev/null | sort | tail -1)
[ -n "$BASE" ] || die "no base backup. Run scripts/04-backup.sh."
STARTSEG=$(sed -n 's/^START WAL LOCATION: .* (file \(.*\))$/\1/p' "$BASE/backup_label")
[ "$((16#${STARTSEG:0:8}))" = "$(timeline "$PP")" ] \
  || die "latest backup is from an older timeline (a failover happened since). Run scripts/04-backup.sh."

# ---- 1-2: load, then the incident ---------------------------------------------------------
log "transfer load on node $P for ${LOAD_SECS}s ($LOAD_CLIENTS clients)"
start_load "$PP" "$LOAD_SECS" "$LOGS/pitr-load.txt"
sleep 15

log "INCIDENT: UPDATE core.accounts SET balance = 0;   (no WHERE clause, autocommit)"
XID=""
for attempt in 1 2 3 4 5; do
  # The fat-fingered statement competes with live transfers for row locks, so it can lose
  # a deadlock and roll back. A real operator would just hit enter again.
  if XID=$(q "$PP" 2>/dev/null <<'SQL'
begin;
select pg_current_xact_id();
update core.accounts set balance = 0;
commit;
SQL
  ); then break; fi
  XID=""
  warn "incident statement lost a deadlock and rolled back, retrying ($attempt)"
done
[ -n "$XID" ] || die "could not run the incident statement"
INC_TS=$(q "$PP" -c "select pg_xact_commit_timestamp(($XID % 4294967296)::text::xid)")
ok "committed as xid $XID at $INC_TS ($(q "$PP" -c "select count(*) from core.accounts where balance = 0") of $(q "$PP" -c "select count(*) from core.accounts") balances now zero)"
log "load keeps running on the damaged data until the timer ends..."
wait "$LOADPID" || true
ok "load finished: $(load_tps "$LOGS/pitr-load.txt") TPS"

SEG=$(q "$PP" -d postgres -c "select pg_walfile_name(pg_switch_wal())")
wait_until 30 "[ -f '$ARCHIVE/$SEG' ]" || die "segment $SEG was never archived"
ok "WAL switched and archived through $SEG"

# ---- 3: forensics ---------------------------------------------------------------------------
log "forensics: newest committed transaction that rewrote most of core.accounts"
RELPATH=$(q "$PP" -c "select pg_relation_filepath('core.accounts')")       # base/<db oid>/<relfilenode>
REL="1663/$(echo "$RELPATH" | cut -d/ -f2)/$(echo "$RELPATH" | cut -d/ -f3)"
NACC=$(q "$PP" -c "select count(*) from core.accounts")
# Per transaction: heap records on the table and the position of its last record.
pg_waldump -p "$ARCHIVE" --relation="$REL" -r Heap "$STARTSEG" "$SEG" 2>/dev/null \
  | awk -F'tx: *' '{ split($2, a, ","); n[a[1]]++; last[a[1]] = NR } END { for (x in n) print n[x], last[x], x }' \
  | awk -v min=$((NACC / 2)) '$1 >= min' | sort -k2 -rn > "$LOGS/pitr-forensics.txt" || true
FOUND=""
echo "     candidates (records, xid, status), newest first:"
while read -r cnt _ x; do
  st=$(q "$PP" -c "select pg_xact_status('$x'::xid8)")
  echo "       $cnt  $x  $st"
  [ -z "$FOUND" ] && [ "$st" = committed ] && FOUND=$x
done < "$LOGS/pitr-forensics.txt"
[ -n "$FOUND" ] || die "no committed mass update found in WAL"
TRUE_XID=$((XID % 4294967296))
if [ "$FOUND" = "$TRUE_XID" ]; then ok "WAL points at xid $FOUND, which is the incident"
else die "WAL forensics found xid $FOUND but the incident was $TRUE_XID"; fi

# ---- 4: restore to just before it ---------------------------------------------------------
is_up "$RP" && stop_node restore immediate
rm -rf "$RDIR"
log "restoring $(basename "$BASE") to port $RP, recovery_target_xid = $FOUND (exclusive)"
t0=$(now_ms)
cp -R "$BASE" "$RDIR"; chmod 700 "$RDIR"
rm -f "$RDIR/standby.signal"
cat >> "$RDIR/postgresql.auto.conf" <<EOF

# ---- restore drill ----
port = $RP
archive_mode = off                 # never let a restored copy write into the live archive
primary_conninfo = ''
primary_slot_name = ''
restore_command = 'cp $ARCHIVE/%f %p'
recovery_target_xid = '$FOUND'
recovery_target_inclusive = off
recovery_target_action = 'promote'
EOF
touch "$RDIR/recovery.signal"
start_node restore
wait_until 120 "is_primary $RP" || die "restore did not finish recovery (see $LOGS/node-restore.log)"
RTO=$(secs_since "$t0")
ok "restored instance is open read-write after ${RTO}s"
grep -E 'recovery stopping|archive recovery complete|selected new timeline' "$LOGS/node-restore.log" | tail -3 | sed 's/^.*LOG: */     /'

# ---- 5: did we lose anything? -------------------------------------------------------------
ZEROED=$(q "$RP" -c "select count(*) from core.accounts where balance = 0")
BEFORE_PRIMARY=$(q "$PP" -c "select count(*) from core.ledger
  where coalesce(pg_xact_commit_timestamp(xmin), '-infinity') < '$INC_TS'")
RESTORED=$(q "$RP" -c "select count(*) from core.ledger")
AFTER=$(q "$PP" -c "select count(*) / 2 from core.ledger where pg_xact_commit_timestamp(xmin) > '$INC_TS'")
LOST=$((BEFORE_PRIMARY - RESTORED))
echo "     zeroed balances on the restored copy: $ZEROED"
echo "     ledger rows committed before the incident: primary $BEFORE_PRIMARY, restored $RESTORED"
echo "     transfers committed after the incident (only on the primary): $AFTER"
integrity "$RP" || die "integrity failed on the restored copy"
[ "$LOST" = 0 ] && ok "RPO 0: every row committed before the incident is in the restore" \
                || warn "$LOST ledger rows committed before the incident are missing"

# ---- 6: repair ----------------------------------------------------------------------------
if [ "$REPAIR" = 1 ]; then
  log "repair: the ledger was never touched, so rebuild balances from it on the live primary"
  t1=$(now_ms)
  q "$PP" <<'SQL'
begin;
update core.accounts a
set balance = coalesce(l.s, 0), updated_at = now()
from core.accounts a2
left join (select account_id, sum(amount) s from core.ledger group by account_id) l on l.account_id = a2.id
where a.id = a2.id and a.balance <> coalesce(l.s, 0);
commit;
SQL
  ok "balances rebuilt in $(secs_since "$t1")s, no downtime"
  integrity "$PP" || die "integrity failed after repair"
  # Proof for every account: repaired balance minus what moved after the incident
  # must equal the restored (pre-incident) balance, to the cent.
  q "$PP" -c "select a.id, a.balance - coalesce(sum(l.amount), 0)
              from core.accounts a
              left join core.ledger l on l.account_id = a.id
                and pg_xact_commit_timestamp(l.xmin) > '$INC_TS'
              group by a.id, a.balance" > "$LOGS/pitr-expected.txt"
  q "$RP" -c "select id, balance from core.accounts" > "$LOGS/pitr-restored.txt"
  CHECKED=$(wc -l < "$LOGS/pitr-expected.txt" | tr -d ' ')
  DIFF=$(awk -F'|' 'NR == FNR { b[$1] = $2; next } b[$1] + 0 != $2 + 0 { d++ } END { print d + 0 }' \
           "$LOGS/pitr-restored.txt" "$LOGS/pitr-expected.txt")
  [ "$DIFF" = 0 ] && ok "cross-check: all $CHECKED accounts, repaired minus post-incident transfers = restored copy" \
                 || die "cross-check: $DIFF of $CHECKED accounts differ from the restored copy"
fi

record "PITR" "forensics found incident xid" "$([ "$FOUND" = "$TRUE_XID" ] && echo yes || echo no)"
record "PITR" "restore time (RTO)" "${RTO}s"
record "PITR" "rows lost before incident (RPO)" "$LOST"
record "PITR" "post-incident transfers to reconcile" "$AFTER"
log "restored copy left running on port $RP for inspection. Stop it with scripts/teardown.sh restore"
