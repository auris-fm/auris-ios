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
# The name alone is not enough: a device left over from an uninstalled runtime
# keeps its name and cannot boot, so matching on it would pick a device every run
# then fails on. Only a device on an available iOS runtime is usable.
SIMULATOR_ID="$(xcrun simctl list devices runtimes --json | python3 -c '
import json, re, sys
wanted = sys.argv[1]
data = json.load(sys.stdin)
available = {
    r["identifier"] for r in data["runtimes"]
    if r.get("platform") == "iOS" and r.get("isAvailable")
}
def version_key(text):
    return tuple(int(part) for part in re.findall(r"[0-9]+", text))
matches = []
for runtime, group in data["devices"].items():
    if runtime not in available:
        continue
    for device in group:
        if device["name"] == wanted and device.get("isAvailable", True):
            matches.append((version_key(runtime), device["udid"]))
if matches:
    # Newest runtime wins when the name exists on more than one.
    matches.sort(reverse=True)
    print(matches[0][1])
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
# The device is reused between runs, but it must not outlive the job: a booted
# simulator holds a device slot and CPU, and the next job on this machine would
# start with it already running. Shut down on every exit path, not only success.
shutdown_simulator() {
  xcrun simctl shutdown "$SIMULATOR_ID" 2>/dev/null || true
}

# Interface Builder compiles storyboards through helper processes that detach
# from the build's tree: `ibtoold` reparents to launchd and its `IBAgent-iOS`
# helpers are its children. On a shared Mac they cannot be found by name, and
# `ibtoold` ignores TMPDIR (it uses confstr's per-user temp directory, measured),
# so what identifies them is the tree while it is still intact. Every few seconds
# while the build runs, every Interface Builder process reachable from this script
# is recorded with its start time; the cleanup stops exactly that record, leaves
# anything never tied to this job alive, and names it in the report.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/ib-processes.sh"
IB_RECORD="$LOG_DIR/ib-processes.tsv"
: > "$IB_RECORD"
IB_CLEANUP_STATUS=0

# On any exit path: stop the recorded Interface Builder processes (the simulator
# first, since a wedged helper is released by the runtime going away), then shut
# the simulator down. Processes never tied to this job are named, never killed.
on_exit() {
  ib_cleanup "$IB_RECORD" "$SIMULATOR_ID" 10 >/dev/null 2>&1 || true
  ib_unrecorded "$IB_RECORD" | sed 's/^/untied Interface Builder process left running: /' \
    >> "$LOG_DIR/ib-leftovers.txt" 2>/dev/null || true
  shutdown_simulator
}
# The trap install lives in a function so the cancel self-test can run the
# pipeline's own trap line and handler, not a re-typed copy that could drift.
install_exit_trap() { trap on_exit EXIT; }
install_exit_trap

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

echo "--- :closed_lock_with_key: Generating the credentials stub"
# The app's credential build phase requires either shared secrets (which this
# repository does not have) or this stub. Without it the build fails at that
# phase, which reads as a code failure rather than a missing input.
make external_contributor

# Build BEFORE erasing and booting the simulator. Storyboards are compiled by
# helpers launched inside the simulator runtime, and a runtime that was just
# erased may not be ready to launch them: a run hung for nine minutes with every
# Interface Builder helper wedged in dyld's cache mapping before its own main()
# ran, invisible to any log reader and unkillable by any signal — the helpers
# only cleared when the simulator was shut down. Building against the runtime as
# it stands keeps Interface Builder off a runtime that cannot run its helpers
# yet; the erase and a bounded readiness wait follow the build, before testing.
# The runtime must be able to launch processes before Interface Builder asks it
# to. Checked before the build as well as after the erase: a device left in a bad
# state by an earlier run would otherwise hang the build's storyboard compiles.
# Each bootstatus call is itself bounded — the call can block without limit, and
# one stuck call would stop the retry loop from ever repeating.
wait_simulator_ready() {
  local tries="$1" per_call="$2" i pid waited status
  # errexit off: a killed or failing bootstatus returns non-zero from `wait`,
  # which under `set -e` would end the script instead of retrying.
  set +e
  for i in $(seq 1 "$tries"); do
    xcrun simctl bootstatus "$SIMULATOR_ID" -b >/dev/null 2>&1 &
    pid=$!
    waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$per_call" ]; do
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
    else
      wait "$pid" 2>/dev/null
      status=$?
      # A zero exit alone has lied: bootstatus reported success while the
      # device stayed Shutdown. Success requires the device to actually be
      # Booted.
      if [ "$status" -eq 0 ]; then
        if xcrun simctl list devices 2>/dev/null | grep -q "$SIMULATOR_ID.*Booted"; then
          set -e
          return 0
        fi
        status=1
      fi
    fi
    sleep 5
  done
  set -e
  return 1
}

