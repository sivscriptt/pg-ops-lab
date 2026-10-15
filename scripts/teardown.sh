#!/usr/bin/env bash
# teardown.sh            stop every node and delete the whole lab directory (asks first)
# teardown.sh --yes      same, no prompt
# teardown.sh restore    stop and delete only the scratch restore instance
source "$(dirname "$0")/lib.sh"

if [ "${1:-}" = restore ]; then
  is_up "$PORT_RESTORE" && stop_node restore fast
  rm -rf "$(node_dir restore)"
  ok "restore instance removed"
  exit 0
fi

if [ "${1:-}" != --yes ]; then
  printf 'Stop all nodes and delete %s? [y/N] ' "$LAB_DIR"; read -r ans
  [ "$ans" = y ] || exit 1
fi
for n in a b restore; do
  [ -d "$(node_dir $n)" ] && { stop_node "$n" immediate 2>/dev/null || true; }
done
rm -rf "$LAB_DIR"
ok "lab removed. results/drill-log.md is kept."
