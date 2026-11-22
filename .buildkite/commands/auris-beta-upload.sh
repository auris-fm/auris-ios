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

preflight() {
  fail=0
  command -v fastlane >/dev/null || { echo "no fastlane on PATH"; fail=1; }
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
preflight

if [[ ! -d vendor/bundle ]]; then
  bundle install --quiet
fi
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
