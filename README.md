# pg-ops-lab

A PostgreSQL 17 operations lab built around a small core-banking database. It covers:

- streaming replication
- verified backups
- point-in-time recovery from a real mistake
- unplanned failover

Each one is a repeatable drill script that measures its own result. It runs on a laptop with plain PostgreSQL binaries. No Docker.

## Results

From a clean run on a MacBook Air (M1, 8 GB), all nodes on localhost, with 300 transfers per second running throughout. The full log is in [`results/drill-log.md`](results/drill-log.md).

| Drill | Result |
|---|---|
| Build a standby, then see a commit on it | **22 ms** after commit |
| Base backup, SHA-256 manifest verified | **0.8 s** for 59 MB |
| Find the bad `UPDATE` in the WAL | **exact xid**, no statement logging needed |
| Restore to just before it (RTO) | **0.8 s** |
| Rows committed before the incident that were lost (RPO) | **0** |
| Repair production in place, no downtime | **0.1 s**, all 20,001 accounts proven to the cent |
| Crash the primary, promote the standby | **0.3 s**, apps reconnect on their own |
| Committed transfers lost on failover | **0** (async and sync) |
| Cost of synchronous replication | **+0.22 ms** per commit (2.01 ms vs 2.24 ms) |
| Rejoin the crashed node with `pg_rewind` | **0.9 s** |

## The database

Customers, accounts, and an append-only **double-entry ledger**:

- Every transfer writes one debit and one credit, so the ledger always nets to zero.
- `accounts.balance` is a cached value that can always be rebuilt from the ledger.
- `core.transfer()` locks both accounts in id order, so two opposite transfers can't deadlock.
- `core.verify_integrity()` checks three things: the ledger nets to zero, every balance matches its ledger, and every transfer is balanced. Every drill runs it.

## The drills

| Script | What it does |
|---|---|
| `01-primary.sh` | Creates a primary with data checksums, SCRAM auth on TCP, WAL archiving and commit timestamps. Adds a `replicator` role with REPLICATION only. |
| `02-seed.sh` | Loads the schema, 10,000 customers, 20,001 accounts and opening deposits. |
| `03-replica.sh` | Builds a hot standby with `pg_basebackup` and a replication slot. Checks streaming, catch-up time and read-only mode. |
| `04-backup.sh` | Takes a base backup, runs `pg_verifybackup` on it, keeps the newest 3 backups and cleans old WAL with `pg_archivecleanup`. |
| `05-pitr-drill.sh` | Runs live load, then someone runs `UPDATE core.accounts SET balance = 0` with no WHERE. The script finds that transaction in the WAL with `pg_waldump`, restores to just before it on a scratch instance, proves nothing was lost, repairs production in place, and cross-checks every account. |
| `06-failover-drill.sh [--sync]` | Crashes the primary under load and promotes the standby. Counts exactly which commits were lost, then `pg_rewind`s the old primary back as a standby. Run it again and the roles swap back. |
| `status.sh` | Shows node roles, timelines, replication, WAL held by slots, the archiver and backups. |
| `teardown.sh` | Removes everything (or `teardown.sh restore` for just the scratch instance). |

The step-by-step procedures behind these are in [`docs/RUNBOOK.md`](docs/RUNBOOK.md). [`docs/MSSQL-MAPPING.md`](docs/MSSQL-MAPPING.md) maps each step to its SQL Server equivalent.

## Run it

You need PostgreSQL 17 binaries that include `pg_basebackup`, `pg_rewind`, `pg_waldump` and `pgbench`. I used the EDB macOS build, unzipped, with no installer. Point `PGBIN` in `lab.env` at its `bin` directory.

```sh
./scripts/01-primary.sh
./scripts/02-seed.sh
./scripts/03-replica.sh
./scripts/04-backup.sh
./scripts/05-pitr-drill.sh
./scripts/06-failover-drill.sh
./scripts/06-failover-drill.sh --sync
./scripts/status.sh
./scripts/teardown.sh
```

Cluster data lives in `~/.pg-ops-lab`, outside the repo. Ports are 55432 to 55434.

## Decisions worth explaining

- **Find the bad transaction in the WAL, not the logs.** Production rarely logs every statement. `pg_waldump` filtered to one table shows which transaction rewrote nearly every row. Aborted attempts show up too, so the script checks `pg_xact_status` and takes the newest committed one.
- **Stop at an xid, not a timestamp.** Under concurrent load a timestamp is a guess. With `recovery_target_xid` and `inclusive = off`, recovery stops exactly before that commit.
- **Repair in place instead of promoting the restore.** In the recorded run, promoting the restored copy would have thrown away 6,203 legitimate transfers committed after the mistake. The ledger was untouched, so the balances were rebuilt from it in one transaction. The restored copy is used as proof, not as the fix.
- **A restored copy never archives.** It runs with `archive_mode = off`, so its new timeline can never mix into the live WAL archive.
- **Measure data loss exactly.** `track_commit_timestamp` and starting the crashed node in isolation let the drill compare actual commits, instead of estimating from lag.
- **Least privilege by default.** Replication uses a role that can only replicate. TCP needs a SCRAM password. Sockets live in a directory only the owner can open.

## Limits

- **One machine.** The async loss window is effectively zero on localhost. Over a real network it is the WAL not yet sent, and `--sync` closes it at the cost of commit latency.
- **Manual promotion, on purpose.** These are the steps a failover manager like Patroni or repmgr automates. Doing them by hand shows what that tooling is doing.
- **Backups on the same disk.** Production would ship base backups and WAL to separate storage with pgBackRest or Barman, with encryption and offsite copies.
