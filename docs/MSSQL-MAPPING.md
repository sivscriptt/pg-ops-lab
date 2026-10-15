# SQL Server vs PostgreSQL

I started out on SQL Server, so while building this I kept thinking about how I'd
do each step there. This is that list.

| Task | SQL Server | PostgreSQL (this lab) |
|---|---|---|
| Full backup | `BACKUP DATABASE ... TO DISK` | `pg_basebackup` (copies the whole cluster) |
| Log backups | `BACKUP LOG` on a schedule, full recovery model | WAL archiving with `archive_command`, one file every 16 MB |
| Check a backup | `RESTORE VERIFYONLY`, `WITH CHECKSUM` | `pg_verifybackup`, plus data checksums from `initdb --data-checksums` |
| Restore to a point in time | `RESTORE LOG ... WITH STOPAT` or `STOPBEFOREMARK` | `recovery_target_time` or `recovery_target_xid` with `recovery_target_inclusive = off` |
| Find a bad transaction | `fn_dblog` / `fn_dump_dblog` | `pg_waldump` on the archived WAL, filtered to one table |
| Restore next to production | `RESTORE ... WITH MOVE` under a new database name | Restore to a separate instance on another port |
| Check for corruption | `DBCC CHECKDB` | Data checksums and `pg_amcheck`, plus my own ledger checks |
| Replica for HA | Always On availability group secondary | Streaming replica with a replication slot |
| Sync vs async | Synchronous or asynchronous commit mode on the AG | `synchronous_standby_names` set or empty |
| Fail over | `ALTER AVAILABILITY GROUP ... FAILOVER`, or `FORCE_FAILOVER_ALLOW_DATA_LOSS` | `pg_promote()` or `pg_ctl promote` |
| Point apps at the new primary | AG listener | Connection string with both hosts and `target_session_attrs=read-write` (or a proxy) |
| Bring the old primary back | Resume data movement, reseed if it diverged | `pg_rewind`, then start it as a replica |
| Log kept for replicas | The log can't truncate until the secondary has it | Replication slots hold WAL, so watch for slots nobody uses |
| Least privilege | Logins, users, roles like `db_backupoperator` | Roles. Here `replicator` can only replicate |
| Login security | Windows or SQL auth over TLS | SCRAM-SHA-256 passwords over TCP, plus TLS |