echo "--- :iphone: Checking the simulator runtime is ready before building"
if ! wait_simulator_ready 12 30; then
  echo "simulator runtime did not become ready within 6 minutes before the build"
  exit 1
fi

echo "--- :hammer: Building for testing"
# The build is watched too. A run has hung in Interface Builder for nine minutes
# with the log frozen and every process idle — the test watchdog below never
# started, because testing never started. While the build runs, a watchdog subshell
# watches the log for growth and records which Interface Builder processes appear
# in this job's tree; the same no-progress rule as the test watchdog applies, with
# a window well above any single slow compile, and a whole-build cap because the
# per-test allowances do not cover this phase at all.
BUILD_PROGRESS_DEADLINE="${BUILDKITE_AURIS_BUILD_PROGRESS_DEADLINE:-300}"
BUILD_TOTAL_DEADLINE="${BUILDKITE_AURIS_BUILD_TOTAL_DEADLINE:-2700}"

# `|| BUILD_STATUS=$?` rather than reading $? on the next line: errexit is in force
# here, so a failing build would end the script at this line and none of the report
# below would print. The failure path is the one that most needs to say something.
# The whole build step is a function so a self-test can run exactly this code
# with a stub xcodebuild earlier in PATH — a test of the extracted watchdog body
# alone cannot catch how the step starts it or how errexit treats its waits.
run_build_step() {
BUILD_STATUS=0
# A verdict from an earlier attempt must never be mistaken for this one's.
rm -f "$LOG_DIR/build-watchdog-verdict"
xcodebuild build-for-testing \
  -project podcasts.xcodeproj \
  -scheme pocketcasts \
  -testPlan UnitTests \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$DERIVED" \
  -clonedSourcePackagesDirPath "$DERIVED/SourcePackages" \
  -disableAutomaticPackageResolution \
  ARCHS=arm64 \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="-" \
  SKIP_LINT=1 \
  > "$LOG_DIR/build.log" 2>&1 &
BUILD_PID=$!

# Watch the build: kill it on no progress or total time, record Interface Builder
# processes while the tree is intact either way. The watchdog is a subshell so its
# verdict can be waited on without confusing it with xcodebuild's exit status.
(
  # errexit and pipefail off: a process vanishing between the listing and its
  # status read must shorten the record, not kill the watchdog — a dead
  # watchdog means the build runs unwatched.
  # Every loop statement below is written to be safe without errexit.
  set +e
  waited=0
  last_size=0
  stalled=0
  while kill -0 "$BUILD_PID" 2>/dev/null; do
    # Interface Builder daemons detach from the tree as soon as they are spawned,
    # so the record must be taken while the build is running, repeatedly.
    ib_record_snapshot "$IB_RECORD" "$$"
    size=$(wc -c < "$LOG_DIR/build.log" 2>/dev/null || echo 0)
    if [ "$size" -gt "$last_size" ]; then
      last_size=$size
      stalled=0
    else
      stalled=$((stalled + 10))
      if [ "$stalled" -ge "$BUILD_PROGRESS_DEADLINE" ]; then
        echo "no build output for ${BUILD_PROGRESS_DEADLINE}s: the build stopped making progress." >&2
        echo "Last build line: $(tail -1 "$LOG_DIR/build.log" 2>/dev/null)" >&2
        # The verdict is written before the kill: the parent can then tell the
        # watchdog's decision apart from its own cleanup kill, even when the
        # parent reaches the watchdog between the kill and the exit and the
        # status comes back an ambiguous 143.
        printf '%s\n' 4 > "$LOG_DIR/build-watchdog-verdict" 2>/dev/null
        kill "$BUILD_PID" 2>/dev/null
        exit 4
      fi
    fi
    if [ "$waited" -ge "$BUILD_TOTAL_DEADLINE" ]; then
      echo "building exceeded ${BUILD_TOTAL_DEADLINE}s in total." >&2
      printf '%s\n' 5 > "$LOG_DIR/build-watchdog-verdict" 2>/dev/null
      kill "$BUILD_PID" 2>/dev/null
      exit 5
    fi
    sleep 10
    waited=$((waited + 10))
  done
) &
BUILD_WATCHDOG_PID=$!
# errexit is off around the waits and kills: `wait` on a killed process returns
# 143 and `kill`/`pkill` return non-zero when the target has already exited, and
# under `set -e` each of those would end the script before the report — the very
# report that says what happened. Statuses are captured, not allowed to exit.
set +e
wait "$BUILD_PID"
BUILD_STATUS=$?
# A recorded verdict outranks every exit status: the watchdog writes it before
# killing the build, so it exists exactly when the watchdog made the decision,
# even if the parent's cleanup kill of the watchdog lands between the kill and
# the exit and the status comes back an ambiguous 143.
WATCHDOG_VERDICT=""
# Default: no kill of ours. The verdict branch never reaches the kill.
WE_KILLED_THE_WATCHDOG=0
[ -f "$LOG_DIR/build-watchdog-verdict" ] \
  && WATCHDOG_VERDICT="$(cat "$LOG_DIR/build-watchdog-verdict" 2>/dev/null || true)"
case "$WATCHDOG_VERDICT" in
  4|5) BUILD_WATCHDOG_STATUS="$WATCHDOG_VERDICT" ;;
  *)
    # 143 only means "our kill, not a verdict" if we did the killing: the
    # watchdog must still be alive right now. A watchdog that died on its own
    # leaves the build unwatched and reports nothing — that silence is the
    # failure, so a non-verdict status with no kill of ours is fatal below.
    if kill -0 "$BUILD_WATCHDOG_PID" 2>/dev/null; then
      WE_KILLED_THE_WATCHDOG=1
      pkill -P "$BUILD_WATCHDOG_PID" 2>/dev/null
      kill "$BUILD_WATCHDOG_PID" 2>/dev/null
      wait "$BUILD_WATCHDOG_PID" 2>/dev/null
    else
      WE_KILLED_THE_WATCHDOG=0
      wait "$BUILD_WATCHDOG_PID" 2>/dev/null
    fi
    BUILD_WATCHDOG_STATUS=$?
    ;;
