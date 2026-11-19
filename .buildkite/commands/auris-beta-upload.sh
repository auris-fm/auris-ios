#!/bin/bash
# Upload the Auris app to TestFlight internal testers after a green
# build-and-test step on main.
#
# Runs `fastlane auris_beta_build` (device archive with automatic signing
# via the App Store Connect API key) then `auris_beta_upload`. The build
# number comes from the Buildkite build so successive uploads never
# collide. Everything before the upload needs no credentials; the upload
# fails fast when the key env vars are missing.

set -euo pipefail
cd "$(dirname "$0")/../.."

if [[ "${1:-}" == "--check" ]]; then
  # Preflight: things that must be true on the agent before any heavy work.
  fail=0
  [[ -x "$(command -v fastlane || true)" ]] || { echo "no fastlane on PATH"; fail=1; }
  [[ -d ThirdParty/llama-cpp-build/ios-device/lfm ]] || { echo "device llama build missing"; fail=1; }
  for v in APP_STORE_CONNECT_API_KEY_KEY_ID APP_STORE_CONNECT_API_KEY_ISSUER_ID APP_STORE_CONNECT_API_KEY_KEY; do
    [[ -n "${!v:-}" ]] || { echo "missing env: $v"; fail=1; }
  done
  [[ "$fail" == 0 ]] && echo "auris-beta-upload: preflight OK"
  exit "$fail"
fi

: "${BUILDKITE_BUILD_NUMBER:?must run under Buildkite}"

if [[ ! -d vendor/bundle ]]; then
  bundle install --quiet
fi
bundle exec fastlane auris_beta_build build_number:"$BUILDKITE_BUILD_NUMBER"
bundle exec fastlane auris_beta_upload
