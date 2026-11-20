#!/usr/bin/env bash
# Runs the security scanners over this repository and writes one Markdown report.
#
#   security-audit.sh pr <base-commit>   only what the checked-out tree adds on top of <base-commit>
#   security-audit.sh full               everything: the whole tree and the whole history
#
# Scanners, each needed on PATH along with git and jq:
#   gitleaks      credentials committed to the repository
#   osv-scanner   dependencies with a published vulnerability (reads the lockfiles)
#   semgrep       risky code patterns
#   zizmor        unsafe GitHub Actions workflows
#
# Environment (all optional):
#   AUDIT_OUT              directory for the report and the raw scanner output (default: a temp
#                          dir). `unscanned.tsv` there lists what semgrep did not finish, as
#                          `path<TAB>rule`, with `*` for a file no rule finished.
#   AUDIT_SCANNERS         which of "secrets deps code workflows" to run (default: all four)
#   AUDIT_ENFORCE          "true" makes high-severity findings from deps, code and workflows
#                          fail a `pr` run. A leaked secret fails a `pr` run regardless.
#   AUDIT_QUIET            "true" prints the count per scanner and not the findings, for a run
#                          whose log is public. The full report is still written to AUDIT_OUT.
#   AUDIT_HISTORY_SINCE    `full` only: scan history after this commit instead of all of it
#   AUDIT_CODE_TARGETS     `full` only: file listing the paths semgrep scans, one per line
#   AUDIT_GITHUB_TOKEN     token for zizmor, which looks up the actions a workflow references.
#                          It is removed from the environment before any scanner starts and
#                          handed to zizmor alone. Run this from a job whose token is read-only.
#   AUDIT_CODE_RULES       semgrep configuration (default: the registry's `p/default`)
#   AUDIT_PREVIOUS_SARIF   `full` only: the semgrep results the last run published, as SARIF
#   AUDIT_PREVIOUS_REPORT  `full` only: the same, given as the last report this script wrote
#
# A `full` run that is told what the last run reported checks each of those findings against
# what semgrep did not finish this time. One that sits in an unfinished file has not been
# shown to be fixed, unless this run reports that very finding again. It goes to
# `unverified.tsv` and into the report under "Not verified this run", for the caller to keep
# instead of dropping. Given the last results as SARIF the script keeps them itself: it adds
# them to `semgrep.sarif` in AUDIT_OUT, so that publishing that file in place of the last
# one drops no finding the scan could not check. See `unverified_code_findings`.
#
# Exit status: 0 nothing blocks, 1 a blocking finding in a `pr` run, 2 the audit could not be
# completed. A scanner that fails, a workflow or lockfile that cannot be read and a bad
# argument all exit 2: a scan that did not happen must never read as "no findings". The one
# partial result that does not stop the run is semgrep failing to parse or finish a file;
# those files are listed in the report under "Not fully scanned". A `full` run never exits 1:
# it is an inventory, and the caller publishes the report.
#
# The same file lives in `core`, `auris-ios` and `auris-android`; keep the three identical.

set -Eeuo pipefail

die() {
  echo "security-audit: $*" >&2
  exit 2
}
# Anything that fails outside an explicit check is also "could not be completed".
trap 'die "failed at line $LINENO"' ERR

mode=${1:-}
base=${2:-}
case "$mode" in
  pr) [ -n "$base" ] || die "pr mode needs the base commit" ;;
  full) ;;
  *) die "usage: security-audit.sh pr <base-commit> | full" ;;
esac

root=$(git rev-parse --show-toplevel)
cd "$root"
out=${AUDIT_OUT:-$(mktemp -d)}
mkdir -p "$out"
scanners=${AUDIT_SCANNERS:-secrets deps code workflows}
tab=$(printf '\t')
enabled() { case " $scanners " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
# A misspelt name would otherwise switch its scanner off and the run would report 0 findings.
[ -n "${scanners// /}" ] || die "AUDIT_SCANNERS names no scanner"
for name in $scanners; do
  case "$name" in
    secrets | deps | code | workflows) ;;
    *) die "AUDIT_SCANNERS: unknown scanner '$name'" ;;
  esac
