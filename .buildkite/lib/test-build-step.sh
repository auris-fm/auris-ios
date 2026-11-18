#!/bin/bash
# Run the REAL build step with a stub xcodebuild earlier in PATH.
#
# The extracted-watchdog self-test proves the watchdog body; it cannot catch how
# the step starts the build or how errexit treats its waits — two defects that
# would end every run were found exactly there in review. This test runs the
# step function itself, from the pipeline script, with `xcodebuild` replaced by
# a stub: once hanging (must be killed, verdict 4, report printed) and once
# healthy (exit 0, report printed).
set -u
SCRIPT="$(cd "$(dirname "$0")/../commands" && pwd)/auris-build-and-test.sh"
LIBDIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
report() { if [ "$1" -eq 0 ]; then echo "PASS  $2"; PASS=$((PASS+1)); else echo "FAIL  $2"; FAIL=$((FAIL+1)); fi; }

# Extract the step function and everything it needs, verbatim from the script.
extract_step() {
  # The function's closing brace is the first line that is exactly "}" at column
  # zero after its start; inner blocks are indented. Matching on indentation, not
  # on any "}", keeps nested braces from ending the extraction early.
  # Ends at the function's own closing brace: the line "}" that follows its
  # final "return 0". Inner blocks close with indented braces or "}" after other
  # statements, so anchoring on the return keeps the extraction exact.
  awk '/^run_build_step\(\) \{/{f=1} f{print} f && prev ~ /^return 0$/ && /^\}$/{exit} {prev=$0}' "$SCRIPT"
}

make_stub() {
  local dir="$1" behaviour="$2"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/xcodebuild" <<STUB
#!/bin/bash
# Stub xcodebuild: only build-for-testing is exercised here.
case "\$1" in
  build-for-testing)
    if [ "$behaviour" = hang ]; then
      echo "CompileStoryboard MainInterface.storyboard"
      sleep 300
    else
      for i in \$(seq 1 6); do echo "CompileLine \$i"; sleep 1; done
      echo "** BUILD FOR TESTING SUCCEEDED **"
    fi
    ;;
esac
STUB
  chmod +x "$dir/bin/xcodebuild"
}

run_case() {
  local name="$1" behaviour="$2" want_status="$3" want_text="$4"
  local dir; dir=$(mktemp -d)
  make_stub "$dir" "$behaviour"
  mkdir -p "$dir/artifacts"
  {
    echo 'set -euo pipefail'
    echo "source \"$LIBDIR/ib-processes.sh\""
    echo "LOG_DIR=\"$dir/artifacts\""
    echo "IB_RECORD=\"$dir/artifacts/ib-processes.tsv\""
    echo ': > "$IB_RECORD"'
    echo 'SIMULATOR_ID="stub-sim"; DERIVED="'"$dir"'/dd"'
    # Deadline must leave room for the first no-progress poll (one POLL=10s
    # window is added before the first growth check can reset it), so 25s, not
    # 8s: at 8s the very first poll — taken before the stub has flushed any
    # output — already exceeds the budget, which is a fixture bug, not a
    # step bug. The real pipeline uses 300s against 10s polls.
    echo 'BUILD_PROGRESS_DEADLINE=25; BUILD_TOTAL_DEADLINE=60'
    extract_step
    echo 'set +e'
    echo 'run_build_step'
    echo 'status=$?'
    echo 'set -e'
    echo 'echo "STEP_STATUS=$status"'
  } > "$dir/step.sh"
  PATH="$dir/bin:$PATH" bash "$dir/step.sh" > "$dir/out.txt" 2>&1
  local ok=0
  grep -q "STEP_STATUS=$want_status" "$dir/out.txt" || ok=1
  if [ -n "$want_text" ] && ! grep -q "$want_text" "$dir/out.txt"; then ok=1; fi
  # No stub left running: the step must have stopped what it started.
  if pgrep -f "$dir/bin/xcodebuild" >/dev/null 2>&1; then ok=1; fi
  report "$ok" "$name"
  sed 's/^/        /' "$dir/out.txt" | tail -6
  pkill -KILL -f "$dir/bin/xcodebuild" 2>/dev/null
  rm -rf "$dir"
}

run_case "hanging build is killed, verdict 4, report printed" hang 4 "stopped making progress"
run_case "healthy build exits 0 and the report prints" healthy 0 "BUILD FOR TESTING SUCCEEDED"

echo "real-step self-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
