#!/usr/bin/env bash
# Build node A as the primary: data checksums, SCRAM over TCP, WAL archiving, commit timestamps.
source "$(dirname "$0")/lib.sh"

DIR=$(node_dir a)
[ -d "$DIR" ] && die "$DIR already exists. Run scripts/teardown.sh first."
chmod 700 "$LAB_DIR" "$LAB_DIR/sock"

SU_PW=$(openssl rand -hex 16)
REPL_PW=$(openssl rand -hex 16)
( umask 077
  printf '127.0.0.1:*:*:postgres:%s\n127.0.0.1:*:*:replicator:%s\n' "$SU_PW" "$REPL_PW" > "$PGPASSFILE"
  printf '%s\n' "$SU_PW" > "$LAB_DIR/.su_pw" )

log "initdb node A (PostgreSQL $(postgres --version | awk '{print $3}'), data checksums on)"
initdb -D "$DIR" -U postgres --pwfile="$LAB_DIR/.su_pw" --data-checksums \
  --auth-local=trust --auth-host=scram-sha-256 --encoding=UTF8 --locale=C > "$LOGS/initdb-a.log"
rm -f "$LAB_DIR/.su_pw"

cat >> "$DIR/postgresql.conf" <<EOF

# ---- pg-ops-lab ----
port = $PORT_A
listen_addresses = '127.0.0.1'
unix_socket_directories = '$LAB_DIR/sock'
password_encryption = 'scram-sha-256'

wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
wal_keep_size = '256MB'
hot_standby = on
hot_standby_feedback = on
wal_log_hints = on                # pg_rewind needs this (checksums already imply it)
track_commit_timestamp = on       # lets the drills measure data loss exactly

archive_mode = on
archive_command = 'test ! -f $ARCHIVE/%f && cp %p $ARCHIVE/%f'
archive_timeout = 60

shared_buffers = '128MB'          # kept small: three clusters on an 8 GB laptop
log_line_prefix = '%m [%p] %q%u@%d '
log_checkpoints = on
log_lock_waits = on
log_min_duration_statement = '1s'
EOF

# Socket access is limited by the 0700 socket directory; anything over TCP needs a SCRAM password.
cat > "$DIR/pg_hba.conf" <<'EOF'
# TYPE  DATABASE     USER        ADDRESS        METHOD
local   all          all                        trust
host    replication  replicator  127.0.0.1/32   scram-sha-256
host    all          all         127.0.0.1/32   scram-sha-256
EOF

start_node a
ok "node A up on port $PORT_A"

q "$PORT_A" -d postgres -v pw="$REPL_PW" <<'SQL'
create role replicator with login replication password :'pw';
create database bank;
SQL
ok "role replicator (REPLICATION only, no superuser) and database bank created"
log "next: scripts/02-seed.sh"