done

# Out of the environment before anything else runs, so that no scanner but zizmor inherits it.
lookup_token=${AUDIT_GITHUB_TOKEN:-}
unset AUDIT_GITHUB_TOKEN

# A SARIF file with no result, for a scanner that had nothing to scan.
empty_sarif() {
  printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"%s","rules":[]}},"results":[]}]}\n' "$1" > "$2"
}

# A `pr` run compares against the base commit's tree for the two scanners that cannot do it
# themselves (osv-scanner, zizmor). gitleaks takes a commit range and semgrep a baseline commit.
base_tree=""
if [ "$mode" = pr ]; then
  base=$(git rev-parse --verify --quiet "$base^{commit}") || die "base commit not found"
  if enabled deps || enabled workflows; then
    base_tree="$out/base"
    git worktree add --quiet --detach "$base_tree" "$base"
    trap 'git worktree remove --force "$base_tree" 2>/dev/null || true' EXIT
  fi
fi

# Every scanner ends as rows of `key<TAB>severity<TAB>Markdown line`. The key identifies a finding
# without its line number, so a finding that only moved is not new. `severity` is "high" or "-".

# The first line of a result's message, as the report shows it.
jq_message='def message: (.message.text // "") | split("\n")[0] // "" | gsub("\t"; " ") | .[0:240];'

