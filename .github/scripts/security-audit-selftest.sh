#!/usr/bin/env bash
# Runs `security-audit.sh` against small throwaway repositories whose right answer is known.
#
# Each case is one way the audit has been wrong or could be made wrong without anyone
# noticing: a finding it should report and did not, or a scan that did not happen and read as
# clean. The audit workflow runs this before it trusts the script with a pull request.
#
# Needs the same scanners on PATH as `security-audit.sh`. It uses no network: semgrep gets a
# local rule instead of the registry, and zizmor runs without a token.
#
# The same file lives in `core`, `auris-ios` and `auris-android`; keep the three identical.

set -euo pipefail

audit=$(cd "$(dirname "$0")" && pwd)/security-audit.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
last_out=""

# A credential in a provider's format, put together here so that this file holds no match.
fake_token="ghp_$(printf '%s' 0123456789abcdefghijABCDEFGHIJ012345)"

unsafe_workflow='name: unsafe
on: pull_request_target
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
'

# new_repo <name>: an empty repository with one commit on `main`, and cd into it.
new_repo() {
  mkdir "$work/$1"
  cd "$work/$1"
  git init -q -b main .
  git config user.name selftest
  git config user.email selftest@example.invalid
  git config commit.gpgsign false
  echo "readme" > README.md
  git add -A
  git commit -q -m base
}

commit_all() {
  git add -A
  git commit -q -m "$1" > /dev/null
}

# expect <label> <status> <text the report must contain, or ""> <env assignments and audit arguments...>
expect() {
  local label=$1 want=$2 text=$3 got=0
  shift 3
  last_out=$(mktemp -d "$work/out.XXXXXX")
  env -u AUDIT_GITHUB_TOKEN -u AUDIT_ENFORCE -u AUDIT_QUIET -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY \
    AUDIT_OUT="$last_out" "$@" > "$work/stdout" 2> "$work/stderr" || got=$?
  if [ "$got" -ne "$want" ]; then
    echo "FAIL $label: exit $got, expected $want"
    tail -n 5 "$work/stderr" | sed 's/^/    /'
    failures=$((failures + 1))
  elif [ -n "$text" ] && ! grep -qF -- "$text" "$work/stdout"; then
    echo "FAIL $label: the report does not contain: $text"
    failures=$((failures + 1))
  else
    echo "ok   $label"
  fi
}

new_repo clean
echo "more" >> README.md
commit_all "a harmless change"
expect "a harmless change is clean" 0 "0 new findings" \
  AUDIT_SCANNERS="secrets workflows" bash "$audit" pr 'HEAD^1'

new_repo secret
echo "token = \"$fake_token\"" > settings.txt
commit_all "add a credential"
expect "a credential in a commit blocks" 1 "settings.txt" \
  AUDIT_SCANNERS=secrets bash "$audit" pr 'HEAD^1'

new_repo reverted
echo "token = \"$fake_token\"" > settings.txt
commit_all "add a credential"
git rm -q settings.txt
commit_all "remove it again"
expect "a credential a later commit removes still blocks" 1 "settings.txt" \
  AUDIT_SCANNERS=secrets bash "$audit" pr 'HEAD~2'

# The credential exists in no ordinary commit: only the conflict resolution adds it.
new_repo merge
git checkout -q -b feature
echo "feature" > shared.txt
commit_all "feature side"
git checkout -q main
echo "main" > shared.txt
commit_all "main side"
git checkout -q feature
git merge -q main > /dev/null 2>&1 || true
printf 'resolved\ntoken = "%s"\n' "$fake_token" > shared.txt
commit_all "merge main, resolving the conflict"
expect "a credential added by a merge resolution blocks" 1 "shared.txt" \
  AUDIT_SCANNERS=secrets bash "$audit" pr main

# The base has no workflow at all, so the base scan is empty.
new_repo first-workflow
mkdir -p .github/workflows
printf '%s' "$unsafe_workflow" > .github/workflows/unsafe.yml
commit_all "add the first workflow"
expect "the first workflow of a repository is audited" 0 "zizmor/dangerous-triggers" \
  AUDIT_SCANNERS=workflows bash "$audit" pr 'HEAD^1'
expect "a high-severity finding blocks once enforced" 1 "" \
  AUDIT_SCANNERS=workflows AUDIT_ENFORCE=true bash "$audit" pr 'HEAD^1'

new_repo broken-workflow
mkdir -p .github/workflows
printf 'name: broken\non: [push\njobs: {}\n' > .github/workflows/broken.yml
commit_all "add a workflow that does not parse"
expect "a workflow that does not parse is not reported clean" 2 "" \
  AUDIT_SCANNERS=workflows bash "$audit" pr 'HEAD^1'

new_repo arguments
expect "a misspelt scanner name is refused" 2 "" \
  AUDIT_SCANNERS="secret" bash "$audit" full
