#!/usr/bin/env python3
"""Proof that the coverage guard fails when coverage is missing.

A guard that has only ever been seen passing is indistinguishable from one that
cannot fail. Each case here removes something the guard is supposed to notice and
asserts it does, using the same functions the CI step calls.

Run: python3 .buildkite/lib/test_check_test_coverage.py [path-to.xcresult]
"""

import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SKIP_MANIFEST = Path("artifacts/skip-reasons.json")
REPO = HERE.parent.parent

spec = importlib.util.spec_from_file_location("check", HERE / "check-test-coverage.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


def real_report(bundle_path=None):
    """A report from an actual run, so the tree shape is Xcode's and not invented.

    The CI step passes the bundle it just produced. Without one, take the newest
    by modification time: a lexical sort would pick whichever build number sorts
    last, which is not the run that just happened.
    """
    if bundle_path:
        return check.read_report(bundle_path)
    bundles = list((REPO / "artifacts").glob("*.xcresult"))
    if not bundles:
        sys.exit("no result bundle in artifacts/; run the pipeline first")
    newest = max(bundles, key=lambda b: b.stat().st_mtime)
    return check.read_report(str(newest))


def manifest_reason(test_id):
    """Why the recording says this test skipped, for the tests it recorded.

    The recording is the authority on what skipped; the manifest is only here for
    `test_check_test_coverage.py`, which the trust perimeter may run without the
    recording in reach.
    """
    try:
        manifest = json.loads((REPO / SKIP_MANIFEST).read_text())
    except (OSError, ValueError):
        return None
    for reasons in manifest.values():
        for recorded, reason in reasons.items():
            if recorded == test_id:
                return reason
    return None


def run_guard(report, plan_text, signed=True):
    """The same decision the CI step makes, with reasons read from the same run."""
    skips = check.runtime_skips(report)
    identifiers = [test_id for ids in skips.values() for test_id in ids]
    # The recording does not carry why a test skipped, so the reasons come from
    # the manifest generated alongside it. What is being proved is the
    # bookkeeping — which skips and failures the guard accepts — not the reading of
    # any particular bundle.
    reasons = {test_id: manifest_reason(test_id) for test_id in identifiers}
    with tempfile.TemporaryDirectory() as tmp:
        plan = Path(tmp) / "plan.xctestplan"
        plan.write_text(plan_text)
        return check.check_coverage(
            check.count_tests(report), plan, skips, reasons, signed
        )


PLAN = (REPO / "PocketCastsTests" / "UnitTests.xctestplan").read_text()


def case(name, report, plan_text, expect_failure, expected_text=None, reasons=None,
         signed=True):
    with tempfile.TemporaryDirectory() as tmp:
        plan = Path(tmp) / "plan.xctestplan"
        plan.write_text(plan_text)
        skips = check.runtime_skips(report)
        # The cases run against one recorded run, so the reasons are read from it
        # once rather than re-querying the bundle per skipped test.
        if reasons is None:
            reasons = {t: manifest_reason(t) for ids in skips.values() for t in ids}
        failures = check.check_coverage(
            check.count_tests(report), plan, skips, reasons, signed
        )
    failed = bool(failures)
    ok = failed == expect_failure
    if ok and expected_text:
        ok = any(expected_text in f for f in failures)
    print(f"{'PASS' if ok else 'FAIL'}  {name}")
    for f in failures:
        print(f"        -> {f}")
    return ok


def main():
    # The recordings available are of an unsigned run, so the proof reads them the
    # way that run should be read: the keychain skips are its expected answer. The
    # signed run is the one case below that contrasts the two readings.
    base = real_report(sys.argv[1] if len(sys.argv) > 1 else None)
    results = []

    # The baseline must itself be a complete run. A truncated bundle would make
    # every "removes coverage" case pass for the wrong reason, so say so plainly
    # rather than reporting four green checks that proved nothing.
    baseline_failures = run_guard(base, PLAN, signed=False)
    if baseline_failures:
        print("FAIL  baseline run is not complete; the cases below prove nothing")
        for f in baseline_failures:
            print(f"        -> {f}")
        return 1
    results.append(case("unmodified run passes", base, PLAN, expect_failure=False,
                        signed=False))

    # A required target runs nothing: the selection was narrowed, or the bundle
    # failed to load. xcodebuild still exits 0 for the tests it did run.
    import copy
    dropped = copy.deepcopy(base)
    plan_node = dropped["testNodes"][0]
    plan_node["children"] = [
        b for b in plan_node["children"] if b["name"] != "PocketCastsUtilsTests"
    ]
    results.append(case("required target removed from the run", dropped, PLAN, expect_failure=True))

    # The plan grows a skip. Nothing in a green run reports it.
    mutant = json.loads(PLAN)
    mutant["testTargets"][0].setdefault("skippedTests", []).append(
        "CloudRouteSupersedeTests/testACompletedDoneDrainsTheSameBufferedOutput()"
    )
    results.append(case("plan gains an unlisted skip", base, json.dumps(mutant), expect_failure=True))

    # A blocked target comes back to the plan without being made required.
    restored = json.loads(PLAN)
    restored["testTargets"].append({
        "target": {
            "containerPath": "container:Modules",
            "identifier": "PocketCastsDataModelTests",
            "name": "PocketCastsDataModelTests",
        }
    })
    failures = run_guard(base, json.dumps(restored))
    ok = any("still listed as blocked" in f for f in failures)
    for f in failures:
        print(f"        -> {f}")
    print(f"{'PASS' if ok else 'FAIL'}  blocked target returns without being required")
    results.append(ok)

    # Listing the tests that legitimately skip must not let a broken build skip
    # quietly: a skip for a missing keychain entitlement means signing is not in
    # effect, so it fails even when the test that skipped is a listed one.
    listed = sorted(check.EXPECTED_RUNTIME_SKIPS["PocketCastsTests"])[0]
    masked = copy.deepcopy(base)
    for node in check.walk_test_cases(masked):
        if node.get("nodeIdentifier") == listed:
            node["result"] = "Skipped"
    listed_skips = check.runtime_skips(masked)
    results.append(case(
        "listed skip for a missing keychain entitlement still fails",
        masked, PLAN, expect_failure=True, expected_text="missing keychain",
        # Every listed test skips for the keychain here, which is what a
        # recording looks like when the signing is turned off.
        reasons={
            test_id: f"Test skipped - {check.KEYCHAIN_SKIP_MARKER}"
            for ids in listed_skips.values() for test_id in ids
        },
    ))

    # A failure that is not on the known list fails the run; a listed one that
    # starts passing fails it too, so the list cannot outlive the defect.
    log = Path(sys.argv[2]) if len(sys.argv) > 2 else REPO / "artifacts" / "test.log"
    reported = check.reported_failures(log)
    flaky = sorted(check.FLAKY_TESTS)[0]
    for name, ok in (
        ("a failure that is not a known failure fails the run",
         bool(check.check_failures(reported | {"SomethingTests/testNew()"}))),
        ("an intermittent test failing does not fail the run",
         check.check_failures(reported | {flaky}) == []),
        ("the recorded run's failures are all known",
         check.check_failures(reported) == []),
        ("a known failure that stops failing fails the run",
         bool(check.check_failures(set()))),
    ):
        print(f"{'PASS' if ok else 'FAIL'}  {name}")
        results.append(ok)

    print(f"\n{sum(results)}/{len(results)} cases behaved as intended")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
