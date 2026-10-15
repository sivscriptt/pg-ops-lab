# SQL Server to PostgreSQL: the same jobs, different tools

I started on Microsoft SQL Server. This is how each part of the lab maps to what I would do there.

| Job | SQL Server | PostgreSQL (this lab) |
|---|---|---|
| Full backup | `BACKUP DATABASE ... TO DISK` | `pg_basebackup` (whole cluster, physical) |
| Transaction log backups | `BACKUP LOG` on a schedule, FULL recovery model | Continuous WAL archiving via `archive_command`, one file per 16 MB segment |
| Verify a backup | `RESTORE VERIFYONLY`, `WITH CHECKSUM` | `pg_verifybackup` against a SHA-256 manifest, plus data checksums (`initdb --data-checksums`) |
| Point-in-time restore | `RESTORE LOG ... WITH STOPAT` / `STOPBEFOREMARK` | `recovery_target_time` / `recovery_target_xid` with `recovery_target_inclusive = off` |
| Find a bad transaction | `fn_dblog` / `fn_dump_dblog` on the log | `pg_waldump` on archived WAL, filtered by relation |
| Restore beside production | `RESTORE ... WITH MOVE` to a new database name | Restore to a separate instance on another port |
| Integrity check | `DBCC CHECKDB` | Data checksums, `amcheck` / `pg_amcheck`, plus business-level checks (the ledger) |
| HA replica | Always On availability group secondary | Streaming standby with a replication slot |
| Synchronous vs async commit | AG availability mode: synchronous-commit / asynchronous-commit | `synchronous_standby_names` set or empty |
| Failover | `ALTER AVAILABILITY GROUP ... FAILOVER` / `FORCE_FAILOVER_ALLOW_DATA_LOSS` | `pg_promote()` / `pg_ctl promote` |
| Listener / app redirect | AG listener | libpq multi-host string with `target_session_attrs=read-write` (or a proxy or VIP) |
| Bring old primary back | Resume data movement, reseed if diverged | `pg_rewind`, then rejoin as a standby |
| Log retention for replicas | Log can't truncate until the secondary hardens it | Replication slots hold WAL; watch for abandoned slots |
| Least privilege | Logins, users, roles; `db_backupoperator` | Roles; a `replicator` role with only `REPLICATION` |
| Encrypted logins | Windows / SQL auth, TLS | SCRAM-SHA-256 over TCP, TLS |
