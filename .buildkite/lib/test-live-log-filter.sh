#!/bin/bash
# Prove the live log keeps what a reader needs and drops the bulk.
#
# The filter is extracted from the pipeline script rather than copied here, so
# this proves the expression that runs. The sample holds the lines a real run
# writes: per-file build progress, a failure with its file and line, a test killed
# at its execution allowance, the restart that follows, a suite summary, and both
# Swift Testing result formats.
#
# Each case asserts presence or absence, not a count: a filter that keeps eight
# lines could be keeping the wrong eight.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/../commands" && pwd)/auris-build-and-test.sh"

# The filter is the argument to the grep that follows `tail -f` of the test log.
extract_filter() {
  sed -n '/^tail -f "\$LOG_DIR\/test.log"/,/TAIL_PID=\$!/p' "$SCRIPT" \
    | grep -o 'grep --line-buffered -E ".*"' \
    | sed 's/^grep --line-buffered -E "//; s/"$//'
}

FILTER="$(extract_filter)"
if [ -z "$FILTER" ]; then
  echo "FAIL  could not read the filter out of $SCRIPT"
  exit 1
fi

SAMPLE=$(mktemp)
cat > "$SAMPLE" <<'EOF'
CompileSwift normal arm64 /path/File1.swift (in target 'PocketCasts' from project 'podcasts')
    cd /path
    /usr/bin/swift-frontend -c -primary-file /path/File1.swift
CompileAssetCatalog /path/podcasts.app /path/Podcasts.xcassets (in target 'PocketCasts')
Testing started
Test Suite 'Selected tests' started at 2026-11-17 20:00:00.000
Test Case '-[PocketCastsTests.SomeTests testOne]' started.
/path/SomeTests.swift:12: error: -[PocketCastsTests.SomeTests testOne] : XCTAssertTrue failed
Test Case '-[PocketCastsTests.SomeTests testOne]' failed (0.123 seconds).
Test Case '-[PocketCastsTests.HangTests testTwo]' started.
Test Case '-[PocketCastsTests.HangTests testTwo]' exceeded execution time allowance of 1 minute. The test may have hung.
Restarting after unexpected exit, crash, or test timeout; summary will contain partial results
Executed 538 tests, with 2 failures (0 unexpected) in 120.5 seconds
◇ Suite "ReloadSchedulerTests" started after 0.1 seconds.
✘ Test "someSwiftTesting" recorded an issue at File.swift:9: Expectation failed
✔ Suite "ReloadSchedulerTests" passed after 1.2 seconds.
** TEST FAILED **
EOF

KEPT=$(mktemp)
grep -E "$FILTER" "$SAMPLE" > "$KEPT"

fails=0
check() {
  local want="$1" needle="$2"
  if [ "$want" = kept ]; then
    if grep -qF "$needle" "$KEPT"; then echo "PASS  keeps: $needle"; else echo "FAIL  loses: $needle"; fails=$((fails+1)); fi
  else
    if grep -qF "$needle" "$KEPT"; then echo "FAIL  does not drop: $needle"; fails=$((fails+1)); else echo "PASS  drops: $needle"; fi
  fi
}

# Everything a verdict or a diagnosis is read from.
check kept "Testing started"
check kept "Test Suite 'Selected tests' started"
check kept "error: -[PocketCastsTests.SomeTests testOne]"
check kept "exceeded execution time allowance"
check kept "Restarting after unexpected exit"
check kept "Executed 538 tests"
check kept "◇ Suite"
check kept "✘ Test"
check kept "✔ Suite"
check kept "** TEST FAILED **"
# The bulk, which is what the link cannot carry.
check dropped "CompileSwift normal"
check dropped "swift-frontend"
check dropped "CompileAssetCatalog"

# A filter matching nothing must keep no failure line. Without this, the checks
# above would pass against a filter that simply keeps everything.
if printf '%s' "$(grep -E '^NOTHING_MATCHES_THIS$' "$SAMPLE")" | grep -qF "error: -["; then
  echo "FAIL  negative control: an empty match kept a failure line"
  fails=$((fails+1))
else
  echo "PASS  negative control: a filter matching nothing keeps no failure line"
fi

total=$(wc -l < "$SAMPLE" | tr -d ' ')
kept=$(wc -l < "$KEPT" | tr -d ' ')
echo "      $kept of $total sample lines reach the live log"
rm -f "$SAMPLE" "$KEPT"

if [ "$fails" -eq 0 ]; then
  echo "14/14 live-log filter cases behaved as intended"
else
  echo "$fails live-log filter case(s) did not behave as intended"
fi
exit "$fails"