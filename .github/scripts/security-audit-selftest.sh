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
check_unverified() {
  local label=$1 want=$2 got
  got=$(cut -f1 "$last_out/unverified.tsv" | sort | tr '\n' ' ')
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
check_unverified "only the finding in the unfinished file is unverified" "unparsable.py "

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
check_unverified "the report is read back section by section" "unparsable.py "

rm unparsable.py
commit_all "remove the file that does not parse"
expect "a complete scan verifies every open finding" 0 "" \
  AUDIT_SCANNERS=code AUDIT_CODE_RULES="$work/rules.yml" AUDIT_PREVIOUS="$work/previous.tsv" bash "$audit" full
check_unverified "nothing is unverified after a complete scan" ""

# A gap semgrep reports without saying where: a stand-in semgrep that finds nothing and
# reports one error with no path. Every open finding is then unverified.
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
echo '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Semgrep OSS","rules":[]}},"results":[]}]}' > "$sarif"
echo '{"results":[],"errors":[{"type":"Fatal error","level":"warn","message":"gave up"}]}' > "$json"
SEMGREP
chmod +x "$work/fake-bin/semgrep"
expect "a gap with no path leaves every open finding unverified" 0 "Not verified this run (semgrep): 3" \
  PATH="$work/fake-bin:$PATH" AUDIT_SCANNERS=code AUDIT_PREVIOUS="$work/previous.tsv" bash "$audit" full
check_unverified "all three are unverified" "gone.py risky.py unparsable.py "

if [ "$failures" -gt 0 ]; then
  echo "$failures case(s) failed"
  exit 1
fi
echo "all cases passed"
