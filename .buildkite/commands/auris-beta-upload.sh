#!/bin/bash
# Upload the Auris app to TestFlight internal testers after a green
# build-and-test step on main.
#
# Unlike build-and-test, this step never stubs the API credentials: a beta
# archive must carry real ones or it refuses to build.
#
# Runs `fastlane auris_beta_build` (device archive with automatic signing
# via the App Store Connect API key) on every main run. Publishing to
# TestFlight is separate: only a build carrying `BETA_UPLOAD=1` also runs
# `auris_beta_upload`, so the first run after a merge is a signed dry run
# and no build reaches testers by accident. The build number comes from
# the Buildkite build so successive uploads never collide. The preflight
# runs on every path, before the archive, so a misconfigured agent fails
# in seconds instead of burning an archive.

set -euo pipefail
cd "$(dirname "$0")/../.."

# Same toolchain reasoning as the sibling build-and-test step: the agent's
# service PATH is Homebrew plus system directories, so `ruby` would resolve to
# macOS's own while the repo pins another version. Shims first, then assert the
# pins — an archive built by another toolchain does not vouch for this one.
export PATH="$HOME/.rbenv/shims:$PATH"

# fastlane requires a UTF-8 locale and a Buildkite job has no login shell to set
# one: with LANG/LC_ALL unset, `locale charmap` reports US-ASCII and fastlane
# errors on every run. Set it here so the step does not depend on the agent's
# environment hook happening to provide it.
# Override by value, not only when unset: an inherited `C` would otherwise
# survive and reintroduce the very locale this removes.
case "${LC_ALL:-${LANG:-}}" in
  *UTF-8|*utf8) ;;
  *) export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ;;
esac

assert_toolchain() {
  local want_xcode want_ruby out
  want_xcode="$(sed -E 's/^~> ?//' .xcode-version)"
  out="$(xcodebuild -version)"
  grep -q "Xcode $want_xcode" <<< "$out" || {
    echo "expected Xcode $want_xcode (from .xcode-version), got: $out"; return 1; }
  want_ruby="$(cat .ruby-version)"
  out="$(ruby --version)"
  grep -q "$want_ruby" <<< "$out" || {
    echo "expected Ruby $want_ruby (from .ruby-version), got: $out"; return 1; }
}

# Inputs the archive needs that a fresh checkout does not carry. Each is
# created here rather than assumed present: the sibling job builds them into
# its own checkout, and this step runs in a different one.
# A release archive must carry SHAPE-CORRECT credentials; whether each value is
# populated is a provisioning call, not a build gate — the beta-feature audit of
# the template found every credential optional, and the app hides or degrades
# the feature cleanly when a value is blank, so a credentials-less beta runs.
# The guard checks SHAPE only, identically for both sources (a local
# LocalApiCredentials.swift wins in the build phase; otherwise
# scripts/build-phases/generate-credentials.sh generates from
# CREDENTIALS_JSON_PATH — config/PocketCasts.base.xcconfig — on an internal
# contributor's machine): every template key present, every value a string,
# no unreplaced %{placeholder}, no whitespace-only value. Blank (`""`) is fine;
# whitespace-only is refused as a provisioning typo — the app gates on
# `isEmpty`, which a `" "` defeats, so the feature would surface broken.
# `replace_secrets.rb` does `line % secrets`, so a missing key raises KeyError
# deep inside the build phase; a non-string (`null`, `false`) interpolates ""
# or "false", landing in the build as a bogus literal.
# `timestamp` is supplied by the script itself, not by the secrets file.
assert_complete_secrets() {
  local json="$1" tpl=podcasts/Credentials/ApiCredentials.tpl
  python3 - "$json" "$tpl" <<'PYSECRETS'
import json, re, sys
json_path, tpl_path = sys.argv[1], sys.argv[2]
try:
    secrets = json.load(open(json_path))
except Exception as e:
    print(f"{json_path} is not readable JSON: {e}")
    sys.exit(1)
if not isinstance(secrets, dict):
    print(f"{json_path} must be a JSON object of credentials")
    sys.exit(1)
# Match any placeholder Ruby would substitute, not just lowercase names: a key
# with a digit or capital must not escape the check.
keys = set(re.findall(r'%\{([^}]*)\}', open(tpl_path).read())) - {'timestamp'}
missing = sorted(k for k in keys if k not in secrets)
# A credential is a STRING — empty is fine, a wrong type is not. `null`
# interpolates to "" and `false` to "false" in Ruby, and str(None) == "None"
# would pass a truthiness check, so the TYPE is what the check pins.
wrong_type = sorted(k for k in keys
                    if k in secrets and not isinstance(secrets[k], str))
# Exactly "" is the audited blank; " " defeats the app's isEmpty gate, so it
# is a provisioning typo, not a deliberate blank.
whitespace = sorted(k for k in keys
                    if k in secrets and isinstance(secrets[k], str)
                    and secrets[k] != "" and secrets[k].strip() == "")
if missing or wrong_type or whitespace:
    if missing:
        print(f"{json_path} is missing credentials: {', '.join(missing)}")
    if wrong_type:
        print(f"{json_path} has non-string credentials: {', '.join(wrong_type)}")
    if whitespace:
        print(f"{json_path} has whitespace-only credentials: {', '.join(whitespace)}")
    print("refusing to archive a build that would fail or misbehave")
    sys.exit(1)
PYSECRETS
}

