# The test step's verdict for the test phase, shared by the pipeline step and
# its self-test so both exercise the same decision.
#
# The coverage guard, not xcodebuild's raw exit status, decides whether a red
# xcodebuild run fails the step — and only a red with real, listed failures is
# tolerated. The guard distinguishes its acceptances: exit 0 is a run with no
# test failures at all, exit 10 is a run whose failures are all on the
# known-failures list with the whole plan run. So a red xcodebuild beside a
# guard 10 is the known-failures case and passes; a red xcodebuild beside a
# guard 0 is exactly the infrastructure failure the guard cannot see, and
# stays red; the two agreeing on green passes; and a guard rejection — an
# unlisted failure, missing coverage, an unreadable bundle — is never
# tolerated, whichever way xcodebuild went. A green xcodebuild beside a guard
# 10 means the two disagree about whether anything failed, and fails.

# tests_verdict TEST_STATUS COVERAGE_STATUS
# Exits with the step's exit code for the test phase. Prints one line saying
# what a red xcodebuild was taken to mean, so the step's output explains its
# verdict.
tests_verdict() {
  test_status="$1"
  coverage_status="$2"
  if [ "$coverage_status" -eq 10 ]; then
    if [ "$test_status" -eq 0 ]; then
      echo "xcodebuild reported no failing tests but the coverage guard counted known failures; the disagreement fails the step."
      return 10
    fi
    echo "xcodebuild exited $test_status, and the coverage guard accepted the run: every failing test is on the known-failures list and the whole plan ran."
    return 0
  fi
  if [ "$coverage_status" -ne 0 ]; then
    echo "the coverage guard rejected the run (exit $coverage_status): an unlisted failure, missing coverage, or a bundle it could not read."
    return "$coverage_status"
  fi
  if [ "$test_status" -ne 0 ]; then
    echo "xcodebuild exited $test_status with no test failures; that is an infrastructure failure the coverage guard cannot see, so the step stays red."
    return "$test_status"
  fi
  return 0
}

# step_result
# The step's final block: prints the Result section and exits with the step's
# exit code. Reads the statuses by the variable names the pipeline step sets —
# TEST_STATUS, COVERAGE_STATUS, one per self-test, and IB_CLEANUP_STATUS — so
# the caller is one line and the self-test can exercise the exact code that
# runs in CI by setting the same names. Must run in the step's own shell: it
# exits the process.
step_result() {
  # Ends in exit or return either way, and every status here is an expected,
  # handled value: errexit must not end the block at the first non-zero gate
  # before its messages are printed.
  set +e
  echo "--- :result: Result"
  echo "xcodebuild exit: $TEST_STATUS"
  echo "coverage check exit: $COVERAGE_STATUS"
  echo "guard self-test exit: $SELFTEST_STATUS"
  echo "build-step self-test exit: $BUILD_STEP_SELFTEST_STATUS"
  echo "watchdog self-test exit: $WATCHDOG_SELFTEST_STATUS"
  echo "stuck-test sampler self-test exit: $SAMPLER_SELFTEST_STATUS"
  echo "build-watchdog self-test exit: $BUILD_WATCHDOG_SELFTEST_STATUS"
  echo "Interface Builder cleanup self-test exit: $IB_SELFTEST_STATUS"
  echo "cancel-cleanup self-test exit: $CANCEL_SELFTEST_STATUS"
  echo "grants self-test exit: $GRANTS_SELFTEST_STATUS"
  echo "live-log filter self-test exit: $FILTER_SELFTEST_STATUS"
  echo "step-verdict self-test exit: $VERDICT_SELFTEST_STATUS"
  # The verdict is decided in one place, tests_verdict above: a red xcodebuild
  # passes only beside a guard 10. No gate on the raw status exists outside it,
  # so a known-only run cannot exit red here however the lines are ordered.
  VERDICT_OUT="$(tests_verdict "$TEST_STATUS" "$COVERAGE_STATUS")"
  TESTS_VERDICT=$?
  [ -n "$VERDICT_OUT" ] && echo "$VERDICT_OUT"
  [ "$SELFTEST_STATUS" -eq 0 ] || { echo "the coverage guard did not prove it can fail"; exit "$SELFTEST_STATUS"; }
  [ "$BUILD_STEP_SELFTEST_STATUS" -eq 0 ] || { echo "the build step did not prove it can be killed and still report why"; exit "$BUILD_STEP_SELFTEST_STATUS"; }
  [ "$WATCHDOG_SELFTEST_STATUS" -eq 0 ] || { echo "the watchdog did not prove it can stop a run"; exit "$WATCHDOG_SELFTEST_STATUS"; }
  [ "$SAMPLER_SELFTEST_STATUS" -eq 0 ] || { echo "the stuck-test sampler did not prove it captures a hung test once"; exit "$SAMPLER_SELFTEST_STATUS"; }
  [ "$BUILD_WATCHDOG_SELFTEST_STATUS" -eq 0 ] || { echo "the build watchdog did not prove it can stop a build"; exit "$BUILD_WATCHDOG_SELFTEST_STATUS"; }
  [ "$IB_SELFTEST_STATUS" -eq 0 ] || { echo "the Interface Builder cleanup did not prove it kills only what it recorded"; exit "$IB_SELFTEST_STATUS"; }
  [ "$CANCEL_SELFTEST_STATUS" -eq 0 ] || { echo "a cancelled job would skip the exit cleanup"; exit "$CANCEL_SELFTEST_STATUS"; }
  [ "$GRANTS_SELFTEST_STATUS" -eq 0 ] || { echo "the grants step did not prove it retries a not-ready privacy service"; exit "$GRANTS_SELFTEST_STATUS"; }
  [ "$FILTER_SELFTEST_STATUS" -eq 0 ] || { echo "the live log would lose a failure's detail"; exit "$FILTER_SELFTEST_STATUS"; }
  [ "$VERDICT_SELFTEST_STATUS" -eq 0 ] || { echo "the step verdict did not prove it trusts the guard"; exit "$VERDICT_SELFTEST_STATUS"; }
  [ "$TESTS_VERDICT" -eq 0 ] || exit "$TESTS_VERDICT"
  [ "$IB_CLEANUP_STATUS" -eq 0 ] || { echo "this build's Interface Builder processes could not all be stopped"; exit "$IB_CLEANUP_STATUS"; }
  echo "Build and full plan passed."
  return 0
}
