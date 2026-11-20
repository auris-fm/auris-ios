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
# Compares `path:line` of each unverified finding; a finding from a list has no line.
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
printf 'risky.py\tselftest-eval\ngone.py\tselftest-eval\nunparsable.py\tselftest-eval\n' > "$work/previous.tsv"
expect "an open finding in an unfinished file is kept" 0 "Not verified this run (semgrep): 1" \
  AUDIT_SCANNERS=code AUDIT_CODE_RULES="$work/rules.yml" AUDIT_PREVIOUS="$work/previous.tsv" bash "$audit" full
check_unverified "only the finding in the unfinished file is unverified" "unparsable.py: "

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
# fake_result <path> <line, or "" for a result that states none> [message]: one
# `selftest-eval` result as semgrep writes it.
fake_result() {
  local region=""
  if [ -n "$2" ]; then region=$(printf ',"region":{"startLine":%s}' "$2"); fi
  printf '{"ruleId":"selftest-eval","level":"error","message":{"text":"%s"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"%s"}%s}}]}' \
    "${3:-eval of a dynamic value}" "$1" "$region"
}
# The environment of a `full` run in which semgrep gives up on `long.py` part of the way
# through. What it reports before that is set per case, in FAKE_RESULTS.
gave_up=(PATH="$work/fake-bin:$PATH" AUDIT_SCANNERS=code
  FAKE_ERRORS='{"type":"Timeout","level":"warn","message":"gave up","path":"long.py"}')

# A gap semgrep reports without saying where. Every open finding is then unverified.
expect "a gap with no path leaves every open finding unverified" 0 "Not verified this run (semgrep): 3" \
  PATH="$work/fake-bin:$PATH" FAKE_RESULTS="" \
  FAKE_ERRORS='{"type":"Fatal error","level":"warn","message":"gave up"}' \
  AUDIT_SCANNERS=code AUDIT_PREVIOUS="$work/previous.tsv" bash "$audit" full
check_unverified "all three are unverified" "gone.py: risky.py: unparsable.py: "

# The cases below are about one question: semgrep did not finish `long.py`, the last run
# left findings open there, and this run reports something in that file. A result confirms
# an open finding only when it can be no other finding; in every other case the open finding
# is kept.

# First with the open findings given as a list of `path<TAB>rule`, as a caller that reads
# them from GitHub's code scanning alerts does. One open alert, and one result of the same
# rule in the same file: the result may be that finding or another, and the list cannot
# tell. The alert is kept, even when the caller adds the line and it is the result's.
printf 'long.py\tselftest-eval\t2\n' > "$work/one.tsv"
expect "a result does not confirm an open finding from a list" 0 "Not verified this run (semgrep): 1" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py 2)" AUDIT_PREVIOUS="$work/one.tsv" bash "$audit" full
check_unverified "the open finding from the list is kept" "long.py: "
# The report that run wrote is the next run's previous report, as the issue body is. The
# finding has no line there either, and has to come back out of it.
cp "$work/stdout" "$work/no-line.md"
expect "a finding without a line is read back from a report" 0 "Not verified this run (semgrep): 1" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py 2)" AUDIT_PREVIOUS_REPORT="$work/no-line.md" bash "$audit" full
check_unverified "the finding without a line is carried a second time" "long.py: "
# The same for a finding written without the `:?`, and for a result that had no line.
printf '%s\n' "### Not verified this run (semgrep): 1" "" \
  "- \`selftest-eval\` at \`long.py\`: eval of a dynamic value" > "$work/bare.md"
expect "a finding with a bare path is read back from a report" 0 \
  "- \`selftest-eval\` at \`long.py\`: eval of a dynamic value" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py "")" AUDIT_PREVIOUS_REPORT="$work/bare.md" bash "$audit" full
check_unverified "the finding with a bare path is carried" "long.py: "

# Open findings where semgrep finished are not held back by a gap somewhere else.
printf 'short.py\tselftest-eval\n' > "$work/elsewhere.tsv"
expect "a gap in one file leaves an open finding in another verified" 0 "" \
  "${gave_up[@]}" FAKE_RESULTS="" AUDIT_PREVIOUS="$work/elsewhere.tsv" bash "$audit" full
check_unverified "nothing is unverified outside the unfinished file" ""

