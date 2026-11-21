#!/bin/bash
# Prove the stuck-test sampler: a test that runs past the threshold is sampled
# once, a healthy run produces nothing, and the sampler never touches the run.
# The sampler body is extracted from the pipeline script, so this exercises the
# code that runs. `sample` and `xcrun` are stubbed — the cases prove the
# orchestration (when it fires, how often, what it names), not macOS's sampler.
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

# Stub toolchain: `sample` records its arguments and writes a plausible file;
# `xcrun simctl spawn … log show` records the invocation and writes a log file.
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
STUB
  cat > "$dir/bin/xcrun" <<'STUB'
#!/bin/bash
echo "xcrun $*" >> "$STUB_CALLS"
# The sampler redirects this output into its own file.
echo "stub simctl log for $*"
STUB
  chmod +x "$dir/bin/sample" "$dir/bin/xcrun"
}

fails=0
report() { if [ "$1" -eq 0 ]; then echo "PASS  $2"; else echo "FAIL  $2"; fails=$((fails+1)); fi; }

# Case 1: one test stays in flight past the threshold -> exactly one sample and
# one audio log, both naming the run's host pid; the stub run is never killed.
dir=$(mktemp -d); mkdir -p "$dir/artifacts"
log="$dir/artifacts/test.log"; : > "$log"
make_stubs "$dir"
export STUB_CALLS="$dir/calls.txt"; : > "$STUB_CALLS"
extract_sampler "$dir/sampler.sh"
( sleep 1; echo "Test Case '-[X.Y testStuck]' started."; echo "2026-11-21 07:34:01.000000+0800 podcasts[424242:1] stub host line"; sleep 30 ) >> "$log" &
writer=$!
( sleep 12 ) &
stub=$!
( cd "$dir/artifacts" && PATH="$dir/bin:$PATH" /bin/bash "$dir/sampler.sh" "$dir/artifacts" "$stub" "SIM-TEST" 3 )
status=$?
kill "$writer" "$stub" 2>/dev/null; wait "$writer" "$stub" 2>/dev/null
ok=0
[ "$status" -eq 0 ] || ok=1
[ "$(grep -c '^sample ' "$STUB_CALLS")" = 1 ] || ok=1
grep -q "^sample 424242 10" "$STUB_CALLS" || ok=1
[ "$(grep -c '^xcrun simctl spawn SIM-TEST log show' "$STUB_CALLS")" = 1 ] || ok=1
grep -q -- '--last 2m' "$STUB_CALLS" || ok=1
[ -s "$dir/artifacts/stuck-sample-1-424242.txt" ] || ok=1
ls "$dir/artifacts"/stuck-audio-1-*.log >/dev/null 2>&1 || ok=1
report "$ok" "a stuck test is sampled once, with an audio log, and the run is untouched"
rm -rf "$dir"

# Case 2: the same test stays stuck much longer -> still exactly one sample.
dir=$(mktemp -d); mkdir -p "$dir/artifacts"
log="$dir/artifacts/test.log"; : > "$log"
make_stubs "$dir"
export STUB_CALLS="$dir/calls.txt"; : > "$STUB_CALLS"
extract_sampler "$dir/sampler.sh"
( sleep 1; echo "Test Case '-[X.Y testStuck]' started."; echo "2026-11-21 07:34:01.000000+0800 podcasts[424242:1] stub host line"; sleep 60 ) >> "$log" &
writer=$!
( sleep 14 ) &
stub=$!
( cd "$dir/artifacts" && PATH="$dir/bin:$PATH" /bin/bash "$dir/sampler.sh" "$dir/artifacts" "$stub" "SIM-TEST" 3 )
kill "$writer" "$stub" 2>/dev/null; wait "$writer" "$stub" 2>/dev/null
ok=0
[ "$(grep -c '^sample ' "$STUB_CALLS")" = 1 ] || ok=1
report "$ok" "one stuck test is sampled once, not every poll"
rm -rf "$dir"

