#!/bin/bash
# Prove each way the watchdog can stop a run, with a stub in place of xcodebuild.
#
# The watchdog body is extracted from the pipeline script rather than copied
# here, so this proves the code that runs. Deadlines are shortened so the cases
# take seconds; the shapes are the real ones.
#
# Each case asserts the exit status and that the report names what was running: a
# stop that says nothing leaves the next person to guess which test hung.
#
# The no-progress window must stay above the pipeline's maximum per-test execution
# allowance. Below it, this would kill a test xcodebuild was about to time out and
# name itself, and the report would lose that name.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/../commands" && pwd)/auris-build-and-test.sh"
POLL=5

extract_watchdog() {
  local out="$1"
  {
    echo 'LOG_DIR="$1"; XCODEBUILD_PID="$2"'
    echo 'TEST_START_DEADLINE="$3"; TEST_PROGRESS_DEADLINE="$4"; TEST_TOTAL_DEADLINE="$5"'
    sed -n '/^($/,/^) &$/p' "$SCRIPT" | sed '1d;$d' | sed 's/sleep 10/sleep 5/; s/waited + 10/waited + 5/; s/stalled + 10/stalled + 5/'
  } > "$out"
}

run_case() {
  local name="$1" behaviour="$2" expect="$3" expect_text="$4"
  local dir; dir=$(mktemp -d)
  mkdir -p "$dir/artifacts"
  local LOG_DIR="$dir/artifacts"
  : > "$LOG_DIR/test.log"
  extract_watchdog "$dir/watchdog.sh"

  case "$behaviour" in
    silent)      ( sleep 300 ) & ;;
    start-stall) ( sleep 1; echo "Testing started"; echo "Test Case '-[X.Y testZ]' started."; sleep 300 ) >> "$LOG_DIR/test.log" & ;;
    slow)        ( sleep 1; echo "Testing started"; for i in $(seq 1 40); do echo "Test Case '-[X.Y test$i]' passed (0.1 seconds)."; sleep 3; done ) >> "$LOG_DIR/test.log" & ;;
    healthy)     ( sleep 1; echo "Testing started"; for i in $(seq 1 4); do echo "Test Case '-[X.Y test$i]' passed (0.1 seconds)."; sleep 2; done ) >> "$LOG_DIR/test.log" & ;;
  esac
  local stub=$!

  bash "$dir/watchdog.sh" "$LOG_DIR" "$stub" 20 20 40 2>"$dir/verdict.txt"
  local status=$?
  wait "$stub" 2>/dev/null

  local ok=1
  [ "$status" -eq "$expect" ] || ok=0
  if [ -n "$expect_text" ] && ! grep -q "$expect_text" "$dir/verdict.txt"; then ok=0; fi
  if [ "$ok" -eq 1 ]; then echo "PASS  $name"; else echo "FAIL  $name (status $status, wanted $expect)"; fi
  sed 's/^/        /' "$dir/verdict.txt"
  rm -rf "$dir"
  return $((1 - ok))
}

fails=0
run_case "testing never starts" silent 1 "runner never connected" || fails=$((fails+1))
run_case "starts then stops making progress" start-stall 3 "testZ" || fails=$((fails+1))
run_case "keeps running past the total cap" slow 2 "exceeded" || fails=$((fails+1))
run_case "a healthy run is left alone" healthy 0 "" || fails=$((fails+1))

if [ "$fails" -eq 0 ]; then
  echo "4/4 watchdog cases behaved as intended"
else
  echo "$fails watchdog case(s) did not behave as intended"
fi
exit "$fails"
