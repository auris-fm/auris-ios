#!/bin/bash
# Run the REAL build step — the step function AND the call site that starts it —
# with a stub xcodebuild earlier in PATH.
#
# The extracted-watchdog self-test proves the watchdog body; it cannot catch how
# the step starts the build or how errexit treats its waits and returns — three
# defects that would end or mute every run were found exactly there in review.
# The call site is extracted too, so its errexit dance is what actually runs.
set -u
SCRIPT="$(cd "$(dirname "$0")/../commands" && pwd)/auris-build-and-test.sh"
LIBDIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
report() { if [ "$1" -eq 0 ]; then echo "PASS  $2"; PASS=$((PASS+1)); else echo "FAIL  $2"; FAIL=$((FAIL+1)); fi; }

# The step function, verbatim: from its header to the "}" after its final
# "return 0". Anchoring on the return keeps inner braces from ending extraction.
extract_step() {
  awk '/^run_build_step\(\) \{/{f=1} f{print} f && prev ~ /^return 0$/ && /^\}$/{exit} {prev=$0}' "$SCRIPT"
}

# The call site, verbatim: the errexit-off call, the status capture, and the
# gate that turns a non-zero step status into the script's exit.
extract_call_site() {
  awk 'index($0, "# errexit off around the call") == 1 {f=1}
       f{print}
       f && index($0, "BUILD_STEP_STATUS\" -eq 0 ] || exit") {exit}' "$SCRIPT"
}

