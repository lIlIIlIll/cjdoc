#!/usr/bin/env python3
"""Fail the fixed-name aggregate gate unless every planned job really succeeded.

The gate is the only required check name. It re-reads the raw `needs` results and
the routing plan: a job that was planned and did not report `success` fails the
gate, including `skipped`, because a skip is indistinguishable from a silently
dropped requirement. Jobs the plan marked as not applicable may be `skipped`.

This script only reads. It never edits branch protections or workflow files.
"""

from __future__ import annotations

import argparse
import json
import sys

sys.dont_write_bytecode = True

PLANNED_JOBS = ("changes", "candidate-linux", "linux-acceptance", "candidate-other")


def workflow_problems(document: object) -> list[str]:
    """Compare `PLANNED_JOBS` with the aggregate gate's real `needs`.

    The constant and `.github/workflows/ci.yml` describe the same thing twice, and
    nothing used to bind them: a job added to the workflow's `required.needs` (or
    removed from the workflow while the constant stayed) drifted silently. The
    document is passed in already parsed so this module stays stdlib-only; the
    contract test parses the workflow with a real YAML parser and asserts an empty
    result.
    """
    if not isinstance(document, dict):
        return ["workflow: not a mapping"]
    jobs = document.get("jobs")
    if not isinstance(jobs, dict):
        return ["workflow: no `jobs` mapping"]
    gate = jobs.get("required")
    if not isinstance(gate, dict):
        return ["workflow: no `required` job"]
    needs = gate.get("needs")
    if isinstance(needs, str):
        names = [needs]
    elif isinstance(needs, list) and all(isinstance(name, str) for name in needs):
        names = list(needs)
    else:
        return ["workflow: `required` has no usable `needs` list"]
    planned = set(PLANNED_JOBS)
    problems: list[str] = []
    # Removed or misspelled jobs first: a name the workflow waits for that no longer
    # exists means the gate would never report at all, which is worse than a drift.
    problems += [f"{name}: listed in required.needs but ci.yml defines no such job"
                 for name in names if name not in jobs]
    problems += [f"{name}: required gate waits for a job PLANNED_JOBS does not list"
                 for name in sorted(set(names) - planned)]
    problems += [f"{name}: PLANNED_JOBS lists a job the required gate does not wait for"
                 for name in sorted(planned - set(names))]
    problems += [f"{name}: PLANNED_JOBS names a job ci.yml does not define"
                 for name in sorted(planned - set(jobs))]
    if "required" in planned:
        problems.append("required: the aggregate gate cannot gate itself")
    return problems


def needs_results(raw: str) -> dict[str, dict[str, object]]:
    try:
        value = json.loads(raw)
    except ValueError as error:
        raise SystemExit(f"ci_required.py: --outcome-json is not JSON: {error}")
    if not isinstance(value, dict):
        raise SystemExit("ci_required.py: --outcome-json must be an object")
    return value


def planned_set(plan_raw: str) -> tuple[set[str], set[str], str]:
    """Return (planned jobs, routable jobs, basis).

    A job that the plan cannot route (the classifier itself) is always required.
    """
    routable = set(PLANNED_JOBS) - {"changes"}
    if not plan_raw:
        return set(PLANNED_JOBS), routable, "no plan supplied; requiring every gated job"
    try:
        plan = json.loads(plan_raw)
    except ValueError as error:
        raise SystemExit(f"ci_required.py: --plan is not JSON: {error}")
    if plan.get("mode") != "classified":
        return set(PLANNED_JOBS), routable, "plan is not classified; requiring every gated job"
    job_set = plan.get("jobSet")
    if not isinstance(job_set, dict) or set(job_set) != routable:
        raise SystemExit("ci_required.py: plan jobSet does not cover the routable jobs")
    needed = {name for name, required in job_set.items() if required} | {"changes"}
    return needed, routable, "classified plan"


def evaluate(outcomes: dict[str, dict[str, object]], planned: set[str],
             routable: set[str]) -> list[str]:
    problems: list[str] = []
    # Fail closed on a dependency this module was never taught about: `needs` is the
    # workflow's real list, so an unlisted name means the gate is judging a graph it
    # does not know. Ignoring it is what let a new `required` dependency ship
    # unenforced.
    problems += [f"{job}: reported in the needs graph but PLANNED_JOBS does not list it"
                 for job in sorted(set(outcomes) - set(PLANNED_JOBS))]
    for job in PLANNED_JOBS:
        outcome = outcomes.get(job)
        if outcome is None:
            if job in planned:
                problems.append(f"{job}: planned but missing from the needs graph")
            continue
        result = outcome.get("result")
        if job in planned or job not in routable:
            if result != "success":
                problems.append(f"{job}: required job reported {result!r}")
        elif result not in {"success", "skipped"}:
            problems.append(f"{job}: unplanned job reported {result!r}")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--outcome-json", required=True)
    parser.add_argument("--plan", default="")
    args = parser.parse_args()
    planned, routable, basis = planned_set(args.plan)
    problems = evaluate(needs_results(args.outcome_json), planned, routable)
    if problems:
        for problem in problems:
            print(f"CI required gate failed: {problem}", file=sys.stderr)
        return 1
    print(f"CI required gate passed ({basis}; required={sorted(planned)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
