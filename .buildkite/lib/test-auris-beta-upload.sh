#!/bin/bash
# Self-test for .buildkite/commands/auris-beta-upload.sh and the pipeline
# wiring. Runs without credentials or fastlane: it exercises the
# preflight's failure paths with a stubbed PATH and env, and asserts the
# pipeline gates the upload step on a green build-and-test and a main
# branch.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
CMD="$ROOT/.buildkite/commands/auris-beta-upload.sh"
PIPE="$ROOT/.buildkite/auris-pipeline.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. Preflight fails fast when the key env vars are missing.
if env -i PATH="$PATH" bash "$CMD" --check >/dev/null 2>&1; then
  fail "preflight passed without the App Store Connect key env vars"
fi
echo "ok: preflight rejects missing key env vars"

# 2. Preflight fails when the device llama build is absent.
if env -i PATH="$PATH" APP_STORE_CONNECT_API_KEY_KEY_ID=k APP_STORE_CONNECT_API_KEY_ISSUER_ID=i \
     APP_STORE_CONNECT_API_KEY_KEY=secret \
     bash -c "cd '$TMP' && cp '$CMD' . && mkdir -p ThirdParty/llama-cpp-build && ./auris-beta-upload.sh --check" >/dev/null 2>&1; then
  fail "preflight passed without the device llama build"
fi
echo "ok: preflight rejects missing device llama build"

# 3. Pipeline: the upload step exists, runs only on main, and waits for
#    the tests.
grep -q "key: beta-upload" "$PIPE" || fail "no beta-upload step in the pipeline"
grep -q 'build.branch == "main"' "$PIPE" || fail "beta-upload step not restricted to main"
grep -q "depends_on: build-and-test" "$PIPE" || fail "beta-upload step does not depend on build-and-test"
echo "ok: pipeline gates the upload step correctly"

echo "all auris-beta-upload self-tests passed"
