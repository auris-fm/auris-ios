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

# From here on: what happens to the findings the last run reported, when this run did not
# finish a file. `risky.py` is scanned and still reported, `gone.py` is scanned and clean,
# `unparsable.py` is not finished.

# Compares `path:line` of each finding the run could not verify.
check_unverified() {
  local label=$1 want=$2 got
  got=$(awk -F'\t' '{ print $1 ":" $3 }' "$last_out/unverified.tsv" | sort | tr '\n' ' ')
  if [ "$got" != "$want" ]; then
    echo "FAIL $label: unverified is '$got', expected '$want'"
    failures=$((failures + 1))
  fi
}
# Compares `path:line` of each result in the file the run leaves for publishing.
check_published() {
  local label=$1 want=$2 got
  got=$(jq -r '.runs[].results[] | .locations[0].physicalLocation
    | "\(.artifactLocation.uri):\(.region.startLine // "")"' "$last_out/semgrep.sarif" | sort | tr '\n' ' ')
  if [ "$got" != "$want" ]; then
    echo "FAIL $label: the results to publish are '$got', expected '$want'"
    failures=$((failures + 1))
  fi
}
# fake_result <path> <line, or "" for a result that states none> [message] [column]: one
# `selftest-eval` result as semgrep writes it.
fake_result() {
  local region=""
  if [ -n "$2" ]; then region=$(printf ',"region":{"startLine":%s,"startColumn":%s}' "$2" "${4:-5}"); fi
  printf '{"ruleId":"selftest-eval","level":"error","message":{"text":"%s"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"%s"}%s}}]}' \
    "${3:-eval of a dynamic value}" "$1" "$region"
}
# sarif <results, comma separated>: a SARIF file with those results, as the last run
# published them.
sarif() {
  printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Semgrep OSS","rules":[{"id":"selftest-eval","name":"eval"}]}},"results":[%s]}]}\n' "$1"
}

echo "x = 1" > gone.py
commit_all "a file with nothing to report"

# First with the last results given as SARIF, as a caller that publishes SARIF has them.
sarif "$(fake_result risky.py 2),$(fake_result gone.py 1),$(fake_result unparsable.py 2)" > "$work/previous.sarif"
expect "a previous result in an unfinished file is kept" 0 "Not verified this run (semgrep): 1" \
  AUDIT_SCANNERS=code AUDIT_CODE_RULES="$work/rules.yml" AUDIT_PREVIOUS_SARIF="$work/previous.sarif" bash "$audit" full
check_unverified "only the result in the unfinished file is unverified" "unparsable.py:2 "
check_published "it is published along with what the run found" "risky.py:2 unparsable.py:2 "

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

# A scope of which no file exists: nothing was scanned, and nothing may be dropped.
echo "no/such/file.py" > "$work/scope.txt"
expect "a scan with nothing in scope keeps every previous result" 0 "Not verified this run (semgrep): 3" \
  AUDIT_SCANNERS=code AUDIT_CODE_RULES="$work/rules.yml" AUDIT_CODE_TARGETS="$work/scope.txt" \
  AUDIT_PREVIOUS_SARIF="$work/previous.sarif" bash "$audit" full
check_published "all three are published again" "gone.py:1 risky.py:2 unparsable.py:2 "

: > "$work/empty.sarif"
expect "previous results that cannot be read are not taken for none" 2 "" \
  AUDIT_SCANNERS=code AUDIT_CODE_RULES="$work/rules.yml" AUDIT_PREVIOUS_SARIF="$work/empty.sarif" bash "$audit" full

rm unparsable.py
commit_all "remove the file that does not parse"
expect "a complete scan verifies every previous result" 0 "" \
  AUDIT_SCANNERS=code AUDIT_CODE_RULES="$work/rules.yml" AUDIT_PREVIOUS_SARIF="$work/previous.sarif" bash "$audit" full
check_unverified "nothing is unverified after a complete scan" ""
check_published "only what the run found is published" "risky.py:2 "

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
# The environment of a `full` run in which semgrep gives up on `long.py` part of the way
# through. What it reports before that is set per case, in FAKE_RESULTS.
gave_up=(PATH="$work/fake-bin:$PATH" AUDIT_SCANNERS=code
  FAKE_ERRORS='{"type":"Timeout","level":"warn","message":"gave up","path":"long.py"}')

# A gap semgrep reports without saying where. Every previous result is then unverified.
expect "a gap with no path keeps every previous result" 0 "Not verified this run (semgrep): 3" \
  PATH="$work/fake-bin:$PATH" FAKE_RESULTS="" \
  FAKE_ERRORS='{"type":"Fatal error","level":"warn","message":"gave up"}' \
  AUDIT_SCANNERS=code AUDIT_PREVIOUS_SARIF="$work/previous.sarif" bash "$audit" full
check_unverified "all three are unverified" "gone.py:1 risky.py:2 unparsable.py:2 "

# The cases below are about one question: semgrep did not finish `long.py`, the last run
# reported findings there, and this run reports something in that file. A previous finding
# is let go only when this run reports that very finding; in every other case it is kept.

# One previous result, and a result of the same rule at the same line that is not the same
# result: it starts at another column. It may be another finding. Both are published.
sarif "$(fake_result long.py 2)" > "$work/one.sarif"
expect "a different result at its line does not replace a previous result" 0 "Not verified this run (semgrep): 1" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py 2 "" 9)" AUDIT_PREVIOUS_SARIF="$work/one.sarif" bash "$audit" full
check_unverified "the previous result is kept" "long.py:2 "
check_published "both results are published" "long.py:2 long.py:2 "

