# Runbook

Standard operating procedures for the lab. Each one is written the way I would hand it to an on-call colleague: when to use it, the steps, how to check it worked, and how to back out. The scripts in `scripts/` automate exactly these steps.

Conventions: node A listens on 55432, node B on 55433, the scratch restore instance on 55434. `$ARCHIVE` is the WAL archive, `$BACKUPS` holds base backups.

---

## SOP-01 Build a streaming standby

**When:** new replica, or rebuilding one that fell too far behind.

1. On the primary, create a physical slot so it keeps the WAL the standby still needs:
   `select pg_create_physical_replication_slot('node_b');`
2. Copy the cluster while streaming WAL alongside it:
   `pg_basebackup -h <primary> -U replicator -D <datadir> -X stream -S node_b -c fast`
3. In the standby's `postgresql.auto.conf` set `port`, `primary_conninfo` (with `application_name=node_b`) and `primary_slot_name = 'node_b'`. Create `standby.signal`.
4. Start it.

**Check:**
- On the primary, `pg_stat_replication` shows `node_b | streaming`.
- Commit on the primary, then compare `pg_current_wal_lsn()` there with `pg_last_wal_replay_lsn()` on the standby.
- A write on the standby must fail with "read-only transaction".

**Back out:** stop the standby, delete its data directory, and `select pg_drop_replication_slot('node_b')` on the primary. **An abandoned slot keeps WAL forever and will fill the disk.** `status.sh` shows WAL held per slot.

---

## SOP-02 Take and verify a base backup

**When:** on schedule, and always right after a failover (a new timeline needs a new base).

1. `pg_basebackup -D $BACKUPS/base-<ts> -Fp -X stream -c fast --manifest-checksums=SHA256`
2. `pg_verifybackup $BACKUPS/base-<ts>`. This checks every file against the SHA-256 manifest and confirms the WAL needed for consistency is present.
3. Retention: keep the newest N backups, then `pg_archivecleanup $ARCHIVE <oldest kept backup's start segment>`.

**Check:** `pg_verifybackup` exits 0. A backup that was never verified does not count as a backup. Restoring it is the only real proof, which is what SOP-03 does.

---

## SOP-03 Recover from a destructive statement (point-in-time recovery)

**When:** someone ran a bad `UPDATE`/`DELETE` and committed it. The server is healthy; the data is wrong.

**Do not** restore over production, and do not promote the restored copy as the new production by default. Everything committed after the mistake would be thrown away.

1. **Freeze the evidence.** Run `select pg_switch_wal()` and wait for the segment to land in `$ARCHIVE`.
2. **Find the transaction in the WAL.** Statement logs are usually off in production, so don't depend on them.
   - Get the table's file: `select pg_relation_filepath('core.accounts')`, which returns `base/<db oid>/<relfilenode>`.
   - Count heap records per transaction:
     `pg_waldump -p $ARCHIVE --relation=1663/<db oid>/<relfilenode> -r Heap <backup start seg> <current seg>`
   - The bad transaction touches roughly every row. Normal ones touch a few. Take the newest one whose `pg_xact_status(xid)` is `committed`. Aborted attempts also show up in the WAL; ignore them.
3. **Restore to a scratch instance.** Copy the latest base backup and in `postgresql.auto.conf` set:
   ```
   port = 55434
   archive_mode = off                 # a restored copy must never write into the live archive
   restore_command = 'cp $ARCHIVE/%f %p'
   recovery_target_xid = '<xid>'
   recovery_target_inclusive = off    # stop just BEFORE it commits
   recovery_target_action = 'promote'
   ```
   Create `recovery.signal` and start it. The log should say `recovery stopping before commit of transaction <xid>`.
4. **Verify the restore.**
   - The integrity checks pass.
   - Rows committed before the incident match production exactly. Compare using `pg_xact_commit_timestamp(xmin)`, which needs `track_commit_timestamp = on`.
5. **Repair production in place.** In this schema the ledger is append-only and was not touched, so balances are rebuilt from it inside one transaction, with no downtime.
   - For data with no ledger to rebuild from, copy the affected rows out of the restored instance instead, using `postgres_fdw` or `pg_dump -t`.
6. **Prove the repair.** For every account: repaired balance minus everything posted after the incident equals the restored balance.

**Back out:** the repair is a single transaction, so roll it back before commit if the checks fail. The restored instance stays up until you remove it (`teardown.sh restore`).

---

## SOP-04 Unplanned failover

**When:** the primary is gone (host down, storage lost) and will not be back within the outage budget.

1. **Confirm it is really down.** Otherwise you get two primaries: check it from two places, not just the app's error.
2. Promote the standby: `pg_ctl -D <standby datadir> promote` or `select pg_promote()`.
3. Apps use a multi-host connection string and follow on their own:
   `host=a,b port=55432,55433 target_session_attrs=read-write`
4. Run the integrity checks on the new primary.
5. **Take a new base backup (SOP-02).** The timeline changed.

**Measure the loss when the old node comes back.**
- Start it isolated (`listen_addresses=''`, `archive_mode=off`) and compare its last commits with the new primary.
- With asynchronous replication, the window is whatever WAL had not been sent yet.
- With `synchronous_standby_names` set it is zero, at the cost of every commit waiting for the standby.

---

## SOP-05 Rejoin the old primary

**When:** after SOP-04, once the old node is reachable again.

1. Shut it down cleanly. `pg_rewind` refuses a crashed data directory, so start it once (isolated) and stop it with `-m fast`.
2. Create its slot on the new primary.
3. `pg_rewind -D <old datadir> --source-server="host=<new primary> user=postgres dbname=postgres"`
4. `pg_rewind` copies config files from the source, so rewrite `port`, `primary_conninfo` and `primary_slot_name` for this node. Clear `synchronous_standby_names`. Create `standby.signal`.
5. Start it and confirm `streaming` in `pg_stat_replication` on the new primary.

**Check:** it replays a fresh commit within milliseconds and rejects writes.
