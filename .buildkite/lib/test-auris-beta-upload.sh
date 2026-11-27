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

# Every preflight fixture must genuinely be ON MAIN, or the provenance refusal
# fires first and the case stops testing the condition it names. This makes a
# real repo with a real origin at the given path and leaves HEAD on main.
make_on_main_repo() { # $1 = repo dir
  local d="$1"
  rm -rf "$d" "$d.origin.git"
  git init --quiet --bare "$d.origin.git"
  git init --quiet "$d"
  (
    cd "$d"
    git config user.email t@t; git config user.name t
    git config commit.gpgsign false
    mkdir -p .buildkite/commands
    cp "$CMD" .buildkite/commands/
    git add -A >/dev/null 2>&1
    git commit --quiet -m base
    git branch -M main
    git remote add origin "$d.origin.git"
    git push --quiet origin main
  ) >/dev/null 2>&1
}

run_case() { # $1 = expected message; $2.. = env assignments applied over the base set
  local expected="$1"; shift
  make_on_main_repo "$TMP/repo"
  mkdir -p "$TMP/repo/ThirdParty/llama-cpp-build/ios-device/lfm"
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
make_on_main_repo "$TMP/repo"
mkdir -p "$TMP/repo/ThirdParty"
out=$(env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" APP_STORE_CONNECT_API_KEY_KEY_ID=k APP_STORE_CONNECT_API_KEY_ISSUER_ID=i APP_STORE_CONNECT_API_KEY_KEY=secret bash -c "cd '$TMP/repo/.buildkite/commands' && ./auris-beta-upload.sh --check" 2>&1)
if [[ "$out" == *"device llama build missing"* ]]; then
  echo "ok: preflight reports 'device llama build missing'"
else
  fail "preflight did not report 'device llama build missing' (got: $out)"
fi

# Happy path passes when everything is in place.
make_on_main_repo "$TMP/repo"
mkdir -p "$TMP/repo/ThirdParty/llama-cpp-build/ios-device/lfm"
if env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" APP_STORE_CONNECT_API_KEY_KEY_ID=k APP_STORE_CONNECT_API_KEY_ISSUER_ID=i APP_STORE_CONNECT_API_KEY_KEY=secret bash -c "cd '$TMP/repo/.buildkite/commands' && ./auris-beta-upload.sh --check" >/dev/null 2>&1; then
  echo "ok: preflight passes with everything in place"
else
  fail "preflight failed with all conditions satisfied"
fi

# ---------------------------------------------------------------------------
# Provenance: a branch NAME is a label, not proof of where a commit came from,
# and this repo is public. The step must refuse a checkout that is not on main
# BEFORE it reads the App Store Connect key. Each case builds a REAL git repo
# with a real `origin`, so the assertion is about ancestry rather than a string.
# ---------------------------------------------------------------------------
provenance_case() { # $1 = on-main|off-main ; $2 = expect-pass|expect-refuse
  local mode="$1" expect="$2"
  rm -rf "$TMP/prov" "$TMP/origin.git"
  git init --quiet --bare "$TMP/origin.git"
  git init --quiet "$TMP/prov"
  (
    cd "$TMP/prov"
    git config user.email t@t; git config user.name t
    git config commit.gpgsign false
    mkdir -p .buildkite/commands ThirdParty/llama-cpp-build/ios-device/lfm
    cp "$CMD" .buildkite/commands/
    git add -A >/dev/null 2>&1
    git commit --quiet -m base
    git branch -M main
    git remote add origin "$TMP/origin.git"
    git push --quiet origin main
    if [[ "$mode" == off-main ]]; then
      # A commit that exists in the checkout but was never on main. This is the
      # shape a pull-request build has, whatever its branch happens to be called.
      git checkout --quiet -b main   # SAME LABEL, different history
      echo unreviewed > extra.txt
      git add -A >/dev/null 2>&1
      git commit --quiet -m "not on main"
    fi
  ) >/dev/null 2>&1
  local out rc
  out=$(env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" \
        APP_STORE_CONNECT_API_KEY_KEY_ID=k APP_STORE_CONNECT_API_KEY_ISSUER_ID=i \
        APP_STORE_CONNECT_API_KEY_KEY=secret BUILDKITE_BRANCH=main \
        bash -c "cd '$TMP/prov/.buildkite/commands' && ./auris-beta-upload.sh --check" 2>&1) && rc=0 || rc=$?
  if [[ "$expect" == expect-refuse ]]; then
    if [[ "$rc" -ne 0 && "$out" == *"not on main"* ]]; then
      echo "ok: a checkout that is not on main is refused before the key is read"
    else
      fail "an off-main checkout was NOT refused (rc=$rc, got: $out)"
    fi
  else
    if [[ "$rc" -eq 0 ]]; then
      echo "ok: a checkout genuinely on main passes the provenance check"
    else
      fail "an on-main checkout was refused (rc=$rc, got: $out)"
    fi
  fi
}

# A remote that cannot be reached must REFUSE, not pass: "could not verify" is
# not "verified". Same repo shape, origin pointed at a path that does not exist.
provenance_unreachable() {
  make_on_main_repo "$TMP/prov"
  ( cd "$TMP/prov" && git remote set-url origin "$TMP/does-not-exist.git" ) >/dev/null 2>&1
  local out rc
  out=$(env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" \
        APP_STORE_CONNECT_API_KEY_KEY_ID=k APP_STORE_CONNECT_API_KEY_ISSUER_ID=i \
        APP_STORE_CONNECT_API_KEY_KEY=secret BUILDKITE_BRANCH=main \
        bash -c "cd '$TMP/prov/.buildkite/commands' && ./auris-beta-upload.sh --check" 2>&1) && rc=0 || rc=$?
  if [[ "$rc" -ne 0 && "$out" == *"cannot fetch origin/main"* ]]; then
    echo "ok: an unreachable origin refuses rather than assuming provenance"
  else
    fail "an unverifiable checkout was NOT refused (rc=$rc, got: $out)"
  fi
}

provenance_case off-main expect-refuse
provenance_case on-main  expect-pass
provenance_unreachable
echo "3/3 provenance cases passed (counted separately from the gate/env tally below)"

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
  # ON MAIN, like a real upload job: otherwise the provenance refusal fires
  # first and every gate case below would pass for the wrong reason.
  make_on_main_repo "$TMP/up"
  mkdir -p "$TMP/up/ThirdParty/llama-cpp-build/ios-device/lfm" "$TMP/up/bin" "$TMP/up/podcasts/Credentials"
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
  # ON MAIN, so these cases test the environment rather than provenance.
  make_on_main_repo "$TMP/env"
  mkdir -p "$TMP/env/bin" "$TMP/env/podcasts/Credentials"
  cp "$ROOT/.ruby-version" "$ROOT/.xcode-version" "$TMP/env/"
  cp "$ROOT/podcasts/Credentials/ApiCredentials.tpl" "$TMP/env/podcasts/Credentials/"
  sed 's/%{[^}]*}/real-value/g' "$ROOT/podcasts/Credentials/ApiCredentials.tpl" > "$TMP/env/podcasts/Credentials/LocalApiCredentials.swift"
  # bundle: records the invocation, and `bundle check` reports missing gems.
  cat > "$TMP/env/bin/bundle" <<STUB
#!/bin/sh
echo "bundle \$@" >> "$TMP/env/calls.txt"
echo "\${LC_ALL:-\${LANG:-unset}}" > "$TMP/env/locale.txt"
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

# Writes an internal secrets JSON covering every %{key} the template needs.
# $1 = value for each key (default real-value); $2 = optional key to omit.
write_secrets() {
  mkdir -p "$TMP/.configure/pocketcasts-ios/secrets"
  python3 - "$TMP/.configure/pocketcasts-ios/secrets/pocket_casts_credentials.json" \
    "$TMP/env/podcasts/Credentials/ApiCredentials.tpl" "${1-real-value}" "${2:-}" <<'PYJSON'
import json,re,sys
out,tpl,value,omit=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
keys=set(re.findall(r'%\{([^}]*)\}', open(tpl).read()))-{'timestamp'}
if omit: keys.discard(omit); open(out+'.missing','w').write(omit)
json.dump({k:value for k in keys}, open(out,'w'))
PYJSON
}

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

# 13. A missing signing key must fail in seconds, not after a full llama.cpp
#     build and gem install. The header promises this; the order must deliver it.
#     Mutant: `prepare_inputs` before the env-var check.
make_env_repo
run_env APP_STORE_CONNECT_API_KEY_KEY=
[[ "$status" != 0 ]] || fail "missing key accepted"
[[ "$(env_calls)" != *"llama-build"* ]] || fail "built llama before checking the signing key (calls: $(env_calls))"
[[ "$(env_calls)" != *"bundle install"* ]] || fail "installed gems before checking the signing key (calls: $(env_calls))"
report "checks the signing key before any heavy input preparation"

# 14. The repo's documented INTERNAL credential source must be accepted: the
#     build phase generates ApiCredentials.swift from CREDENTIALS_JSON_PATH when
#     LocalApiCredentials.swift is absent (scripts/build-phases/generate-credentials.sh).
#     Refusing that agent would refuse a build that gets real values.
make_env_repo
rm -f "$TMP/env/podcasts/Credentials/LocalApiCredentials.swift"
write_secrets
run_env
[[ "$status" == 0 ]] || fail "refused the internal secrets source (got: $out)"
[[ "$(env_calls)" == *"auris_beta_build"* ]] || fail "did not archive with internal secrets (calls: $(env_calls))"
report "accepts the repo's internal secrets JSON as a credentials source"

# 14b. An EMPTY internal secrets file is no better than the stub: it would
#      generate blank values. Mutant: accepting the path on existence alone.
make_env_repo
rm -f "$TMP/env/podcasts/Credentials/LocalApiCredentials.swift"
mkdir -p "$TMP/.configure/pocketcasts-ios/secrets"
echo '{}' > "$TMP/.configure/pocketcasts-ios/secrets/pocket_casts_credentials.json"
run_env
[[ "$status" != 0 ]] || fail "archived from an empty internal secrets file"
[[ "$(env_calls)" != *"auris_beta_build"* ]] || fail "archived from empty internal secrets (calls: $(env_calls))"
report "refuses an internal secrets file with no values"

# 14d. Keys present but EMPTY now ARCHIVE: the beta-feature audit of the
#      template found every credential optional — the app hides or degrades
#      the feature cleanly when a value is blank, so a credentials-less beta
#      runs. Only the shape is guarded: presence and string-ness. Mutant:
#      restoring the non-empty requirement (this row goes red).
make_env_repo
rm -f "$TMP/env/podcasts/Credentials/LocalApiCredentials.swift"
write_secrets ""
run_env
[[ "$status" == 0 ]] || fail "refused all-empty internal secrets (got: $out)"
[[ "$(env_calls)" == *"auris_beta_build"* ]] || fail "did not archive all-empty internal secrets (calls: $(env_calls))"
report "archives internal secrets whose keys hold empty values"

# 14e. A MISSING key is worse than an empty one: `line % secrets` raises KeyError,
#      so the archive would fail deep inside the build phase. Refuse up front and
#      name the key. Mutant: checking only the keys that happen to be present.
make_env_repo
rm -f "$TMP/env/podcasts/Credentials/LocalApiCredentials.swift"
write_secrets real-value zendesk_url
run_env
[[ "$status" != 0 ]] || fail "accepted internal secrets missing a template key"
[[ "$out" == *"$(cat "$TMP/.configure/pocketcasts-ios/secrets/pocket_casts_credentials.json.missing")"* ]] \
  || fail "missing key not named (got: $out)"
report "refuses internal secrets missing a template key, naming it"

# 14f. Every template key present with a real value: archives. Pins that the
#      check is about presence and type, not a blanket refusal.
make_env_repo
rm -f "$TMP/env/podcasts/Credentials/LocalApiCredentials.swift"
write_secrets
run_env
[[ "$status" == 0 ]] || fail "refused complete internal secrets (got: $out)"
[[ "$(env_calls)" == *"auris_beta_build"* ]] || fail "did not archive with complete internal secrets (calls: $(env_calls))"
report "archives when every template key has a real value"

# 14g. A JSON null or false is not a credential. `str(None)` is "None" and
#      Ruby interpolates "" for nil / "false" for false, so a mistyped value
#      would land in the build as a bogus literal. Empty strings stay legal;
#      the wrong TYPE does not. Mutant: `isinstance(secrets[k], str)` dropped.
make_env_repo
rm -f "$TMP/env/podcasts/Credentials/LocalApiCredentials.swift"
write_secrets
python3 - "$TMP/.configure/pocketcasts-ios/secrets/pocket_casts_credentials.json" <<'PYJSON'
import json,sys
d=json.load(open(sys.argv[1])); d['sentry_dsn']=None; d['zendesk_url']=False
json.dump(d, open(sys.argv[1],'w'))
PYJSON
run_env
[[ "$status" != 0 ]] || fail "archived with null/false credentials"
[[ "$(env_calls)" != *"auris_beta_build"* ]] || fail "archived with null/false credentials (calls: $(env_calls))"
report "refuses non-string credential values (null, false)"
# 14d-2. The refusal of empties is really gone, not just bypassed: exactly the
#        all-empty file 14d accepts, with one key's value swapped to a string
#        that LOOKS empty after strip — still archives. Mutant: a truthiness
#        check like `not secrets[k].strip()` sneaking back in.
make_env_repo
rm -f "$TMP/env/podcasts/Credentials/LocalApiCredentials.swift"
write_secrets " "
run_env
[[ "$status" == 0 ]] || fail "refused whitespace-valued secrets (got: $out)"
report "archives whitespace-only credential values (emptiness is not policed)"

# 14h. The required keys come from the TEMPLATE, so the pattern must match any
#      placeholder Ruby would substitute, not just lowercase-and-underscore.
#      A future key with a digit or capital would otherwise escape the guard.
#      Mutant: `%\{([a-z_]+)\}` in either the guard or this derivation.
make_env_repo
rm -f "$TMP/env/podcasts/Credentials/LocalApiCredentials.swift"
printf 'let extra = "%%{api_key_v2}"\n' >> "$TMP/env/podcasts/Credentials/ApiCredentials.tpl"
# Write the secrets WITHOUT the new key: the guard must notice it is required.
write_secrets real-value api_key_v2
run_env
[[ "$status" != 0 ]] || fail "a template key with a digit escaped the check"
[[ "$out" == *"api_key_v2"* ]] || fail "the escaped key was not named (got: $out)"
report "covers template keys containing digits or capitals"

# 14c. Neither source present: still refuses, and names both so the reader knows
#      either route works. Pins that adding the second source did not remove the refusal.
make_env_repo
rm -f "$TMP/env/podcasts/Credentials/LocalApiCredentials.swift"
rm -rf "$TMP/.configure"
run_env
[[ "$status" != 0 ]] || fail "archived with no credentials source at all"
[[ "$out" == *"pocket_casts_credentials.json"* ]] || fail "internal source not named as an alternative (got: $out)"
report "refuses when neither credentials source is present, naming both"

# 15. fastlane needs a UTF-8 locale and a Buildkite job has no login shell to
#     provide one: with LANG/LC_ALL unset, `locale charmap` is US-ASCII and
#     fastlane prints its "requires your locale to be set to UTF-8" error on
#     every run. The step must set it itself rather than depend on the agent's
#     hook happening to do so. Mutant: dropping the export.
make_env_repo
run_env
[[ "$status" == 0 ]] || fail "run failed (got: $out)"
grep -q 'UTF-8' "$TMP/env/locale.txt" 2>/dev/null || fail "no UTF-8 locale exported to the lanes (got: $(cat "$TMP/env/locale.txt" 2>/dev/null))"
report "exports a UTF-8 locale for fastlane"

# 15b. An inherited NON-UTF-8 locale must be overridden, not merely defaulted:
#      `${LC_ALL:-...}` keeps a `C` that the agent exported, reintroducing exactly
#      the US-ASCII locale this line exists to remove. Mutant: the `:-` form.
make_env_repo
run_env LC_ALL=C LANG=C
[[ "$status" == 0 ]] || fail "run failed (got: $out)"
grep -q 'UTF-8' "$TMP/env/locale.txt" 2>/dev/null || fail "inherited non-UTF-8 locale survived (got: $(cat "$TMP/env/locale.txt" 2>/dev/null))"
report "overrides an inherited non-UTF-8 locale"

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
# Every declared glob must match something the lane actually writes, or the
# claim "the archive is kept" is only partly true. `build_app` alone writes the
# ipa and the dSYM zip; the .xcarchive.zip needs an explicit `zip` call.
FASTFILE="$ROOT/fastlane/Fastfile"
awk '/^  lane :auris_beta_build/,/^  end/' "$FASTFILE" | grep -q 'zip(path: AURIS_XCARCHIVE_PATH' \
  || fail "pipeline declares artifacts/*.xcarchive.zip but the lane never zips the archive"
awk '/key: beta-upload/,/^  - label:|^$/' "$PIPE" | grep -q 'artifacts/\*.app.dSYM.zip' \
  || fail "dSYMs are written beside the ipa but not declared as artifacts"
# The log glob is only honest if the lane writes a log there. gym's default
# buildlog_path is ~/Library/Logs/gym, outside the checkout, so nothing would
# be collected. Mutant: dropping buildlog_path from build_app.
awk '/^  lane :auris_beta_build/,/^  end/' "$FASTFILE" | grep -q 'buildlog_path: ARTIFACTS_FOLDER' \
  || fail "pipeline declares artifacts/*.log but the lane writes its build log elsewhere"
echo "ok: pipeline gates the upload step correctly and keeps the archive"

echo "all auris-beta-upload self-tests passed"
