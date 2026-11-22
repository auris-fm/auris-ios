#!/bin/bash
# Upload the Auris app to TestFlight internal testers after a green
# build-and-test step on main.
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
prepare_inputs() {
  if [[ ! -f podcasts/Credentials/LocalApiCredentials.swift ]]; then
    make external_contributor
  fi
  if [[ ! -d ThirdParty/llama-cpp-build/ios-device/lfm ]]; then
    "${LLAMA_BUILD_SCRIPT:-./scripts/build-llama-ios.sh}"
  fi
  # Gems live in vendor/bundle (.bundle/config), so `fastlane` is never on
  # PATH here: check the bundle rather than a global binary, and install only
  # when something is actually missing.
  bundle check >/dev/null 2>&1 || bundle install --quiet
}

preflight() {
  fail=0
  [[ -d ThirdParty/llama-cpp-build/ios-device/lfm ]] || { echo "device llama build missing"; fail=1; }
  for v in APP_STORE_CONNECT_API_KEY_KEY_ID APP_STORE_CONNECT_API_KEY_ISSUER_ID APP_STORE_CONNECT_API_KEY_KEY; do
    [[ -n "${!v:-}" ]] || { echo "missing env: $v"; fail=1; }
  done
  [[ "$fail" == 0 ]] && echo "auris-beta-upload: preflight OK"
  return "$fail"
}

if [[ "${1:-}" == "--check" ]]; then
  preflight
  exit "$?"
fi

: "${BUILDKITE_BUILD_NUMBER:?must run under Buildkite}"
assert_toolchain
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