expect "an unknown history bound is refused" 2 "" \
  AUDIT_SCANNERS=secrets AUDIT_HISTORY_SINCE=no-such-tag bash "$audit" full
expect "an unknown base commit is refused" 2 "" \
  AUDIT_SCANNERS=secrets bash "$audit" pr no-such-commit

new_repo code
cat > "$work/rules.yml" << 'EOF'
rules:
  - id: selftest-eval
    languages: [python]
    severity: ERROR
    message: eval of a dynamic value
    pattern: eval(...)
EOF
printf 'def run(text):\n    return eval(text)\n' > risky.py
printf 'def broken(:\n    return eval(text\n' > unparsable.py
commit_all "add code"
expect "a risky call in changed code is reported" 0 "selftest-eval" \
  AUDIT_SCANNERS=code AUDIT_CODE_RULES="$work/rules.yml" bash "$audit" pr 'HEAD^1'
expect "a file semgrep cannot parse is named" 0 "unparsable.py" \
  AUDIT_SCANNERS=code AUDIT_CODE_RULES="$work/rules.yml" bash "$audit" full
if ! grep -q "^unparsable.py$(printf '\t')\*\$" "$last_out/unscanned.tsv"; then
  echo "FAIL the unparsed file is not in the list handed to the publisher"
  failures=$((failures + 1))
fi
expect "quiet mode does not print the findings" 0 "Risky code patterns (semgrep): 1" \
  AUDIT_SCANNERS=code AUDIT_CODE_RULES="$work/rules.yml" AUDIT_QUIET=true bash "$audit" full
if grep -q "risky.py" "$work/stdout" "$work/stderr"; then
  echo "FAIL quiet mode named a file with a finding"
  failures=$((failures + 1))
fi

# What the publisher is told about findings the last run left open. `risky.py` is scanned
# and still reported, `gone.py` is scanned and clean, `unparsable.py` is not finished.
# Compares `path:line` of each unverified finding.
check_unverified() {
  local label=$1 want=$2 got
  got=$(awk -F'\t' '{ print $1 ":" $3 }' "$last_out/unverified.tsv" | sort | tr '\n' ' ')
  if [ "$got" != "$want" ]; then
    echo "FAIL $label: unverified is '$got', expected '$want'"
    failures=$((failures + 1))
  fi
}
echo "x = 1" > gone.py
commit_all "a file with nothing to report"
printf 'risky.py\tselftest-eval\t2\ngone.py\tselftest-eval\t1\nunparsable.py\tselftest-eval\t2\n' > "$work/previous.tsv"
expect "an open finding in an unfinished file is kept" 0 "Not verified this run (semgrep): 1" \
  AUDIT_SCANNERS=code AUDIT_CODE_RULES="$work/rules.yml" AUDIT_PREVIOUS="$work/previous.tsv" bash "$audit" full
check_unverified "only the finding in the unfinished file is unverified" "unparsable.py:2 "

# The same, read back from a report of this script, as an issue body is.
cat > "$work/previous.md" << 'REPORT'
## Security audit: 3 findings at 0000000

### Risky code patterns (semgrep): 2

- `selftest-eval` at `gone.py:1`: eval of a dynamic value
- `selftest-eval` at `risky.py:2`: eval of a dynamic value

### Not verified this run (semgrep): 1

- `selftest-eval` at `unparsable.py:2`: eval of a dynamic value

### Unsafe workflows (zizmor): 1

- `zizmor/unpinned-uses` at `unparsable.py:7`: not a semgrep finding
REPORT
expect "a finding carried over once is carried again" 0 \
  "at \`unparsable.py:2\`: eval of a dynamic value" \
  AUDIT_SCANNERS=code AUDIT_CODE_RULES="$work/rules.yml" AUDIT_PREVIOUS_REPORT="$work/previous.md" bash "$audit" full
check_unverified "the report is read back section by section" "unparsable.py:2 "

rm unparsable.py
commit_all "remove the file that does not parse"
expect "a complete scan verifies every open finding" 0 "" \
  AUDIT_SCANNERS=code AUDIT_CODE_RULES="$work/rules.yml" AUDIT_PREVIOUS="$work/previous.tsv" bash "$audit" full
check_unverified "nothing is unverified after a complete scan" ""

# The rest needs semgrep to answer in ways it cannot be made to on demand, so a stand-in
# answers for it: it writes the results and the errors it is handed.
mkdir "$work/fake-bin"
cat > "$work/fake-bin/semgrep" << 'SEMGREP'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in
    --sarif-output) sarif=$2 ;;
    --json-output) json=$2 ;;
  esac
  shift