make_stub() {
  local dir="$1" behaviour="$2"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/xcodebuild" <<STUB
#!/bin/bash
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

# Assemble and run one case. Extra PATH entries can carry shims (a failing ps,
# for example); extra shell lines run before the step.
run_case() {
  local name="$1" behaviour="$2" want_status="$3" want_text="$4" timeout_secs="$5"
  shift 5
  local shim_dir="$1" extra_lines="$2"
  local dir; dir=$(mktemp -d)
  make_stub "$dir" "$behaviour"
  mkdir -p "$dir/artifacts"
  {
    echo 'set -euo pipefail'
    echo "source \"$LIBDIR/ib-processes.sh\""
    echo "LOG_DIR=\"$dir/artifacts\""
    echo "IB_RECORD=\"$dir/artifacts/ib-processes.tsv\""
    echo ': > "$IB_RECORD"'
    echo "SIMULATOR_ID=\"stub-sim\"; DERIVED=\"$dir/dd\""
    # Deadline must leave room for the first no-progress poll (one POLL=10s
    # window is added before the first growth check can reset it), so 25s, not
    # 8s: at 8s the very first poll — taken before the stub has flushed any
    # output — already exceeds the budget, which is a fixture bug, not a
    # step bug. The real pipeline uses 300s against 10s polls.
    echo 'BUILD_PROGRESS_DEADLINE=25; BUILD_TOTAL_DEADLINE=60'
    echo "$extra_lines"
    echo 'trap '"'"'echo "STEP_STATUS=$BUILD_STEP_STATUS"'"'"' EXIT'
    extract_step
    extract_call_site
    echo 'trap '"'"'echo "STEP_STATUS=$BUILD_STEP_STATUS"'"'"' EXIT'
  } > "$dir/step.sh"
  PATH="$shim_dir:$dir/bin:$PATH" timeout "$timeout_secs" bash "$dir/step.sh" > "$dir/out.txt" 2>&1
  local ok=0
  grep -q "STEP_STATUS=$want_status" "$dir/out.txt" || ok=1
  if [ -n "$want_text" ] && ! grep -q "$want_text" "$dir/out.txt"; then ok=1; fi
  # No stub left running: the step must have stopped what it started.
  if pgrep -f "$dir/bin/xcodebuild" >/dev/null 2>&1; then ok=1; fi
  report "$ok" "$name"
  sed 's/^/        /' "$dir/out.txt" | tail -4
  pkill -KILL -f "$dir/bin/xcodebuild" 2>/dev/null
  rm -rf "$dir"
}

run_case "hanging build is killed, verdict 4, report printed" hang 4 "stopped making progress" 90 "" ":"
run_case "healthy build exits 0 and the report prints" healthy 0 "BUILD FOR TESTING SUCCEEDED" 90 "" ":"

run_vanish_case() {
  local dir; dir=$(mktemp -d)
  local shim="$dir/shim"
  mkdir -p "$dir/bin" "$dir/artifacts" "$shim"
  # A live fixture daemon launched BY the step (so the recorder's tree walk
  # reaches it) whose start-time read fails: the recorder lists it, asks ps for
  # its start time, and ps (the shim) fails for exactly that pid.
  cp /bin/sleep "$dir/bin/ibtoold"
  codesign -f -s - --identifier com.apple.ibtoold "$dir/bin/ibtoold" >/dev/null 2>&1
  make_stub "$dir" hang
  cat > "$shim/ps" <<SHIM
#!/bin/bash
if [ "\$1" = "-o" ] && [ "\$2" = "lstart=" ] && [ "\$4" = "\$(cat "$dir/daemon-pid" 2>/dev/null)" ] && [ -n "\$(cat "$dir/daemon-pid" 2>/dev/null)" ]; then
  exit 1
fi
exec /bin/ps "\$@"
SHIM
  chmod +x "$shim/ps"
  {
    echo 'set -euo pipefail'
    echo "source \"$LIBDIR/ib-processes.sh\""
    echo "LOG_DIR=\"$dir/artifacts\""
    echo "IB_RECORD=\"$dir/artifacts/ib-processes.tsv\""
    echo ': > "$IB_RECORD"'
    echo "SIMULATOR_ID=\"stub-sim\"; DERIVED=\"$dir/dd\""
    echo 'BUILD_PROGRESS_DEADLINE=25; BUILD_TOTAL_DEADLINE=60'
    echo "\"$dir/bin/ibtoold\" 120 >/dev/null 2>&1 & echo \$! > \"$dir/daemon-pid\""
    echo 'trap '"'"'echo "STEP_STATUS=$BUILD_STEP_STATUS"'"'"' EXIT'
    extract_step
    extract_call_site
    echo 'trap '"'"'echo "STEP_STATUS=$BUILD_STEP_STATUS"'"'"' EXIT'
  } > "$dir/step.sh"
  PATH="$shim:$dir/bin:$PATH" timeout 90 bash "$dir/step.sh" > "$dir/out.txt" 2>&1
  local ok=0
  # Keep watching (verdict 4) or fail loudly (the watchdog-death report); a 0
  # means the watchdog died quietly and the build ran to its timeout unwatched.
  grep -q "STEP_STATUS=4\|STEP_STATUS=1" "$dir/out.txt" || ok=1
  report "$ok" "vanishing process does not silence the watchdog"
  sed 's/^/        /' "$dir/out.txt" | tail -4
  local leftover; leftover=$(cat "$dir/daemon-pid" 2>/dev/null || true)
  [ -n "$leftover" ] && kill -KILL "$leftover" 2>/dev/null
  pkill -KILL -f "$dir/bin/xcodebuild" 2>/dev/null
  rm -rf "$dir"
}

run_vanish_case

# A watchdog that dies on its own must fail the run loudly, never be normalised
# to fine. The shim kills the watchdog subshell (ps's grandparent, since
# ib_start_time runs inside the recorder's command substitution) on its first
# start-time read, then the healthy build finishes unwatched. With death
# detection the step reports "watchdog died" and fails; without it the death is
# normalised away and the case sees STEP_STATUS=0 — the silent-mute shape.
run_watchdog_kill_case() {
  local dir; dir=$(mktemp -d)
  local shim="$dir/shim"
  mkdir -p "$dir/bin" "$dir/artifacts" "$shim"
  make_stub "$dir" healthy
  # The recorder only reads start times for Interface Builder processes, so the
  # tree needs one: a fixture ibtoold launched by the step itself.
  cp /bin/sleep "$dir/bin/ibtoold"
  codesign -f -s - --identifier com.apple.ibtoold "$dir/bin/ibtoold" >/dev/null 2>&1
  cat > "$shim/ps" <<SHIM
#!/bin/bash
if [ "\$1" = "-o" ] && [ "\$2" = "lstart=" ] && [ ! -f "$dir/killed" ]; then
  : > "$dir/killed"
  gp="\$(ps -o ppid= -p "\$PPID" | tr -d ' ')"
  gp="\$(ps -o ppid= -p "\$gp" | tr -d ' ')"
  kill -TERM "\$gp" 2>/dev/null
fi
exec /bin/ps "\$@"
SHIM
  chmod +x "$shim/ps"
  {
    echo 'set -euo pipefail'
    echo "source \"$LIBDIR/ib-processes.sh\""
    echo "LOG_DIR=\"$dir/artifacts\""
    echo "IB_RECORD=\"$dir/artifacts/ib-processes.tsv\""
    echo ': > "$IB_RECORD"'
    echo "SIMULATOR_ID=\"stub-sim\"; DERIVED=\"$dir/dd\""
    echo 'BUILD_PROGRESS_DEADLINE=25; BUILD_TOTAL_DEADLINE=60'
    echo "\"$dir/bin/ibtoold\" 120 >/dev/null 2>&1 & echo \$! > /dev/null"
    echo "trap 'echo \"STEP_STATUS=\$BUILD_STEP_STATUS\"' EXIT"
    extract_step
    extract_call_site
  } > "$dir/step.sh"
  PATH="$shim:$dir/bin:$PATH" timeout 90 bash "$dir/step.sh" > "$dir/out.txt" 2>&1
  local ok=0
  grep -q "watchdog died with status" "$dir/out.txt" || ok=1
  grep -q "STEP_STATUS=1" "$dir/out.txt" || ok=1
  report "$ok" "a watchdog that dies on its own fails the run loudly"
  sed 's/^/        /' "$dir/out.txt" | tail -4
  pkill -KILL -f "$dir/bin/xcodebuild" 2>/dev/null
  pkill -KILL -f "$dir/bin/ibtoold" 2>/dev/null
  rm -rf "$dir"
}

run_watchdog_kill_case

echo "real-step self-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
