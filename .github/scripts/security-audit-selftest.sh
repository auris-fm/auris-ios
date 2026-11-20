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
expect "a list of open findings, which is no longer read, is refused" 2 "" \
  AUDIT_SCANNERS=secrets AUDIT_PREVIOUS=README.md bash "$audit" full

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
# fake_result <path> <line, or "" for a result that states none> [message] [fingerprint]:
# one `selftest-eval` result, with the fingerprint that tells GitHub which alert it is.
fake_result() {
  local region="" fingerprint=""
  if [ -n "$2" ]; then region=$(printf ',"region":{"startLine":%s,"startColumn":5}' "$2"); fi
  if [ -n "${4:-}" ]; then fingerprint=$(printf ',"partialFingerprints":{"primaryLocationLineHash":"%s"}' "$4"); fi
  printf '{"ruleId":"selftest-eval","level":"error","message":{"text":"%s"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"%s"}%s}}]%s}' \
    "${3:-eval of a dynamic value}" "$1" "$region" "$fingerprint"
}
# Lists `path:line=fingerprint` of each result in the file the run leaves for publishing.
published_fingerprints() {
  jq -r '.runs[].results[] | "\(.locations[0].physicalLocation | "\(.artifactLocation.uri):\(.region.startLine // "")")=\(.partialFingerprints.primaryLocationLineHash // "")"' \
    "$last_out/semgrep.sarif" | sort | tr '\n' ' '
}
# sarif <results, comma separated>: a SARIF file with those results, as the last run
# published them.
sarif() {
  printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Semgrep OSS","rules":[{"id":"selftest-eval","name":"eval"}]}},"results":[%s]}]}\n' "$1"
}

echo "x = 1" > gone.py
commit_all "a file with nothing to report"

# Each result of a full run has a fingerprint made from the code it matched. Two matches of
# the same code in one file are told apart by a count, and moving the code changes nothing.
printf 'def twice(text):\n    eval(text)\n    eval(text)\n' > twice.py
commit_all "the same call twice"
expect "a full run fingerprints its results" 0 "" \
  AUDIT_SCANNERS=code AUDIT_CODE_RULES="$work/rules.yml" bash "$audit" full
before=$(published_fingerprints | tr ' ' '\n' | sed 's/^[^=]*=//' | sort | tr '\n' ' ')
if ! printf '%s' "$before" | grep -qE '^([0-9a-f]{40}_[01] ){3}$' ||
  [ "$(printf '%s' "$before" | tr ' ' '\n' | grep -c '_1$')" -ne 1 ] ||
  [ "$(printf '%s' "$before" | tr ' ' '\n' | sed 's/_[0-9]*$//' | sort -u | grep -c .)" -ne 2 ]; then
  echo "FAIL the fingerprints of three results, two of them of the same code, are: $before"
  failures=$((failures + 1))
fi
printf '# a comment\n\ndef twice(text):\n        eval(text)\n        eval(text)\n' > twice.py
commit_all "move the calls and indent them"
expect "a full run fingerprints moved code" 0 "" \
  AUDIT_SCANNERS=code AUDIT_CODE_RULES="$work/rules.yml" bash "$audit" full
after=$(published_fingerprints | tr ' ' '\n' | sed 's/^[^=]*=//' | sort | tr '\n' ' ')
if [ "$before" != "$after" ]; then
  echo "FAIL moving code changed its fingerprints: $before became $after"
  failures=$((failures + 1))
fi
git rm -q twice.py
commit_all "remove it again"

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

# One previous result, and a result that looks the same in every way (rule, file, place,
# message) but has another fingerprint: to GitHub it is another alert. Both are published,
# the previous one with the fingerprint it had.
sarif "$(fake_result long.py 2 "" aaa_0)" > "$work/one.sarif"
expect "a result with another fingerprint does not replace a previous result" 0 "Not verified this run (semgrep): 1" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py 2 "" bbb_0)" AUDIT_PREVIOUS_SARIF="$work/one.sarif" bash "$audit" full
check_unverified "the previous result is kept" "long.py:2 "
if [ "$(published_fingerprints)" != "long.py:2=aaa_0 long.py:2=bbb_0 " ]; then
  echo "FAIL both results should be published with their fingerprints, not: $(published_fingerprints)"
  failures=$((failures + 1))
