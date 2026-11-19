#!/bin/bash
# Prove the build watchdog: a stub build that stops logging is killed and the
# verdict says so; a healthy stub is left alone. The watchdog body is extracted
# from the pipeline script, so this exercises the code that runs.
set -u
SCRIPT="$(cd "$(dirname "$0")/../commands" && pwd)/auris-build-and-test.sh"
LIB="$(cd "$(dirname "$0")" && pwd)/ib-processes.sh"
PASS=0; FAIL=0
report() { if [ "$1" -eq 0 ]; then echo "PASS  $2"; PASS=$((PASS+1)); else echo "FAIL  $2"; FAIL=$((FAIL+1)); fi; }

# The extracted body reads LOG_DIR, BUILD_PID and the deadlines, and calls
# ib_record_snapshot; the lib and those variables are provided here.
source "$LIB"
IB_RECORD="$(mktemp)/rec.tsv"; : > "$IB_RECORD"

source "$LIB"
# The watchdog calls ib_record_snapshot every poll; it needs the lib and a record.
IB_RECORD="$(mktemp -d)/rec.tsv"; : > "$IB_RECORD"

run_watchdog() {
  local dir="$1" stub="$2" progress="$3" total="$4"
  LOG_DIR="$dir"
  BUILD_PID="$stub"
  {
    echo 'LOG_DIR="$1"; BUILD_PID="$2"'
    echo 'BUILD_PROGRESS_DEADLINE="$3"; BUILD_TOTAL_DEADLINE="$4"'
    # The build watchdog is the subshell that reads BUILD_TOTAL_DEADLINE.
    awk '/^\($/{buf=""} {buf=buf $0 "\n"} /^\) &$/{if (buf ~ /BUILD_TOTAL_DEADLINE/) printf "%s", buf}' "$SCRIPT" \
      | sed '1d;$d; s/sleep 10/sleep 2/; s/waited + 10/waited + 2/; s/stalled + 10/stalled + 2/'
  } > "$dir/wd.sh"
  bash "$dir/wd.sh" "$dir" "$stub" "$progress" "$total" 2>"$dir/verdict.txt"
}

dir=$(mktemp -d); log="$dir/build.log"; : > "$log"
( for i in $(seq 1 3); do echo "CompileLine $i" >> "$log"; sleep 1; done; sleep 120 ) &
stub=$!
run_watchdog "$dir" "$stub" 8 30
status=$?
kill -KILL "$stub" 2>/dev/null
ok=0
[ "$status" -eq 4 ] || ok=1
grep -q "stopped making progress" "$dir/verdict.txt" || ok=1
report "$ok" "silent build is killed with the no-progress verdict"
sed 's/^/        /' "$dir/verdict.txt"
rm -rf "$dir"

dir=$(mktemp -d); log="$dir/build.log"; : > "$log"
( for i in $(seq 1 12); do echo "CompileLine $i" >> "$log"; sleep 2; done ) &
stub=$!
run_watchdog "$dir" "$stub" 10 60
status=$?
wait "$stub" 2>/dev/null
ok=0
[ "$status" -eq 0 ] || ok=1
report "$ok" "healthy build is left alone"
rm -rf "$dir"

echo "build-watchdog self-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
