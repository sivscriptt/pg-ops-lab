| When | Drill | Metric | Value |
|---|---|---|---|
| 2026-10-15 15:57 | Replica build | catch-up after one commit | 22 ms |
| 2026-10-15 15:57 | Base backup | take + verify | 0.8s, 59M |
| 2026-10-15 15:58 | PITR | forensics found incident xid | yes |
| 2026-10-15 15:58 | PITR | restore time (RTO) | 0.8s |
| 2026-10-15 15:58 | PITR | rows lost before incident (RPO) | 0 |
| 2026-10-15 15:58 | PITR | post-incident transfers to reconcile | 6203 |
| 2026-10-15 15:58 | Failover (async) | promote time | 0.3s |
| 2026-10-15 15:58 | Failover (async) | transfers lost | 0 |
| 2026-10-15 15:58 | Failover (async) | load before crash | 301 TPS, 2.013 ms avg commit latency |
| 2026-10-15 15:58 | Failover (async) | rejoin with pg_rewind | 0.9s |
| 2026-10-15 15:59 | Failover (sync) | promote time | 0.3s |
| 2026-10-15 15:59 | Failover (sync) | transfers lost | 0 |
| 2026-10-15 15:59 | Failover (sync) | load before crash | 302 TPS, 2.236 ms avg commit latency |
| 2026-10-15 15:59 | Failover (sync) | rejoin with pg_rewind | 0.9s |
