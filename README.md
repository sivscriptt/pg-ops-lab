# pg-ops-lab

I built this to practise the parts of database admin work you hope you never need:
building a replica, restoring a backup after someone breaks the data, and failing
over when the primary dies. Everything is a script, so I can run the same drill
again and get real numbers instead of guessing.

It runs PostgreSQL 17 on my laptop (M1 MacBook Air, 8 GB) using the plain Postgres
binaries. No Docker.

## The database

A small banking setup: customers, accounts and a ledger. Every transfer writes two
ledger rows, a debit and a credit, and an account's balance is just the total of
its ledger rows. That gives me an easy way to check nothing is broken. The whole
ledger has to add up to zero, and every balance has to match its rows. Every drill
runs this check at the end.

While the drills run, pgbench keeps about 300 transfers a second going, so nothing
is tested on an idle database.

## Results

From my last full run:

| Test | Result |
|---|---|
| New commit shows up on the replica | 22 ms |
| Take a backup and verify it | 0.8 s |
| Restore to just before a bad UPDATE | 0.8 s, nothing lost |
| Fix the live database after that UPDATE | 0.1 s, no downtime |
| Kill the primary and promote the replica | 0.3 s, no transfers lost |
| Bring the old primary back as a replica | 0.9 s |
| Extra cost of synchronous replication | about 0.2 ms per commit |

Every run is logged in `results/drill-log.md`.

## The restore drill

Halfway through the load, I run `UPDATE core.accounts SET balance = 0` with no
WHERE clause. Then the script has to:

1. Find that transaction in the WAL with `pg_waldump`. I didn't want this to depend
   on statement logging, because production usually has it off.
2. Restore the last backup to a separate instance, stopping right before that
   transaction.
3. Check that nothing committed before the mistake is missing.
4. Fix the live database.

Step 4 was the interesting part. My first thought was to switch over to the
restored copy, but by the time it's ready, the live database has kept taking
transfers. In my run that was 6,203 transfers that would have been thrown away.
The ledger wasn't touched, so I rebuilt the balances from it on the live database
and only used the restored copy to prove every account matched.

One thing I didn't expect: in the early runs, the bad UPDATE kept losing deadlocks
to the live transfers and rolling back, and those rollbacks still show up in the
WAL. So the script looks for the newest *committed* transaction that touched most
of the table, not just the biggest one.

## The failover drill

The script kills the primary with `pg_ctl stop -m immediate` (the same as pulling
the plug) and promotes the replica. The app connection string lists both servers
with `target_session_attrs=read-write`, so clients find the new primary on their
own.

To count exactly what was lost, I start the crashed server on its own, with no
network access, and compare its ledger with the new primary's. Then `pg_rewind`
brings it back as a replica. Run the script again and the roles swap back.

Run it with `--sync` to compare async and synchronous replication. On one machine
async lost nothing too, but over a real network it would, and synchronous mode is
how you close that gap.

## Running it

You need PostgreSQL 17 with `pg_basebackup`, `pg_rewind`, `pg_waldump` and
`pgbench`. Set `PGBIN` in `lab.env` to point at them.

    ./scripts/01-primary.sh        # primary with checksums, archiving, SCRAM
    ./scripts/02-seed.sh           # 10,000 customers, 20,001 accounts
    ./scripts/03-replica.sh        # streaming replica with a slot
    ./scripts/04-backup.sh         # backup, verify, clean old WAL
    ./scripts/05-pitr-drill.sh     # the restore drill
    ./scripts/06-failover-drill.sh # add --sync for synchronous
    ./scripts/status.sh
    ./scripts/teardown.sh

The data lives in `~/.pg-ops-lab`, outside the repo.

## Docs

- `docs/RUNBOOK.md` has each procedure written as a step by step SOP.
- `docs/MSSQL-MAPPING.md` exists because I started on SQL Server. It lines up each
  step with what I'd do there (log backups, STOPBEFOREMARK, Always On and so on).

## What's missing

- Everything runs on one machine.
- Promotion is manual. In production, Patroni or repmgr would handle it, but I
  wanted to do the steps by hand first.
- Backups sit on the same disk. A real setup would send them to separate storage
  with something like pgBackRest or Barman.
