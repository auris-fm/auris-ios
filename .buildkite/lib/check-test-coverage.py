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
]

# A floor per target, not just "more than zero". A test runner that dies after one
# test still reports that test as passing; only a count near the target's real size
# tells a complete run from a truncated one. Set below the observed counts so ordinary
# growth does not trip it, and raised when a target gains tests deliberately.
MINIMUM_TESTS = {
    "PocketCastsTests": 2000,
    "PocketCastsUtilsTests": 50,
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
    # The successor is refused where the test expects it to be admitted, so the
    # stop and cleanup it then asserts never happen.
    "CloudRouteSupersedeTests/testSuccessorAdmissionAwaitsPredecessorQuiescence":
        "successor admission is refused instead of waiting for the predecessor",
    "CloudRouteSupersedeTests/testSupersededCleanupAwaitsItsCapturedRetireIdentity":
        "superseded cleanup is never reached because the successor is refused",
    # Nothing anchors after the inserted ad, so the timings it asserts are absent.
    # This one only became visible when the build was signed: with no keychain
    # entitlement the test skipped itself, so no unsigned run ever reported it.
    "FingerprintPreparationTests/testPreparationAbsorbsADynamicAdInsertedIntoTheEpisode":
        "fails on main; was hidden by the unsigned keychain skip",
}

# Tests that fail in some runs and pass in others. Either result is accepted, and
# the outcome is printed, so a run says how often they fail instead of going red at
# random or hiding the frequency. They are not in KNOWN_FAILURES: that list means
# "fails every time", and a test that also passes would break its own entry.
FLAKY_TESTS = {
    "VoiceSharingGateLossScopeControls/test_iAWithdrawalOvertakenByAnotherMutationIsStillReported":
        "fails in a full run, passes alone or in a smaller selection",
    "InterruptionOrderingControl/testRefusalFirstDiscardsAndSubmitsNothing":
        "fails in a full run, passes alone or in a smaller selection",
}

# Targets that belong in the plan but cannot currently build for the simulator.
# PocketCastsDataModel depends on GRDBMacros, whose plugin is a macro target —
# host code, built for macOS. Linking its object into an iOS-simulator test
# bundle fails:
#   ld: building for 'iOS-simulator', but linking in object file
#       (.../Debug/ExecutableModules/GRDBMacrosPlugin.o) built for 'macOS'
# PocketCastsServerTests links PocketCastsServer, which reaches the same target.
# Neither is skipped or quarantined: they are absent from the plan until the
# package separates host and simulator code, and this list is what makes their
# absence visible rather than forgotten. Adding a target back to the plan means
# moving it from here into REQUIRED_TARGETS.
BLOCKED_TARGETS = [
    "PocketCastsDataModelTests",
    "PocketCastsServerTests",
]

# Skips to carry over when PocketCastsDataModelTests returns to the plan, so the
# target comes back with its reasons rather than without them:
#   AutoAddCandidatesDataManagerTests/testNewQueryPerformance() — a performance
#     measurement rather than a correctness check, too slow for CI.
#   AutoAddCandidatesDataManagerTests/testSyncableUpNextSetting() — needs the sync
#     server stack this plan does not stand up.

# The skips that exist today, each for a stated reason. A skip absent from this
# list fails the run, so adding one is a deliberate edit here with its reason.
EXPECTED_SKIPS = {
    "PocketCastsTests": {
        # StoreKit purchase flow needs a signed build with a store configuration.
        "IAPHelperTests",
        "IAPHelperTests/testPurchase()",
    },
    "PocketCastsUtilsTests": set(),
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


def check_failures(reported: set, flaky_outcomes: dict = None) -> list:
    """Compare the tests that failed against the ones expected to."""
    failures = []
    for test in sorted(reported):
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
                if signed:
                    failures.append(
                        f"{target}: '{skip}' skipped for a missing keychain "
                        "entitlement. The host is signed so that it has one, which "
                        "makes this a signing failure rather than a limit of the "
                        "environment: fix the signing instead of listing the skip."
                    )
                elif skip in UNSIGNED_KEYCHAIN_SKIPS.get(target, set()):
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle")
    parser.add_argument("--plan", default=DEFAULT_PLAN)
    parser.add_argument("--log", default="artifacts/test.log")
    args = parser.parse_args()

    try:
        report = read_report(args.bundle)
        counts = count_tests(report)
        skips = runtime_skips(report)
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
    failed = reported_failures(Path(args.log))
    failures += check_failures(failed)
    if failures:
        print("\nCoverage check FAILED:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    if failed:
        print("\nFailing tests, all known:")
        for test in sorted(failed):
            print(f"  {test}")
    if FLAKY_TESTS:
        # Printed on every run, passing or failing: the count over runs is what
        # says whether one of these is getting worse.
        print("\nTests that fail intermittently:")
        for name, reason in sorted(FLAKY_TESTS.items()):
            outcome = "failed" if any(name in test for test in failed) else "passed"
            print(f"  {name}: {outcome} this run ({reason})")
    print("\nCoverage check passed: every buildable target ran, no unexpected skips.")
    if BLOCKED_TARGETS:
        print(f"Still blocked: {', '.join(BLOCKED_TARGETS)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
