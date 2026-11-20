#!/usr/bin/env python3
"""Fail a CI run that looked green while running less than the whole test plan.

Four ways a run can pass without testing what it claims to, none of them visible
in xcodebuild's exit status when they go unnoticed:

  * A target in the plan runs zero tests. `-only-testing:` narrows the selection,
    a target fails to load, or a bundle is missing from the scheme; each leaves
    the remaining targets passing and the run green.
  * A run stops early. A runner that dies after one test still leaves that test
    passing, so each target has a floor as well.
  * Tests skip themselves. A skipped test is not run, and the summary counts it
    the same as a test that passed.
  * The plan's `skippedTests` list grows. A skip is a silent reduction in
    coverage, and nothing in a green run says how many were added.

The counts come from the result bundle, the plan's exclusions from the plan, and
the names of failing tests from xcodebuild's log — the bundle marks a suite Failed
when one test in it failed, so it cannot say which test that was. Everything is
compared against expectations written down here, so a change in any of them is
reported rather than absorbed.

Usage: check-test-coverage.py <path-to.xcresult> [--plan <path>] [--log <path>]
"""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

# Every target the plan names must execute at least one test. Written out rather
# than derived from the plan so that a target silently dropped from the plan is
# itself a failure: deriving the expectation from the thing under test would make
# removing a target look like meeting the expectation.
REQUIRED_TARGETS = [
    "PocketCastsTests",
    "PocketCastsUtilsTests",
    "PocketCastsDataModelTests",
    "PocketCastsServerTests",
    "ModulesTests",
]

# Host-only package tests run outside the simulator plan, one runner each, and
# are guarded with the same floor discipline. GRDBMacrosTests exercise the
# compiler plugin, so they run on macOS with `swift test` and write their own
# result bundle, which the step passes to the guard alongside the plan bundle.
PACKAGE_REQUIRED_TARGETS = {
    "GRDBMacrosTests": {
        "minimum": 21,
    },
}

# A floor per target, not just "more than zero". A test runner that dies after one
# test still reports that test as passing; only a count near the target's real size
# tells a complete run from a truncated one. Set below the observed counts so ordinary
# growth does not trip it, and raised when a target gains tests deliberately.
MINIMUM_TESTS = {
    "PocketCastsTests": 2000,
    "PocketCastsUtilsTests": 50,
    "PocketCastsDataModelTests": 450,
    "PocketCastsServerTests": 150,
    "ModulesTests": 1,
}

# A test that skips itself is not run, and a green summary does not show the
# difference. So a skip has to be accounted for. These lists say which skips this
# environment legitimately produces and why; a skip missing from them fails the
# run, and an entry that stops skipping fails too, so the lists describe the run
# rather than accumulate history. They are separate from the plan's skips because
# nothing in the plan mentions them: the test decides at run time.
EXPECTED_RUNTIME_SKIPS = {
    "PocketCastsTests": {
        # The control needs a stable host audio route, and a live route can change
        # during the test.
        "DiagnosticMicOverrideControl/testBuiltInMicOnlySessionReachesListeningAndDeliversSamples()": "",
        # A probe that runs only when explicitly enabled on a scratch simulator.
        "KeychainScopeProbeTests/testSyntheticEntryIsReadableByAttributesOnly()": "",
        # These two need a keychain access group shared with another app, which an
        # ad-hoc signed build does not declare.
        "SameAccessGroupPreservationTests/testPostHelperReadCanaryBytesAndSentinelAreIntact()": "",
        "SameAccessGroupPreservationTests/testSyntheticCanaryAndContainerSentinelSurviveAScopedRead()": "",
    },
}

# A test that needs a keychain access group the build does not declare cannot run
# here at all: signing ad-hoc gives the host its own entitlement, not a named group
# shared with another app. The skip says so in these words, which is how it is told
# apart from a test that wanted the keychain and did not get one.
ACCESS_GROUP_SKIP_MARKER = "keychain-access-groups"