esac
# errexit stays OFF through the end of this function: a non-zero `return` while
# errexit is on ends the whole script with that status instead of coming back to
# the call site, which re-enables errexit after capturing the status.
# A watchdog we killed after the build finished on its own reports 143; that is
# our kill, not a verdict. Only its own exits (4, 5) count as verdicts, and only
# when the death was ours: a watchdog that died on its own never normalises.
if [ "$WE_KILLED_THE_WATCHDOG" -eq 1 ]; then
  [ "$BUILD_WATCHDOG_STATUS" = 143 ] && BUILD_WATCHDOG_STATUS=0
  case "$BUILD_WATCHDOG_STATUS" in
    0|4|5) ;;
    *) BUILD_WATCHDOG_STATUS=0 ;;
  esac
fi
# The live log gets the tail, not the whole build: this agent streams its log in
# chunks over a link that drops them, and a run has been lost to upload retries
# alone. The file keeps everything, so a failure's detail is never only in the
# stream. On success the tail is the summary; on failure it is where to look.
tail -n 60 "$LOG_DIR/build.log"
if [ "$WE_KILLED_THE_WATCHDOG" -eq 0 ]; then
  case "$BUILD_WATCHDOG_STATUS" in
    0|4|5) ;;
    *)
      echo "--- :warning: The build watchdog died with status $BUILD_WATCHDOG_STATUS"
      echo "The build ran with no watchdog from that point on. Failing the run:"
      echo "a watchdog that dies quietly is how a hang goes unreported."
      return 1
      ;;
  esac