# Case 3: tests keep finishing -> no sample at all.
dir=$(mktemp -d); mkdir -p "$dir/artifacts"
log="$dir/artifacts/test.log"; : > "$log"
make_stubs "$dir"
export STUB_CALLS="$dir/calls.txt"; : > "$STUB_CALLS"
extract_sampler "$dir/sampler.sh"
( sleep 1; for i in 1 2 3 4 5 6; do echo "Test Case '-[X.Y test$i]' started."; echo "Test Case '-[X.Y test$i]' passed (0.1 seconds)."; sleep 1; done ) >> "$log" &
writer=$!
( sleep 10 ) &
stub=$!
( cd "$dir/artifacts" && PATH="$dir/bin:$PATH" /bin/bash "$dir/sampler.sh" "$dir/artifacts" "$stub" "SIM-TEST" 3 )
kill "$writer" "$stub" 2>/dev/null; wait "$writer" "$stub" 2>/dev/null
ok=0
[ ! -s "$STUB_CALLS" ] || ok=1
report "$ok" "a healthy run is never sampled"
rm -rf "$dir"

# Case 4: two different tests stick in turn -> one sample each.
dir=$(mktemp -d); mkdir -p "$dir/artifacts"
log="$dir/artifacts/test.log"; : > "$log"
make_stubs "$dir"
export STUB_CALLS="$dir/calls.txt"; : > "$STUB_CALLS"
extract_sampler "$dir/sampler.sh"
( sleep 1; echo "Test Case '-[X.Y testA]' started."; echo "2026-11-21 07:34:01.000000+0800 podcasts[424242:1] stub host line"; sleep 6; echo "Test Case '-[X.Y testA]' failed (6.0 seconds)."; echo "Test Case '-[X.Y testB]' started."; sleep 30 ) >> "$log" &
writer=$!
( sleep 18 ) &
stub=$!
( cd "$dir/artifacts" && PATH="$dir/bin:$PATH" /bin/bash "$dir/sampler.sh" "$dir/artifacts" "$stub" "SIM-TEST" 3 )
kill "$writer" "$stub" 2>/dev/null; wait "$writer" "$stub" 2>/dev/null
ok=0
[ "$(grep -c '^sample ' "$STUB_CALLS")" = 2 ] || ok=1
# Both captures must survive under distinct names even with one host pid.
[ -s "$dir/artifacts/stuck-sample-1-424242.txt" ] || ok=1
[ -s "$dir/artifacts/stuck-sample-2-424242.txt" ] || ok=1
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
( sleep 2 ) &
stub=$!
start=$(date +%s)
( cd "$dir/artifacts" && PATH="$dir/bin:$PATH" /bin/bash "$dir/sampler.sh" "$dir/artifacts" "$stub" "SIM-TEST" 30 )
elapsed=$(( $(date +%s) - start ))
kill "$writer" 2>/dev/null; wait "$writer" 2>/dev/null
ok=0
[ "$elapsed" -le 8 ] || ok=1
[ ! -s "$STUB_CALLS" ] || ok=1
report "$ok" "the sampler ends when the run ends"
rm -rf "$dir"

# Case 6: a wedged diagnostic command must not hold the sampler past the run.
# The stub `sample` sleeps far longer than the bound; the run ends while it is
# still "capturing". The sampler must kill it and exit promptly.
dir=$(mktemp -d); mkdir -p "$dir/artifacts"
log="$dir/artifacts/test.log"; : > "$log"
make_stubs "$dir"
cat > "$dir/bin/sample" <<'STUB'
#!/bin/bash
echo "sample $*" >> "$STUB_CALLS"
sleep 300
STUB
chmod +x "$dir/bin/sample"
export STUB_CALLS="$dir/calls.txt"; : > "$STUB_CALLS"
extract_sampler "$dir/sampler.sh"
( sleep 1; echo "Test Case '-[X.Y testStuck]' started."; echo "2026-11-21 07:34:01.000000+0800 podcasts[424242:1] stub host line" ) >> "$log" &
writer=$!
( sleep 8 ) &
stub=$!
start=$(date +%s)
( cd "$dir/artifacts" && PATH="$dir/bin:$PATH" /bin/bash "$dir/sampler.sh" "$dir/artifacts" "$stub" "SIM-TEST" 3 )
elapsed=$(( $(date +%s) - start ))
kill "$writer" 2>/dev/null; wait "$writer" 2>/dev/null
ok=0
# Threshold 3s + poll slack, then the 30s bound on the wedged sample.
[ "$elapsed" -le 45 ] || ok=1
# The stub's own sleep must be gone too, not just the stub script.
pgrep -f "^sleep 300$" >/dev/null 2>&1 && ok=1
report "$ok" "a wedged diagnostic is bounded; the sampler still ends with the run"
rm -rf "$dir"

if [ "$fails" -eq 0 ]; then
  echo "6/6 stuck-test sampler cases behaved as intended"
else
  echo "$fails sampler case(s) did not behave as intended"
fi
exit "$fails"
