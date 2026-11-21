#!/usr/bin/env bash
# Proof that the step's verdict trusts the coverage guard over xcodebuild's
# raw exit status, and tolerates a red xcodebuild only when the guard reports
# real, listed failures (guard exit 10, not a bare 0).
#
# A gate that exits on xcodebuild's raw status alone turns a run whose only
# failures are the listed known failures permanently red, which makes the
# known-failures list decoration. But a red xcodebuild beside a guard 0 — no
# test failures at all — is an infrastructure failure the guard cannot see,
# and excusing it would turn the gate into a rubber stamp. The guard's exit
# codes are what make the two distinguishable. One case per row of that
# decision, plus the disagreement row. The guard's own self-test proves exit
# 10 means the recording's failures are all listed; this file proves what the
# step then does with each code.
#
# The final cases run step_result — the exact block CI runs — under the
# pipeline's shell options (set -euo pipefail), because the block must print
# its verdict and its gate messages before exiting even when a gate fails;
# under errexit an unguarded command substitution would end the step silently
# on the first non-zero status.
#
# Run: bash .buildkite/lib/test-step-verdict.sh

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=step-verdict.sh
source "$HERE/step-verdict.sh"

results=0
cases=0

case_verdict() {
  local name="$1" test_status="$2" coverage_status="$3" want="$4" want_say="$5" want_words="${6:-}"
  local out rc
  out="$(tests_verdict "$test_status" "$coverage_status")"
  rc=$?
  cases=$((cases + 1))
  local shape_ok=no
  { [ "$want_say" = no ] && [ -z "$out" ]; } && shape_ok=yes
  { [ "$want_say" = yes ] && [ -n "$out" ]; } && shape_ok=yes
  local words_ok=yes
  if [ "$want_say" = yes ] && [ -n "$want_words" ]; then
    printf '%s' "$out" | grep -q "$want_words" && words_ok=yes || words_ok=no
  fi
  if [ "$rc" -eq "$want" ] && [ "$shape_ok" = yes ] && [ "$words_ok" = yes ]; then
    printf 'PASS  %s\n' "$name"
    results=$((results + 1))
  else
    printf 'FAIL  %s (exit %s, want %s; said: %s)\n' "$name" "$rc" "$want" "${out:-nothing}"
  fi
}

case_verdict "both green exits 0" 0 0 0 no
case_verdict "red xcodebuild beside guard 10 exits 0, with the reason said" 65 10 0 yes "known-failures"
case_verdict "red xcodebuild beside guard 0 stays red" 65 0 65 yes "infrastructure"
case_verdict "green xcodebuild beside guard 10 fails on the disagreement" 0 10 10 yes "disagreement"
case_verdict "an unlisted failure fails the step, with the reason said" 65 1 1 yes "rejected"
case_verdict "missing or partial coverage fails the step even when xcodebuild is green" 0 1 1 yes "rejected"

out="$(tests_verdict 65 10)"
cases=$((cases + 1))
if printf '%s' "$out" | grep -q "exited 65" && printf '%s' "$out" | grep -q "known-failures"; then
  printf 'PASS  the tolerated-red reason states the status and the acceptance\n'
  results=$((results + 1))
else
  printf 'FAIL  the tolerated-red reason is missing or too vague: %s\n' "$out"
fi
out="$(tests_verdict 65 0)"
cases=$((cases + 1))
if printf '%s' "$out" | grep -q "infrastructure"; then
  printf 'PASS  the infrastructure-red reason names it as such\n'
  results=$((results + 1))
else
  printf 'FAIL  the infrastructure-red reason is missing: %s\n' "${out:-nothing}"
fi

# step_result under the pipeline's shell options, in a subshell so its exit can
# be asserted. Arguments: name, want-exit, TEST_STATUS, COVERAGE_STATUS,
# SELFTEST_STATUS, IB_CLEANUP_STATUS, words that must appear in the output.
result_case() {
  local name="$1" want="$2" test_status="$3" coverage_status="$4" selftest_status="$5" ib_status="$6" want_said="${7:-}"
  local out rc
  out="$(bash -euo pipefail -c "
    source '$HERE/step-verdict.sh'
    TEST_STATUS=$test_status COVERAGE_STATUS=$coverage_status SELFTEST_STATUS=$selftest_status \
    BUILD_STEP_SELFTEST_STATUS=0 WATCHDOG_SELFTEST_STATUS=0 SAMPLER_SELFTEST_STATUS=0 BUILD_WATCHDOG_SELFTEST_STATUS=0 \
    IB_SELFTEST_STATUS=0 CANCEL_SELFTEST_STATUS=0 GRANTS_SELFTEST_STATUS=0 \
    FILTER_SELFTEST_STATUS=0 VERDICT_SELFTEST_STATUS=0 IB_CLEANUP_STATUS=$ib_status \
    step_result
  " 2>&1)"
  rc=$?
  cases=$((cases + 1))
  local said_ok=yes
  if [ -n "$want_said" ]; then
    printf '%s' "$out" | grep -q "$want_said" && said_ok=yes || said_ok=no
  fi
  if [ "$rc" -eq "$want" ] && [ "$said_ok" = yes ]; then
    printf 'PASS  %s\n' "$name"
    results=$((results + 1))
  else
    printf 'FAIL  %s (exit %s, want %s; said: %s)\n' "$name" "$rc" "$want" "${out//$'\n'/ | }"
  fi
}

echo
echo "step_result, the block CI actually runs, under the pipeline's shell options:"
result_case "a known-only run exits 0 from the real block" 0 65 10 0 0 "known-failures"
result_case "a red xcodebuild with no failures stays red, with the reason said" 65 65 0 0 0 "infrastructure"
result_case "an unexpected failure exits non-zero from the real block" 1 65 1 0 0 "rejected"
result_case "a failed self-test exits non-zero, with its message" 1 0 0 1 0 "did not prove"
result_case "Interface Builder survivors exit non-zero, with their message" 1 0 0 0 1 "could not all be stopped"
result_case "a fully green run announces itself" 0 0 0 0 0 "Build and full plan passed"

printf '\n%s/%s cases behaved as intended\n' "$results" "$cases"
[ "$results" -eq "$cases" ]