fi
case "$BUILD_WATCHDOG_STATUS" in
  0) ;;
  4)
    echo "--- :warning: Build stopped making progress"
    echo "No build output for ${BUILD_PROGRESS_DEADLINE}s. Interface Builder helpers from"
    echo "this build are stopped; any process it started that could not be tied to this"
    echo "job is left running and named below."
    ;;
  5)
    echo "--- :warning: Building took too long overall"
    echo "Building was stopped after ${BUILD_TOTAL_DEADLINE}s."
    ;;
  *)
    echo "--- :warning: Build watchdog ended with status $BUILD_WATCHDOG_STATUS"
    ;;
esac
echo "xcodebuild exited $BUILD_STATUS"
# The watchdog's verdict comes first: a build it killed has no success marker,
# and reporting that as "building failed" would hide the reason it was stopped.
[ "$BUILD_WATCHDOG_STATUS" -eq 0 ] || return "$BUILD_WATCHDOG_STATUS"
grep -q "BUILD SUCCEEDED\|BUILD FOR TESTING SUCCEEDED" "$LOG_DIR/build.log" || {
  echo "building for testing failed; see $LOG_DIR/build.log"
  return 1
}
return 0
}

# errexit off around the call: the function returns the watchdog's verdict or a
# build failure as its status, and that status is reported by the gates below,
# not allowed to end the script silently.
set +e
run_build_step
BUILD_STEP_STATUS=$?
set -e
[ "$BUILD_STEP_STATUS" -eq 0 ] || exit "$BUILD_STEP_STATUS"

echo "--- :iphone: Erasing the simulator for a clean test container"
# State left by an earlier run — a database, a keychain item, a file in the app's
# documents — is one way a test passes or fails depending on what ran before it,
# and the runner has hung after connecting on several runs. Erasing keeps the
# device (same name and identifier, so nothing else has to change) while removing
# everything the last run left behind. This happens after the build (see the
# comment above the build step), but before anything runs on the device.
echo "Erasing $CI_SIMULATOR_NAME so no state carries over from the previous run"
xcrun simctl shutdown "$SIMULATOR_ID" 2>/dev/null || true
xcrun simctl erase "$SIMULATOR_ID"

# Bootstatus alone does not prove helpers can launch: a previous run hung with
# every Interface Builder helper wedged in the runtime's dyld cache mapping on a
# freshly erased device. This wait is bounded so a runtime that never becomes
# ready fails the job with a reason instead of hanging it.
if ! wait_simulator_ready 60 30; then
  echo "simulator did not become bootable within 10 minutes of erasing"
  exit 1
fi

# An erased device has no privacy permissions, so the first microphone or speech
# access waits on a prompt nobody answers. Measured on this device: one speech
# test took 54.8s without the grant and 2.6s with it. That wait sits just under
# the per-test execution allowance, and in a full run it crosses it — the test is
# then killed and the runner relaunched, which is what a run dying partway through
# looks like from outside. Granting them makes the run measure the code.
# Measured on this machine: a grant issued immediately after a fresh erase and
# boot fails with EPERM — the privacy service is not ready yet — and the same
# grant succeeds seconds later. So each grant is retried on a bound instead of
# tripping errexit on the first try.
grant_test_permissions() {
  local host_bundle="$1" service tries="$2" per_try="$3" i rc
  for service in microphone speech-recognition; do
    rc=1
    for i in $(seq 1 "$tries"); do
      if xcrun simctl privacy "$SIMULATOR_ID" grant "$service" "$host_bundle"; then
        echo "$service granted on try $i"
        rc=0
        break
      fi
      echo "$service grant failed (try $i/$tries), retrying in ${per_try}s"
      sleep "$per_try"
    done
    [ "$rc" -eq 0 ] || { echo "$service was not granted within $((tries * per_try))s"; return 1; }
  done
  return 0
}

