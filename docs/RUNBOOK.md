# Runbook

These are the steps behind each script, written so someone on call could follow
them without reading the code.

Ports: node A is 55432, node B is 55433, and the throwaway restore instance is 55434.
`$ARCHIVE` is the WAL archive folder and `$BACKUPS` is where base backups go.

## 1. Build a replica

Use this for a new replica, or to rebuild one that fell too far behind.

1. On the primary, create a replication slot so it holds on to the WAL the replica
   still needs:

       select pg_create_physical_replication_slot('node_b');

2. Copy the primary while streaming WAL at the same time:

       pg_basebackup -h <primary> -U replicator -D <datadir> -X stream -S node_b -c fast

3. In the replica's `postgresql.auto.conf`, set `port`, `primary_conninfo` (with
   `application_name=node_b`) and `primary_slot_name = 'node_b'`. Create an empty
   `standby.signal` file.
4. Start it.

To check it worked:

- `pg_stat_replication` on the primary should show `node_b | streaming`.
- Make a commit on the primary and check it appears on the replica.
- Try a write on the replica. It should fail with a read-only error.

To undo it, stop the replica, delete its folder, and drop the slot on the primary
with `select pg_drop_replication_slot('node_b')`. Don't skip dropping the slot. A
slot nobody uses keeps WAL forever and will eventually fill the disk.
`status.sh` shows how much WAL each slot is holding.

## 2. Take a backup and check it

Do this on a schedule, and always straight after a failover, because the timeline
changes and old backups won't line up with it anymore.

1. Take the backup:

       pg_basebackup -D $BACKUPS/base-<time> -Fp -X stream -c fast --manifest-checksums=SHA256

2. Verify it:

       pg_verifybackup $BACKUPS/base-<time>

   This checks every file against its checksum and makes sure the WAL needed to
   start it is there.
3. Keep the last few backups. Then clear WAL older than the oldest backup you kept:

       pg_archivecleanup $ARCHIVE <start segment of oldest kept backup>

A backup you never checked isn't really a backup. Actually restoring it is the
real test, which is what the next section does.

## 3. Recover from a bad UPDATE or DELETE

Use this when someone ran a bad statement and it committed. The server is fine,
but the data is wrong.

Don't restore over production, and don't switch to the restored copy by default.
Anything committed after the mistake would be lost.

1. **Save the evidence.** Run `select pg_switch_wal()` and wait for that file to
   show up in `$ARCHIVE`.

2. **Find the transaction in the WAL.** Don't count on statement logs, because
   production usually has them off.
   - Get the table's file with `select pg_relation_filepath('core.accounts')`. It
     returns something like `base/16385/16399`.
   - Count WAL records per transaction for that table:

         pg_waldump -p $ARCHIVE --relation=1663/16385/16399 -r Heap <backup start segment> <current segment>

   - The bad one touches almost every row, while normal transfers touch a few.
     Rolled-back attempts show up too, so check `pg_xact_status(xid)` and take the
     newest one that says `committed`.

3. **Restore to a separate instance.** Copy the latest backup into a new folder and
   add this to its `postgresql.auto.conf`:

       port = 55434
       archive_mode = off
       restore_command = 'cp $ARCHIVE/%f %p'
       recovery_target_xid = '<xid>'
       recovery_target_inclusive = off
       recovery_target_action = 'promote'

   `archive_mode = off` matters. A restored copy must never write into the live
   archive. `inclusive = off` makes it stop just before the bad commit. Create
   `recovery.signal` and start it. The log should say `recovery stopping before
   commit of transaction <xid>`.

4. **Check the restore.** Run the integrity checks. Then compare the rows
   committed before the mistake on both sides. They should match exactly. This
   uses `pg_xact_commit_timestamp(xmin)`, so `track_commit_timestamp` has to be on.

5. **Fix production.** The ledger wasn't touched, so rebuild the balances from it
   in one transaction on the live database. Nobody has to go offline. If the data
   you need to fix has nothing to rebuild it from, copy the affected rows out of
   the restored instance instead, with `postgres_fdw` or `pg_dump -t`.

6. **Prove the fix.** For every account, take the fixed balance, subtract
   everything posted after the mistake, and compare it with the restored copy.
   They should be equal.

If the checks fail, roll back the fix transaction before committing. The restored
instance stays up until you remove it with `teardown.sh restore`.

## 4. Fail over when the primary dies

Use this when the primary is down and won't be back in time.

1. Make sure it's really down. Check from more than one place, not just from the
   app's error. If you promote while the old primary is still running, you end up
   with two primaries.
2. Promote the replica with `pg_ctl -D <datadir> promote` or `select pg_promote()`.
3. Apps that use a connection string with both servers will find the new primary
   on their own:

       host=a,b port=55432,55433 target_session_attrs=read-write

4. Run the integrity checks on the new primary.
5. Take a new backup (section 2).

Once the old server is back, you can measure what was lost. Start it on its own,
with `listen_addresses=''` and `archive_mode=off`, and compare its last commits
with the new primary.

- With async replication, you lose whatever WAL hadn't been sent yet.
- With `synchronous_standby_names` set, you lose nothing, but every commit has to
  wait for the replica.

## 5. Bring the old primary back

Do this after a failover, once the old server is reachable again.

1. Shut it down cleanly. `pg_rewind` won't work on a crashed server, so start it
   once on its own and stop it with `-m fast`.
2. Create a slot for it on the new primary.
3. Rewind it:

       pg_rewind -D <old datadir> --source-server="host=<new primary> user=postgres dbname=postgres"

4. `pg_rewind` copies the config files over from the new primary, so set `port`,
   `primary_conninfo` and `primary_slot_name` back for this server. Clear
   `synchronous_standby_names`, and create `standby.signal`.
5. Start it and check it shows as `streaming` in `pg_stat_replication` on the new
   primary.

It should pick up a new commit within milliseconds and refuse writes.