fi

# The result with the same fingerprint is the previous result reported again, wherever it
# is now. It is published once, at its new place.
expect "a result with its fingerprint is a previous result reported again" 0 "" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py 7 "" aaa_0)" AUDIT_PREVIOUS_SARIF="$work/one.sarif" bash "$audit" full
check_unverified "nothing is unverified" ""
if [ "$(published_fingerprints)" != "long.py:7=aaa_0 " ]; then
  echo "FAIL the result should be published once at its new place, not: $(published_fingerprints)"
  failures=$((failures + 1))
fi

# A previous result that was published without a fingerprint cannot be shown to be any
# result of this run, however alike the two look. It is kept.
sarif "$(fake_result long.py 2)" > "$work/bare.sarif"
expect "a previous result without a fingerprint is never taken for reported again" 0 "Not verified this run (semgrep): 1" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py 2 "" aaa_0)" AUDIT_PREVIOUS_SARIF="$work/bare.sarif" bash "$audit" full
if [ "$(published_fingerprints)" != "long.py:2= long.py:2=aaa_0 " ]; then
  echo "FAIL both results should be published, not: $(published_fingerprints)"
  failures=$((failures + 1))
fi
# Without fingerprints, a result at another place is not the previous one either.
expect "a result without a fingerprint elsewhere does not replace one without" 0 "Not verified this run (semgrep): 1" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py 7)" AUDIT_PREVIOUS_SARIF="$work/bare.sarif" bash "$audit" full
check_published "both are published" "long.py:2 long.py:7 "
# Nor can a result of this run that has none stand for a previous one.
expect "a result without a fingerprint does not replace a previous result" 0 "Not verified this run (semgrep): 1" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py 2)" AUDIT_PREVIOUS_SARIF="$work/one.sarif" bash "$audit" full
check_published "both results at that place are published" "long.py:2 long.py:2 "

# Two previous results from one rule, one of them reported again: the other is kept.
sarif "$(fake_result long.py 2 "" aaa_0),$(fake_result long.py 9 "" aaa_1)" > "$work/two.sarif"
expect "one result does not stand in for two previous results" 0 "Not verified this run (semgrep): 1" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py 2 "" aaa_0)" AUDIT_PREVIOUS_SARIF="$work/two.sarif" bash "$audit" full
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
# published as a plain result, with its rule and its fingerprint.
cat > "$work/stored.sarif" << 'SARIF'
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Semgrep OSS","rules":[
  {"id":"selftest-unrelated","name":"unrelated"},{"id":"selftest-stored","name":"stored"}]}},
 "artifacts":[{"location":{"uri":"long.py"}}],
 "results":[{"ruleId":"selftest-stored","rule":{"id":"selftest-stored","index":1},"level":"warning",
  "correlationGuid":"00000000-0000-0000-0000-000000000000","message":{"text":"stored finding"},
  "partialFingerprints":{"primaryLocationLineHash":"ccc_0"},"properties":{"github/alertNumber":7},
  "locations":[{"physicalLocation":{"artifactLocation":{"uri":"long.py","index":0},
   "region":{"startLine":4,"startColumn":1,"endLine":4,"endColumn":9}}}]}]}]}
