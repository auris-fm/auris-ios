#!/usr/bin/env bash
# Regression test for upstream-sync-finalize.sh's `read_audit`.
#
# Background: the audit script always writes github_changed_files.txt and
# workflow_changed_files.txt — even when nothing changed, they contain a single
# newline. `read_audit` used trailing `&&` chains, so an empty diff made the
# chain return 1 and `set -e` aborted the whole finalize step silently (no push,
# no PR). This test pins the fix: empty files must leave the flags false *and*
# the function must return 0.
#
# Run: bash .github/scripts/tests/upstream-sync-finalize-read-audit-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FINALIZE="${SCRIPT_DIR}/upstream-sync-finalize.sh"

failures=0
assert_eq() {
  local actual="$1" expected="$2" what="$3"
  if [ "$actual" = "$expected" ]; then
    printf 'ok: %s = %s\n' "$what" "$actual"
  else
    printf 'FAIL: %s = %s (expected %s)\n' "$what" "$actual" "$expected" >&2
    failures=$((failures + 1))
  fi
}

# --- Case 1: audit reports no .github changes (the failing production shape) ---
tmp1="$(mktemp -d)"
mkdir -p "${tmp1}/upstream-sync"
export RUNNER_TEMP="$tmp1"
cat >"${tmp1}/upstream-sync/state.env" <<'EOF'
WORKTREE_ROOT=/tmp
SYNC_TAG=8.21.0.0
SYNC_BRANCH=upstream-sync/8.21.0.0
UPSTREAM_REPO=Automattic/pocket-casts-ios
EOF
printf '%s\n' "" >"${tmp1}/upstream-sync/github_changed_files.txt"
printf '%s\n' "" >"${tmp1}/upstream-sync/workflow_changed_files.txt"
printf 'has_unresolved_conflicts=false\ngithub_changed=false\nworkflow_changed=false\n' \
  >"${tmp1}/upstream-sync/audit.env"

# shellcheck disable=SC1090
source "$FINALIZE"
set +e
read_audit
rc=$?
set -e
assert_eq "$rc" "0" "read_audit exit status with empty audit files"
assert_eq "${github_changed:-unset}" "false" "github_changed"
assert_eq "${workflow_changed:-unset}" "false" "workflow_changed"

# --- Case 2: audit reports .github/workflows changes ---
tmp2="$(mktemp -d)"
mkdir -p "${tmp2}/upstream-sync"
export RUNNER_TEMP="$tmp2"
# REPORT_DIR is derived from RUNNER_TEMP when the script is sourced, so repoint it
# for this case (the file is sourced once per test script run).
REPORT_DIR="${tmp2}/upstream-sync"
AUDIT_FILE="${REPORT_DIR}/audit.env"
cp "${tmp1}/upstream-sync/state.env" "${tmp2}/upstream-sync/state.env"
printf '.github/workflows/claude.yml\n' >"${tmp2}/upstream-sync/github_changed_files.txt"
printf '.github/workflows/claude.yml\n' >"${tmp2}/upstream-sync/workflow_changed_files.txt"

github_changed=false
workflow_changed=false
read_audit
assert_eq "$rc" "0" "read_audit exit status with non-empty audit files"
assert_eq "$github_changed" "true" "github_changed (workflow-only diff)"
assert_eq "$workflow_changed" "true" "workflow_changed (workflow-only diff)"

rm -rf "$tmp1" "$tmp2"

if [ "$failures" -gt 0 ]; then
  printf '\n%s assertion(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall assertions passed\n'
