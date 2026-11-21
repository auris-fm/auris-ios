#!/bin/bash
# Prove the stuck-test sampler: a test that runs past the threshold is sampled
# once, a healthy run produces nothing, and the sampler never touches the run.
# The sampler body is extracted from the pipeline script, so this exercises the
# code that runs. `sample` is stubbed — the cases prove the orchestration (when
# it fires, how often, what it names), not macOS's sampler. `sample <pid> 10`
# bounds itself by its duration argument, so there is no termination machinery
# to test; Buildkite's step timeout is the backstop for a tool that hangs.
# Everything runs under /bin/bash (3.2 on this Mac), the production interpreter.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/../commands" && pwd)/auris-build-and-test.sh"

extract_sampler() {
  local out="$1"
  {
    echo 'LOG_DIR="$1"; XCODEBUILD_PID="$2"; SIMULATOR_ID="$3"; STUCK_TEST_THRESHOLD="$4"'
    # The sampler is the subshell that reads STUCK_TEST_THRESHOLD. Selecting on
    # that keeps this reading the sampler when other subshells change.
    awk '/^\($/{buf=""} {buf=buf $0 "\n"} /^\) &$/{if (buf ~ /STUCK_TEST_THRESHOLD/) printf "%s", buf}' "$SCRIPT" \
      | sed '1d;$d' | sed 's/sleep 5/sleep 1/'
  } > "$out"
}

# Stub toolchain: `sample` records its arguments and writes a plausible file.
make_stubs() {
  local dir="$1"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/sample" <<'STUB'
#!/bin/bash
echo "sample $*" >> "$STUB_CALLS"
pid="$1"
out=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-file" ]; then out="$a"; fi
  prev="$a"
done
if [ -n "$out" ]; then echo "stub sample of pid $pid" > "$out"; else echo "stub sample of pid $pid" > "stuck-sample-${pid}.txt"; fi
# Model the tool's own duration bound: the sampler waits for it in the foreground.
sleep "${STUB_SAMPLE_SECONDS:-0}"
STUB
  chmod +x "$dir/bin/sample"
  # `sysctl` records its arguments and answers with a fixed load average, so
  # the cases can assert what was recorded without depending on the host.
  cat > "$dir/bin/sysctl" <<'STUB'
#!/bin/bash
echo "sysctl $*" >> "$STUB_CALLS"
echo "{ 1.25 2.50 3.75 }"
STUB
  chmod +x "$dir/bin/sysctl"
}

fails=0
report() { if [ "$1" -eq 0 ]; then echo "PASS  $2"; else echo "FAIL  $2"; fails=$((fails+1)); fi; }

# Wait for a condition to become true, polling briefly under a generous
# ceiling. Cases wait on the event itself (a capture appearing, a call being
# recorded), never on a fixed sleep: under load the sampler's polls are slow,
# and a fixed deadline turns that into a false failure — this suite flaked
# exactly that way at load ~30 before this helper existed. Returns 1 only when
# the ceiling expires, which is a real failure, not a slow machine.
wait_for() {
  local ceiling="$1"; shift
  local waited=0
  while ! "$@"; do
    if [ "$waited" -ge "$ceiling" ]; then return 1; fi
    sleep 1
    waited=$((waited + 1))
  done
  return 0
}
capture_has_load() { grep -q '^loadavg: ' "$1" 2>/dev/null; }
sample_called_n() { [ "$(grep -c '^sample ' "$STUB_CALLS" 2>/dev/null)" -eq "$1" ]; }
# Start the sampler watching a stub run that lives `secs` seconds. The run is
# long enough that every event a case waits for arrives before it ends, even
# under load; the case ends the run itself once its assertions are done.
start_sampler() {
  local dir="$1" secs="$2" threshold="$3"
  ( sleep "$secs" ) &
  stub=$!
  ( cd "$dir/artifacts" && PATH="$dir/bin:$PATH" /bin/bash "$dir/sampler.sh" "$dir/artifacts" "$stub" "SIM-TEST" "$threshold" ) &
  sampler=$!
}
stop_sampler() {
  kill "$stub" 2>/dev/null; wait "$stub" 2>/dev/null
  wait "$sampler" 2>/dev/null
  kill "$writer" 2>/dev/null; wait "$writer" 2>/dev/null
}

