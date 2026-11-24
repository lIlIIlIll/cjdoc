#!/usr/bin/env python3
"""What each measured run is, and the raw report built from all of them.

A record is classified along independent dimensions, so no nearby success can
upgrade a failure: a budget breach, a client error, a missing structured answer
or a session that never reached its documentation server each fail the task on
their own. Compilation and behavior stay pending until the parent's real
compiler run. The report keeps raw sums with explicit denominators and never
selects a best run.
"""

from __future__ import annotations

import sys
from typing import Any

sys.dont_write_bytecode = True

RECORD_NAME = "record.json"
CONSUMER_COMPILE_STATES = ("pending-parent-compile", "missing-code", "not-applicable")
FAILURE_CAUSES = ("client-error", "contract-breach", "no-server-contact",
                  "budget", "answer-missing", "missing-consumer-code")
BUDGET_FAILURE_KINDS = ("toolCalls", "documentBytes", "relayRefusal", "seconds")


def _server_contact_missing(contact: dict) -> bool:
    """True when this session never reached the server it was meant to evaluate."""
    return not (contact.get("transportAvailable")
                and contact.get("initialized")
                and contact.get("toolsListed")
                and not contact.get("missingTools"))


def _consumer_states(answer: dict, behavior_required: bool) -> tuple[str, str]:
    """The compile/behavior state a consumer's presence can justify, and no more."""
    has_code = isinstance(answer.get("consumerCode"), str) and answer["consumerCode"] != ""
    if has_code:
        return ("pending-parent-compile",
                "pending-parent-verification" if behavior_required else "not-required")
    if behavior_required:
        return "missing-code", "not-applicable-without-code"
    return "not-applicable", "not-required"


def _outcome_facts(record: dict) -> dict:
    """Every independent failure dimension of one record, from the record alone."""
    client = record["client"]
    answer = record["answer"]
    timed_out = bool(client["process"]["timedOut"])
    exit_code = client["process"]["exitCode"]
    # Every arm documents itself through its own MCP server. A session that never
    # reached that server did not perform the arm under evaluation, whatever the
    # client event log claims.
    contact = record["toolUse"].get("serverContact") or {}
    compile_state, behavior_state = _consumer_states(answer,
                                                     record["task"]["behaviorRequired"])
    return {
        "client": client,
        "answer": answer,
        "timedOut": timed_out,
        "exitCode": exit_code,
        "clientError": timed_out or exit_code != 0 or not client["threadId"],
        "budgetFailure": bool(record.get("budgetExceeded")),
        "missingAnswer": not answer["present"],
        "contact": contact,
        "noServerContact": _server_contact_missing(contact),
        "compileState": compile_state,
        "behaviorState": behavior_state,
    }


def _failure_causes(record: dict, facts: dict) -> list[str]:
    """Independent causes, in the order the frozen policy reports them."""
    causes = []
    if facts["clientError"]:
        causes.append("client-error")
    if facts["budgetFailure"]:
        causes.append("budget")
    if facts["missingAnswer"]:
        causes.append("answer-missing")
    if record.get("contractBreaches"):
        causes.append("contract-breach")
    if facts["noServerContact"]:
        causes.append("no-server-contact")
    if facts["compileState"] == "missing-code":
        causes.append("missing-consumer-code")
    return causes


def _failure_reasons(record: dict, facts: dict) -> list[str]:
    """Human-readable reasons, aligned with the causes this record actually has."""
    client, answer, contact = facts["client"], facts["answer"], facts["contact"]
    reasons = []
    if facts["timedOut"]:
        reasons.append(f"client exceeded the {record['budgets']['maximumSecondsPerTask']}s budget")
    if facts["exitCode"] != 0 and not facts["timedOut"]:
        reasons.append(f"client exited with {facts['exitCode']}")
    if not client["threadId"]:
        reasons.append("client never started a session")
    if facts["budgetFailure"]:
        reasons.append("fixed budget exceeded: " + "; ".join(
            f"{failure['kind']} limit {failure['limit']} observed {failure['observed']}"
            for failure in record.get("budgetFailures") or
            [{"kind": kind, "limit": "frozen", "observed": "recorded"}
             for kind in record["budgetExceeded"]]))
    if facts["missingAnswer"]:
        reasons.append(answer["parseError"] or "no structured answer")
    for breach in record.get("contractBreaches") or []:
        reasons.append(f"{breach['kind']} violated: {breach['rule']} "
                       f"(observed {breach['observed']})")
    if facts["noServerContact"]:
        missing = contact.get("missingTools") or []
        if not contact.get("transportAvailable"):
            reasons.append("the documentation server produced no stdio transcript")
        elif not contact.get("initialized") or not contact.get("toolsListed"):
            reasons.append("the documentation server was never initialized or listed")
        else:
            reasons.append("the documentation server did not advertise: "
                           + ", ".join(missing))
    if facts["compileState"] == "missing-code":
        reasons.append("no consumer code where the task requires generated code")
    return reasons


