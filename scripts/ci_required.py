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
