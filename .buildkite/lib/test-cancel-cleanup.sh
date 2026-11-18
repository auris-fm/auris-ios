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
  # on_exit, the install function and the sentinel, verbatim.
  # shutdown_simulator is not extracted: the test overrides it below with an
  # observable stub, and sourcing the pipeline's own definition would
  # overwrite the stub.
  for fn in cleanup_everything on_exit install_exit_trap install_cleanup_sentinel stop_cleanup_sentinel; do
    # The closing brace check covers single-line functions too (a lone "}"
    # or a "; }" ending) — without that, extracting a one-liner would dump
    # the rest of the pipeline, call lines included, into traps.sh.
    awk -v name="$fn" '
      index($0, name "() {") == 1 {f=1}
      f{print}
      f && ($0 == "}" || $0 ~ /; \}$/){exit}
    ' "$SCRIPT"
    echo
  done
}

if [ "${1:-}" = "--child-sentinel" ]; then
  dir_child="$2"
  record="$dir_child/rec.tsv"
  LOG_DIR="$dir_child"
  IB_RECORD="$record"
  SIMULATOR_ID="fake-sim"
  CLEANUP_SENTINEL_PID=""
  shutdown_simulator() { echo called > "$dir_child/shutdown-called"; }
  extract_traps > "$dir_child/traps.sh"
  # shellcheck disable=SC1090
  source "$dir_child/traps.sh"
  install_cleanup_sentinel
  # Block on a FOREGROUND command: bash defers the shell's own traps until it
  # returns, so only the sentinel can react to a group signal here. This is
  # the state the cancelled job was really in.
  sleep 300
  stop_cleanup_sentinel
  exit 0
fi

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
  install_exit_trap
  # Wait to be signalled, like a job mid-run. The backgrounded sleep plus wait
  # is a state where bash does run its own trap on SIGTERM.
  sleep 300 &
  wait $!
  exit 0
fi

# The sentinel must clean up when the signal hits while the main script is
# blocked inside a foreground command — where bash will not run its own traps.
# The child here blocks on a foreground sleep the way the real pipeline blocks
# on xcodebuild, and the signal goes to the whole process group, the way
# Buildkite cancels a job.
run_sentinel_case() {
  local name="$1"
  local dir; dir=$(mktemp -d)
  mkdir -p "$dir/bin"
  cp /bin/sleep "$dir/bin/ibtoold"
  codesign -f -s - --identifier com.apple.ibtoold "$dir/bin/ibtoold" >/dev/null 2>&1
  "$dir/bin/ibtoold" 300 >/dev/null 2>&1 &
  local victim=$!
  printf '%s\t%s\n' "$victim" "$(ib_start_time "$victim")" >> "$dir/rec.tsv"

  # The python wrapper makes the child lead its own process group (macOS has
  # no setsid), so the kill below reaches the child's group only — the same
  # shape as Buildkite signalling a job group.
  python3 -c 'import os, sys; os.setpgid(0, 0); os.execvp(sys.argv[1], sys.argv[1:])' \
    bash "$0" --child-sentinel "$dir" >/dev/null 2>&1 &
  local job=$!
  sleep 2
  # Signal the group, not the shell: the shell is inside a foreground command
  # and would defer its own trap.
  kill -TERM -- "-$job" 2>/dev/null
  # The main shell has no TERM trap, so it dies at once; the sentinel then
  # cleans up, which includes ib_cleanup's grace period. Wait on the effect,
  # not on a pid.
  local waited=0
  while [ "$waited" -lt 40 ]; do
    [ -f "$dir/shutdown-called" ] && break
    sleep 1
    waited=$((waited + 1))
  done
  wait "$job" 2>/dev/null

  local ok=0
  [ -f "$dir/shutdown-called" ] || ok=1
  [ -f "$dir/ib-leftovers.txt" ] || ok=1
  local rec_victim
  rec_victim=$(cut -f1 "$dir/rec.tsv" 2>/dev/null)
  if [ -n "$rec_victim" ] && kill -0 "$rec_victim" 2>/dev/null; then ok=1; fi
  report_case "$ok" "$name" "$dir"
  rm -rf "$dir"
  return $ok
}

report_case() {
  if [ "$1" -eq 0 ]; then
    echo "PASS  $2"
  else
    echo "FAIL  $2"
    ls "$3" | sed 's/^/        /'
  fi
}

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
if [ "$ok" -eq 0 ]; then
  echo "PASS  SIGTERM runs the exit cleanup: recorded process stopped, simulator shutdown called, leftovers written"
else
  echo "FAIL  SIGTERM did not run the exit cleanup"
fi
rm -rf "$dir"

run_sentinel_case "a group-wide SIGTERM mid-command still cleans up (the sentinel)"
sentinel_rc=$?

if [ "$ok" -eq 0 ] && [ "$sentinel_rc" -eq 0 ]; then
  echo "cancel-cleanup self-test: 2 passed, 0 failed"
  exit 0
fi
echo "cancel-cleanup self-test: failures above"
exit 1