SARIF
expect "a stored result is kept with its rule" 0 "at \`long.py:4\`: stored finding" \
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py 2)" AUDIT_PREVIOUS_SARIF="$work/stored.sarif" bash "$audit" full
want='{"level":"warning","locations":[{"physicalLocation":{"artifactLocation":{"uri":"long.py"},"region":{"endColumn":9,"endLine":4,"startColumn":1,"startLine":4}}}],"message":{"text":"stored finding"},"partialFingerprints":{"primaryLocationLineHash":"ccc_0"},"ruleId":"selftest-stored"}'
got=$(jq -cS '.runs[0].results[] | select(.ruleId == "selftest-stored")' "$last_out/semgrep.sarif")
if [ "$got" != "$want" ]; then
  echo "FAIL the stored result is published as: $got"
  failures=$((failures + 1))
fi
if [ "$(jq -c '[.runs[0].tool.driver.rules[].id]' "$last_out/semgrep.sarif")" != '["selftest-stored"]' ]; then
  echo "FAIL the rule of the stored result is not published with it, or another rule is"
  failures=$((failures + 1))
fi

# The fingerprints this script makes itself, where the scan did not finish. `hit` is a
# result as semgrep writes it, with the code it matched and no fingerprint.
hit() { # path line code
  printf '{"ruleId":"selftest-eval","message":{"text":"eval of a dynamic value"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"%s"},"region":{"startLine":%s,"startColumn":5,"endLine":%s,"endColumn":15,"snippet":{"text":"    %s"}}}}]}' \
    "$1" "$2" "$2" "$3"
}
check_fingerprints() { # label, then what `published_fingerprints` should print with H for the hash
  local label=$1 want=$2 got
  got=$(published_fingerprints | sed -E 's/=[0-9a-f]{40}_/=H_/g')
  if [ "$got" != "$want" ]; then
    echo "FAIL $label: published '$got', expected '$want'"
    failures=$((failures + 1))
  fi
}
finished=(PATH="$work/fake-bin:$PATH" AUDIT_SCANNERS=code FAKE_ERRORS="")

# A match of several lines is the same code however its lines are indented.
expect "a match of several lines is fingerprinted" 0 "" \
  "${finished[@]}" FAKE_RESULTS="$(hit long.py 10 'eval(\n        text)')" bash "$audit" full
before=$(published_fingerprints)
expect "the same match with its lines indented otherwise is fingerprinted" 0 "" \
  "${finished[@]}" FAKE_RESULTS="$(hit long.py 10 'eval(\n  text)')" bash "$audit" full
if [ "$before" != "$(published_fingerprints)" ] || ! printf '%s' "$before" | grep -qE '=[0-9a-f]{40}_0 $'; then
  echo "FAIL indenting the lines of a match changed its fingerprint: $before became $(published_fingerprints)"
  failures=$((failures + 1))
fi

# A complete scan finds the same code at lines 10 and 20: the first and the second match.
expect "a complete scan numbers two matches of the same code" 0 "" \
  "${finished[@]}" FAKE_RESULTS="$(hit long.py 10 "eval(text)"),$(hit long.py 20 "eval(text)")" bash "$audit" full
check_fingerprints "they are the first and the second" "long.py:10=H_0 long.py:20=H_1 "
cp "$last_out/semgrep.sarif" "$work/twice.sarif"

# The next scan gives up on the file and reports the match at line 20 alone. It is still
# the second: counting what this scan returned would make it the first, and the one at
# line 10, which the scan did not check, would be dropped for it.
expect "the only match an unfinished scan reports keeps its own number" 0 "Not verified this run (semgrep): 1" \
  "${gave_up[@]}" FAKE_RESULTS="$(hit long.py 20 "eval(text)")" AUDIT_PREVIOUS_SARIF="$work/twice.sarif" bash "$audit" full
check_fingerprints "the unchecked match is kept at its place" "long.py:10=H_0 long.py:20=H_1 "
check_unverified "the unchecked match is the one not verified" "long.py:10 "

# Both reported where they were: nothing to keep, nothing renumbered.
expect "matches reported at their places keep their numbers" 0 "" \
  "${gave_up[@]}" FAKE_RESULTS="$(hit long.py 10 "eval(text)"),$(hit long.py 20 "eval(text)")" \
  AUDIT_PREVIOUS_SARIF="$work/twice.sarif" bash "$audit" full