# Case 1: one test stays in flight past the threshold -> exactly one sample
# naming the run's host pid; the stub run is never killed.
dir=$(mktemp -d); mkdir -p "$dir/artifacts"
log="$dir/artifacts/test.log"; : > "$log"
make_stubs "$dir"
export STUB_CALLS="$dir/calls.txt"; : > "$STUB_CALLS"
export STUB_SAMPLE_SECONDS=2
extract_sampler "$dir/sampler.sh"
( sleep 1; echo "Test Case '-[X.Y testStuck]' started."; echo "2026-11-21 07:34:01.000000+0800 podcasts[424242:1] stub host line"; sleep 30 ) >> "$log" &
writer=$!
# The sampler lives as long as the run does; what matters is that it sampled
# once, named the right pid and file, and never signalled the run. Run it in
# the background and stop it by ending the stub run, as production does.
start_sampler "$dir" 300 3
# Wait for the capture to be complete — the load line is appended after the
# sample returns — not for a fixed number of seconds. The stub run outlives
# the ceiling, so under any load the event arrives before the run ends.
ok=0
wait_for 120 capture_has_load "$dir/artifacts/stuck-sample-1-424242.txt" || ok=1
kill -0 "$sampler" 2>/dev/null || ok=1   # still watching the live run
kill -0 "$stub" 2>/dev/null || ok=1      # run untouched
[ "$(grep -c '^sample ' "$STUB_CALLS")" -eq 1 ] || ok=1
grep -q '^sample 424242 10 -file .*stuck-sample-1-424242.txt$' "$STUB_CALLS" || ok=1
[ -s "$dir/artifacts/stuck-sample-1-424242.txt" ] || ok=1
# The capture carries the machine's load at the moment it fired: a sample
# taken on a swamped host reads differently from one taken on a quiet one.
grep -q '^loadavg: { 1.25 2.50 3.75 }$' "$dir/artifacts/stuck-sample-1-424242.txt" || ok=1
grep -q '^sysctl -n vm.loadavg$' "$STUB_CALLS" || ok=1
stop_sampler
report "$ok" "a stuck test is sampled once and the run continues"
rm -rf "$dir"

# Case 2: the same test stays stuck much longer -> still exactly one sample.
dir=$(mktemp -d); mkdir -p "$dir/artifacts"
log="$dir/artifacts/test.log"; : > "$log"
make_stubs "$dir"
export STUB_CALLS="$dir/calls.txt"; : > "$STUB_CALLS"
extract_sampler "$dir/sampler.sh"
( sleep 1; echo "Test Case '-[X.Y testStuck]' started."; echo "2026-11-21 07:34:01.000000+0800 podcasts[424242:1] stub host line"; sleep 300 ) >> "$log" &
writer=$!
start_sampler "$dir" 300 3
ok=0
wait_for 120 sample_called_n 1 || ok=1
# Let several more polls pass with the same test still in flight: the count
# must stay at one. This wait proves absence over a window, so it is a fixed
# observation period, not a deadline for an event.
sleep 5
[ "$(grep -c '^sample ' "$STUB_CALLS")" -eq 1 ] || ok=1
stop_sampler
report "$ok" "one stuck test is sampled once, not every poll"
rm -rf "$dir"

# Case 3: tests keep finishing -> no sample at all.
dir=$(mktemp -d); mkdir -p "$dir/artifacts"
log="$dir/artifacts/test.log"; : > "$log"
make_stubs "$dir"
export STUB_CALLS="$dir/calls.txt"; : > "$STUB_CALLS"
extract_sampler "$dir/sampler.sh"
( sleep 1; for i in 1 2 3 4 5 6; do echo "Test Case '-[X.Y test$i]' started."; echo "Test Case '-[X.Y test$i]' passed (0.1 seconds)."; sleep 1; done; echo "ALL_TESTS_DONE" ) >> "$log" &
writer=$!
start_sampler "$dir" 300 3
ok=0
# Wait until every healthy test has finished, then assert nothing was sampled.
wait_for 120 grep -q ALL_TESTS_DONE "$log" || ok=1
[ ! -s "$STUB_CALLS" ] || ok=1
stop_sampler
report "$ok" "a healthy run is never sampled"
rm -rf "$dir"

# Case 4: two different tests stick in turn -> one sample each, distinct files.
dir=$(mktemp -d); mkdir -p "$dir/artifacts"
log="$dir/artifacts/test.log"; : > "$log"
make_stubs "$dir"
export STUB_CALLS="$dir/calls.txt"; : > "$STUB_CALLS"
extract_sampler "$dir/sampler.sh"
( sleep 1; echo "Test Case '-[X.Y testA]' started."; echo "2026-11-21 07:34:01.000000+0800 podcasts[424242:1] stub host line"; sleep 6; echo "Test Case '-[X.Y testA]' failed (6.0 seconds)."; echo "Test Case '-[X.Y testB]' started."; sleep 300 ) >> "$log" &
writer=$!
start_sampler "$dir" 300 3
ok=0
wait_for 120 capture_has_load "$dir/artifacts/stuck-sample-2-424242.txt" || ok=1
[ "$(grep -c '^sample ' "$STUB_CALLS")" -eq 2 ] || ok=1
[ -s "$dir/artifacts/stuck-sample-1-424242.txt" ] || ok=1
[ -s "$dir/artifacts/stuck-sample-2-424242.txt" ] || ok=1
stop_sampler
report "$ok" "two stuck tests are sampled once each, both files survive"
rm -rf "$dir"