assert_real_credentials() {
  local f=podcasts/Credentials/LocalApiCredentials.swift
  local json="$HOME/.configure/pocketcasts-ios/secrets/pocket_casts_credentials.json"
  if [[ -f "$f" ]]; then
    # One rule with the JSON source: blanks are fine, an unreplaced %{…}
    # placeholder is the stub shape the build phase must never ship.
    if grep -qE '"%\{[^}]*\}"' "$f"; then
      echo "$f holds unreplaced placeholder credentials; refusing to archive a build that would misbehave"
      return 1
    fi
    return 0
  fi
  if [[ -r "$json" ]]; then
    assert_complete_secrets "$json" || return 1
    return 0
  fi
  echo "missing $f (or $json): a beta archive needs real API credentials, not the empty stub"
  return 1
}

prepare_inputs() {
  if [[ ! -d ThirdParty/llama-cpp-build/ios-device/lfm ]]; then
    "${LLAMA_BUILD_SCRIPT:-./scripts/build-llama-ios.sh}"
  fi
  # Gems live in vendor/bundle (.bundle/config), so `fastlane` is never on
  # PATH here: check the bundle rather than a global binary, and install only
  # when something is actually missing.
  bundle check >/dev/null 2>&1 || bundle install --quiet
}

# The signing key is checked FIRST, before any input preparation: a cold
# checkout must not spend a full llama.cpp build and gem install discovering
# that the agent has no key.
assert_signing_env() {
  fail=0
  for v in APP_STORE_CONNECT_API_KEY_KEY_ID APP_STORE_CONNECT_API_KEY_ISSUER_ID APP_STORE_CONNECT_API_KEY_KEY; do
    [[ -n "${!v:-}" ]] || { echo "missing env: $v"; fail=1; }
  done
  return "$fail"
}

# PROVENANCE, not a label. `build.branch == "main"` in the pipeline compares a
# NAME, and this repository is public: anyone can push a branch called `main`,
# or open a pull request whose build carries that label. A name is not evidence
# of where a commit came from, so it must not be the only thing standing between
# an unreviewed checkout and the App Store Connect signing key.
#
# The check is ancestry: the checked-out commit must be reachable from the
# server's main. It runs BEFORE any key is read, and fails CLOSED — a fetch that
# cannot complete is a refusal, not a pass, because "could not verify" is not
# "verified".
assert_on_main() {
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "not a git checkout: refusing to sign a build whose provenance cannot be established"
    return 1
  }
  if ! git -C "$root" fetch --quiet origin main 2>/dev/null; then
    echo "cannot fetch origin/main: refusing to sign a build whose provenance cannot be verified"
    return 1
  fi
  if ! git -C "$root" merge-base --is-ancestor HEAD FETCH_HEAD 2>/dev/null; then
    echo "this checkout is not on main: refusing to read the signing key for an unreviewed commit"
    return 1
  fi
}

preflight() {
  assert_on_main || return 1
  assert_signing_env || return 1
  [[ -d ThirdParty/llama-cpp-build/ios-device/lfm ]] || { echo "device llama build missing"; return 1; }
  echo "auris-beta-upload: preflight OK"
}

if [[ "${1:-}" == "--check" ]]; then
  preflight
  exit "$?"
fi

: "${BUILDKITE_BUILD_NUMBER:?must run under Buildkite}"
assert_on_main
assert_signing_env
assert_toolchain
assert_real_credentials
prepare_inputs
preflight

bundle exec fastlane auris_beta_build build_number:"$BUILDKITE_BUILD_NUMBER"

# Archiving and signing happen on every main run; publishing to TestFlight
# is a separate, deliberate act. Only an explicit `BETA_UPLOAD=1` on that
# one build uploads — any other value (including a truthy-looking typo)
# leaves the signed archive as the whole result. The preflight above runs
# on both paths, so a missing key fails before an archive is attempted.
if [[ "${BETA_UPLOAD:-0}" == "1" ]]; then
  bundle exec fastlane auris_beta_upload
else
  echo "auris-beta-upload: signed archive only; set BETA_UPLOAD=1 on a build to publish it"
fi