# One rule failed on `long.py` and the others finished: only that rule's finding is kept.
printf 'long.py\tselftest-eval\nlong.py\tselftest-other\n' > "$work/rules.tsv"
expect "a rule that failed on a file leaves its own open finding unverified" 0 "Not verified this run (semgrep): 1" \
  PATH="$work/fake-bin:$PATH" AUDIT_SCANNERS=code FAKE_RESULTS="" \
  FAKE_ERRORS='{"type":"Internal matching error","level":"warn","message":"failed","path":"long.py","rule_id":"selftest-eval"}' \
  AUDIT_PREVIOUS="$work/rules.tsv" bash "$audit" full
if [ "$(cut -f2 "$last_out/unverified.tsv")" != selftest-eval ]; then
  echo "FAIL the finding kept is not the one from the rule that failed"
  failures=$((failures + 1))
fi

# Through a report the line and the message are known as well, and a finding can be
# recognised. The line that was not reported again is the one carried over, word for word.
cat > "$work/two.md" << 'REPORT'
### Risky code patterns (semgrep): 2

- `selftest-eval` at `long.py:2`: eval of a dynamic value
- `selftest-eval` at `long.py:9`: eval of a dynamic value
REPORT
expect "the finding a report listed and this run lacks is carried over" 0 \
  "at \`long.py:9\`: eval of a dynamic value" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py 2)" AUDIT_PREVIOUS_REPORT="$work/two.md" bash "$audit" full
check_unverified "only that finding is carried over" "long.py:9 "

# Both are reported again, each at its line, so the gap hides neither.
expect "findings reported again at their lines are verified" 0 "" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py 2),$(fake_result long.py 9)" \
  AUDIT_PREVIOUS_REPORT="$work/two.md" bash "$audit" full
check_unverified "nothing is unverified when both are reported" ""

# Two results fit one open finding: the report would show them as one line, so there is no
# telling how many findings its line stood for.
expect "two results that fit one open finding do not confirm it" 0 "Not verified this run (semgrep): 1" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py 2),$(fake_result long.py 2),$(fake_result long.py 9)" \
  AUDIT_PREVIOUS_REPORT="$work/two.md" bash "$audit" full
check_unverified "the open finding at that line is kept" "long.py:2 "

# The result states no line. It is not at line 1, and it confirms nothing there.
printf '%s\n' "### Risky code patterns (semgrep): 1" "" \
  "- \`selftest-eval\` at \`long.py:1\`: eval of a dynamic value" > "$work/first-line.md"
expect "a result without a line does not confirm a finding at line 1" 0 "Not verified this run (semgrep): 1" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py "")" AUDIT_PREVIOUS_REPORT="$work/first-line.md" bash "$audit" full
check_unverified "the finding at line 1 is kept" "long.py:1 "
if ! grep -qF "at \`long.py:?\`" "$work/stdout"; then
  echo "FAIL a result without a line is not shown at \`long.py:?\`"
  failures=$((failures + 1))
fi

# The same report as an issue edited on the web returns it, with CRLF line ends.
sed 's/$/\r/' "$work/two.md" > "$work/crlf.md"
expect "a report with CRLF line ends is read the same" 0 "Not verified this run (semgrep): 1" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py 2)" AUDIT_PREVIOUS_REPORT="$work/crlf.md" bash "$audit" full
check_unverified "only the finding not reported again is carried" "long.py:9 "

# A result at the line of an open finding, from the same rule, with another message: a
# different finding. It does not confirm the open one.
expect "a result with another message is a different finding" 0 \
  "at \`long.py:9\`: eval of a dynamic value" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py 2),$(fake_result long.py 9 "exec of a dynamic value")" \
  AUDIT_PREVIOUS_REPORT="$work/two.md" bash "$audit" full
check_unverified "the open finding with the first message is kept" "long.py:9 "

# Two findings at one line that differ by message, and one of them reported again: that
# one is confirmed, and the other is the one kept.
cat > "$work/same-line.md" << 'REPORT'
### Risky code patterns (semgrep): 2

- `selftest-eval` at `long.py:2`: eval of a dynamic value
- `selftest-eval` at `long.py:2`: exec of a dynamic value
REPORT
expect "of two findings on a line the one not reported again is kept" 0 \
  "Not verified this run (semgrep): 1" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py 2 "exec of a dynamic value")" AUDIT_PREVIOUS_REPORT="$work/same-line.md" bash "$audit" full
if ! cut -f4 "$last_out/unverified.tsv" | grep -qxF -- "- \`selftest-eval\` at \`long.py:2\`: eval of a dynamic value"; then
  echo "FAIL the wrong one of two findings on a line was kept"
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "all cases passed"
