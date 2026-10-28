#!/usr/bin/env bash
# Runs heavy Flutter commands without overloading the machine when several
# people or agents work at once:
#   tool/kbuild.sh analyze lib/modules/billing test/modules/billing   (2 at a time)
#   tool/kbuild.sh test test/modules/billing                          (1 at a time)
#   tool/kbuild.sh run <any command...>                                (1 at a time)
set -u
export PATH="$HOME/development/flutter/bin:$PATH"
cd "$(dirname "$0")/.."
mode="$1"; shift
case "$mode" in
  analyze) slots=2; cmd=(dart analyze "$@") ;;
  test)    slots=1; cmd=(flutter test "$@") ;;
  run)     slots=1; cmd=("$@") ;;
  *) echo "usage: kbuild.sh analyze|test|run ..." >&2; exit 2 ;;
esac
lockdir=/tmp/kendra_locks; mkdir -p "$lockdir"
while true; do
  for i in $(seq 1 "$slots"); do
    exec 9>"$lockdir/$mode.$i.lock"
    if flock -n 9; then
      "${cmd[@]}"; status=$?
      flock -u 9; exit $status
    fi
    exec 9>&-
  done
  sleep 3
done