def classify(record: dict) -> dict:
    """Separate every outcome; no dimension is upgraded by a nearby success.

    A budget failure is a task failure (`budgetFailureIsTaskFailure`), and so is a
    client error or a missing structured answer. Compilation and behavior are not
    inferred here: they stay pending until the parent's real compiler run, and a
    task that correctly declines code is not-applicable rather than compile-pass.
    """
    facts = _outcome_facts(record)
    causes = _failure_causes(record, facts)
    return {
        "taskOutcome": "failed" if causes else "completed",
        "primaryCause": causes[0] if causes else "none",
        "causes": causes,
        "failureReasons": _failure_reasons(record, facts),
        "clientError": facts["clientError"],
        "serverContact": facts["contact"],
        "budgetFailure": facts["budgetFailure"],
        "budgetFailures": record.get("budgetFailures") or [],
        "contractBreaches": record.get("contractBreaches") or [],
        "answerMissing": facts["missingAnswer"],
        "consumerCompile": facts["compileState"],
        "consumerBehavior": facts["behaviorState"],
        "adjudication": "unadjudicated",
    }


def report_row(record: dict) -> dict:
    """One report row: the same record the outcome was classified from."""
    return {
        "task": record["task"]["id"],
        "arm": record["arm"],
        "ordinal": record["ordinal"],
        "armPosition": record["armPosition"],
        "record": record["session"]["relativeToOutput"] + "/" + RECORD_NAME,
        "outcome": classify(record),
        "toolCalls": record["toolUse"]["calls"],
        "resultBytes": record["toolUse"]["resultBytes"],
        "elapsedMs": record["client"]["process"].get("elapsedMs"),
        "timedOut": record["client"]["process"]["timedOut"],
        "usage": record["client"]["usage"],
        "answerPresent": record["answer"]["present"],
        "missingAnswerFields": record["answer"]["missingFields"],
        "consumerCodeBytes": len(record["answer"]["consumerCode"].encode("utf-8")),
        "serverKind": record["session"].get("serverKind"),
        "serverContact": record["toolUse"]["serverContact"],
        "requiredFacts": [
            {"fact": fact, "verdict": None, "evidence": []}
            for fact in record["task"]["requiredFacts"]
        ],
    }


def _metric_sum(rows: list[dict], key: str) -> tuple[float, int]:
    """Report a raw sum with its denominator; unmeasured values are excluded."""
    values = [row[key] for row in rows
              if isinstance(row.get(key), (int, float)) and not isinstance(row[key], bool)]
    return sum(values), len(values)


def arm_totals(arm_rows: list[dict]) -> dict:
    """Raw additive totals for one arm, each with the number of measured tasks."""
    calls, calls_measured = _metric_sum(arm_rows, "toolCalls")
    byte_total, bytes_measured = _metric_sum(arm_rows, "resultBytes")
    elapsed, elapsed_measured = _metric_sum(arm_rows, "elapsedMs")
    return {
        "attempted": len(arm_rows),
        "completed": sum(1 for row in arm_rows
                         if row["outcome"]["taskOutcome"] == "completed"),
        "failed": sum(1 for row in arm_rows if row["outcome"]["taskOutcome"] == "failed"),
        "failedByCause": {
            cause: sum(1 for row in arm_rows if cause in row["outcome"]["causes"])
            for cause in FAILURE_CAUSES
        },
        "budgetFailures": {
            kind: sum(1 for row in arm_rows
                      if any(failure["kind"] == kind
                             for failure in row["outcome"]["budgetFailures"]))
            for kind in BUDGET_FAILURE_KINDS
        },
        "serverContactFailures": [
            row["task"] for row in arm_rows
            if _server_contact_missing(row["serverContact"])
        ],
        "toolCalls": {"total": calls, "measuredTasks": calls_measured},
        "resultBytes": {"total": byte_total, "measuredTasks": bytes_measured},
        "elapsedMs": {"total": elapsed, "measuredTasks": elapsed_measured},
        "consumerCompile": {
            state: sum(1 for row in arm_rows if row["outcome"]["consumerCompile"] == state)
            for state in CONSUMER_COMPILE_STATES
        },
        "adjudicatedTasks": 0,
        "adjudicationDenominator": len(arm_rows),
    }


