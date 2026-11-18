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
    # No guessing: artifacts/ holds probe and red-proof bundles too, so picking
    # the newest by mtime once selected a one-test recording and the suite
    # proved nothing. The CI step passes the bundle it just produced; locally,
    # pass the recording explicitly.
    sys.exit(
        "pass the result bundle to test: "
        "test_check_test_coverage.py <path/to/run.xcresult>"
    )


def run_guard(report, plan_text, signed=True, bundle=None):
    """The same decision the CI step makes, with reasons read from the same run.

    A skipped case's detail record carries the message it skipped with, so the
    reasons are read from the bundle under test — the same reader the CI step
    uses. An unsigned recording then proves its own expected skips instead of
    depending on a manifest file that nothing writes.
    """
    skips = check.runtime_skips(report)
    identifiers = [test_id for ids in skips.values() for test_id in ids]
    reasons = check.skip_reasons(bundle, identifiers) if bundle else {}
    with tempfile.TemporaryDirectory() as tmp:
        plan = Path(tmp) / "plan.xctestplan"
        plan.write_text(plan_text)
        return check.check_coverage(
            check.count_tests(report), plan, skips, reasons, signed
        )


PLAN = (REPO / "PocketCastsTests" / "UnitTests.xctestplan").read_text()


def case(name, report, plan_text, expect_failure, expected_text=None, reasons=None,
         signed=True, bundle=None):
    with tempfile.TemporaryDirectory() as tmp:
        plan = Path(tmp) / "plan.xctestplan"
        plan.write_text(plan_text)
        skips = check.runtime_skips(report)
        # The cases run against one recorded run, so the reasons are read from it
        # once rather than re-querying the bundle per skipped test.
        if reasons is None:
            reasons = check.skip_reasons(
                bundle, [t for ids in skips.values() for t in ids]
            ) if bundle else {}
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
    bundle = sys.argv[1] if len(sys.argv) > 1 else None
    base = real_report(bundle)
    results = []

    # The baseline must itself be a complete run. A truncated bundle would make
    # every "removes coverage" case pass for the wrong reason, so say so plainly
    # rather than reporting four green checks that proved nothing.
    baseline_failures = run_guard(base, PLAN, signed=signed, bundle=bundle)
    if baseline_failures:
        # Two different things can make a recording unusable as a baseline. Missing
        # coverage invalidates every case below, because each one removes coverage
        # and would pass for the wrong reason. Failures the guard does not recognise
        # do not: they are what this recording measured, and the cases that compare
        # against them say so rather than pretending the run was clean.
        coverage_lost = [f for f in baseline_failures if "failed and is not a known" not in f
                         and "listed as a known failure but passed" not in f]
        if coverage_lost:
            print("FAIL  baseline run is not complete; the cases below prove nothing")
            for f in coverage_lost:
                print(f"        -> {f}")
            return 1
        print("      this recording has failures the guard does not recognise:")
        for f in baseline_failures:
            print(f"        -> {f}")
        print("      the cases that compare failures against the lists are reported "
              "as unproved for it; the coverage cases still apply")
    results.append(case("unmodified run passes", base, PLAN, expect_failure=False,
                        signed=signed, bundle=bundle))

    # A required target runs nothing: the selection was narrowed, or the bundle
    # failed to load. xcodebuild still exits 0 for the tests it did run.
    import copy
    dropped = copy.deepcopy(base)
    plan_node = dropped["testNodes"][0]
    plan_node["children"] = [
        b for b in plan_node["children"] if b["name"] != "PocketCastsUtilsTests"
    ]
    results.append(case("required target removed from the run", dropped, PLAN,
                        expect_failure=True, bundle=bundle))

    # The plan grows a skip. Nothing in a green run reports it.
    mutant = json.loads(PLAN)
    mutant["testTargets"][0].setdefault("skippedTests", []).append(
        "CloudRouteSupersedeTests/testACompletedDoneDrainsTheSameBufferedOutput()"
    )
    results.append(case("plan gains an unlisted skip", base, json.dumps(mutant),
                        expect_failure=True, bundle=bundle))

    # The plan narrows a target to a handful of its tests. Every count and skip
    # check still passes, because the target ran and nothing was skipped.
    narrowed = json.loads(PLAN)
    narrowed["testTargets"][0]["selectedTests"] = ["FeatureFlagTests"]
    results.append(case("plan narrows a target to selected tests", base,
                        json.dumps(narrowed), expect_failure=True,
                        expected_text="narrowed to", signed=signed, bundle=bundle))

    # A blocked target comes back to the plan without being made required.
    restored = json.loads(PLAN)
    restored["testTargets"].append({
        "target": {
            "containerPath": "container:Modules",
            "identifier": "PocketCastsDataModelTests",
            "name": "PocketCastsDataModelTests",
        }
    })
    failures = run_guard(base, json.dumps(restored), bundle=bundle)
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
    # Read failures the way the guard does: the log names the tests that reported
    # one, and the bundle also marks the ones killed at their execution allowance,
    # which print no result line. Using the log alone here would test a different
    # set from the one the run is judged on.
    reported = check.reported_failures(log) | check.bundle_failures(base)
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
    # A test that ran and passed in this recording, so all three outcomes can be
    # exercised from it. Taking the first name alphabetically would pick one that
    # failed here, and "passed" could then never be produced.
    flaky = next(
        (name for name in sorted(check.FLAKY_TESTS)
         if check.intermittent_outcome(name, reported, check.executed_tests(base)) == "passed"),
        None,
    )
    if flaky is None:
        # Every listed intermittent failed in this recording. The tolerated set
        # is then exercised by the recording itself, not by this case, which can
        # only prove the three-outcome read from a test that passed. Reported as
        # unproved rather than passed, so a green total is never read as
        # covering it.
        print("SKIP  an intermittent test reads passed, failed or not run — no "
              "listed intermittent passed in this recording, so the case would "
              "prove nothing")
    else:
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
    timed_out = sorted(check.bundle_failures(base) - check.reported_failures(log))
    # A timed-out test that is not on any tolerated list must fail the run. Ones
    # that are listed are the next case, which checks the outcome they report.
    # A test killed at its allowance is a failure, full stop: it prints no result
    # line, so nothing but the bundle records it. Nothing excuses it — if a wait
    # survives the privacy grants, that is what the run must report.
    timeout_ok = bool(timed_out) and bool(
        check.check_failures(reported | set(timed_out), timed_out=set(timed_out))
    )
    if timed_out:
        print(f"{'PASS' if timeout_ok else 'FAIL'}  a timed-out test fails the run")
        results.append(timeout_ok)
    else:
        # Not a failure of the guard: this recording has nothing to exercise the
        # rule with. Reported as unproved rather than passed, so a green total is
        # never read as covering it.
        print("SKIP  a timed-out test fails the run — this recording has none, so "
              "the case would prove nothing; run it against a recording that does")

    if timed_out:
        # Listing a timed-out test as intermittent must not excuse it: the outcome
        # reported has to be the one that happened, and the run still fails. This
        # is what stops the tolerated list from becoming a way to hide a hang.
        victim = timed_out[0]
        check.FLAKY_TESTS[victim] = "added by this case"
        outcome = check.intermittent_outcome(
            victim, reported | {victim}, check.executed_tests(base)
        )
        still_fails = bool(
            check.check_failures(reported | {victim}, timed_out={victim})
        )
        del check.FLAKY_TESTS[victim]
        reports_failed = outcome == "failed" and still_fails
        print(f"{'PASS' if reports_failed else 'FAIL'}  "
              "a timed-out test reports failed, not passed or never run, and the "
              "intermittent list does not excuse it")
        if not reports_failed:
            print(f"        -> outcome was '{outcome}', still_fails was {still_fails}")
        results.append(reports_failed)

    # A known failure that this recording never ran is not one that passed. On an
    # unsigned build the keychain tests skip themselves, so a defect only visible
    # when signed is absent here — comparing against the whole list would call that
    # a change in the product when it is a property of the recording.
    executed = check.executed_tests(base)
    absent_known = {
        name for name in check.KNOWN_FAILURES
        if not any(name in t for t in executed)
    }
    saved_known = dict(check.KNOWN_FAILURES)
    for name in absent_known:
        del check.KNOWN_FAILURES[name]
    if absent_known:
        print("      not exercised by this recording, so not compared: "
              + ", ".join(sorted(absent_known)))

    # These two compare this recording's own failures against the lists. A
    # recording holding an unrecognised failure cannot prove them: the comparison
    # would be red for what the recording contains, not for what the guard does.
    baseline_clean = check.check_failures(reported) == []
    for name, ok in (
        ("a failure that is not a known failure fails the run",
         bool(check.check_failures(reported | {"SomethingTests/testNew()"}))),
    ):
        print(f"{'PASS' if ok else 'FAIL'}  {name}")
        results.append(ok)
    # "Stops failing fails the run" and "listed cannot excuse unlisted" must
    # not depend on what the real list holds: after the post-83 push the list
    # is empty for good, and cases that skip while it is empty would never run
    # again. So both run against a name the test itself puts on the list,
    # restoring the list afterwards.
    synthetic = "SomethingTests/testSyntheticallyListed()"
    saved_known_full = dict(check.KNOWN_FAILURES)
    check.KNOWN_FAILURES.clear()
    check.KNOWN_FAILURES.update({synthetic: "listed by this self-test, not a product defect"})
    ok = bool(check.check_failures(set()))
    print(f"{'PASS' if ok else 'FAIL'}  a listed failure that stops failing fails the run")
    results.append(ok)
    alone_accepted = check.check_failures({synthetic}) == []
    excused = check.check_failures({synthetic, "SomethingTests/testUnlisted()"}) == []
    check.KNOWN_FAILURES.clear()
    check.KNOWN_FAILURES.update(saved_known_full)
    ok = alone_accepted and not excused
    print(f"{'PASS' if ok else 'FAIL'}  a listed failure alone is accepted, and cannot excuse an unlisted one beside it")
    results.append(ok)
    # The acceptance codes are list-independent: exit_code takes the failure
    # sets it is given and does not consult KNOWN_FAILURES.
    for name, got, want in (
        ("the guard's acceptance code says no failures", check.exit_code([], set()), 0),
        ("the guard's acceptance code says failures, all listed",
         check.exit_code([], {synthetic}), 10),
        ("the guard's rejection code covers any unaccepted failure",
         check.exit_code(["x"], {synthetic}), 1),
    ):
        ok = got == want
        print(f"{'PASS' if ok else 'FAIL'}  {name} (got {got}, want {want})")
        results.append(ok)
    # This case only calls check_failures on a set, so it needs no recorded pass:
    # a synthetic entry added to the list (saved and restored, as for
    # KNOWN_FAILURES) exercises the tolerance whatever the recording holds.
    synthetic_flaky = "SelfTestSyntheticSuite/testIntermittentTolerance"
    saved_flaky = dict(check.FLAKY_TESTS)
    check.FLAKY_TESTS[synthetic_flaky] = "added by this case"
    flaky_tolerated = check.check_failures(reported | {synthetic_flaky}) == []
    check.FLAKY_TESTS.clear()
    check.FLAKY_TESTS.update(saved_flaky)
    for name, ok in (
        ("an intermittent test failing does not fail the run",
         flaky_tolerated),
        ("the recorded run's failures are all known",
         baseline_clean),
    ):
        if baseline_clean:
            print(f"{'PASS' if ok else 'FAIL'}  {name}")
            results.append(ok)
        else:
            print(f"SKIP  {name} — this recording holds an unrecognised failure, so "
                  "the comparison would be red for the recording, not for the guard")
    check.KNOWN_FAILURES.clear()
    check.KNOWN_FAILURES.update(saved_known)

    print(f"\n{sum(results)}/{len(results)} cases behaved as intended")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
