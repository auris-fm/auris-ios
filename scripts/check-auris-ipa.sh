#!/bin/bash
# check-auris-ipa.sh <path.ipa>
#
# Verifies a built app archive is fit for a TestFlight upload:
#   1. the file exists and is a zip with a Payload/podcasts.app/podcasts binary;
#   2. that binary contains the lfm (speech runtime) symbols — the static
#      liblfm_runtime.a is linked into the app, so a device archive that was
#      built without ThirdParty/llama-cpp-build/ios-device passes the build
#      but would crash at first voice use; this check makes that visible.
#
# Exit 0 = fit to upload; non-zero with a diagnostic = not fit.

set -u

fail() { echo "check-auris-ipa: FAIL: $*" >&2; exit 1; }

IPA="${1:-}"
[[ -n "$IPA" ]] || fail "usage: check-auris-ipa.sh <path.ipa>"
[[ -f "$IPA" ]] || fail "no such file: $IPA"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unzip -q "$IPA" -d "$TMP" || fail "not a readable zip archive"

BIN="$TMP/Payload/podcasts.app/podcasts"
[[ -f "$BIN" ]] || fail "Payload/podcasts.app/podcasts not found in archive"

# Mach-O check first: a fat/binary mismatch would make the symbol scan lie.
file "$BIN" | grep -q "Mach-O" || fail "payload binary is not a Mach-O image"

if ! nm "$BIN" 2>/dev/null | grep -q "lfm"; then
  # Stripped release binaries may drop local symbols; fall back to the
  # linked-library table, then to string literals from the runtime itself.
  if otool -L "$BIN" 2>/dev/null | grep -q "lfm"; then
    :
  elif strings "$BIN" 2>/dev/null | grep -q "lfm_runtime"; then
    :
  else
    fail "speech runtime (lfm_runtime) not found in the payload binary — the device llama build was not linked in"
  fi
fi

echo "check-auris-ipa: OK — lfm runtime present in $IPA"