def _completeness(rows: list[dict], protocol: dict, arms: tuple[str, ...]) -> dict:
    return {
        "frozenTasks": len(protocol["tasks"]),
        "frozenArms": len(arms),
        "observedRuns": len(rows),
        "completePair": (
            {row["task"] for row in rows} == {task["id"] for task in protocol["tasks"]}
            and {row["arm"] for row in rows} == set(arms)
            and all(sum(1 for row in rows
                        if row["task"] == task["id"] and row["arm"] == arm) == 1
                    for task in protocol["tasks"] for arm in arms)),
        "repetitionsPerTaskPerPath": 1,
    }


def _measurement_gaps(records: list[dict]) -> dict:
    """Name every task/arm where a measurement itself is missing, by gap."""
    gaps = sorted({gap for record in records for gap in record.get("measurementGaps", [])})
    return {gap: [record["task"]["id"] + ":" + record["arm"]
                  for record in records
                  if gap in record.get("measurementGaps", [])]
            for gap in gaps}


def _selection(rows: list[dict]) -> dict:
    return {
        "bestOf": False,
        "retries": 0,
        "retainedFailures": [row["task"] + ":" + row["arm"] for row in rows
                             if row["outcome"]["taskOutcome"] == "failed"],
    }


def _scoring(protocol: dict) -> dict:
    return {
        "state": "unadjudicated",
        "reason": ("deterministic identity, signature, citation and compile evidence require "
                   "the parent's real compiler run and per-required-fact adjudication; this "
                   "report records observations only and assigns no score"),
        "dimensions": {name: {"state": "not-adjudicated"}
                       for name in protocol["scoreDimensions"]},
        "requiredFactVerdicts": "null until adjudicated",
        "naturalLanguageScoring": "unadjudicated",
    }


def _consumer_compile(rows: list[dict]) -> dict:
    pending = [row["task"] + ":" + row["arm"] for row in rows
               if row["outcome"]["consumerCompile"] == "pending-parent-compile"]
    return {
        "state": "pending-parent-verification" if pending else "nothing-to-compile",
        "pending": pending,
        "notApplicableTasks": [row["task"] + ":" + row["arm"] for row in rows
                               if row["outcome"]["consumerCompile"] == "not-applicable"],
        "missingConsumerCode": [row["task"] + ":" + row["arm"] for row in rows
                                if row["outcome"]["consumerCompile"] == "missing-code"],
    }


def aggregate(records: list[dict], protocol: dict, rubric: dict, options: Any,
              manifest: dict) -> dict:
    """The raw observations report; the frozen protocol names the arm pair."""
    arms = tuple(protocol["comparison"]["paths"])
    rows = [report_row(record) for record in records]
    totals = {}
    for arm in arms:
        arm_rows = [row for row in rows if row["arm"] == arm]
        if arm_rows:
            totals[arm] = arm_totals(arm_rows)
    return {
        "schemaVersion": "cjdoc.agent-evaluation-report/1",
        "status": "raw-observations",
        "claim": rubric.get("claim"),
        "denominator": rubric.get("taskDenominator"),
        "manifest": manifest,
        "budgets": options.budgets,
        "arms": list(arms),
        "taskOrder": "task-id-ascending; alternate path order by task ordinal",
        "completeness": _completeness(rows, protocol, arms),
        "reportPerTask": True,
        "keepBothArmFailures": True,
        "measurementGaps": _measurement_gaps(records),
        "records": rows,
        "totals": totals,
        "selection": _selection(rows),
        "scoring": _scoring(protocol),
        "consumerCompile": _consumer_compile(rows),
    }
