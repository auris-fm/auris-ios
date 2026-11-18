#!/bin/bash
# The grants step is the difference between a speech test that takes 2.6s and
# one that takes 54.8s, and in a full run that difference kills the test at its
# execution allowance. Build 24 failed here: a grant issued immediately after a
# fresh erase and boot fails with EPERM — the privacy service is not ready —
# and the same grant succeeds seconds later. This runs the REAL
# grant_test_permissions function against a stub xcrun that is not ready at
# first and recovers, plus one that never recovers.
set -u
SCRIPT="$(cd "$(dirname "$0")/../commands" && pwd)/auris-build-and-test.sh"
PASS=0; FAIL=0
report() { if [ "$1" -eq 0 ]; then echo "PASS  $2"; PASS=$((PASS+1)); else echo "FAIL  $2"; FAIL=$((FAIL+1)); fi; }

extract_grants() {
  awk '/^grant_test_permissions\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$SCRIPT"
}

make_stub_xcrun() {
  local dir="$1" fail_first="$2"
  mkdir -p "$dir"
  cat > "$dir/xcrun" <<STUB
#!/bin/bash
# Count only privacy grant attempts. The call shape is
# call "simctl privacy <device> grant <service> <bundle>": the fourth argument
# is "grant".
if [ "\$2" = "privacy" ] && [ "\$4" = "grant" ]; then
        n=\$(cat "$dir/count" 2>/dev/null || echo 0)
    n=\$((n + 1))
    echo "\$n" > "$dir/count"
    if [ "\$n" -le "$fail_first" ]; then
      echo "Simulator device failed to complete the requested operation." >&2
      exit 1
    fi
    exit 0
fi
exec /usr/bin/xcrun "\$@"
STUB
  chmod +x "$dir/xcrun"
}

run_case() {
  local name="$1" fail_first="$2" want="$3"
  local dir; dir=$(mktemp -d)
  make_stub_xcrun "$dir" "$fail_first"
  {
    echo 'set -euo pipefail'
    echo 'SIMULATOR_ID=fake-sim'
    # The real function verbatim; its xcrun calls are unqualified, so the stub
    # earlier in PATH replaces them.
    awk '/^grant_test_permissions\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$SCRIPT"
    echo 'set +e'
    echo 'grant_test_permissions fm.auris 6 1'
    echo 'echo "GRANTS_RC=$?"'
  } > "$dir/case.sh"
  PATH="$dir:$PATH" timeout 60 bash "$dir/case.sh" > "$dir/out.txt" 2>&1
  local ok=0
  grep -q "GRANTS_RC=$want" "$dir/out.txt" || ok=1
  if [ "$want" = 0 ]; then
    grep -q "speech-recognition granted on try" "$dir/out.txt" || ok=1
  else
    grep -q "never accepted the grants\|was not granted within" "$dir/out.txt" || ok=1
  fi
  report "$ok" "$name"
  sed 's/^/        /' "$dir/out.txt" | tail -3
  rm -rf "$dir"
}

# Privacy service not ready for the first two tries, then it recovers: the
# function must retry, succeed, and return 0.
run_case "transient EPERM right after erase is retried and passes" 2 0
# Privacy service never recovers within the bound: the function must give up
# with a reason, not hang or return 0.
run_case "grants that never land fail the step within the bound" 99 1

echo "grants self-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
