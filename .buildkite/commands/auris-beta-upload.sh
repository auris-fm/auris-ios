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
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"

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
# A release archive must carry REAL API credentials. `make external_contributor`
# writes the template with every placeholder stripped to an empty string, which
# is right for build-and-test and wrong here: a TestFlight build from it would
# reach testers with blank keys. So this step never generates the file — it
# refuses, before any archive, unless the file exists AND holds non-empty values.
# Two sources are legitimate. A local LocalApiCredentials.swift wins in the
# build phase; otherwise scripts/build-phases/generate-credentials.sh generates
# from CREDENTIALS_JSON_PATH (config/PocketCasts.base.xcconfig), which is how an
# internal contributor's machine is provisioned. Either is fine; neither, or a
# stub-shaped one, is not.
assert_real_credentials() {
  local f=podcasts/Credentials/LocalApiCredentials.swift
  local json="$HOME/.configure/pocketcasts-ios/secrets/pocket_casts_credentials.json"
  if [[ -f "$f" ]]; then
    # Empty-valued (the stub) or still-placeholder (the raw template) both fail.
    if grep -qE '"(%\{[^}]*\})?"' "$f"; then
      echo "$f holds empty or placeholder credentials; refusing to archive a build testers cannot use"
      return 1
    fi
    return 0
  fi
  if [[ -r "$json" ]]; then
    # An object with no entries would generate blank values just as the stub does.
    if tr -d '[:space:]' < "$json" | grep -qE '^\{\}$'; then
      echo "$json holds no credentials; refusing to archive a build testers cannot use"
      return 1
    fi
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

preflight() {
  assert_signing_env || return 1
  [[ -d ThirdParty/llama-cpp-build/ios-device/lfm ]] || { echo "device llama build missing"; return 1; }
  echo "auris-beta-upload: preflight OK"
}

if [[ "${1:-}" == "--check" ]]; then
  preflight
  exit "$?"
fi

: "${BUILDKITE_BUILD_NUMBER:?must run under Buildkite}"
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
