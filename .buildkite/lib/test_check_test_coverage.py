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
        return ""
    for reasons in manifest.values():
        for recorded, reason in reasons.items():
            if recorded == test_id:
                return reason
    return ""


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
    # Read the bundle the way this run produced it. CI hands over a signed bundle;
    # a recording of an unsigned run is read as unsigned, where the keychain skips
    # are that run's expected answer rather than coverage it lost.
    signed = check.SIGNED_HOST
    base = real_report(sys.argv[1] if len(sys.argv) > 1 else None)
    results = []

    # The baseline must itself be a complete run. A truncated bundle would make
    # every "removes coverage" case pass for the wrong reason, so say so plainly
    # rather than reporting four green checks that proved nothing.
    baseline_failures = run_guard(base, PLAN, signed=signed)
    if baseline_failures:
        print("FAIL  baseline run is not complete; the cases below prove nothing")
        for f in baseline_failures:
            print(f"        -> {f}")
        return 1
    results.append(case("unmodified run passes", base, PLAN, expect_failure=False,
                        signed=signed))

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

    # The plan narrows a target to a handful of its tests. Every count and skip
    # check still passes, because the target ran and nothing was skipped.
    narrowed = json.loads(PLAN)
    narrowed["testTargets"][0]["selectedTests"] = ["FeatureFlagTests"]
    results.append(case("plan narrows a target to selected tests", base,
                        json.dumps(narrowed), expect_failure=True,
                        expected_text="narrowed to", signed=signed))

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
    # Take a test that ran and make it skip for a missing keychain entitlement.
    # It has to be one that was not skipping already, or the case would only
    # re-test what the run did rather than what the guard decides.
    # A PocketCastsTests case: the guard reads expectations per bundle, so a test
    # from another bundle would not be looked up at all.
    pocket_cases = {
        node.get("nodeIdentifier")
        for node in check.walk_test_cases(base)
        if node.get("result") != "Skipped"
    }
    suite_names = set()

    def collect(node, bundle=None):
        if node.get("nodeType") == "Unit test bundle":
            bundle = node.get("name")
        elif node.get("nodeType") == "Test Case" and bundle == "PocketCastsTests":
            suite_names.add(node.get("nodeIdentifier"))
        for child in node.get("children", []):
            collect(child, bundle)

    for node in base["testNodes"]:
        collect(node)
    listed = sorted(suite_names)[0]
    masked = copy.deepcopy(base)
    for node in check.walk_test_cases(masked):
        if node.get("nodeIdentifier") == listed:
            node["result"] = "Skipped"
    # Restored afterwards: the cases below read the same expectations, and a test
    # left listed here would make them prove something else.
    check.EXPECTED_RUNTIME_SKIPS["PocketCastsTests"][listed] = "added by this case"
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
    del check.EXPECTED_RUNTIME_SKIPS["PocketCastsTests"][listed]

    # An access-group skip is a property of the build, not a signing failure: an
    # ad-hoc signature gives the host its own entitlement and cannot declare a
    # group shared with another app. It must stay allowed on a signed run.
    # The unmodified signed run above is what proves an access-group skip stays
    # allowed on a signed build — but only if the recording contains any. With
    # none present that case passes without exercising the rule at all, so their
    # presence is asserted rather than reported.
    group_ids = list(check.EXPECTED_RUNTIME_SKIPS["PocketCastsTests"])
    group_reasons = check.skip_reasons(sys.argv[1], group_ids)
    present_groups = sorted(
        name for name, reason in group_reasons.items()
        if check.ACCESS_GROUP_SKIP_MARKER in reason
    )
    # The tests that need a group another app shares: named by their suite, since
    # the expectation list holds reasons only as they were recorded.
    expected_groups = sorted(
        name for name in check.EXPECTED_RUNTIME_SKIPS["PocketCastsTests"]
        if name.startswith("SameAccessGroupPreservationTests/")
    )
    groups_ok = not signed or present_groups == expected_groups
    print(f"{'PASS' if groups_ok else 'FAIL'}  the recording exercises the access-group rule")
    if not groups_ok:
        print(f"        -> expected {expected_groups}, found {present_groups}: without "
              "them the signed-run case proves nothing about access-group skips")
    results.append(groups_ok)

    # A test that never ran must not be reported as passing: absence from the
    # failures is also what a filtered or skipped test looks like.
    flaky = sorted(check.FLAKY_TESTS)[0]
    truncated = copy.deepcopy(base)
    for node in check.walk_test_cases(truncated):
        if flaky in (node.get("nodeIdentifier") or ""):
            node["result"] = "Skipped"
    # The verdict itself, not just the set: this is the string the pass rate is
    # read from, so it is what has to be right.
    failed_set = check.reported_failures(log)
    ok = (
        check.intermittent_outcome(flaky, failed_set, check.executed_tests(truncated)) == "not run"
        and check.intermittent_outcome(flaky, failed_set, check.executed_tests(base)) == "passed"
        and check.intermittent_outcome(flaky, failed_set | {flaky}, check.executed_tests(base)) == "failed"
    )
    print(f"{'PASS' if ok else 'FAIL'}  an intermittent test reads passed, failed or not run")
    results.append(ok)
    # A test killed at its execution time allowance prints no result line, so it
    # is absent from the log's failure list while the bundle marks it Failed. It
    # must fail the run, and it must not read as passed or as never run.
    timed_out = sorted(check.bundle_failures(base) - reported)
    timeout_ok = bool(timed_out) and bool(
        check.check_failures(reported | set(timed_out))
    )
    print(f"{'PASS' if timeout_ok else 'FAIL'}  a timed-out test fails the run")
    if not timed_out:
        print("        -> this recording contains no timed-out test, so the case "
              "proves nothing; use a recording that has one")
    results.append(timeout_ok)

    if timed_out:
        victim = timed_out[0]
        # On the flaky list it is still a failure: either result is accepted, but
        # the outcome reported must be the one that happened.
        check.FLAKY_TESTS[victim] = "added by this case"
        outcome = check.intermittent_outcome(
            victim, reported | {victim}, check.executed_tests(base)
        )
        excused = check.check_failures(reported | {victim}) == []
        del check.FLAKY_TESTS[victim]
        flaky_timeout_ok = outcome == "failed" and excused
        print(f"{'PASS' if flaky_timeout_ok else 'FAIL'}  "
              "a timed-out test on the flaky list reports failed")
        if not flaky_timeout_ok:
            print(f"        -> outcome was '{outcome}', expected 'failed'")
        results.append(flaky_timeout_ok)

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