done
printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Semgrep OSS","rules":[]}},"results":[%s]}]}\n' "$FAKE_RESULTS" > "$sarif"
printf '{"results":[],"errors":[%s]}\n' "$FAKE_ERRORS" > "$json"
SEMGREP
chmod +x "$work/fake-bin/semgrep"
# fake_result <path> <line>: one `selftest-eval` result as semgrep writes it.
fake_result() {
  printf '{"ruleId":"selftest-eval","level":"error","message":{"text":"eval of a dynamic value"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"%s"},"region":{"startLine":%s}}}]}' "$1" "$2"
}

# A gap semgrep reports without saying where. Every open finding is then unverified.
expect "a gap with no path leaves every open finding unverified" 0 "Not verified this run (semgrep): 3" \
  PATH="$work/fake-bin:$PATH" FAKE_RESULTS="" \
  FAKE_ERRORS='{"type":"Fatal error","level":"warn","message":"gave up"}' \
  AUDIT_SCANNERS=code AUDIT_PREVIOUS="$work/previous.tsv" bash "$audit" full
check_unverified "all three are unverified" "gone.py:1 risky.py:2 unparsable.py:2 "

# semgrep gave up on `long.py` part of the way through, having reported one finding there.
# The last run left two open in that file, from the same rule. The one result confirms the
# finding at its own line and says nothing about the other.
timeout_error='{"type":"Timeout","level":"warn","message":"gave up","path":"long.py"}'
printf 'long.py\tselftest-eval\t2\nlong.py\tselftest-eval\t9\n' > "$work/two.tsv"
expect "one result does not stand in for two open findings" 0 "Not verified this run (semgrep): 1" \
  PATH="$work/fake-bin:$PATH" FAKE_RESULTS="$(fake_result long.py 2)" FAKE_ERRORS="$timeout_error" \
  AUDIT_SCANNERS=code AUDIT_PREVIOUS="$work/two.tsv" bash "$audit" full
check_unverified "the finding that was not reported again is kept" "long.py:9 "

# Two open findings on one line, and one result there: it answers for one of them.
printf 'long.py\tselftest-eval\t2\nlong.py\tselftest-eval\t2\n' > "$work/same-line.tsv"
expect "one result answers for one open finding on its line" 0 "Not verified this run (semgrep): 1" \
  PATH="$work/fake-bin:$PATH" FAKE_RESULTS="$(fake_result long.py 2)" FAKE_ERRORS="$timeout_error" \
  AUDIT_SCANNERS=code AUDIT_PREVIOUS="$work/same-line.tsv" bash "$audit" full
check_unverified "the second finding on the line is kept" "long.py:2 "

# The result is at another line than the open finding: not shown to be the same one.
printf 'long.py\tselftest-eval\t9\n' > "$work/moved.tsv"
expect "a result at another line confirms nothing" 0 "Not verified this run (semgrep): 1" \
  PATH="$work/fake-bin:$PATH" FAKE_RESULTS="$(fake_result long.py 2)" FAKE_ERRORS="$timeout_error" \
  AUDIT_SCANNERS=code AUDIT_PREVIOUS="$work/moved.tsv" bash "$audit" full
check_unverified "the open finding at the other line is kept" "long.py:9 "

# An open finding listed without its line can be matched to nothing.
printf 'long.py\tselftest-eval\n' > "$work/no-line.tsv"
expect "an open finding without a line is never confirmed" 0 "Not verified this run (semgrep): 1" \
  PATH="$work/fake-bin:$PATH" FAKE_RESULTS="$(fake_result long.py 2)" FAKE_ERRORS="$timeout_error" \
  AUDIT_SCANNERS=code AUDIT_PREVIOUS="$work/no-line.tsv" bash "$audit" full

# Both open findings are reported again, so the gap hides neither.
expect "findings reported again at their lines are verified" 0 "" \
  PATH="$work/fake-bin:$PATH" FAKE_RESULTS="$(fake_result long.py 2),$(fake_result long.py 9)" \
  FAKE_ERRORS="$timeout_error" \
  AUDIT_SCANNERS=code AUDIT_PREVIOUS="$work/two.tsv" bash "$audit" full
check_unverified "nothing is unverified when both are reported" ""

# The same through a report of this script: the line that was not reported again is the one
# carried over, word for word.
cat > "$work/two.md" << 'REPORT'
### Risky code patterns (semgrep): 2

- `selftest-eval` at `long.py:2`: eval of a dynamic value
- `selftest-eval` at `long.py:9`: eval of a dynamic value
REPORT
expect "the finding a report listed and this run lacks is carried over" 0 \
  "at \`long.py:9\`: eval of a dynamic value" \
  PATH="$work/fake-bin:$PATH" FAKE_RESULTS="$(fake_result long.py 2)" FAKE_ERRORS="$timeout_error" \
  AUDIT_SCANNERS=code AUDIT_PREVIOUS_REPORT="$work/two.md" bash "$audit" full
check_unverified "only that finding is carried over" "long.py:9 "

if [ "$failures" -gt 0 ]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "all cases passed"
