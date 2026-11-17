#!/bin/bash
# Build the app and run the whole test plan on the `auris-ios` Mac agent.
#
# Every requirement below is here because its absence produces a run that looks
# like a pass. They are stated at the point of use rather than assumed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
REPO_ROOT="$PWD"

# The agent's launchd service PATH is Homebrew plus system directories only, so
# rbenv's shims are not on it and `ruby` would resolve to macOS's 3.2 while the
# repo pins another version. Put the shims first and let rbenv select from
# .ruby-version, so the toolchain is the repo's pin rather than the service's.
export PATH="$HOME/.rbenv/shims:$PATH"

LOG_DIR="$REPO_ROOT/artifacts"
mkdir -p "$LOG_DIR"

# One derived-data root per checkout, kept outside the workspace: the agent runs
# `git clean` between builds, and a cache inside the checkout would be deleted
# with it. Keyed on the pipeline so concurrent pipelines cannot share objects.
DERIVED="${BUILDKITE_AURIS_DERIVED:-$HOME/Library/Developer/Xcode/DerivedData/auris-ci-${BUILDKITE_PIPELINE_SLUG:-local}}"
mkdir -p "$DERIVED"

echo "--- :xcode: Asserting the pinned toolchain"
# The version output is captured before it is matched. Piping `xcodebuild
# -version` straight into `grep -q` fails under `pipefail`: grep exits at the
# first match, xcodebuild then dies on SIGPIPE, and the pipeline reports 141 —
# so a correct toolchain reads as a mismatch.
WANT_XCODE="$(sed -E 's/^~> ?//' .xcode-version)"
XCODE_VERSION_OUTPUT="$(xcodebuild -version)"
echo "$XCODE_VERSION_OUTPUT"
grep -q "Xcode $WANT_XCODE" <<< "$XCODE_VERSION_OUTPUT" || {
  echo "expected Xcode $WANT_XCODE (from .xcode-version); a run under another toolchain does not vouch for this one"
  exit 1
}
WANT_RUBY="$(cat .ruby-version)"
RUBY_VERSION_OUTPUT="$(ruby --version)"
echo "$RUBY_VERSION_OUTPUT"
grep -q "$WANT_RUBY" <<< "$RUBY_VERSION_OUTPUT" || {
  echo "expected Ruby $WANT_RUBY (from .ruby-version), got: $RUBY_VERSION_OUTPUT"
  exit 1
}

echo "--- :iphone: Choosing a simulator"
# A concrete destination, never `generic/platform=iOS Simulator`: a generic
# destination has no active arch, so ONLY_ACTIVE_ARCH cannot narrow ARCHS and the
# x86_64 slice is built too — which then fails to link against the arm64-only
# prebuilt llama/lfm archives. ARCHS=arm64 below states the same constraint for
# the build settings, so neither path depends on the other holding.
# A dedicated CI device, created once and reused. Two reasons it is not any
# available iPhone: tests must not run on a device a person is using, and a fresh
# device per run would lose the installed app's state between builds. The name is
# fixed so the same device is found on every run.
CI_SIMULATOR_NAME="${BUILDKITE_AURIS_SIMULATOR:-auris-ci}"
SIMULATOR_ID="$(xcrun simctl list devices --json | python3 -c '
import json, sys
wanted = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
for runtime, group in devices.items():
    if "SimRuntime.iOS" not in runtime:
        continue
    for device in group:
        if device["name"] == wanted:
            print(device["udid"])
            sys.exit(0)
sys.exit(1)
' "$CI_SIMULATOR_NAME" || true)"