check_fingerprints "each is published once" "long.py:10=H_0 long.py:20=H_1 "

# One match, at a line where there was none: it may be either of the two moved, or a third.
# It takes no earlier number, and both earlier matches are kept.
expect "a match at a new place in an unfinished file takes no earlier number" 0 "Not verified this run (semgrep): 2" \
  "${gave_up[@]}" FAKE_RESULTS="$(hit long.py 21 "eval(text)")" AUDIT_PREVIOUS_SARIF="$work/twice.sarif" bash "$audit" full
check_fingerprints "both earlier matches are kept" "long.py:10=H_0 long.py:20=H_1 long.py:21=H_2 "

# The same holds for a single earlier match: a match elsewhere may be a second one.
expect "a complete scan numbers a single match" 0 "" \
  "${finished[@]}" FAKE_RESULTS="$(hit long.py 10 "eval(text)")" bash "$audit" full
cp "$last_out/semgrep.sarif" "$work/once.sarif"
expect "a single match that an unfinished scan reports elsewhere is not taken for the earlier one" 0 "Not verified this run (semgrep): 1" \
  "${gave_up[@]}" FAKE_RESULTS="$(hit long.py 12 "eval(text)")" AUDIT_PREVIOUS_SARIF="$work/once.sarif" bash "$audit" full
check_fingerprints "the earlier match is kept" "long.py:10=H_0 long.py:12=H_1 "

# Where the scan finished, all matches are known. One left of two, at its place, is still
# the second, and the first is gone.
expect "a complete scan keeps the number of a match at its place" 0 "" \
  "${finished[@]}" FAKE_RESULTS="$(hit long.py 20 "eval(text)")" AUDIT_PREVIOUS_SARIF="$work/twice.sarif" bash "$audit" full
check_fingerprints "only that match is published" "long.py:20=H_1 "
# Both moved down a line: they are the first and the second again.
expect "a complete scan renumbers matches that moved" 0 "" \
  "${finished[@]}" FAKE_RESULTS="$(hit long.py 11 "eval(text)"),$(hit long.py 21 "eval(text)")" \
  AUDIT_PREVIOUS_SARIF="$work/twice.sarif" bash "$audit" full
check_fingerprints "they keep their numbers" "long.py:11=H_0 long.py:21=H_1 "
# A new match above one that stayed: the one that stayed keeps its number.
expect "a new match does not take the number of a match at its place" 0 "" \
  "${finished[@]}" FAKE_RESULTS="$(hit long.py 5 "eval(text)"),$(hit long.py 10 "eval(text)")" \
  AUDIT_PREVIOUS_SARIF="$work/once.sarif" bash "$audit" full
check_fingerprints "the new match gets the next number" "long.py:10=H_0 long.py:5=H_1 "

# What was published before results had fingerprints. The same result again is published
# as it was, so that it stays the alert it is.
sarif "$(hit long.py 10 "eval(text)")" > "$work/legacy.sarif"
expect "a result that was published without a fingerprint stays without one" 0 "" \
  "${gave_up[@]}" FAKE_RESULTS="$(hit long.py 10 "eval(text)")" AUDIT_PREVIOUS_SARIF="$work/legacy.sarif" bash "$audit" full
check_fingerprints "it is published once, as before" "long.py:10= "
# Reported elsewhere, it is a result of its own, and the earlier one is kept.
expect "a result published without a fingerprint is kept when it is not reported at its place" 0 "Not verified this run (semgrep): 1" \
  "${gave_up[@]}" FAKE_RESULTS="$(hit long.py 12 "eval(text)")" AUDIT_PREVIOUS_SARIF="$work/legacy.sarif" bash "$audit" full
check_fingerprints "both are published" "long.py:10= long.py:12=H_0 "

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
  "${gave_up[@]}" FAKE_RESULTS="$(fake_result long.py 2),$(fake_result long.py 2 "" other),$(fake_result long.py 9)" \
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
