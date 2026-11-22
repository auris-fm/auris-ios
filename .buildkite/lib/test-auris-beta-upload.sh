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
make_upload_repo() {
  rm -rf "$TMP/up"
  mkdir -p "$TMP/up/.buildkite/commands" "$TMP/up/ThirdParty/llama-cpp-build/ios-device/lfm" "$TMP/up/bin" "$TMP/up/podcasts/Credentials"
  cp "$CMD" "$TMP/up/.buildkite/commands/"
  cp "$ROOT/.ruby-version" "$ROOT/.xcode-version" "$TMP/up/"
  sed 's/%{[^}]*}/real-value/g' "$ROOT/podcasts/Credentials/ApiCredentials.tpl" > "$TMP/up/podcasts/Credentials/LocalApiCredentials.swift"
  printf '#!/bin/sh\necho "$@" >> "%s/lanes.txt"\nexit 0\n' "$TMP/up" > "$TMP/up/bin/bundle"
  printf '#!/bin/sh\nif [ "$1" = "-version" ]; then echo "Xcode %s"; exit 0; fi\nexit 0\n' "$(sed -E 's/^~> ?//' "$ROOT/.xcode-version")" > "$TMP/up/bin/xcodebuild"
  printf '#!/bin/sh\necho "ruby %s"\n' "$(cat "$ROOT/.ruby-version")" > "$TMP/up/bin/ruby"
  chmod +x "$TMP/up/bin/"*
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
[[ "$(lanes_run)" != *"auris_beta_build"* ]] || fail "archived despite a missing key (lanes: $(lanes_run))"
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

# ---------------------------------------------------------------------------
# Environment parity with the sibling build-and-test step. Each case removes
# ONE thing the archive needs and asserts the step supplies it, so a fresh
# checkout cannot go red on an input the other step creates for itself.
# ---------------------------------------------------------------------------

# A repo with a stub toolchain that records what ran, plus the real support
# files the script reads (.ruby-version, .xcode-version, Makefile, template).
make_env_repo() {
  rm -rf "$TMP/env"
  mkdir -p "$TMP/env/.buildkite/commands" "$TMP/env/bin" "$TMP/env/podcasts/Credentials"
  cp "$CMD" "$TMP/env/.buildkite/commands/"
  cp "$ROOT/.ruby-version" "$ROOT/.xcode-version" "$TMP/env/"
  cp "$ROOT/podcasts/Credentials/ApiCredentials.tpl" "$TMP/env/podcasts/Credentials/"
  sed 's/%{[^}]*}/real-value/g' "$ROOT/podcasts/Credentials/ApiCredentials.tpl" > "$TMP/env/podcasts/Credentials/LocalApiCredentials.swift"
  # bundle: records the invocation, and `bundle check` reports missing gems.
  cat > "$TMP/env/bin/bundle" <<STUB
#!/bin/sh
echo "bundle \$@" >> "$TMP/env/calls.txt"
if [ "\$1" = "check" ]; then exit \${BUNDLE_CHECK_EXIT:-1}; fi
exit 0
STUB
  # make: records the target instead of running the real recipe.
  cat > "$TMP/env/bin/make" <<STUB
#!/bin/sh
echo "make \$@" >> "$TMP/env/calls.txt"
[ "\$1" = "external_contributor" ] && cp "$TMP/env/podcasts/Credentials/ApiCredentials.tpl" "$TMP/env/podcasts/Credentials/LocalApiCredentials.swift"
exit 0
STUB
  # llama builder: records the call and creates the device slice.
  cat > "$TMP/env/bin/llama-build" <<STUB
#!/bin/sh
echo "llama-build" >> "$TMP/env/calls.txt"
mkdir -p "$TMP/env/ThirdParty/llama-cpp-build/ios-device/lfm"
exit 0
STUB
  # ruby/xcodebuild report the pinned versions unless a case overrides them.
  cat > "$TMP/env/bin/ruby" <<STUB
#!/bin/sh
echo "ruby \${FAKE_RUBY:-$(cat "$ROOT/.ruby-version")}"
STUB
  cat > "$TMP/env/bin/xcodebuild" <<STUB
#!/bin/sh
if [ "\$1" = "-version" ]; then echo "Xcode \${FAKE_XCODE:-$(sed -E 's/^~> ?//' "$ROOT/.xcode-version")}"; exit 0; fi
exit 0
STUB
  chmod +x "$TMP/env/bin/"*
}

run_env() { # $1.. = extra env assignments
  out=$(env -i PATH="$TMP/env/bin:/usr/bin:/bin" HOME="$TMP" \
    BUILDKITE_BUILD_NUMBER=4242 \
    APP_STORE_CONNECT_API_KEY_KEY_ID=k \
    APP_STORE_CONNECT_API_KEY_ISSUER_ID=i \
    APP_STORE_CONNECT_API_KEY_KEY=secret \
    LLAMA_BUILD_SCRIPT="$TMP/env/bin/llama-build" \
    "$@" bash -c "cd '$TMP/env/.buildkite/commands' && ./auris-beta-upload.sh" 2>&1)
  status=$?
}

env_calls() { cat "$TMP/env/calls.txt" 2>/dev/null || true; }

# 7. Gems are checked, not assumed: no vendor/bundle means `bundle install`
#    runs before any fastlane lane. The old preflight demanded a global
#    `fastlane` binary this pipeline never installs.
make_env_repo
run_env BUNDLE_CHECK_EXIT=1
[[ "$status" == 0 ]] || fail "fresh-checkout run failed (got: $out)"
[[ "$(env_calls)" == *"bundle install"* ]] || fail "gems not installed on a fresh checkout (calls: $(env_calls))"
[[ "$out" != *"no fastlane on PATH"* ]] || fail "still demands a global fastlane (got: $out)"
report "installs gems when they are absent; does not require a global fastlane"

# 7b. The check must be about the GEMS, not about a directory that happens to
#     exist: a vendor/bundle left by an older bundle with missing gems must
#     still be repaired. Mutant: `[[ -d vendor/bundle ]] || bundle install`.
make_env_repo
mkdir -p "$TMP/env/vendor/bundle"
run_env BUNDLE_CHECK_EXIT=1
[[ "$(env_calls)" == *"bundle install"* ]] || fail "missing gems not repaired because vendor/bundle exists (calls: $(env_calls))"
report "repairs missing gems even when vendor/bundle already exists"

# 8. Gems already present: no reinstall. Pins that the check is a check, not
#    an unconditional install that would cost minutes on every main push.
make_env_repo
run_env BUNDLE_CHECK_EXIT=0
[[ "$status" == 0 ]] || fail "warm-checkout run failed (got: $out)"
[[ "$(env_calls)" != *"bundle install"* ]] || fail "reinstalled gems that were present (calls: $(env_calls))"
report "does not reinstall gems that are already present"

# 9. A release archive must never be built from the empty credentials stub:
#    that would ship testers an app with blank API keys. Absent file ⇒ refuse,
#    before any archive, and never generate a stub here.
make_env_repo
rm -f "$TMP/env/podcasts/Credentials/LocalApiCredentials.swift"
run_env
[[ "$status" != 0 ]] || fail "archived without real credentials"
[[ "$out" == *"LocalApiCredentials.swift"* ]] || fail "missing credentials not named (got: $out)"
[[ "$(env_calls)" != *"auris_beta_build"* ]] || fail "archived despite missing credentials (calls: $(env_calls))"
[[ "$(env_calls)" != *"external_contributor"* ]] || fail "generated a stub for a release archive (calls: $(env_calls))"
report "refuses to archive without real credentials, and never stubs them"

# 9b. A file that EXISTS but is the stub must also be refused: the placeholder
#     values are what makes it a stub, not its absence. Mutant: checking only
#     for the file's existence.
make_env_repo
cp "$TMP/env/podcasts/Credentials/ApiCredentials.tpl" "$TMP/env/podcasts/Credentials/LocalApiCredentials.swift"
run_env
[[ "$status" != 0 ]] || fail "archived from the placeholder template"
[[ "$(env_calls)" != *"auris_beta_build"* ]] || fail "archived from the template (calls: $(env_calls))"
report "refuses a credentials file that still holds template placeholders"

# 9c. An EMPTY-valued credentials file is a stub too: `make external_contributor`
#     strips the placeholders to empty strings, so emptiness is the real shape
#     of the stub this step must refuse.
make_env_repo
sed 's/%{[^}]*}//g' "$TMP/env/podcasts/Credentials/ApiCredentials.tpl" > "$TMP/env/podcasts/Credentials/LocalApiCredentials.swift"
run_env
[[ "$status" != 0 ]] || fail "archived from the empty-valued stub"
[[ "$(env_calls)" != *"auris_beta_build"* ]] || fail "archived from the empty stub (calls: $(env_calls))"
report "refuses the empty-valued stub make external_contributor produces"

# 9d. Real credentials present: the archive proceeds. Pins that the refusal is
#     about the values, not a blanket ban on the file.
make_env_repo
sed 's/%{[^}]*}/real-value/g' "$TMP/env/podcasts/Credentials/ApiCredentials.tpl" > "$TMP/env/podcasts/Credentials/LocalApiCredentials.swift"
run_env
[[ "$status" == 0 ]] || fail "refused real credentials (got: $out)"
[[ "$(env_calls)" == *"auris_beta_build"* ]] || fail "did not archive with real credentials (calls: $(env_calls))"
report "archives when the credentials file holds real values"

# 10. The device llama slice is built when absent, rather than failing the
#     preflight on an artifact the sibling job builds into its own checkout.
make_env_repo
run_env
[[ "$(env_calls)" == *"llama-build"* ]] || fail "device llama not built when missing (calls: $(env_calls))"
[[ -d "$TMP/env/ThirdParty/llama-cpp-build/ios-device/lfm" ]] || fail "device slice still missing after the build"
report "builds the device llama slice when the checkout lacks it"

# 11. Toolchain pins are asserted, not inherited: a wrong Ruby must fail
#     before an archive, naming the pin.
make_env_repo
run_env FAKE_RUBY=3.2.0
[[ "$status" != 0 ]] || fail "wrong Ruby accepted"
[[ "$out" == *"expected Ruby"* ]] || fail "wrong Ruby not reported (got: $out)"
[[ "$(env_calls)" != *"auris_beta_build"* ]] || fail "archived under the wrong Ruby (calls: $(env_calls))"
report "refuses a Ruby other than the repo pin, before archiving"

# 12. Same for Xcode: an archive produced by another toolchain does not
#     vouch for the pinned one.
make_env_repo
run_env FAKE_XCODE=15.0
[[ "$status" != 0 ]] || fail "wrong Xcode accepted"
[[ "$out" == *"expected Xcode"* ]] || fail "wrong Xcode not reported (got: $out)"
[[ "$(env_calls)" != *"auris_beta_build"* ]] || fail "archived under the wrong Xcode (calls: $(env_calls))"
report "refuses an Xcode other than the repo pin, before archiving"

echo "$cases/$cases upload-gate and environment cases passed"

# Pipeline: the upload step exists, runs only on main, and waits for the
# tests.
grep -q "key: beta-upload" "$PIPE" || fail "no beta-upload step in the pipeline"
grep -q 'build.branch == "main"' "$PIPE" || fail "beta-upload step not restricted to main"
grep -q "depends_on: build-and-test" "$PIPE" || fail "beta-upload step does not depend on build-and-test"
# The signed archive from a gate-off run must be kept, or the dry run produces
# nothing anyone can inspect or install.
awk '/key: beta-upload/,/^  - label:|^$/' "$PIPE" | grep -q 'artifacts/\*.ipa' \
  || fail "beta-upload step keeps no archive artifact"
echo "ok: pipeline gates the upload step correctly and keeps the archive"

echo "all auris-beta-upload self-tests passed"
