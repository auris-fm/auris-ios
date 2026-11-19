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

# Pipeline: the upload step exists, runs only on main, and waits for the
# tests.
grep -q "key: beta-upload" "$PIPE" || fail "no beta-upload step in the pipeline"
grep -q 'build.branch == "main"' "$PIPE" || fail "beta-upload step not restricted to main"
grep -q "depends_on: build-and-test" "$PIPE" || fail "beta-upload step does not depend on build-and-test"
echo "ok: pipeline gates the upload step correctly"

echo "all auris-beta-upload self-tests passed"