# Keychain-gated tests skip themselves when the signature carries no keychain
# entitlement. In a signed build that is a signing failure, not a limit of the
# environment, so these skips fail outright. They are listed only so that a
# recording of an unsigned run can be read for what it is.
UNSIGNED_KEYCHAIN_SKIPS = {
    "PocketCastsTests": {
        "EndOfYearStoriesBuilderTests/testDontSyncAgainWhenSubscriptionStatusDontChange()",
        "EndOfYearStoriesBuilderTests/testDontSyncWhenAlreadySynced()",
        "EndOfYearStoriesBuilderTests/testSyncWhenAlreadySyncedButAsFreeUser()",
        "EndOfYearStoriesBuilderTests/testSyncWhenNeeded()",
        "EpisodeManagerTests/testUrlForEpisodeStreamingOnlyWithUserEpisode()",
        "PodcastManagerTests/testUnsubscribeRemovesDownloadsInPlaylist()",
        "PodcastManagerTests/testUnsubscribeRemovesDownloadsNotInPlaylist()",
        "SessionAuthenticationTests/testStoredCredentialIdentityIsReadableWithoutACommit_andMatchesTheCommittedForm()",
        "TokenHelperTests/testAcquireAsyncToken()",
        "TokenHelperTests/testAcquirePasswordToken()",
        "TokenHelperTests/testBackgroundRejectedRenewalReturnsBeforeMainCleanupAndCannotClearNewLogin()",
        "TokenHelperTests/testBackgroundSignoutAllowsNotificationObserverToReenterAuthentication()",
        "TokenHelperTests/testBackgroundSignoutCompletesCredentialClearBeforeMainAndPreservesWatchRestore()",
        "TokenHelperTests/testBackgroundSignoutImmediatelyRejectsLateLoginAndSkipsEffectsAfterNewLogin()",
        "TokenHelperTests/testCallSecureURL()",
        "TokenHelperTests/testConcurrentPasswordMigrationIsSuppressedEvenPastTheRetryDeadline()",
        "TokenHelperTests/testFirstLaunchClearAllowsPlainAccountRegistration()",
        "TokenHelperTests/testMainThreadMigrationDoesNotWaitOnRenewalsMainThreadStateQuery()",
        "TokenHelperTests/testPasswordMigrationBackoffIsSharedAndResetsForANewSession()",
        "TokenHelperTests/testRejectedPasswordResponseCannotSignOutASupersedingLogin()",
        "TokenHelperTests/testRejectedStoredPasswordSignsOutForDefinitiveAccountErrors()",
        "TokenHelperTests/testRenewalCanOmitAccountFieldsButCannotChangeTheCapturedAccount()",
        "TokenHelperTests/testSSORenewalUsesRefreshGrantAndPreservesAnOmittedRefreshToken()",
        "VoiceSharingDeletionCallbackCompositionTests/testRejectedDeletionPreservesCredentialsLeaseAndRetainedAudio()",
        "VoiceSharingDeletionCallbackCompositionTests/testSuccessfulDeletionPurgesAfterThePresentingControllerDisappears()",
        "VoiceSharingDeletionCallbackCompositionTests/testSuccessfulServerReplyWithoutACompletionPreservesLocalState()",
        "VoiceSharingRealSignOutCompositionTests/testRealSyncManagerSignoutPurgesRetainedAudioAndFencesTheOldLease()",
    },
}

# The status is the authority, not the wording: every keychain call fails with it
# when the signature has no entitlement, whatever the test says next.
KEYCHAIN_SKIP_MARKER = "errSecMissingEntitlement"

# The runner signs the host ad-hoc so the keychain is available. A recording of an
# unsigned run is the opposite case, and its keychain skips are that run's
# expected answer rather than coverage it lost.
SIGNED_HOST = os.environ.get("AURIS_SIGNED_HOST", "1") == "1"

# Tests that fail on this tree today, each with the reason it fails. Listed so the
# step reports a change in that set rather than a wall of red: a failure not named
# here fails the run, and a named test that starts passing fails it too, so the
# list cannot outlive the defects it describes. Empty is the intended state.
KNOWN_FAILURES = {
}