if [ -z "$SIMULATOR_ID" ]; then
  # Pick the newest iOS runtime and an iPhone device type from it, so the CI
  # device matches the toolchain rather than whatever was created last by hand.
  # Newest available iOS runtime, and the newest standard iPhone it supports.
  # Version numbers are compared numerically: sorting the names as text puts
  # "iPhone 11" above "iPhone 17".
  read -r RUNTIME_ID DEVICE_TYPE_ID < <(xcrun simctl list runtimes devicetypes --json | python3 -c "
import json, re, sys
data = json.load(sys.stdin)
ios = [r for r in data['runtimes'] if r.get('platform') == 'iOS' and r.get('isAvailable')]
if not ios:
    sys.exit('no available iOS runtime; install it for the pinned Xcode')
def version_key(text):
    return tuple(int(part) for part in re.findall(r'[0-9]+', text))
ios.sort(key=lambda r: version_key(r['version']), reverse=True)
runtime = ios[0]
supported = {s['identifier'] for s in runtime.get('supportedDeviceTypes', [])}
iphones = [t for t in data['devicetypes']
           if t['name'].startswith('iPhone') and t['identifier'] in supported]
if not iphones:
    sys.exit('no iPhone device type supported by the newest iOS runtime')
def device_key(t):
    # Highest-numbered current iPhone, Pro included: that is the device class the
    # app is developed against. SE and Air sort below by their own names.
    return version_key(t['name'])
iphones.sort(key=device_key, reverse=True)
print(runtime['identifier'], iphones[0]['identifier'])
")
  echo "Creating CI simulator '$CI_SIMULATOR_NAME' on $RUNTIME_ID ($DEVICE_TYPE_ID)"
  SIMULATOR_ID="$(xcrun simctl create "$CI_SIMULATOR_NAME" "$DEVICE_TYPE_ID" "$RUNTIME_ID")"
fi
echo "Using simulator $CI_SIMULATOR_NAME ($SIMULATOR_ID)"
xcrun simctl bootstatus "$SIMULATOR_ID" -b

echo "--- :closed_lock_with_key: Generating the credentials stub"
# The app's credential build phase requires either shared secrets (which this
# repository does not have) or this stub. Without it the build fails at that
# phase, which reads as a code failure rather than a missing input.
make external_contributor

echo "--- :llama: Building the pinned llama.cpp archives"
./scripts/build-llama-ios.sh 2>&1 | tee "$LOG_DIR/llama.log"

echo "--- :swift: Resolving packages"
# Resolution is a separate step so a network or pin failure is reported as
# itself. The test invocation below disables automatic resolution: re-resolving
# on every invocation costs minutes and can change versions mid-run.
xcodebuild -resolvePackageDependencies \
  -project podcasts.xcodeproj \
  -scheme pocketcasts \
  -derivedDataPath "$DERIVED" \
  -clonedSourcePackagesDirPath "$DERIVED/SourcePackages" \
  2>&1 | tee "$LOG_DIR/resolve.log"

echo "--- :test_tube: Running the full test plan"
RESULT_BUNDLE="$LOG_DIR/auris-${BUILDKITE_BUILD_NUMBER:-local}-${BUILDKITE_JOB_ID:-job}.xcresult"
rm -rf "$RESULT_BUNDLE"

# `-testPlan UnitTests` names the plan explicitly. Marking a plan `default = YES`
# in the scheme is not enough on the command line: without this flag xcodebuild
# runs the scheme's Testables list, which holds only PocketCastsTests, and the
# plan's other targets never execute while the run still reports success.
#
# No `-only-testing:` — that flag overrides the plan's target list and is how a
# run ends up covering one group while reporting success.
#
# SKIP_LINT: the two SwiftLint build phases shell out to `make lint`, which needs
# the BuildTools package built; linting is not this job's subject.
# CODE_SIGNING_ALLOWED=NO: a simulator test build needs no signature, and signing
# would require credentials this machine does not hold.
set +e
xcodebuild test \
  -project podcasts.xcodeproj \
  -scheme pocketcasts \
  -testPlan UnitTests \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$DERIVED" \
  -clonedSourcePackagesDirPath "$DERIVED/SourcePackages" \
  -disableAutomaticPackageResolution \
  -resultBundlePath "$RESULT_BUNDLE" \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 120 \
  ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO \
  SKIP_LINT=1 \
  2>&1 | tee "$LOG_DIR/test.log"
TEST_STATUS=${PIPESTATUS[0]}
set -e

echo "--- :mag: Checking the coverage guard itself"
# The guard is only worth trusting if it can fail. These cases remove coverage
# and assert it notices, against the result bundle this run just produced.
python3 .buildkite/lib/test_check_test_coverage.py

echo "--- :mag: Checking that the whole plan ran"
# Runs even when tests failed: "which targets ran" is the question that tells a
# real failure apart from a run that never tested the failing area. Its own exit
# status is reported separately so a coverage gap is not hidden by a test failure
# and a test failure is not excused by coverage being complete.
set +e
python3 .buildkite/lib/check-test-coverage.py "$RESULT_BUNDLE"
COVERAGE_STATUS=$?
set -e

if [ -d "$RESULT_BUNDLE" ]; then
  # Zipped for upload: an .xcresult is a directory, and the artifact glob would
  # otherwise upload thousands of loose files.
  (cd "$LOG_DIR" && zip -qry "$(basename "$RESULT_BUNDLE").zip" "$(basename "$RESULT_BUNDLE")")
fi

echo "--- :result: Result"
echo "xcodebuild exit: $TEST_STATUS"
echo "coverage check exit: $COVERAGE_STATUS"
[ "$TEST_STATUS" -eq 0 ] || { echo "tests failed"; exit "$TEST_STATUS"; }
[ "$COVERAGE_STATUS" -eq 0 ] || { echo "the run did not cover the whole plan"; exit "$COVERAGE_STATUS"; }
echo "Build and full plan passed."
