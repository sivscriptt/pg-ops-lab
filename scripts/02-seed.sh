#!/usr/bin/env bash
# Load the banking schema and seed customers, accounts and opening deposits.
source "$(dirname "$0")/lib.sh"

P=$(primary_node); [ -n "$P" ] || die "no primary running. Run scripts/01-primary.sh."
PP=$(node_port "$P")

[ "$(q "$PP" -c "select count(*) from pg_namespace where nspname = 'core'")" = 0 ] \
  || die "schema core already exists on node $P"

t0=$(now_ms)
q "$PP" -f "$LAB_ROOT/sql/schema.sql"
q "$PP" -v customers="$SEED_CUSTOMERS" -f "$LAB_ROOT/sql/seed.sql"
q "$PP" -c "vacuum analyze"
ok "seeded in $(secs_since "$t0")s"

q "$PP" -F ' ' -c "select (select count(*) from core.customers) || ' customers, ' ||
                          (select count(*) from core.accounts) || ' accounts, ' ||
                          (select count(*) from core.ledger) || ' ledger rows, ' ||
                          pg_size_pretty(pg_database_size('bank'))" | sed 's/^/     /'
integrity "$PP" || die "integrity check failed after seed"
log "next: scripts/03-replica.sh"
