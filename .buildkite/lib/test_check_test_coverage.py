#!/usr/bin/env python3
"""Proof that the coverage guard fails when coverage is missing.

A guard that has only ever been seen passing is indistinguishable from one that
cannot fail. Each case here removes something the guard is supposed to notice and
asserts it does, using the same functions the CI step calls.

Run: python3 .buildkite/lib/test_check_test_coverage.py
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


def real_report():
    """A report from an actual run, so the tree shape is Xcode's and not invented.

    Newest by modification time: a lexical sort would pick whichever build number
    sorts last, which is not the run that just happened.
    """
    bundles = list((REPO / "artifacts").glob("*.xcresult"))
    if not bundles:
        sys.exit("no result bundle in artifacts/; run the pipeline first")
    newest = max(bundles, key=lambda b: b.stat().st_mtime)
    return check.read_report(str(newest))


def run_guard(report, plan_text):
    with tempfile.TemporaryDirectory() as tmp:
        plan = Path(tmp) / "plan.xctestplan"
        plan.write_text(plan_text)
        return check.check_coverage(check.count_tests(report), plan)


PLAN = (REPO / "PocketCastsTests" / "UnitTests.xctestplan").read_text()


def case(name, report, plan_text, expect_failure):
    failures = run_guard(report, plan_text)
    failed = bool(failures)
    ok = failed == expect_failure
    print(f"{'PASS' if ok else 'FAIL'}  {name}")
    for f in failures:
        print(f"        -> {f}")
    return ok


def main():
    base = real_report()
    results = []

    results.append(case("unmodified run passes", base, PLAN, expect_failure=False))

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

    print(f"\n{sum(results)}/{len(results)} cases behaved as intended")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