echo "--- :lock: Granting the permissions the tests need"
TEST_HOST="$DERIVED/Build/Products/Debug-iphonesimulator/podcasts.app"
HOST_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TEST_HOST/Info.plist")"
echo "Test host: $HOST_BUNDLE_ID"
if ! grant_test_permissions "$HOST_BUNDLE_ID" 12 10; then
  echo "simulator privacy service never accepted the grants"
  exit 1
fi

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
# Parallel testing is off explicitly rather than left at its default: clones of
# the simulator would each run part of the plan, and a runner that dies in one
# clone leaves the others reporting success.
#
# The build's output goes to a file and only its tail reaches the live log. This
# agent uploads that log chunk by chunk over a link that drops them — a run was
# lost to 107 failed chunks and the retries that followed. Filtering xcodebuild's
# output instead would shorten the file as well, and the file is what a failure is
# read from afterwards.
#
# SKIP_LINT: the two SwiftLint build phases shell out to `make lint`, which needs
# the BuildTools package built; linting is not this job's subject.
# Ad-hoc signing (`CODE_SIGN_IDENTITY=-`) needs no account or certificate, and the
# signature is what carries entitlements: an unsigned build's keychain and
# app-group calls fail with -34018, which reads as a product failure.
# A runner that never connects leaves xcodebuild sitting indefinitely: the build
# is finished, the simulator is booted, and nothing reports a problem. Watch the
# log for the first sign of testing and stop the run if it never appears, so the
# step says what happened instead of consuming the job's whole timeout.
TEST_START_DEADLINE="${BUILDKITE_AURIS_TEST_START_DEADLINE:-900}"
# A test that reaches its execution time allowance is killed and the runner is
# relaunched. One hanging test can therefore cost many minutes: a run has been
# seen making fourteen launches, most of which executed one test before dying
# again. Watching only for the first sign
# of testing leaves that loop unwatched, so progress is watched too — and the
# whole testing phase is bounded, because the per-test allowance is per launch
# and does not limit how many launches there are.
TEST_PROGRESS_DEADLINE="${BUILDKITE_AURIS_TEST_PROGRESS_DEADLINE:-300}"
TEST_TOTAL_DEADLINE="${BUILDKITE_AURIS_TEST_TOTAL_DEADLINE:-3600}"

set +e
xcodebuild test-without-building \
  -project podcasts.xcodeproj \
  -scheme pocketcasts \
  -testPlan UnitTests \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$DERIVED" \
  -clonedSourcePackagesDirPath "$DERIVED/SourcePackages" \
  -disableAutomaticPackageResolution \
  -resultBundlePath "$RESULT_BUNDLE" \
  -parallel-testing-enabled NO \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 120 \
  ARCHS=arm64 \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="-" \
  SKIP_LINT=1 \
  > "$LOG_DIR/test.log" 2>&1 &
XCODEBUILD_PID=$!