# Rows from a SARIF file, for the scanners whose findings sit at a place in a file. A result
# that states no level of its own has its rule's default level (semgrep writes them that way).
# One that states no line is shown at `file:?`, not at a line made up for it.
sarif_rows() {
  jq -r "$jq_message"'
    .runs[]
    | ((.tool.driver.rules // [])
       | map({ key: .id, value: (.defaultConfiguration.level // "warning") }) | from_entries) as $default
    | .results[]
    | (.level // $default[.ruleId] // "warning") as $level
    | (.locations[0].physicalLocation // {}) as $at
    | ($at.artifactLocation.uri // "?") as $file
    | message as $message
    | [ ([.ruleId, $file, $message, ($at.region.snippet.text // "")] | @json),
        (if $level == "error" then "high" else "-" end),
        "- `\(.ruleId)` at `\($file):\($at.region.startLine // "?")`: \($message)"
      ] | @tsv' "$1"
}

# Two identical findings in one file share a key; number them so that adding a second one to a
# file that already had one still counts as new.
number_repeats() {
  awk -F'\t' 'BEGIN { OFS = "\t" } { n[$1]++; print $1 "#" n[$1], $2, $3 }'
}

# Rows of the second file whose key is absent from the first. The first file is told apart
# by name, not by `NR == FNR`: that test stays true through the second file when the first is
# empty, and every row of a pull request against a clean base would then be dropped.
only_new() {
  awk -F'\t' 'FILENAME == ARGV[1] { seen[$1] = 1; next } !($1 in seen)' "$1" "$2"
}

scan_secrets() {
  local range=HEAD report="$out/gitleaks.sarif" log="$out/gitleaks.log"
  if [ "$mode" = pr ]; then
    # Every commit the pull request adds, including one that a later commit reverts: a
    # credential that was pushed is exposed whether or not it survives to the final tree.
    range="$base..HEAD"
  elif [ -n "${AUDIT_HISTORY_SINCE:-}" ]; then
    git rev-parse --verify --quiet "$AUDIT_HISTORY_SINCE^{commit}" > /dev/null ||
      die "AUDIT_HISTORY_SINCE is not a commit: $AUDIT_HISTORY_SINCE"
    range="$AUDIT_HISTORY_SINCE..HEAD"
  fi
  # --remerge-diff: `git log -p` shows no diff for a merge commit, so what a conflict
  # resolution adds would not be scanned. This shows a merge as the difference between
  # merging its parents mechanically and what was committed, which is exactly that addition.
  gitleaks git --no-banner --no-color --redact --exit-code 0 --log-opts="--remerge-diff $range" \
    --report-format sarif --report-path "$report" . 2> "$log" || {
    cat "$log" >&2
    die "gitleaks failed"
  }
  cat "$log" >&2
  # gitleaks exits 0 when the `git log` it reads from fails, having scanned nothing.
  if grep -q ' ERR ' "$log"; then die "gitleaks reported an error"; fi
  # One row per rule and file. gitleaks reports a value again for every commit that touches
  # its line, and all of those are one leak.
  jq -r '
    [ .runs[].results[]
      | { rule: .ruleId,
          file: (.locations[0].physicalLocation.artifactLocation.uri // "?"),
          commit: (.partialFingerprints.commitSha // "") } ]
    | group_by([.rule, .file])[]
    | [ ([.[0].rule, .[0].file] | @json), "high",
        "- `\(.[0].rule)` in `\(.[0].file)` (\(length) occurrence\(if length == 1 then "" else "s" end), e.g. in commit \(.[0].commit[0:8]))"
      ] | @tsv' "$report" > "$out/secrets.tsv"
}

# One row per package and advisory, so that an upgrade which keeps a known advisory is not new
# but one that brings in another is. An advisory is high at a CVSS score of 7 or more, or when
# it marks the package itself as malicious (`MAL-`); one with no score is listed, not high.
osv_rows() {
  local tree json=$2 log="$2.log" status=0
  tree=$(cd "$1" && pwd -P) # the path osv-scanner prints, with symlinks resolved
  # Twice: the advisories come from osv.dev at scan time, and one dropped connection should
  # not fail a pull request.
  for _ in 1 2; do
    status=0
    osv-scanner scan source --recursive --format json --output-file "$json" "$tree" > "$log" 2>&1 ||
      status=$?
    cat "$log" >&2
    case "$status" in 0 | 1 | 128) break ;; esac
  done
  case "$status" in
    0 | 1) ;;                               # 1: vulnerabilities found
    128) echo '{"results":[]}' > "$json" ;; # no lockfile at all
    *) die "osv-scanner failed with status $status" ;;
  esac
  # A lockfile it cannot parse is logged and left out, and the status stays 0 or 1.
  if grep -q 'Error during extraction' "$log"; then die "osv-scanner left a lockfile out"; fi
  jq -r --arg tree "$tree/" '
    .results[]
    | (.source.path | ltrimstr($tree)) as $lock
    | .packages[]
    | "`\(.package.name)@\(.package.version)` in `\($lock)`" as $package
    | .package.name as $name
    | .groups[]
    | ((.max_severity // "") | if . == "" then 0 else tonumber end) as $score
    | [ ([$lock, $name, .ids[0]] | @json),
        (if $score >= 7 or any(.ids[]; startswith("MAL-")) then "high" else "-" end),
        $package, .ids[0] ] | @tsv' "$json"
}

# One Markdown line per package from its advisory rows, high ones named first.
package_lines() {
  sort -t "$tab" -k2,2r -k4,4 "$1" | awk -F'\t' '
    { n[$3]++
      if ($2 == "high") high[$3]++
      if (n[$3] <= 3) ids[$3] = ids[$3] (n[$3] > 1 ? ", " : "") $4 }
    END {
      for (p in n)
        printf "%s\t%s\t- %s: %d advisor%s%s (%s%s)\n", p, (high[p] ? "high" : "-"), p, n[p],
          (n[p] == 1 ? "y" : "ies"), (high[p] ? ", " high[p] " high severity" : ""),
          ids[p], (n[p] > 3 ? ", ..." : "")
    }'
}

scan_deps() {
  osv_rows "$root" "$out/osv.json" > "$out/deps.all.tsv"
  if [ "$mode" = pr ]; then
    osv_rows "$base_tree" "$out/osv.base.json" > "$out/deps.base.tsv"
    only_new "$out/deps.base.tsv" "$out/deps.all.tsv" > "$out/deps.new.tsv"
    package_lines "$out/deps.new.tsv" > "$out/deps.tsv"
  else
    package_lines "$out/deps.all.tsv" > "$out/deps.tsv"
  fi
}

scan_code() {
  local report="$out/semgrep.sarif" errors="$out/semgrep.json" targets=0 path
  : > "$out/unscanned.lines"
  : > "$out/unscanned.tsv"
  : > "$out/unverified.tsv"
  set -- --metrics=off --quiet --config "${AUDIT_CODE_RULES:-p/default}" \
    --sarif-output "$report" --json-output "$errors"
  if [ "$mode" = pr ]; then
    set -- "$@" --baseline-commit "$base" .
  elif [ -n "${AUDIT_CODE_TARGETS:-}" ]; then
    # A scoped full scan: only the listed files that still exist.
    [ -r "$AUDIT_CODE_TARGETS" ] || die "AUDIT_CODE_TARGETS is not readable: $AUDIT_CODE_TARGETS"
    while IFS= read -r path || [ -n "$path" ]; do
      if [ -f "$path" ]; then
        set -- "$@" "$path"
        targets=$((targets + 1))
      fi
    done < "$AUDIT_CODE_TARGETS"
  else
    set -- "$@" .
  fi
  if [ -n "${AUDIT_CODE_TARGETS:-}" ] && [ "$mode" = full ] && [ "$targets" -eq 0 ]; then
    # With no target semgrep scans the whole repository, which is the opposite of the scope.
    # So it is not run, and that is a scan which did not happen, not one which found
    # nothing: it is recorded as a gap with no path, which keeps every previous finding.
    empty_sarif "Semgrep OSS" "$report"
    echo '{"results":[],"errors":[{"type":"No file of the scope exists"}]}' > "$errors"
  else
    # semgrep prints each finding on stdout as well as writing the report; errors go to stderr.
    semgrep scan "$@" > /dev/null || die "semgrep failed"
  fi
  sarif_rows "$report" | number_repeats > "$out/code.tsv"
  # semgrep exits 0 when it could not parse a file or gave up on it, and its `--strict` would
  # fail every run here: the registry rules themselves produce such warnings on files this
  # size. So the gaps are reported instead: one line per file, and one per rule that failed.
  jq -r '
    [ .errors[]
      | { kind: (.type | if type == "array" then .[0] else . end),
          path: (.path // "?"), rule: (.rule_id // "") } ] as $all
    | ( $all | map(select(.kind != "Internal matching error")) | group_by(.path)[]
        | "- `\(.[0].path)`: \([.[].kind] | unique | join(", "))" ),
      ( $all | map(select(.kind == "Internal matching error")) | group_by(.rule)[]
        | "- rule `\(.[0].rule)` failed on \(length) file\(if length == 1 then "" else "s" end)" )
  ' "$errors" > "$out/unscanned.lines"
  # The same gaps for whoever publishes the results: `path<TAB>rule`, with `*` for a file
  # that no rule finished. A finding an earlier run reported there cannot be called fixed
  # because this run does not report it. A timeout counts for the whole file: after a few
  # of them semgrep stops running rules on it.
  jq -r '
    .errors[]
    | (.type | if type == "array" then .[0] else . end) as $kind
    | [ (.path // "?"),
        (if $kind == "Internal matching error" and .rule_id != null then .rule_id else "*" end) ]
    | @tsv' "$errors" | sort -u > "$out/unscanned.tsv"
  if [ "$mode" = full ]; then unverified_code_findings "$report"; fi
}

# What the last report listed from semgrep, as
# `path<TAB>rule<TAB>line<TAB>Markdown line<TAB>message`. The line is empty for a finding
# that had none.
previous_report_findings() {
  [ -r "$AUDIT_PREVIOUS_REPORT" ] || die "AUDIT_PREVIOUS_REPORT is not readable: $AUDIT_PREVIOUS_REPORT"
  # The two sections of this script's own report that hold semgrep findings. A finding is
  # read back whether or not its place ends in a line, so that one without a line is
  # carried and not lost here. An issue edited on the web comes back with CRLF line ends.
  # The report lists a line once however many findings share it, hence `sort -u`.
  awk '
    { sub(/\r$/, ""); gsub(/\t/, " ") }
    /^### / { inside = ($0 ~ /^### (Risky code patterns|Not verified this run) \(semgrep\)/); next }
    inside && /^- `[^`]+` at `[^`]+`/ {
      rest = $0; sub(/^- `/, "", rest)
      rule = rest; sub(/`.*/, "", rule)
      sub(/^[^`]+` at `/, "", rest)
      place = rest; sub(/`.*/, "", place)
      message = substr(rest, length(place) + 2); sub(/^: /, "", message)
      path = place; line = ""
      if (place ~ /:([0-9]+|\?)$/) {
        line = place; sub(/^.*:/, "", line); sub(/:[^:]*$/, "", path)
        if (line == "?") line = ""
      }
      print path "\t" rule "\t" line "\t" $0 "\t" message
    }' "$AUDIT_PREVIOUS_REPORT" | sort -u
}

# The previous results that sit where semgrep did not finish and that this run does not
# report again, as a SARIF file of their own. "Again" is the same result: the same rule,
# file, region and message. Two such results are one to whoever reads the file, so leaving
# the previous one out loses nothing; any other previous result in a gap is kept.
previous_results_to_keep() {
  [ -r "$AUDIT_PREVIOUS_SARIF" ] || die "AUDIT_PREVIOUS_SARIF is not readable: $AUDIT_PREVIOUS_SARIF"
  # An empty or cut-off file would read as "the last run reported nothing".
  jq -e '.runs | type == "array"' "$AUDIT_PREVIOUS_SARIF" > /dev/null 2>&1 ||
    die "AUDIT_PREVIOUS_SARIF is not a SARIF file: $AUDIT_PREVIOUS_SARIF"
  jq --slurpfile previous "$AUDIT_PREVIOUS_SARIF" --rawfile gaps "$out/unscanned.tsv" '
    def place: .locations[0].physicalLocation // {};
    def identity:
      [ .ruleId, (place | .artifactLocation.uri, (.region // {} | .startLine, .startColumn, .endLine, .endColumn)),
        .message.text ] | tojson;
    [ $gaps | split("\n")[] | select(. != "") | split("\t") ] as $gap
    | any($gap[]; .[0] == "?") as $anywhere
    | ([ .runs[].results[] | { key: identity, value: true } ] | from_entries) as $reported
    | [ $previous[0].runs[]?
        | (.tool.driver.rules // []) as $rules
        | (.results // [])[]
        | (place.artifactLocation.uri // "?") as $path
        | .ruleId as $rule
        | select($anywhere or any($gap[]; .[0] == $path and (.[1] == "*" or .[1] == $rule)))
        | select($reported[identity] | not)
        # Only what a result is made of. What GitHub adds when it stores one (the alert it
        # belongs to, positions in lists of the file it was stored in) does not carry over.
        | { key: identity,
            rule: (first($rules[] | select(.id == $rule)) // null),
            result: ( { ruleId: $rule, message: { text: (.message.text // "") },
                        locations: [ { physicalLocation:
                          ( { artifactLocation: { uri: $path } }
                            + (if place.region then { region: place.region } else {} end) ) } ] }
                      + (if .level then { level: .level } else {} end) ) } ]
      | unique_by(.key) as $keep
    | { version: "2.1.0",
        runs: [ { tool: { driver: { name: "Semgrep OSS",
                                    rules: ([ $keep[].rule | select(. != null) ] | unique_by(.id)) } },
                  results: [ $keep[].result ] } ] }
  ' "$1"
}

# The previous findings this run can neither confirm nor rule out: in a file semgrep did not
# finish (or from a rule that failed on it), and not reported again. A gap with no path, `?`,
# could be anywhere, so it covers every previous finding. They go to `unverified.tsv`, as
# `path<TAB>rule<TAB>line<TAB>Markdown line<TAB>message`.
#
# "Reported again" has to mean that finding and no other, or a result would let a different
# finding be dropped unchecked.
#
# From SARIF a previous result is complete, and it is reported again when this run has the
# identical result. Every other one in a gap is added to this run's SARIF file, so that the
# file can replace the last one: nothing the scan could not check is dropped from it. A
# result kept this way stays until a run finishes its file, at the place it had when it was
# last found.
#
# From a report a previous finding is a line of text: its rule, file, line and message. It
# is confirmed only when its line is known and exactly one result of this run has all four.
# Anything less leaves it unverified:
#
#   - a finding or a result without a line;
#   - two results that fit it: the report shows them as one line, so there is no telling
#     how many findings that line stood for;
#   - a finding whose line has moved, until its file is scanned to the end.
unverified_code_findings() {
  local report=$1
  if [ -n "${AUDIT_PREVIOUS_SARIF:-}" ]; then
    previous_results_to_keep "$report" > "$out/kept.sarif"
    # `@tsv` doubles a backslash; the report shows one.
    jq -r "$jq_message"'
      .runs[].results[]
      | (.locations[0].physicalLocation // {}) as $at
      | ($at.artifactLocation.uri // "?") as $file
      | [ $file, .ruleId, ($at.region.startLine // ""),
          "- `\(.ruleId)` at `\($file):\($at.region.startLine // "?")`: \(message)", message ] | @tsv
    ' "$out/kept.sarif" | sed 's/\\\\/\\/g' > "$out/unverified.tsv"
    jq --slurpfile kept "$out/kept.sarif" '
      $kept[0].runs[0] as $kept
      | [ .runs[0].tool.driver.rules[]?.id ] as $known
      | .runs[0].tool.driver.rules =
          (.runs[0].tool.driver.rules // []) + [ $kept.tool.driver.rules[] | select(.id as $id | all($known[]; . != $id)) ]
      | .runs[0].results = (.runs[0].results // []) + $kept.results
    ' "$report" > "$report.merged"
    mv "$report.merged" "$report"
  elif [ -n "${AUDIT_PREVIOUS_REPORT:-}" ]; then
    previous_report_findings > "$out/previous.tsv"
    # `@tsv` doubles a backslash; the report, where a previous message comes from, shows one.
    jq -r "$jq_message"'
      .runs[].results[]
      | (.locations[0].physicalLocation // {}) as $at
      | [($at.artifactLocation.uri // "?"), .ruleId, ($at.region.startLine // ""), message] | @tsv' "$report" |
      sed 's/\\\\/\\/g' > "$out/current.tsv"
    awk -F'\t' '
      stage == "gaps" { if ($1 == "?") anywhere = 1; gap[$1 FS $2] = 1; next }
      stage == "results" { results[$1 FS $2 FS $3 FS $4]++; next }
      anywhere || (($1 FS "*") in gap) || (($1 FS $2) in gap) {
        if ($3 != "" && results[$1 FS $2 FS $3 FS $5] == 1) next
        print
      }
    ' stage=gaps "$out/unscanned.tsv" stage=results "$out/current.tsv" \
      stage=previous "$out/previous.tsv" > "$out/unverified.tsv"
  fi
}

zizmor_rows() {
  local status=0
  # --strict-collection: a workflow zizmor cannot parse is an error, not a file to skip.
  (
    cd "$1"
    if [ -n "$lookup_token" ]; then export GH_TOKEN="$lookup_token"; fi
    zizmor --format sarif --no-exit-codes --strict-collection .
  ) > "$2" || status=$?
  case "$status" in
    0) sarif_rows "$2" | number_repeats ;;
    3) empty_sarif zizmor "$2" ;; # nothing to audit: the tree has no workflow
    *) die "zizmor failed with status $status" ;;
  esac
}

scan_workflows() {
  zizmor_rows "$root" "$out/zizmor.sarif" > "$out/workflows.all.tsv"
  if [ "$mode" = pr ]; then
    zizmor_rows "$base_tree" "$out/zizmor.base.sarif" > "$out/workflows.base.tsv"
    only_new "$out/workflows.base.tsv" "$out/workflows.all.tsv" > "$out/workflows.tsv"
  else
    mv "$out/workflows.all.tsv" "$out/workflows.tsv"
  fi
}

total=0
blocking=0
: > "$out/sections.md"
: > "$out/counts.md"

# Appends one scanner's section and adds its counts to the totals.
report() {
  local name=$1 title=$2 rows="$out/$1.tsv" count high
  # The Markdown lines, each once, high severity first.
  cut -f2,3 "$rows" | sort -u | sort -t "$tab" -k1,1r -k2,2 > "$out/$name.lines"
  count=$(wc -l < "$out/$name.lines" | tr -d ' ')
  high=$(grep -c "^high$tab" "$out/$name.lines" || true)
  total=$((total + count))
  if [ "$name" = secrets ] || [ "${AUDIT_ENFORCE:-false}" = true ]; then
    blocking=$((blocking + high))
  fi
  echo "- $title: $count" >> "$out/counts.md"
  {
    echo "### $title: $count"
    echo
    if [ "$count" -eq 0 ]; then
      echo "None."
    else
      if [ "$high" -gt 0 ]; then
        echo "$high high severity, listed first."
        echo
      fi
      # The rows were written by jq's @tsv, which doubles a backslash.
      cut -f2 "$out/$name.lines" | sed 's/\\\\/\\/g'
    fi
    echo
  } >> "$out/sections.md"
}

# Each scan is its own statement, not the left side of `&&`: bash ignores `set -e` inside a
# function called that way, and a scanner that failed halfway would then report "None."
if enabled secrets; then
  scan_secrets
  report secrets "Leaked secrets (gitleaks)"
fi
if enabled deps; then
  scan_deps
  report deps "Vulnerable dependencies (osv-scanner)"
fi
if enabled code; then
  scan_code
  report code "Risky code patterns (semgrep)"
  unscanned=$(wc -l < "$out/unscanned.lines" | tr -d ' ')
  if [ "$unscanned" -gt 0 ]; then
    echo "- Not fully scanned (semgrep): $unscanned" >> "$out/counts.md"
    {
      echo "### Not fully scanned (semgrep): $unscanned"
      echo
      echo "semgrep could not parse these files completely, or gave up on them. A finding in them may be missing, including one an earlier run reported."
      echo
      sort "$out/unscanned.lines"
      echo
    } >> "$out/sections.md"
  fi
  unverified=$(wc -l < "$out/unverified.tsv" | tr -d ' ')
  if [ "$unverified" -gt 0 ]; then
    echo "- Not verified this run (semgrep): $unverified" >> "$out/counts.md"
    {
      echo "### Not verified this run (semgrep): $unverified"
      echo
      echo "The last run reported these, in a file or from a rule that semgrep did not finish this time, and this run does not report exactly them again. They stay listed until a run reports them again or finishes that file."
      echo
      cut -f4 "$out/unverified.tsv" | sort
      echo
    } >> "$out/sections.md"
  fi
fi
if enabled workflows; then
  scan_workflows
  report workflows "Unsafe workflows (zizmor)"
fi

if [ "$mode" = pr ]; then
  heading="## Security audit: $total new finding$([ "$total" -eq 1 ] || echo s) in this pull request"
else
  heading="## Security audit: $total finding$([ "$total" -eq 1 ] || echo s) at $(git rev-parse --short HEAD)"
fi
{
  echo "$heading"
  echo
  cat "$out/sections.md"
} > "$out/report.md"

shown="$out/report.md"
if [ "${AUDIT_QUIET:-false}" = true ]; then
  shown="$out/shown.md"
  {
    echo "$heading"
    echo
    cat "$out/counts.md"
  } > "$shown"
fi
cat "$shown"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat "$shown" >> "$GITHUB_STEP_SUMMARY"; fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "findings=$total"
    echo "unscanned=${unscanned:-0}"
    echo "unverified=${unverified:-0}"
  } >> "$GITHUB_OUTPUT"
fi

if [ "$mode" = pr ] && [ "$blocking" -gt 0 ]; then
  echo "::error::Security audit: $blocking blocking finding(s). See the job summary."
  exit 1
fi
if [ "$mode" = pr ] && [ "$total" -gt 0 ]; then
  echo "::warning::Security audit: $total new finding(s), none blocking. See the job summary."
fi
