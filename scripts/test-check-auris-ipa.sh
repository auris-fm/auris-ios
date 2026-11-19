#!/bin/bash
# Self-test for scripts/check-auris-ipa.sh
#
# Builds two synthetic .ipa bundles — one whose app binary carries the lfm
# runtime symbols, one without — and asserts the checker accepts the first
# and rejects the second. Runs entirely from fixtures; no real archive needed.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$HERE/check-auris-ipa.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v zip >/dev/null || fail "zip not available"
command -v clang >/dev/null || fail "clang not available"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

make_ipa() { # $1 = out path, $2 = with-symbols? (yes/no)
  local out="$1" with="$2"
  local root="$TMP/pay-$(basename "$out" .ipa)"
  mkdir -p "$root/Payload/podcasts.app"
  local src="$TMP/src-$(basename "$out" .ipa).c"
  if [[ "$with" == yes ]]; then
    cat > "$src" <<'EOF'
const char *lfm_runtime_marker = "lfm_runtime";
const char *lfm_create_marker = "lfm_create";
int main(void) { return 0; }
EOF
  else
    cat > "$src" <<'EOF'
const char *nothing_here = "plain app";
int main(void) { return 0; }
EOF
  fi
  clang -arch arm64 "$src" -o "$root/Payload/podcasts.app/podcasts" || fail "fixture compile failed"
  (cd "$root" && zip -qr "$out" Payload)
}

make_ipa "$TMP/with-lfm.ipa" yes
make_ipa "$TMP/without-lfm.ipa" no

# 1. The checker must accept a payload that carries the runtime symbols.
if "$CHECK" "$TMP/with-lfm.ipa" >/dev/null 2>&1; then
  echo "ok: ipa with lfm runtime accepted"
else
  fail "checker rejected an ipa that contains the lfm runtime"
fi

# 2. The checker must reject a payload without them.
if "$CHECK" "$TMP/without-lfm.ipa" >/dev/null 2>&1; then
  fail "checker accepted an ipa whose binary lacks the lfm runtime"
else
  echo "ok: ipa without lfm runtime rejected"
fi

# 3. A missing file must be rejected, not skipped.
if "$CHECK" "$TMP/does-not-exist.ipa" >/dev/null 2>&1; then
  fail "checker accepted a non-existent ipa"
else
  echo "ok: missing ipa rejected"
fi

echo "all check-auris-ipa self-tests passed"