(
  # errexit and pipefail off: a process vanishing between the listing and its
  # status read must shorten the record, not kill the watchdog — a dead
  # watchdog means the tests run unwatched.
  # Every loop statement below is written to be safe without errexit.
  set +e
  waited=0
  started=0
  # Progress is measured by the log growing, not by a particular line: XCTest and
  # Swift Testing write different formats, and a relaunch writes neither for as
  # long as it is failing to connect.
  last_size=0
  stalled=0
  while kill -0 "$XCODEBUILD_PID" 2>/dev/null; do
    if [ "$started" -eq 0 ] && grep -q "Testing started\|Test Case '-\[\|◇ Test " "$LOG_DIR/test.log" 2>/dev/null; then
      started=1
    fi
    if [ "$started" -eq 0 ] && [ "$waited" -ge "$TEST_START_DEADLINE" ]; then
      echo "runner never connected: no testing began within ${TEST_START_DEADLINE}s of xcodebuild starting" >&2
      kill "$XCODEBUILD_PID" 2>/dev/null
      exit 1
    fi
    if [ "$waited" -ge "$TEST_TOTAL_DEADLINE" ]; then
      echo "testing exceeded ${TEST_TOTAL_DEADLINE}s in total." >&2
      echo "Last test in flight: $(grep -E "Test Case .* started\.$|◇ Test .* started\.$" "$LOG_DIR/test.log" 2>/dev/null | tail -1)" >&2
      echo "Last test to report a result: $(grep -E "Test Case .*(passed|failed) \(|✔ Test |✘ Test " "$LOG_DIR/test.log" 2>/dev/null | tail -1)" >&2
      kill "$XCODEBUILD_PID" 2>/dev/null
      exit 2
    fi
    if [ "$started" -eq 1 ]; then
      size=$(wc -c < "$LOG_DIR/test.log" 2>/dev/null || echo 0)
      if [ "$size" -gt "$last_size" ]; then
        last_size=$size
        stalled=0
      else
        stalled=$((stalled + 10))
        if [ "$stalled" -ge "$TEST_PROGRESS_DEADLINE" ]; then
          echo "no test output for ${TEST_PROGRESS_DEADLINE}s: the runner stopped making progress." >&2
          # The last test to start without finishing is the one it stopped on.
          echo "Last test in flight: $(grep -E "Test Case .* started\.$|◇ Test .* started\.$" "$LOG_DIR/test.log" 2>/dev/null | tail -1)" >&2
      echo "Last test to report a result: $(grep -E "Test Case .*(passed|failed) \(|✔ Test |✘ Test " "$LOG_DIR/test.log" 2>/dev/null | tail -1)" >&2
          kill "$XCODEBUILD_PID" 2>/dev/null
          exit 3
        fi
      fi
    fi
    sleep 10
    waited=$((waited + 10))
  done
) &
WATCHDOG_PID=$!

# The live log gets test results, not the whole run. Two thousand tests each print
# a start line and a result line, and this agent streams its log in chunks over a
# link that drops them; a run has been lost to upload retries alone. Filtering here
# rather than at xcodebuild keeps every line in test.log, which is what the watchdog
# and the failure reader read, and what a failure is diagnosed from afterwards.
# In a subshell so $! is the pid of something that can be killed as a whole. After
# a pipeline, $! is the last command in it — grep — and killing that leaves tail -f
# running against a file that will never grow again, so it never gets a SIGPIPE.
(
  tail -f "$LOG_DIR/test.log" \
    | grep --line-buffered -E "^--- |Test Suite .* (started|passed|failed)|Executed [0-9]+ test|error:|exceeded execution time allowance|Restarting after unexpected exit|Testing started|TEST (SUCCEEDED|FAILED)|◇ Suite|✘ Test |✔ Suite"
) &
TAIL_PID=$!

wait "$XCODEBUILD_PID"
TEST_STATUS=$?
# The subshell and everything it started: killing only the subshell would leave
# tail and grep behind.
pkill -P "$TAIL_PID" 2>/dev/null
kill "$TAIL_PID" 2>/dev/null
# The watchdog exits on its own once xcodebuild is gone. Waiting for it here
# rather than killing it is what makes its verdict readable: killing it first
# would report the kill as the watchdog's status and hide a real timeout.
wait "$WATCHDOG_PID" 2>/dev/null
WATCHDOG_STATUS=$?
set -e

case "$WATCHDOG_STATUS" in
  0) ;;
  1)
    echo "--- :warning: Runner never connected"
    echo "Testing did not start within ${TEST_START_DEADLINE}s."
    echo "This is a test-runner failure, not a test failure: no tests ran to completion."
    ;;
  2)
    echo "--- :warning: Testing took too long overall"
    echo "Testing was stopped after ${TEST_TOTAL_DEADLINE}s. A test killed at its"
    echo "execution time allowance relaunches the runner, and the allowance applies"
    echo "per launch, so repeated relaunches are not bounded by it."
    ;;
  3)
    echo "--- :warning: Runner stopped making progress"
    echo "No test output for ${TEST_PROGRESS_DEADLINE}s after testing had begun."
    echo "A relaunch that cannot reconnect looks like this: the run is alive and"
    echo "nothing is running."
    ;;
  *)
    echo "--- :warning: Watchdog ended with status $WATCHDOG_STATUS"
    ;;
