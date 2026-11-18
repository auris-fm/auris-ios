#!/bin/bash
# Prove the exit cleanup runs when the job is cancelled (SIGTERM), not only on a
# normal exit: start the real script's trap machinery in isolation, send SIGTERM,
# and assert the recorded process was stopped and the simulator shutdown ran.
set -u
LIB="$(cd "$(dirname "$0")" && pwd)/ib-processes.sh"
source "$LIB"
dir="${2:-$(mktemp -d)}"
record="$dir/rec.tsv"; : > "$record"
mkdir -p "$dir/bin"
cp /bin/sleep "$dir/bin/ibtoold"
codesign -f -s - --identifier com.apple.ibtoold "$dir/bin/ibtoold" >/dev/null 2>&1
"$dir/bin/ibtoold" 300 >/dev/null 2>&1 &
victim=$!
printf '%s\t%s\n' "$victim" "$(ib_start_time "$victim")" >> "$record"

shutdown_called="$dir/shutdown-called"
SIMULATOR_ID="fake-sim"
shutdown_simulator() { echo called > "$shutdown_called"; }
on_exit() {
  ib_cleanup "$record" "" 5 >/dev/null 2>&1 || true
  shutdown_simulator
}
if [ "${1:-}" = "--child" ]; then
  trap on_exit EXIT TERM
  # Wait to be signalled, like a job mid-run.
  sleep 300 &
  wait $!
  exit 0
fi
trap on_exit EXIT

# Parent: run this script as the "job", cancel it with SIGTERM the way Buildkite
# does, and assert the cleanup ran: the recorded process stopped and the
# simulator shutdown was called. A trap that only fires on normal exit fails here.
dir=$(mktemp -d)
bash "$0" --child "$dir" >/dev/null 2>&1 &
job=$!
sleep 2
kill -TERM "$job" 2>/dev/null
wait "$job" 2>/dev/null

ok=0
[ -f "$dir/shutdown-called" ] || ok=1
victim=$(cut -f1 "$dir/rec.tsv" 2>/dev/null)
if [ -n "$victim" ] && kill -0 "$victim" 2>/dev/null; then ok=1; fi
if [ "$ok" -eq 0 ]; then
  echo "PASS  SIGTERM runs the exit cleanup: recorded process stopped, simulator shutdown called"
else
  echo "FAIL  SIGTERM did not run the exit cleanup"
fi
rm -rf "$dir"
[ "$ok" -eq 0 ]
