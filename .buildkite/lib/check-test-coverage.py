#!/usr/bin/env python3
"""Fail a CI run that looked green while running less than the whole test plan.

Two ways a run can pass without testing what it claims to test, both invisible in
xcodebuild's exit status:

  * A target in the plan runs zero tests. `-only-testing:` narrows the selection,
    a target fails to load, or a bundle is missing from the scheme; each leaves
    the remaining targets passing and the run green.
  * The plan's `skippedTests` list grows. A skip is a silent reduction in
    coverage, and nothing in a green run says how many were added.

So this reads the result bundle rather than the log: the bundle records which
bundles actually executed, and the plan records what was deliberately excluded.
Both are compared against expectations written down here.

Usage: check-test-coverage.py <path-to.xcresult> [--plan <path>]
"""

import argparse
import json
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
    """Test cases per unit-test bundle, counted from the report's own tree."""
    counts = {}

    def walk(node, bundle_name=None):
        kind = node.get("nodeType")
        if kind == "Unit test bundle":
            bundle_name = node.get("name")
            counts.setdefault(bundle_name, 0)
        elif kind == "Test Case" and bundle_name is not None:
            counts[bundle_name] += 1
        for child in node.get("children", []):
            walk(child, bundle_name)

    for node in report.get("testNodes", []):
        walk(node)
    return counts


def plan_skips(plan_path: Path) -> dict:
    plan = json.loads(plan_path.read_text())
    return {
        entry["target"]["name"]: set(entry.get("skippedTests", []))
        for entry in plan.get("testTargets", [])
    }


def check_coverage(counts: dict, plan_path: Path) -> list:
    """Every way this run could have covered less than it claims to."""
    failures = []

    for target in REQUIRED_TARGETS:
        if counts.get(target, 0) == 0:
            failures.append(
                f"{target} executed 0 tests. A target that runs nothing is "
                "indistinguishable from a pass in xcodebuild's exit status."
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
    args = parser.parse_args()

    try:
        counts = count_tests(read_report(args.bundle))
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
    for target in BLOCKED_TARGETS:
        print(f"{target}: not in the plan — cannot link for the simulator yet")

    failures = check_coverage(counts, Path(args.plan))
    if failures:
        print("\nCoverage check FAILED:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    print("\nCoverage check passed: every buildable target ran, no unexpected skips.")
    if BLOCKED_TARGETS:
        print(f"Still blocked: {', '.join(BLOCKED_TARGETS)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