esac

echo "--- :mag: Checking the build watchdog itself"
# A build that stops logging must be killed with a verdict naming why; a healthy
# one must be left alone. Uses the watchdog body from this script, like the test
# watchdog self-test below.
set +e
bash .buildkite/lib/test-build-watchdog.sh
BUILD_WATCHDOG_SELFTEST_STATUS=$?
set -e

echo "--- :mag: Checking that a cancel still cleans up"
# Buildkite's job-wide timeout cancels by signalling the job. The exit cleanup
# must run on that path too, not only on a normal exit.
set +e
bash .buildkite/lib/test-cancel-cleanup.sh
CANCEL_SELFTEST_STATUS=$?
set -e

echo "--- :mag: Checking the Interface Builder cleanup itself"
# A recorded process must be stopped, an unrecorded same-named process must
# survive, a reused pid must not be killed, and survivors must fail the run.
set +e
bash .buildkite/lib/test-ib-processes.sh
IB_SELFTEST_STATUS=$?
set -e

echo "--- :mag: Checking the grants step itself"
# A grant issued right after an erase fails with EPERM until the privacy
# service is ready, so the step retries on a bound. These cases run the real
# grant function against a stub xcrun: a service that recovers must be granted,
# one that never recovers must give up with a reason.
set +e
bash .buildkite/lib/test-grants.sh
GRANTS_SELFTEST_STATUS=$?
set -e

echo "--- :mag: Checking the watchdog itself"
# Each way the watchdog can stop a run is proved against a stub, using the
# watchdog body from this script rather than a copy of it.
set +e
bash .buildkite/lib/test-watchdog.sh
WATCHDOG_SELFTEST_STATUS=$?
set -e

echo "--- :mag: Checking what reaches the live log"
# The live log is filtered so a dropped chunk cannot cost a whole run. That filter
# is only safe if it keeps every line a verdict or a diagnosis is read from, which
# these cases assert against the expression this script actually uses.
set +e
bash .buildkite/lib/test-live-log-filter.sh
FILTER_SELFTEST_STATUS=$?
set -e

echo "--- :mag: Checking the coverage guard itself"
# The guard is only worth trusting if it can fail. These cases remove coverage
# and assert it notices, against the result bundle this run just produced.
# Its status is recorded rather than allowed to end the step: a broken self-test
# would otherwise hide the coverage verdict and the artifacts, which are what say
# what the run actually did.
set +e
python3 .buildkite/lib/test_check_test_coverage.py "$RESULT_BUNDLE" "$LOG_DIR/test.log"
SELFTEST_STATUS=$?
set -e

echo "--- :mag: Checking that the whole plan ran"
# Runs even when tests failed: "which targets ran" is the question that tells a
# real failure apart from a run that never tested the failing area. Its own exit
# status is reported separately so a coverage gap is not hidden by a test failure
# and a test failure is not excused by coverage being complete.
set +e
python3 .buildkite/lib/check-test-coverage.py "$RESULT_BUNDLE" --log "$LOG_DIR/test.log"
COVERAGE_STATUS=$?
set -e

if [ -d "$RESULT_BUNDLE" ]; then
  # Zipped for upload: an .xcresult is a directory, and the artifact glob would
  # otherwise upload thousands of loose files.
  (cd "$LOG_DIR" && zip -qry "$(basename "$RESULT_BUNDLE").zip" "$(basename "$RESULT_BUNDLE")")
fi

