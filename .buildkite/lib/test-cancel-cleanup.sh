#!/bin/bash
# Prove the exit cleanup runs when the job is cancelled (SIGTERM), not only on a
# normal exit. The child runs the pipeline's OWN `on_exit` and trap install —
# extracted from the real script the way test-build-step.sh runs its step — not
# a re-typed copy, so the test fails if the pipeline's trap machinery drifts.
# bash runs the EXIT trap on SIGTERM; that behaviour is what is under test, so
# the child installs exactly the pipeline's trap: EXIT only, no TERM trap.
set -u
SCRIPT="$(cd "$(dirname "$0")/../commands" && pwd)/auris-build-and-test.sh"
LIB="$(cd "$(dirname "$0")" && pwd)/ib-processes.sh"
source "$LIB"

extract_traps() {
  # on_exit and the install function, verbatim. shutdown_simulator is not
  # extracted: the test overrides it below with an observable stub, and
  # sourcing the pipeline's own definition would overwrite the stub.
  for fn in on_exit install_exit_trap; do
    awk -v name="$fn" '
      index($0, name "() {") == 1 {f=1}
      f{print}
      f && $0 == "}"{exit}
    ' "$SCRIPT"
    echo
  done
}

if [ "${1:-}" = "--child" ]; then
  dir_child="$2"
  record="$dir_child/rec.tsv"
  LOG_DIR="$dir_child"
  IB_RECORD="$record"
  SIMULATOR_ID="fake-sim"
  # The pipeline's shutdown_simulator talks to simctl; replace its body, keep
  # its name and call site, so the test can observe the call.
  shutdown_simulator() { echo called > "$dir_child/shutdown-called"; }
  extract_traps > "$dir_child/traps.sh"
  # shellcheck disable=SC1090
  source "$dir_child/traps.sh"
  # Wait to be signalled, like a job mid-run.
  sleep 300 &
  wait $!
  exit 0
fi

# Parent: record a fake ibtoold the way the pipeline does, start this script as
# the "job", cancel it with SIGTERM the way Buildkite does, and assert the
# cleanup ran: the recorded process stopped and the simulator shutdown called.
dir=$(mktemp -d)
mkdir -p "$dir/bin"
cp /bin/sleep "$dir/bin/ibtoold"
codesign -f -s - --identifier com.apple.ibtoold "$dir/bin/ibtoold" >/dev/null 2>&1
"$dir/bin/ibtoold" 300 >/dev/null 2>&1 &
victim=$!
printf '%s\t%s\n' "$victim" "$(ib_start_time "$victim")" >> "$dir/rec.tsv"

bash "$0" --child "$dir" >/dev/null 2>&1 &
job=$!
sleep 2
kill -TERM "$job" 2>/dev/null
wait "$job" 2>/dev/null

ok=0
[ -f "$dir/shutdown-called" ] || ok=1
rec_victim=$(cut -f1 "$dir/rec.tsv" 2>/dev/null)
if [ -n "$rec_victim" ] && kill -0 "$rec_victim" 2>/dev/null; then ok=1; fi
if [ "$ok" -eq 0 ]; then
  echo "PASS  SIGTERM runs the exit cleanup: recorded process stopped, simulator shutdown called"
else
  echo "FAIL  SIGTERM did not run the exit cleanup"
fi
rm -rf "$dir"
[ "$ok" -eq 0 ]