# Case 5: the run ends while a test is in flight -> the sampler exits with it.
dir=$(mktemp -d); mkdir -p "$dir/artifacts"
log="$dir/artifacts/test.log"; : > "$log"
make_stubs "$dir"
export STUB_CALLS="$dir/calls.txt"; : > "$STUB_CALLS"
extract_sampler "$dir/sampler.sh"
( sleep 1; echo "Test Case '-[X.Y testQuick]' started." ) >> "$log" &
writer=$!
( sleep 3 ) &
stub=$!
start=$(date +%s)
( cd "$dir/artifacts" && PATH="$dir/bin:$PATH" /bin/bash "$dir/sampler.sh" "$dir/artifacts" "$stub" "SIM-TEST" 30 )
elapsed=$(( $(date +%s) - start ))
kill "$writer" 2>/dev/null; wait "$writer" 2>/dev/null
ok=0
[ "$elapsed" -le 15 ] || ok=1
[ ! -s "$STUB_CALLS" ] || ok=1
report "$ok" "the sampler ends when the run ends"
rm -rf "$dir"

# Case 6: a Swift Testing test (◇ Test … started.) hangs — it must be sampled
# like an XCTest one, and a mid-test issue line must not retire it.
dir=$(mktemp -d); mkdir -p "$dir/artifacts"
log="$dir/artifacts/test.log"; : > "$log"
make_stubs "$dir"
export STUB_CALLS="$dir/calls.txt"; : > "$STUB_CALLS"
extract_sampler "$dir/sampler.sh"
( sleep 1; echo "◇ Test testStuck() started."; echo "2026-11-21 07:34:01.000000+0800 podcasts[424242:1] stub host line"; sleep 4; echo "✘ Test testStuck() recorded an issue"; sleep 300 ) >> "$log" &
writer=$!
start_sampler "$dir" 300 3
ok=0
wait_for 120 capture_has_load "$dir/artifacts/stuck-sample-1-424242.txt" || ok=1
[ "$(grep -c '^sample ' "$STUB_CALLS")" -eq 1 ] || ok=1
[ -s "$dir/artifacts/stuck-sample-1-424242.txt" ] || ok=1
stop_sampler
report "$ok" "Swift Testing starts and results are tracked like XCTest ones"
rm -rf "$dir"

# Case 7: the test hangs before the host has written any pid line. Nothing can
# be sampled yet, so the test must stay eligible and be sampled once the pid
# appears — not silently retired.
dir=$(mktemp -d); mkdir -p "$dir/artifacts"
log="$dir/artifacts/test.log"; : > "$log"
make_stubs "$dir"
export STUB_CALLS="$dir/calls.txt"; : > "$STUB_CALLS"
extract_sampler "$dir/sampler.sh"
( sleep 1; echo "Test Case '-[X.Y testEarly]' started."; sleep 8; echo "2026-11-21 07:34:01.000000+0800 podcasts[424242:1] first host line"; sleep 300 ) >> "$log" &
writer=$!
start_sampler "$dir" 300 3
ok=0
wait_for 120 capture_has_load "$dir/artifacts/stuck-sample-1-424242.txt" || ok=1
[ "$(grep -c '^sample ' "$STUB_CALLS")" -eq 1 ] || ok=1
[ -s "$dir/artifacts/stuck-sample-1-424242.txt" ] || ok=1
stop_sampler
report "$ok" "a hang before the first pid line is retried, not silently retired"
rm -rf "$dir"

# Case 8: the step records the machine's load at the start and end of the test
# window, into the kept artifacts. A run that times out under load 300 must be
# distinguishable from one that hangs on a quiet machine; without these two
# lines every timeout is ambiguous. The recording lines are extracted from the
# pipeline script, so this exercises the code that runs.
dir=$(mktemp -d); mkdir -p "$dir/artifacts"
make_stubs "$dir"
export STUB_CALLS="$dir/calls.txt"; : > "$STUB_CALLS"
awk '/^record_load\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$SCRIPT" > "$dir/record-load.sh"
(
  LOG_DIR="$dir/artifacts"
  PATH="$dir/bin:$PATH"
  . "$dir/record-load.sh"
  record_load start
  record_load end
)
ok=0
[ "$(grep -c '^sysctl -n vm.loadavg$' "$STUB_CALLS")" -eq 2 ] || ok=1
grep -q '^start loadavg: { 1.25 2.50 3.75 }$' "$dir/artifacts/loadavg.log" || ok=1
grep -q '^end loadavg: { 1.25 2.50 3.75 }$' "$dir/artifacts/loadavg.log" || ok=1
report "$ok" "the test window's start and end load are recorded into artifacts"
rm -rf "$dir"

if [ "$fails" -eq 0 ]; then
  echo "8/8 stuck-test sampler cases behaved as intended"
else
  echo "$fails stuck-test sampler case(s) FAILED"
  exit 1
fi