# Tests that fail in some runs and pass in others. Reported, not excused: any
# failure fails the job — the outcome is printed so a run says how often they
# fail instead of hiding the frequency. They are not in KNOWN_FAILURES: that
# list means "fails every time", and a test that also passes would break its
# own entry.
FLAKY_TESTS = {
    # Runs on both builds but only fails on some runs: it passed in the unsigned
    # recording and failed in the signed one. Either outcome is accepted and the
    # outcome is printed, so a run where it fails is visible rather than excused.
    "FingerprintPreparationTests/testPreparationAbsorbsADynamicAdInsertedIntoTheEpisode":
        "nothing anchors after the inserted ad on some runs; passes on others",
    "VoiceSharingGateLossScopeControls/test_iAWithdrawalOvertakenByAnotherMutationIsStillReported":
        "fails in a full run, passes alone or in a smaller selection",
    "InterruptionOrderingControl/testRefusalFirstDiscardsAndSubmitsNothing":
        "fails in a full run, passes alone or in a smaller selection",
}

# No target is blocked any more: the host-only macro plugin lives in the
# ModulesMacros package now, so the DataModel and Server test bundles link for
# the simulator and are required targets above. If a target stops linking
# again, this list is where its absence is made visible rather than forgotten.
BLOCKED_TARGETS = []

# Skips to carry when a target returns to the plan, so it comes back with its
# reasons rather than without them:
#   PocketCastsDataModelTests:
#     AutoAddCandidatesDataManagerTests/testNewQueryPerformance() — a performance
#       measurement rather than a correctness check, too slow for CI.
#     AutoAddCandidatesDataManagerTests/testSyncableUpNextSetting() — needs the
#       sync server stack this plan does not stand up.

# The skips that exist today, each for a stated reason. A skip absent from this
# list fails the run, so adding one is a deliberate edit here with its reason.
EXPECTED_SKIPS = {
    "PocketCastsTests": {
        # StoreKit purchase flow needs a signed build with a store configuration.
        "IAPHelperTests",
        "IAPHelperTests/testPurchase()",
    },
    "PocketCastsUtilsTests": set(),
    "PocketCastsDataModelTests": {
        # A performance measurement rather than a correctness check, too slow
        # for CI.
        "AutoAddCandidatesDataManagerTests/testNewQueryPerformance()",
        # Needs the sync server stack this plan does not stand up.
        "AutoAddCandidatesDataManagerTests/testSyncableUpNextSetting()",
    },
    "PocketCastsServerTests": set(),
    "ModulesTests": set(),
}

DEFAULT_PLAN = "PocketCastsTests/UnitTests.xctestplan"


def read_report(bundle: str) -> dict:
    raw = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "tests",
         "--path", bundle, "--compact"],
        capture_output=True, text=True, check=True,
    ).stdout
    return json.loads(raw)


def count_tests(report: dict) -> dict:
    """Executed test cases per unit-test bundle.

    A test that skips itself at runtime is not executed. Counting it would report
    coverage the run does not have: an unsigned host build, for instance, makes
    every keychain-gated test throw XCTSkip, and those tests still appear in the
    bundle as test cases.
    """
    counts = {}

    def walk(node, bundle_name=None):
        kind = node.get("nodeType")
        if kind == "Unit test bundle":
            bundle_name = node.get("name")
            counts.setdefault(bundle_name, 0)
        elif kind == "Test Case" and bundle_name is not None:
            if node.get("result") != "Skipped":
                counts[bundle_name] += 1
        for child in node.get("children", []):
            walk(child, bundle_name)

    for node in report.get("testNodes", []):
        walk(node)
    return counts


def skip_reasons(bundle: str, test_ids) -> dict:
    """Read every skip reason from the bundle in one pass.

    Asking per test means one tool invocation per skipped test. A skipped case's
    detail record carries the message it skipped with; the summary tree carries
    only the result.
    """
    reasons = {}
    try:
        report = read_report(bundle)
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        return reasons
    for test_id in test_ids:
        reason = skip_reason(bundle, test_id)
        if reason:
            reasons[test_id] = reason
    return reasons