# The same for a result at the very same place with another message.
expect "a result with another message does not replace a previous result" 0 "Not verified this run (semgrep): 1" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py 2 "exec of a dynamic value")" AUDIT_PREVIOUS_SARIF="$work/one.sarif" bash "$audit" full
check_published "both results at that place are published" "long.py:2 long.py:2 "

# The identical result is the previous result reported again, and is published once.
expect "the identical result is a previous result reported again" 0 "" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py 2)" AUDIT_PREVIOUS_SARIF="$work/one.sarif" bash "$audit" full
check_unverified "nothing is unverified" ""
check_published "the result is published once" "long.py:2 "

# Two previous results from one rule, one of them reported again: the other is kept.
sarif "$(fake_result long.py 2),$(fake_result long.py 9)" > "$work/two.sarif"
expect "one result does not stand in for two previous results" 0 "Not verified this run (semgrep): 1" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py 2)" AUDIT_PREVIOUS_SARIF="$work/two.sarif" bash "$audit" full
check_unverified "the result that was not reported again is kept" "long.py:9 "
check_published "both are published" "long.py:2 long.py:9 "

# What that run leaves for publishing is the next run's previous results. With nothing
# reported this time, both come back out of it.
cp "$last_out/semgrep.sarif" "$work/second.sarif"
expect "a result kept once is kept again" 0 "Not verified this run (semgrep): 2" \
  "${gave_up[@]}" FAKE_RESULTS="" AUDIT_PREVIOUS_SARIF="$work/second.sarif" bash "$audit" full
check_published "both are published a second time" "long.py:2 long.py:9 "

# A previous result as GitHub hands it back: with the alert it belongs to and positions in
# the lists of the file it was stored in, and under a rule this run did not load. It is
# published as a plain result, with its rule.
cat > "$work/stored.sarif" << 'SARIF'
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Semgrep OSS","rules":[
  {"id":"selftest-unrelated","name":"unrelated"},{"id":"selftest-stored","name":"stored"}]}},
 "artifacts":[{"location":{"uri":"long.py"}}],
 "results":[{"ruleId":"selftest-stored","rule":{"id":"selftest-stored","index":1},"level":"warning",
  "correlationGuid":"00000000-0000-0000-0000-000000000000","message":{"text":"stored finding"},
  "partialFingerprints":{"primaryLocationLineHash":""},"properties":{"github/alertNumber":7},
  "locations":[{"physicalLocation":{"artifactLocation":{"uri":"long.py","index":0},
   "region":{"startLine":4,"startColumn":1,"endLine":4,"endColumn":9}}}]}]}]}
SARIF
expect "a stored result is kept with its rule" 0 "at \`long.py:4\`: stored finding" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py 2)" AUDIT_PREVIOUS_SARIF="$work/stored.sarif" bash "$audit" full
want='{"level":"warning","locations":[{"physicalLocation":{"artifactLocation":{"uri":"long.py"},"region":{"endColumn":9,"endLine":4,"startColumn":1,"startLine":4}}}],"message":{"text":"stored finding"},"ruleId":"selftest-stored"}'
got=$(jq -cS '.runs[0].results[] | select(.ruleId == "selftest-stored")' "$last_out/semgrep.sarif")
if [ "$got" != "$want" ]; then
  echo "FAIL the stored result is published as: $got"
  failures=$((failures + 1))
