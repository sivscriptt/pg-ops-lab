#!/usr/bin/env bash
# Shared helpers for every lab script. Sourced, never run directly.
# Written for the bash 3.2 that ships with macOS, so no associative arrays or mapfile.
set -euo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lab.env
source "$LAB_ROOT/lab.env"

export PATH="$PGBIN:$PATH"
export PGPASSFILE="$LAB_DIR/.pgpass"
export PGHOST="$LAB_DIR/sock"
export PGUSER=postgres
export PGDATABASE=bank

ARCHIVE="$LAB_DIR/wal_archive"
BACKUPS="$LAB_DIR/backups"
LOGS="$LAB_DIR/logs"
RESULTS="$LAB_ROOT/results/drill-log.md"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  FAIL %s\033[0m\n' "$*" >&2; exit 1; }

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }
secs_since() { awk -v a="$1" -v b="$(now_ms)" 'BEGIN { printf "%.1f", (b - a) / 1000 }'; }

node_dir() { echo "$LAB_DIR/node-$1"; }    # a | b | restore
node_port() {
  case "$1" in
    a) echo "$PORT_A" ;;
    b) echo "$PORT_B" ;;
    restore) echo "$PORT_RESTORE" ;;
    *) die "unknown node '$1'" ;;
  esac
}
other_node() { [ "$1" = a ] && echo b || echo a; }

# q <port> [psql args...]: unaligned, tuples only, stop on first error.
q() { local port=$1; shift; psql -X -q -A -t -v ON_ERROR_STOP=1 -p "$port" "$@"; }

is_up() { pg_isready -q -p "$1" >/dev/null 2>&1; }
in_recovery() { q "$1" -d postgres -c "select pg_is_in_recovery()"; }

wait_until() { # wait_until <seconds> '<shell condition>': re-evaluated every 250 ms
  local limit=$1 cond=$2 i
  for i in $(seq 1 $((limit * 4))); do eval "$cond" && return 0; sleep 0.25; done
  return 1
}
is_primary() { is_up "$1" && [ "$(in_recovery "$1")" = f ]; }
is_standby() { is_up "$1" && [ "$(in_recovery "$1")" = t ]; }

# Which of node a / b accepts writes right now. Prints a, b, or nothing.
primary_node() { local n; for n in a b; do is_primary "$(node_port $n)" && { echo $n; return 0; }; done; return 0; }
standby_node() { local n; for n in a b; do is_standby "$(node_port $n)" && { echo $n; return 0; }; done; return 0; }

start_node() { pg_ctl -D "$(node_dir "$1")" -l "$LOGS/node-$1.log" -w -t 120 ${2:+-o "$2"} start >/dev/null; }
stop_node()  { pg_ctl -D "$(node_dir "$1")" -m "${2:-fast}" -w stop >/dev/null; }

# Current timeline. pg_control_checkpoint() lags until the first checkpoint after a promotion,
# so read it from the WAL position on a primary and from the WAL receiver on a standby.
timeline() {
  q "$1" -d postgres -c "select case when pg_is_in_recovery()
      then coalesce((select received_tli from pg_stat_wal_receiver), (select timeline_id from pg_control_checkpoint()))
      else ('x' || substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8))::bit(32)::int end"
}

# Point node $1 at upstream $2 as a streaming standby. Rewrites the keys it owns in
# postgresql.auto.conf, because pg_basebackup and pg_rewind both copy that file from the source.
configure_standby() {
  local n=$1 up=$2 dir auto
  dir=$(node_dir "$n"); auto="$dir/postgresql.auto.conf"
  touch "$auto"
  grep -vE '^(port|primary_conninfo|primary_slot_name|synchronous_standby_names|restore_command|recovery_target[a-z_]*) ' "$auto" > "$auto.tmp" || true
  cat >> "$auto.tmp" <<EOF
port = $(node_port "$n")
primary_conninfo = 'host=127.0.0.1 port=$(node_port "$up") user=replicator passfile=''$PGPASSFILE'' application_name=node_$n'
primary_slot_name = 'node_$n'
synchronous_standby_names = ''
EOF
  mv "$auto.tmp" "$auto"
  rm -f "$dir/recovery.signal"
  touch "$dir/standby.signal"
}

ensure_slot() { # ensure_slot <primary port> <slot>
  q "$1" -d postgres -c "select pg_create_physical_replication_slot('$2')
                         where not exists (select 1 from pg_replication_slots where slot_name = '$2')" >/dev/null
}

# Block until the standby on port $2 has replayed everything the primary on $1 had written. Prints ms taken.
wait_caught_up() {
  local sp=$2 lsn t0
  lsn=$(q "$1" -d postgres -c "select pg_current_wal_lsn()"); t0=$(now_ms)
  wait_until 60 _replayed || die "standby on $sp did not reach $lsn"
  echo $(( $(now_ms) - t0 ))
}
_replayed() { [ "$(q "$sp" -d postgres -c "select pg_last_wal_replay_lsn() >= '$lsn'::pg_lsn")" = t ]; }   # uses wait_caught_up's locals

# start_load <port> <seconds> <outfile>: pgbench transfer load in the background; sets LOADPID.
# Call it directly, not inside $( ), or the pid belongs to a subshell and `wait` cannot see it.
# --max-tries retries deadlock and serialization failures instead of killing the client.
start_load() {
  local naccts; naccts=$(q "$1" -c "select max(id) from core.accounts")
  pgbench -n -p "$1" -c "$LOAD_CLIENTS" -j 2 -T "$2" -R "$LOAD_RATE" -P 5 --max-tries=10 \
    -D naccts="$naccts" -f "$LAB_ROOT/sql/transfer.pgbench" bank > "$3" 2>&1 &
  LOADPID=$!
}
load_tps() { sed -n 's/^tps = \([0-9]*\).*/\1/p' "$1" | head -1; }
load_latency() { sed -n 's/^latency average = \([0-9.]*\) ms.*/\1/p' "$1" | head -1; }

integrity() { # integrity <port>: prints the checks, returns non-zero if any failed
  local out; out=$(q "$1" -F ' | ' -c "select check_name, ok, detail from core.verify_integrity()")
  echo "$out" | sed 's/^/     /'
  ! echo "$out" | grep -q '| f |'
}

record() { # record <drill> <metric> <value>
  mkdir -p "$(dirname "$RESULTS")"
  [ -f "$RESULTS" ] || printf '| When | Drill | Metric | Value |\n|---|---|---|---|\n' > "$RESULTS"
  printf '| %s | %s | %s | %s |\n' "$(date '+%Y-%m-%d %H:%M')" "$1" "$2" "$3" >> "$RESULTS"
}

command -v initdb >/dev/null || die "Postgres binaries not found in $PGBIN (set PGBIN in lab.env)"
mkdir -p "$LAB_DIR"/{sock,wal_archive,backups,logs} 2>/dev/null || true
