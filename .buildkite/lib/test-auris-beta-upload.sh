#!/bin/bash
# Self-test for .buildkite/commands/auris-beta-upload.sh and the pipeline
# wiring. Runs without credentials or fastlane: each preflight case
# satisfies every other condition (a stub fastlane, the repo layout
# recreated) so the assertion lands on the one thing being tested, and
# the message itself is asserted. Also asserts the pipeline gates the
# upload step on a green build-and-test and a main branch.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
CMD="$ROOT/.buildkite/commands/auris-beta-upload.sh"
PIPE="$ROOT/.buildkite/auris-pipeline.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A stub fastlane: present on PATH, does nothing.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/fastlane"
chmod +x "$TMP/bin/fastlane"

run_case() { # $1 = expected message; $2.. = env assignments applied over the base set
  local expected="$1"; shift
  rm -rf "$TMP/repo"
  mkdir -p "$TMP/repo/.buildkite/commands" "$TMP/repo/ThirdParty/llama-cpp-build/ios-device/lfm"
  cp "$CMD" "$TMP/repo/.buildkite/commands/"
  local out
  out=$(env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" APP_STORE_CONNECT_API_KEY_KEY_ID=k APP_STORE_CONNECT_API_KEY_ISSUER_ID=i APP_STORE_CONNECT_API_KEY_KEY=secret "$@" bash -c "cd '$TMP/repo/.buildkite/commands' && ./auris-beta-upload.sh --check" 2>&1)
  if [[ "$out" == *"$expected"* ]]; then
    echo "ok: preflight reports '$expected'"
  else
    fail "preflight did not report '$expected' (got: $out)"
  fi
}

run_case "missing env: APP_STORE_CONNECT_API_KEY_KEY_ID" APP_STORE_CONNECT_API_KEY_KEY_ID=
run_case "missing env: APP_STORE_CONNECT_API_KEY_ISSUER_ID" APP_STORE_CONNECT_API_KEY_ISSUER_ID=
run_case "missing env: APP_STORE_CONNECT_API_KEY_KEY" APP_STORE_CONNECT_API_KEY_KEY=

# The llama check, with the env satisfied: point the script's cd at a
# layout whose ThirdParty is empty.
rm -rf "$TMP/repo"
mkdir -p "$TMP/repo/.buildkite/commands" "$TMP/repo/ThirdParty"
cp "$CMD" "$TMP/repo/.buildkite/commands/"
out=$(env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" APP_STORE_CONNECT_API_KEY_KEY_ID=k APP_STORE_CONNECT_API_KEY_ISSUER_ID=i APP_STORE_CONNECT_API_KEY_KEY=secret bash -c "cd '$TMP/repo/.buildkite/commands' && ./auris-beta-upload.sh --check" 2>&1)
if [[ "$out" == *"device llama build missing"* ]]; then
  echo "ok: preflight reports 'device llama build missing'"
else
  fail "preflight did not report 'device llama build missing' (got: $out)"
fi

# Happy path passes when everything is in place.
rm -rf "$TMP/repo"
mkdir -p "$TMP/repo/.buildkite/commands" "$TMP/repo/ThirdParty/llama-cpp-build/ios-device/lfm"
cp "$CMD" "$TMP/repo/.buildkite/commands/"
if env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" APP_STORE_CONNECT_API_KEY_KEY_ID=k APP_STORE_CONNECT_API_KEY_ISSUER_ID=i APP_STORE_CONNECT_API_KEY_KEY=secret bash -c "cd '$TMP/repo/.buildkite/commands' && ./auris-beta-upload.sh --check" >/dev/null 2>&1; then
  echo "ok: preflight passes with everything in place"
else
  fail "preflight failed with all conditions satisfied"
fi

# ---------------------------------------------------------------------------
# The upload gate. Archiving and signing happen on every main run; uploading
# is a separate, deliberate act. Each case below runs the REAL script (not
# --check) against a stub `bundle` that records which lanes were invoked, so
# the assertion is about what the step actually does.
# ---------------------------------------------------------------------------
cases=0
report() { echo "ok: $*"; cases=$((cases + 1)); }

# A repo whose `bundle` records its arguments instead of running fastlane.
make_upload_repo() { # $1 = with key material? (yes/no)
  rm -rf "$TMP/up"
  mkdir -p "$TMP/up/.buildkite/commands" "$TMP/up/ThirdParty/llama-cpp-build/ios-device/lfm" "$TMP/up/bin"
  cp "$CMD" "$TMP/up/.buildkite/commands/"
  printf '#!/bin/sh\necho "$@" >> "%s/lanes.txt"\nexit 0\n' "$TMP/up" > "$TMP/up/bin/bundle"
  chmod +x "$TMP/up/bin/bundle"
  printf '#!/bin/sh\nexit 0\n' > "$TMP/up/bin/fastlane"
  chmod +x "$TMP/up/bin/fastlane"
}

run_upload() { # $1.. = extra env assignments; echoes output, sets $status
  out=$(env -i PATH="$TMP/up/bin:/usr/bin:/bin" HOME="$TMP" \
    BUILDKITE_BUILD_NUMBER=4242 \
    APP_STORE_CONNECT_API_KEY_KEY_ID=k \
    APP_STORE_CONNECT_API_KEY_ISSUER_ID=i \
    APP_STORE_CONNECT_API_KEY_KEY=secret \
    "$@" bash -c "cd '$TMP/up/.buildkite/commands' && ./auris-beta-upload.sh" 2>&1)
  status=$?
}

lanes_run() { cat "$TMP/up/lanes.txt" 2>/dev/null || true; }

# 1. Gate unset: archive and sign, upload nothing, succeed.
make_upload_repo
rm -f "$TMP/up/lanes.txt"
run_upload
[[ "$status" == 0 ]] || fail "gate-unset run failed (got: $out)"
[[ "$(lanes_run)" == *"auris_beta_build"* ]] || fail "gate unset did not archive (lanes: $(lanes_run))"
[[ "$(lanes_run)" != *"auris_beta_upload"* ]] || fail "gate unset still uploaded (lanes: $(lanes_run))"
report "no BETA_UPLOAD: archives and signs, uploads nothing"

# 2. Gate explicitly 0: same as unset.
make_upload_repo
run_upload BETA_UPLOAD=0
[[ "$status" == 0 ]] || fail "BETA_UPLOAD=0 run failed (got: $out)"
[[ "$(lanes_run)" != *"auris_beta_upload"* ]] || fail "BETA_UPLOAD=0 uploaded (lanes: $(lanes_run))"
report "BETA_UPLOAD=0 behaves like unset"

# 3. Gate on: both lanes run, in order, with the build number.
make_upload_repo
run_upload BETA_UPLOAD=1
[[ "$status" == 0 ]] || fail "BETA_UPLOAD=1 run failed (got: $out)"
[[ "$(lanes_run)" == *"auris_beta_build build_number:4242"* ]] || fail "archive missing build number (lanes: $(lanes_run))"
[[ "$(lanes_run)" == *"auris_beta_upload"* ]] || fail "BETA_UPLOAD=1 did not upload (lanes: $(lanes_run))"
report "BETA_UPLOAD=1 archives then uploads"

# 4. Gate on with a missing key: fail closed BEFORE archiving. An upload
#    that cannot authenticate must not burn a device archive first.
make_upload_repo
run_upload BETA_UPLOAD=1 APP_STORE_CONNECT_API_KEY_KEY=
[[ "$status" != 0 ]] || fail "BETA_UPLOAD=1 with no key succeeded"
[[ "$out" == *"missing env: APP_STORE_CONNECT_API_KEY_KEY"* ]] || fail "no key error not reported (got: $out)"
[[ ! -f "$TMP/up/lanes.txt" ]] || fail "archived despite a missing key (lanes: $(lanes_run))"
report "BETA_UPLOAD=1 with a missing key fails closed before archiving"

# 5. Gate off with a missing key: the archive still needs the key to sign,
#    so this fails too — but on the key, not silently. Pins that turning
#    the gate off does not turn the preflight off.
make_upload_repo
run_upload APP_STORE_CONNECT_API_KEY_KEY=
[[ "$status" != 0 ]] || fail "gate-off run with no key succeeded"
[[ "$out" == *"missing env: APP_STORE_CONNECT_API_KEY_KEY"* ]] || fail "gate-off missing key not reported (got: $out)"
report "gate off still requires the signing key"

# 6. An unrecognised gate value is not "on": only 1 uploads. Guards against
#    a typo'd or truthy-looking value silently publishing a build.
make_upload_repo
run_upload BETA_UPLOAD=true
[[ "$status" == 0 ]] || fail "BETA_UPLOAD=true run failed (got: $out)"
[[ "$(lanes_run)" != *"auris_beta_upload"* ]] || fail "BETA_UPLOAD=true uploaded (lanes: $(lanes_run))"
report "only BETA_UPLOAD=1 uploads; other values do not"

echo "$cases/$cases upload-gate cases passed"

# Pipeline: the upload step exists, runs only on main, and waits for the
# tests.
grep -q "key: beta-upload" "$PIPE" || fail "no beta-upload step in the pipeline"
grep -q 'build.branch == "main"' "$PIPE" || fail "beta-upload step not restricted to main"
grep -q "depends_on: build-and-test" "$PIPE" || fail "beta-upload step does not depend on build-and-test"
echo "ok: pipeline gates the upload step correctly"

echo "all auris-beta-upload self-tests passed"