fi
if [ "$(jq -c '[.runs[0].tool.driver.rules[].id]' "$last_out/semgrep.sarif")" != '["selftest-stored"]' ]; then
  echo "FAIL the rule of the stored result is not published with it, or another rule is"
  failures=$((failures + 1))
fi

# Previous results where semgrep finished are not held by a gap somewhere else: the run
# looked there and did not find them.
sarif "$(fake_result short.py 3)" > "$work/elsewhere.sarif"
expect "a gap in one file does not keep a previous result in another" 0 "" \
  "${gave_up[@]}" FAKE_RESULTS="" AUDIT_PREVIOUS_SARIF="$work/elsewhere.sarif" bash "$audit" full
check_unverified "nothing is unverified outside the unfinished file" ""
check_published "nothing is published" ""

# One rule failed on `long.py` and the others finished: only that rule's result is kept.
sarif "$(fake_result long.py 2),$(fake_result long.py 9 | sed 's/selftest-eval/selftest-other/')" > "$work/rules.sarif"
expect "a rule that failed on a file keeps its own previous result" 0 "Not verified this run (semgrep): 1" \
  PATH="$work/fake-bin:$PATH" AUDIT_SCANNERS=code FAKE_RESULTS="" \
  FAKE_ERRORS='{"type":"Internal matching error","level":"warn","message":"failed","path":"long.py","rule_id":"selftest-eval"}' \
  AUDIT_PREVIOUS_SARIF="$work/rules.sarif" bash "$audit" full
check_unverified "the result kept is the one from the rule that failed" "long.py:2 "

# Now with the last findings read from a report. There a finding is a line of text, and it
# is confirmed only when exactly one result has its rule, file, line and message. The line
# that was not reported again is the one carried over, word for word.
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

# Two results fit one listed finding: the report would show them as one line, so there is
# no telling how many findings its line stood for.
expect "two results that fit one listed finding do not confirm it" 0 "Not verified this run (semgrep): 1" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py 2),$(fake_result long.py 2 "" 9),$(fake_result long.py 9)" \
  AUDIT_PREVIOUS_REPORT="$work/two.md" bash "$audit" full
check_unverified "the listed finding at that line is kept" "long.py:2 "

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
# The report that run wrote is the next run's previous report, as the issue body is. The
# finding without a line has to come back out of it, and cannot be confirmed.
cp "$work/stdout" "$work/no-line.md"
expect "a finding without a line is read back from a report" 0 "Not verified this run (semgrep): 2" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py "")" AUDIT_PREVIOUS_REPORT="$work/no-line.md" bash "$audit" full
check_unverified "the finding without a line is carried, with the one at line 1" "long.py: long.py:1 "
# The same for a finding written without the `:?`.
printf '%s\n' "### Not verified this run (semgrep): 1" "" \
  "- \`selftest-eval\` at \`long.py\`: eval of a dynamic value" > "$work/bare.md"
expect "a finding with a bare path is read back from a report" 0 \
  "- \`selftest-eval\` at \`long.py\`: eval of a dynamic value" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py "")" AUDIT_PREVIOUS_REPORT="$work/bare.md" bash "$audit" full
check_unverified "the finding with a bare path is carried" "long.py: "

# The same report as an issue edited on the web returns it, with CRLF line ends.
sed 's/$/\r/' "$work/two.md" > "$work/crlf.md"
expect "a report with CRLF line ends is read the same" 0 "Not verified this run (semgrep): 1" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py 2)" AUDIT_PREVIOUS_REPORT="$work/crlf.md" bash "$audit" full
check_unverified "only the finding not reported again is carried" "long.py:9 "

# A result at the line of a listed finding, from the same rule, with another message: a
# different finding. It does not confirm the listed one.
expect "a result with another message is a different finding" 0 \
  "at \`long.py:9\`: eval of a dynamic value" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py 2),$(fake_result long.py 9 "exec of a dynamic value")" \
  AUDIT_PREVIOUS_REPORT="$work/two.md" bash "$audit" full
check_unverified "the listed finding with the first message is kept" "long.py:9 "

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