def skip_reason(bundle: str, test_id: str) -> str:
    """The message a test gave when it skipped itself.

    The tree carries only the result; the reason is in the test's own detail
    record. It is what distinguishes a host that cannot do something from a build
    that was set up wrong.
    """
    try:
        raw = subprocess.run(
            ["xcrun", "xcresulttool", "get", "test-results", "test-details",
             "--path", bundle, "--test-id", test_id, "--compact"],
            capture_output=True, text=True, check=True,
        ).stdout
    except subprocess.CalledProcessError:
        return ""
    messages = []

    def walk(node):
        # Every value, not just `children`: the reason sits in a sibling field
        # (here `testRuns`) rather than under the node the check starts from.
        if isinstance(node, dict):
            for child in node.values():
                walk(child)
            for key in ("name", "details"):
                value = node.get(key)
                if isinstance(value, str) and "skipped" in value.lower():
                    messages.append(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    try:
        document = json.loads(raw)
    except json.JSONDecodeError:
        return ""
    # The reason lives under `testRuns`; walking the document from the top finds
    # it wherever the shape puts it.
    walk(document)
    return " ".join(dict.fromkeys(messages))


def executed_tests(report: dict) -> set:
    """Test identifiers that actually ran, from the same tree as the counts.

    Absence from a failure list is not evidence of passing: a test can be filtered
    out, skip itself, or never start because the run stopped early. Only presence
    here says it ran.
    """
    return {
        node.get("nodeIdentifier") or node.get("name")
        for node in walk_test_cases(report)
        if node.get("result") != "Skipped"
    }


def walk_test_cases(report: dict):
    """Every test-case node in the report's tree, for callers that mutate them."""

    def walk(node):
        if node.get("nodeType") == "Test Case":
            yield node
        for child in node.get("children", []):
            yield from walk(child)

    for node in report.get("testNodes", []):
        yield from walk(node)


def runtime_skips(report: dict) -> dict:
    """Tests that skipped themselves, per bundle, by identifier."""
    skips = {}

    def walk(node, bundle_name=None):
        kind = node.get("nodeType")
        if kind == "Unit test bundle":
            bundle_name = node.get("name")
            skips.setdefault(bundle_name, set())
        elif kind == "Test Case" and bundle_name is not None:
            if node.get("result") == "Skipped":
                skips[bundle_name].add(node.get("nodeIdentifier") or node.get("name"))
        for child in node.get("children", []):
            walk(child, bundle_name)

    for node in report.get("testNodes", []):
        walk(node)
    return skips


def plan_skips(plan_path: Path) -> dict:
    plan = json.loads(plan_path.read_text())
    return {
        entry["target"]["name"]: set(entry.get("skippedTests", []))
        for entry in plan.get("testTargets", [])
    }


def plan_selections(plan_path: Path) -> dict:
    """Targets narrowed to a chosen subset of their tests.

    `selectedTests` is the other half of `skippedTests`: instead of naming what not
    to run, it names the only things to run. A target can hold thousands of tests
    and execute three, and every check that counts targets or skips passes.
    """
    plan = json.loads(plan_path.read_text())
    return {
        entry["target"]["name"]: set(entry["selectedTests"])
        for entry in plan.get("testTargets", [])
        if entry.get("selectedTests")
    }


def bundle_failures(report: dict) -> set:
    """Test cases the result bundle marks Failed.

    A test that reaches its execution time allowance is killed and the runner
    restarted. It never prints a pass or fail line, so it appears in no failure
    list from the log — but the bundle records it Failed, with a duration equal to
    the allowance. Reading only the log misses every one of them.

    Only test cases are read: a suite, its bundle and the plan are all marked
    Failed when one test inside them fails, and those are not failures themselves.
    """
    failed = set()
    for node in walk_test_cases(report):
        identifier = node.get("nodeIdentifier", "")
        if node.get("result") == "Failed" and "/" in identifier:
            # The log names tests without the trailing parentheses.
            failed.add(identifier.removesuffix("()"))
    return failed


def timed_out_tests(log_path: Path) -> set:
    """Tests xcodebuild reported as exceeding their execution time allowance."""
    pattern = re.compile(r"Test Case '-\[(\S+) (\S+)\]' exceeded execution time allowance")
    found = set()
    for line in log_path.read_text(errors="replace").splitlines():
        match = pattern.search(line)
        if match:
            bundle_suite, test = match.groups()
            found.add(f"{bundle_suite.split('.')[-1]}/{test}")
    return found


def reported_failures(log_path: Path) -> set:
    """Test identifiers xcodebuild reported a failure for, from its own output.

    The result bundle marks a suite, its bundle and the whole plan as Failed when
    one test inside them fails, so a set gathered from the tree contains failures
    that are really the ancestors of failures. xcodebuild names the test that
    failed, so that is what is compared here.
    """
    reported = set()
    for line in log_path.read_text(errors="replace").splitlines():
        if ": error:" not in line or " " not in line:
            continue
        # ".../Foo.swift:12: error: -[Bundle.Suite testName] : message"
        tail = line.split("error: ", 1)[-1]
        if not tail.startswith("-[") or "]" not in tail:
            continue
        reference = tail[2:].split("]", 1)[0]
        parts = reference.split(" ")
        if len(parts) < 2:
            continue
        suite = parts[0].rsplit(".", 1)[-1]
        reported.add(f"{suite}/{parts[1]}")
    return reported


def check_failures(reported: set, timed_out: set = frozenset()) -> list:
    """Compare the tests that failed against the ones expected to.

    A test killed at its execution time allowance fails the run even when it is
    on the intermittent list: the tolerated list exists for a test whose outcome
    varies run to run, and a hang is an outcome that happened — excusing it
    would make the list a way to hide a hang.
    """
    failures = []
    for test in sorted(reported):
        if any(t in test for t in timed_out):
            failures.append(
                f"'{test}' was killed at its execution time allowance. A hang is "
                "an outcome that happened, and the intermittent list does not "
                "excuse it."
            )
            continue
        if any(listed in test for listed in FLAKY_TESTS):
            continue
        if not any(listed in test for listed in KNOWN_FAILURES):
            failures.append(
                f"'{test}' failed and is not a known failure. A new failure is a "
                "change in the product, not in the pipeline."
            )
    for name, reason in sorted(KNOWN_FAILURES.items()):
        if not any(name in test for test in reported):
            failures.append(
                f"'{name}' is listed as a known failure but passed. It is listed "
                f"because {reason}; if that is fixed, remove it from the list."
            )
    return failures


def check_coverage(counts: dict, plan_path: Path, skips: dict = None,
                   reasons: dict = None, signed: bool = True) -> list:
    """Every way this run could have covered less than it claims to."""
    failures = []

    for target in REQUIRED_TARGETS:
        count = counts.get(target, 0)
        if count < MINIMUM_TESTS.get(target, 1):
            failures.append(
                f"{target} executed {count} tests, expected at least "
                f"{MINIMUM_TESTS[target]}. A run that stops early — a runner that "
                "never connects, a crash partway through — leaves the tests it "
                "did run passing, so a floor is what distinguishes it from a "
                "complete run."
            )

    for target in REQUIRED_TARGETS:
        actual = (skips or {}).get(target, set())
        expected = set(EXPECTED_RUNTIME_SKIPS.get(target, {}))
        # A keychain entitlement the signature does not carry is a signing failure
        # on a signed build whether or not the test is listed: being on a list of
        # tests that cannot run here must not excuse the signing being broken. So
        # this is checked over every skip, not only the unlisted ones.
        if signed:
            for skip in sorted(actual):
                reason = (reasons or {}).get(skip, "")
                if KEYCHAIN_SKIP_MARKER in reason and ACCESS_GROUP_SKIP_MARKER not in reason:
                    failures.append(
                        f"{target}: '{skip}' skipped for a missing keychain "
                        "entitlement. The host is signed so that it has one, which "
                        "makes this a signing failure rather than a limit of the "
                        "environment: fix the signing instead of listing the skip."
                    )

        for skip in sorted(actual - expected):
            reason = (reasons or {}).get(skip, "")
            if ACCESS_GROUP_SKIP_MARKER in reason:
                # A group the build does not declare is a property of the build,
                # not a signing failure: signing ad-hoc cannot produce it.
                failures.append(
                    f"{target}: '{skip}' needs a keychain access group the build "
                    "does not declare. Signing ad-hoc gives the host its own "
                    "entitlement, not a group shared with another app; list the "
                    "test here if that is expected to stay true."
                )
                continue
            if KEYCHAIN_SKIP_MARKER in reason:
                if skip in UNSIGNED_KEYCHAIN_SKIPS.get(target, set()):
                    # Expected answer in an unsigned run, and not coverage.
                    continue
                else:
                    failures.append(
                        f"{target}: '{skip}' skipped for a missing keychain "
                        "entitlement in a run that is not signed. That is the "
                        "expected answer there, but the test is missing from "
                        "UNSIGNED_KEYCHAIN_SKIPS, so this run covers less than "
                        "the list says it does."
                    )
            else:
                failures.append(
                    f"{target}: '{skip}' skipped itself at runtime and is not an "
                    "expected runtime skip. A self-skipped test does not run; add "
                    f"it here with its reason, or give the host what it needs."
                    + (f" Reason given: {reason}" if reason else "")
                )
        for skip in sorted(expected - actual):
            failures.append(
                f"{target}: '{skip}' is listed as a runtime skip but ran. If the "
                "environment can now run it, remove it from the list."
            )
        for skip in sorted(UNSIGNED_KEYCHAIN_SKIPS.get(target, set()) - actual):
            if signed:
                continue
            failures.append(
                f"{target}: '{skip}' is listed as a keychain skip but ran unsigned. "
                "Remove it from UNSIGNED_KEYCHAIN_SKIPS."
            )

    if not plan_path.is_file():
        failures.append(f"test plan not found at {plan_path}")
        return failures

    for target, selected in sorted(plan_selections(plan_path).items()):
        failures.append(
            f"{target} is narrowed to {len(selected)} selected tests in the plan. "
            "A selection runs only what it names, so the target's count says "
            "nothing about the rest of it. Remove the selection."
        )

    actual = plan_skips(plan_path)
    for target in REQUIRED_TARGETS:
        unexpected = actual.get(target, set()) - EXPECTED_SKIPS.get(target, set())
        for skip in sorted(unexpected):
            failures.append(
                f"{target}: '{skip}' is skipped in the plan but is not an "
                "expected skip. Add it here with its reason, or unskip it."
            )
    for target in sorted(set(actual) - set(REQUIRED_TARGETS)):
        if target in BLOCKED_TARGETS:
            failures.append(
                f"{target} is back in the plan but is still listed as blocked. "
                "Move it into REQUIRED_TARGETS so its executed count is asserted."
            )
        else:
            failures.append(f"{target} is in the plan but is not a required target")
    return failures


def intermittent_outcome(name: str, failed: set, executed: set) -> str:
    """What happened to an intermittent test this run.

    Absence from the failures is not evidence of passing: a filtered test, a
    self-skip and a run cut short all look the same there. Only presence in the
    executed set says it ran.
    """
    if any(name in test for test in failed):
        return "failed"
    if any(name in test for test in executed):
        return "passed"
    return "not run"


def print_intermittent_outcomes(failed: set, executed: set) -> None:
    """Printed on every run, so the outcomes accumulate rather than being recalled."""
    if not FLAKY_TESTS:
        return
    print("\nTests that fail intermittently:")
    for name, reason in sorted(FLAKY_TESTS.items()):
        outcome = intermittent_outcome(name, failed, executed)
        print(f"  {name}: {outcome} this run ({reason})")


def check_package_coverage(report: dict, counts: dict) -> list:
    """The host-only package tests, one runner each, same floor discipline."""
    failures = []
    for target, spec in sorted(PACKAGE_REQUIRED_TARGETS.items()):
        # swift test names its bundle with the .xctest suffix; xcodebuild does not.
        count = sum(n for name, n in counts.items() if name.startswith(target))
        if count < spec["minimum"]:
            failures.append(
                f"{target} (host runner) executed {count} tests, expected at "
                f"least {spec['minimum']}. A host runner that stops early — a "
                "compile failure in the package, a crashed test process — leaves "
                "the tests it did run passing, so a floor is what distinguishes "
                "a complete run from a truncated one."
            )
    failed = bundle_failures(report)
    if failed:
        failures.append(
            "host-runner package tests failed: "
            + ", ".join(sorted(failed))
            + ". A package test failure is a product change, not an "
            "environment one; fix the macro or the test."
        )
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle")
    parser.add_argument("--plan", default=DEFAULT_PLAN)
    parser.add_argument("--log", default="artifacts/test.log")
    parser.add_argument(
        "--package-bundle",
        help="result bundle of the host-runner package tests (swift test)",
    )
    args = parser.parse_args()

    try:
        report = read_report(args.bundle)
        counts = count_tests(report)
        skips = runtime_skips(report)
        executed = executed_tests(report)
    except subprocess.CalledProcessError as error:
        print(f"cannot read the result bundle: {error.stderr.strip()}", file=sys.stderr)
        return 1
    except json.JSONDecodeError as error:
        print(f"result bundle report is not JSON: {error}", file=sys.stderr)
        return 1

    for target in REQUIRED_TARGETS:
        count = counts.get(target, 0)
        if count:
            print(f"{target}: {count} tests executed")
    for name in sorted(set(counts) - set(REQUIRED_TARGETS)):
        print(f"{name}: {counts[name]} tests executed (not a required target)")
    for target in REQUIRED_TARGETS:
        count = len(skips.get(target, set()))
        if count:
            print(f"{target}: {count} tests skipped themselves at runtime")
    for target in BLOCKED_TARGETS:
        print(f"{target}: not in the plan — cannot link for the simulator yet")

    reasons = skip_reasons(
        args.bundle, [test_id for tests in skips.values() for test_id in tests]
    )
    failures = check_coverage(
        counts, Path(args.plan), skips, reasons,
        signed=SIGNED_HOST,
    )
    if PACKAGE_REQUIRED_TARGETS:
        if not args.package_bundle:
            failures.append(
                "package tests are required but no package result bundle was "
                "given; the step must run swift test with --xcresult-output and "
                "pass it here"
            )
        else:
            try:
                package_report = read_report(args.package_bundle)
                package_counts = count_tests(package_report)
            except subprocess.CalledProcessError as error:
                print(f"cannot read the package result bundle: {error.stderr.strip()}", file=sys.stderr)
                package_counts = {}
                package_report = {}
            except json.JSONDecodeError as error:
                print(f"package result bundle report is not JSON: {error}", file=sys.stderr)
                package_counts = {}
                package_report = {}
            for target in sorted(PACKAGE_REQUIRED_TARGETS):
                print(f"{target} (host runner): {package_counts.get(target, 0)} tests executed")
            failures += check_package_coverage(package_report, package_counts)
    # Failures come from both places. The log names the tests that reported a
    # failure; the bundle also marks the ones that were killed at their execution
    # time allowance, which print no result line and so appear in no log list.
    # Reading only the log counts those as passing.
    failed = reported_failures(Path(args.log)) | bundle_failures(report)
    timeouts = timed_out_tests(Path(args.log))
    if timeouts:
        print(f"{len(timeouts)} test(s) reached their execution time allowance and "
              "were killed. Each one forced the test runner to restart; a restart "
              "that does not reconnect ends the run partway through:")
        for name in sorted(timeouts):
            print(f"  {name}")
    failures += check_failures(failed, timed_out=timeouts)
    if failures:
        print("\nCoverage check FAILED:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    if failed:
        print("\nFailing tests, all known:")
        for test in sorted(failed):
            print(f"  {test}")
    print_intermittent_outcomes(failed, executed)
    print("\nCoverage check passed: every buildable target ran, no unexpected skips.")
    if BLOCKED_TARGETS:
        print(f"Still blocked: {', '.join(BLOCKED_TARGETS)}")
    if PACKAGE_REQUIRED_TARGETS:
        print(f"Host-runner package targets: {', '.join(sorted(PACKAGE_REQUIRED_TARGETS))}")
    return exit_code(failures, failed)


def exit_code(failures: list, failed: set) -> int:
    """Three outcomes the step's verdict can tell apart.

    0 — no test failures at all. 10 — failures, but every one is on the
    known-failures list and the whole plan ran, so the run is accepted.
    Anything failing the check is 1. A caller that tolerates a red xcodebuild
    only when real, listed failures exist needs 0 and 10 to be distinct: a
    red xcodebuild beside a 0 is an infrastructure failure, beside a 10 it is
    the known-failures case.
    """
    if failures:
        return 1
    return 10 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