# The live log is streamed over a link that has dropped chunks, so a failure's
# detail can be missing from what Buildkite shows. These files under artifacts are
# then the only complete record, which is why they are listed here as well as in
# the pipeline's artifact_paths: this says what should be there, and a missing one
# is visible in the step's own output rather than noticed later by whoever needs it.
echo "--- :package: Artifacts"
for f in "$LOG_DIR"/*.log "$LOG_DIR"/*.xcresult.zip; do
  [ -e "$f" ] && echo "  $(basename "$f")  $(wc -c < "$f" | tr -d ' ') bytes"
done

echo "--- :package: Shutting the simulator down"
# Run here as well as on exit so the step reports it rather than only doing it.
shutdown_simulator
echo "Simulator $CI_SIMULATOR_NAME shut down"

echo "--- :broom: Stopping this build's Interface Builder processes"
# The record was taken while the build ran. Only recorded processes are stopped,
# and only if their start time still matches: a reused pid is a different process.
# The simulator is shut down inside the cleanup first, since a helper wedged in
# an uninterruptible wait is released by the runtime going away and would
# otherwise be reported as a survivor that was about to clear on its own.
if ib_cleanup "$IB_RECORD" "$SIMULATOR_ID" 10; then
  echo "all recorded Interface Builder processes stopped"
else
  echo "some recorded Interface Builder processes survived; see the list above"
  IB_CLEANUP_STATUS=1
fi
# Processes never tied to this job are named, never killed.
LEFTOVERS="$(ib_unrecorded "$IB_RECORD")"
if [ -n "$LEFTOVERS" ]; then
  echo "Interface Builder processes not tied to this job, left running:"
  echo "$LEFTOVERS" | sed 's/^/  /'
fi

echo "--- :result: Result"
echo "xcodebuild exit: $TEST_STATUS"
echo "coverage check exit: $COVERAGE_STATUS"
echo "guard self-test exit: $SELFTEST_STATUS"
echo "watchdog self-test exit: $WATCHDOG_SELFTEST_STATUS"
echo "build-watchdog self-test exit: $BUILD_WATCHDOG_SELFTEST_STATUS"
echo "Interface Builder cleanup self-test exit: $IB_SELFTEST_STATUS"
echo "cancel-cleanup self-test exit: $CANCEL_SELFTEST_STATUS"
echo "grants self-test exit: $GRANTS_SELFTEST_STATUS"
echo "live-log filter self-test exit: $FILTER_SELFTEST_STATUS"
[ "$TEST_STATUS" -eq 0 ] || { echo "tests failed"; exit "$TEST_STATUS"; }
[ "$COVERAGE_STATUS" -eq 0 ] || { echo "the run did not cover the whole plan"; exit "$COVERAGE_STATUS"; }
[ "$SELFTEST_STATUS" -eq 0 ] || { echo "the coverage guard did not prove it can fail"; exit "$SELFTEST_STATUS"; }
[ "$WATCHDOG_SELFTEST_STATUS" -eq 0 ] || { echo "the watchdog did not prove it can stop a run"; exit "$WATCHDOG_SELFTEST_STATUS"; }
[ "$BUILD_WATCHDOG_SELFTEST_STATUS" -eq 0 ] || { echo "the build watchdog did not prove it can stop a build"; exit "$BUILD_WATCHDOG_SELFTEST_STATUS"; }
[ "$IB_SELFTEST_STATUS" -eq 0 ] || { echo "the Interface Builder cleanup did not prove it kills only what it recorded"; exit "$IB_SELFTEST_STATUS"; }
[ "$CANCEL_SELFTEST_STATUS" -eq 0 ] || { echo "a cancelled job would skip the exit cleanup"; exit "$CANCEL_SELFTEST_STATUS"; }
[ "$GRANTS_SELFTEST_STATUS" -eq 0 ] || { echo "the grants step did not prove it retries a not-ready privacy service"; exit "$GRANTS_SELFTEST_STATUS"; }
[ "$FILTER_SELFTEST_STATUS" -eq 0 ] || { echo "the live log would lose a failure's detail"; exit "$FILTER_SELFTEST_STATUS"; }
[ "$IB_CLEANUP_STATUS" -eq 0 ] || { echo "this build's Interface Builder processes could not all be stopped"; exit "$IB_CLEANUP_STATUS"; }
echo "Build and full plan passed."
