#!/usr/bin/env python3
"""Comparable outcomes per task/arm and the rubric totals built from them.

A single row fixes both the consumer's compile/behavior state and the measured
dimensions, so aggregation and reporting cannot disagree about what a row
means. Totals keep raw sums and explicit denominators; nothing is re-scored.
"""

from __future__ import annotations

import sys
from typing import Any

sys.dont_write_bytecode = True
try:
    import agent_evaluation as evaluation
except ImportError:  # Package execution.
    from . import agent_evaluation as evaluation

try:
    from .agent_evaluation_capture import (
        Capture, answer_citations, digest_of, digest_text, require)
except ImportError:  # Direct script execution.
    from agent_evaluation_capture import (
        Capture, answer_citations, digest_of, digest_text, require)


def consumer_compile_state(receipt: dict | None, task: dict, record: dict) -> str:
    if receipt is None or receipt.get("state") == "pending":
        return "verification-outstanding"
    if receipt.get("state") == "compiled":
        return "compiled-without-requested-library" if (receipt.get("scopeBinding") or {}).get("state") == "unavailable" else "compiled"
    return {"compile-failed": "failed", "missing-code": "missing-code",
            "not-applicable": "not-applicable"}.get(receipt.get("state"), "verification-outstanding")


def consumer_behavior_state(task: dict, record: dict, receipt: dict | None,
                           assessment: dict | None) -> str:
    if not task["behaviorRequired"]:
        return "not-required"
    if receipt is None or receipt.get("state") == "pending":
        return "verification-outstanding"
    if receipt.get("state") == "missing-code":
        return "failure-missing-code"
    if receipt.get("state") != "compiled":
        return "not-verified-compile-failed"
    behavior = receipt.get("behavior") or {}
    if behavior.get("state") != "runtime-executed":
        return "not-verified-no-runtime"
    run = behavior.get("run") or {}
    if run.get("timedOut"):
        return "runtime-timeout"
    if run.get("launchError") or run.get("exitCode") != 0:
        return "runtime-failed"
    if not assessment:
        return "runtime-executed-behavior-unverified"
    review = assessment.get("behaviorReview") or {}
    if review.get("verdict") == "inadequate":
        return "failed"
    if review.get("verdict") != "adequate" or review.get("coversTaskBoundaries") is not True:
        return "runtime-executed-behavior-unverified"
    assertions = assessment.get("behaviorAssertions") or []
    if not assertions:
        return "runtime-executed-behavior-unverified"
    verdicts = {item.get("verdict") for item in assertions}
    if "not-observed" in verdicts:
        return "failed"
    return "verified" if verdicts == {"observed"} else "runtime-executed-behavior-unverified"


COMPILE_FAILURE_STATES = ("missing-code", "failed", "verification-outstanding", "compiled-without-requested-library")
BEHAVIOR_FAILURE_STATES = ("runtime-timeout", "runtime-failed", "failed",
                           "failure-missing-code", "not-verified-compile-failed",
                           "not-verified-no-runtime")


def row_for(capture: Capture, task: dict, arm: str, receipt: dict | None,
            assessment: dict | None, assessment_errors: list[str],
            adjudicated: dict | None, protocol: dict) -> dict:
    record = capture.records[(task["id"], arm)]
    classification = evaluation.classify(record)
    compile_state = consumer_compile_state(receipt, task, record)
    valid_assessment = adjudicated if not assessment_errors else None
    behavior_state = consumer_behavior_state(task, record, receipt, valid_assessment)
    dimensions = valid_assessment.get("dimensions") if valid_assessment else {}
    tool_use = record.get("toolUse") or {}
    client = record.get("client") or {}
    answer = record.get("answer") or {}
    row = {
        "task": task["id"],
        "arm": arm,
        "ordinal": record.get("ordinal"),
        "armPosition": record.get("armPosition"),
        "scope": task.get("scope"),
        "behaviorRequired": task["behaviorRequired"],
        "record": {"path": (capture.record_paths[(task["id"], arm)]
                            .relative_to(capture.output).as_posix()),
                   "sha256": digest_of(capture.record_paths[(task["id"], arm)])},
        "model": {
            "outcome": classification["taskOutcome"],
            "causes": classification["causes"],
            "failureReasons": classification["failureReasons"],
            "clientError": classification["clientError"],
            "budgetFailure": classification["budgetFailure"],
            "budgetFailures": classification["budgetFailures"],
            "contractBreaches": classification["contractBreaches"],
            "answerMissing": classification["answerMissing"],
            "serverContact": classification["serverContact"],
            "recordedConsumerCompile": classification["consumerCompile"],
            "recordedConsumerBehavior": classification["consumerBehavior"],
        },
        "answer": {
            "present": bool(answer.get("present")),
            "missingFields": answer.get("missingFields"),
            "extraFields": answer.get("extraFields"),
            "parseError": answer.get("parseError"),
            "citations": len(answer_citations(record, protocol)),
            "consumerCodeBytes": len((answer.get("consumerCode") or "").encode("utf-8")),
            "consumerCode": answer.get("consumerCode") or "",
            "raw": answer.get("raw"),
            "rawSha256": digest_text(answer["raw"]) if isinstance(answer.get("raw"), str)
            else None,
        },
        "toolUse": {
            "calls": tool_use.get("calls"),
            "resultBytes": tool_use.get("resultBytes"),
            "elapsedMs": (client.get("process") or {}).get("elapsedMs"),
            "usage": client.get("usage"),
            "measurementGaps": record.get("measurementGaps") or [],
            "note": "copied from the captured record; never re-derived or deduplicated",
        },
        "consumer": {
            "compile": compile_state,
            "behavior": behavior_state,
            "receipt": None if receipt is None else {
                "task": receipt["task"], "arm": receipt["arm"],
                "state": receipt["state"],
                "consumerCodeSha256": receipt.get("consumerCodeSha256"),
                "packaging": receipt.get("packaging"),
                "dependencies": receipt.get("dependencies"),
                "projectLabel": receipt.get("projectLabel"),
                "compileExitCode": (receipt.get("compile") or {}).get("exitCode"),
                "compileTimedOut": (receipt.get("compile") or {}).get("timedOut"),
                "compileElapsedMs": (receipt.get("compile") or {}).get("elapsedMs"),
                "run": ((receipt.get("behavior") or {}).get("run") or None),
            },
            "failure": (receipt or {}).get("failure"),
        },
        "adjudication": {
            "state": ("complete" if adjudicated and not assessment_errors else
                      "missing" if adjudicated is None else "invalid"),
            "errors": assessment_errors,
            "requiredFacts": (adjudicated or {}).get("requiredFacts", []),
            "contractOmissions": (adjudicated or {}).get("contractOmissions"),
            "requiredFactDenominator": (adjudicated or {}).get(
                "requiredFactDenominator", len(task["requiredFacts"])),
            "citations": (adjudicated or {}).get("citations", []),
            "citationDenominator": (adjudicated or {}).get("citationDenominator", 0),
            "behaviorAssertions": (adjudicated or {}).get("behaviorAssertions", []),
            "behaviorReview": (adjudicated or {}).get("behaviorReview"),
            "apiSelection": _dimension_value(dimensions, "apiSelection"),
        },
        "dimensions": {
            "apiSelection": _api_value(dimensions),
            "wrongApiVersion": _count_value(dimensions, "wrongApiVersion"),
            "signatureAndNamedDefaults": _count_value(dimensions,
                                                     "signatureAndNamedDefaults"),
            "contractOmissions": (valid_assessment or {}).get("contractOmissions"),
            "sourceAndDocumentCitations": _citation_counts(valid_assessment),
            "uncertaintyPreservation": _score_value(dimensions,
                                                   "uncertaintyPreservation"),
            "readBytes": tool_use.get("resultBytes"),
            "toolCalls": tool_use.get("calls"),
            "elapsedMs": (client.get("process") or {}).get("elapsedMs"),
            "consumerCompile": compile_state,
            "consumerBehavior": behavior_state,
        },
    }
    return row


def _dimension_value(dimensions: dict, name: str) -> Any:
    entry = dimensions.get(name)
    return entry.get("value") if isinstance(entry, dict) else None


def _api_value(dimensions: dict) -> Any:
    value = _dimension_value(dimensions, "apiSelection")
    return value if value in (0, 1) else None


def _count_value(dimensions: dict, name: str) -> int | None:
    value = _dimension_value(dimensions, name)
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def _score_value(dimensions: dict, name: str) -> int | None:
    value = _dimension_value(dimensions, name)
    return value if value in (0, 1) else None


def _citation_counts(adjudicated: dict | None) -> dict:
    entries = (adjudicated or {}).get("citations") or []
    return {
        "verified": sum(1 for item in entries if item.get("verdict") == "verified"),
        "unverified": sum(1 for item in entries if item.get("verdict") == "unverified"),
        "rejected": sum(1 for item in entries if item.get("verdict") == "rejected"),
        "denominator": (adjudicated or {}).get("citationDenominator", 0),
    }


def aggregate(rows: list[dict], protocol: dict, rubric: dict) -> dict:
    """Every rubric dimension with raw sums and explicit denominators."""
    declare = protocol["scoreDimensions"]
    totals: dict[str, dict] = {}
    for arm in evaluation.ARMS:
        arm_rows = [row for row in rows if row["arm"] == arm]
        if not arm_rows:
            continue
        api_applicable = [row for row in arm_rows
                          if row["dimensions"]["apiSelection"] is not None]
        api_not_applicable = [row["task"] for row in arm_rows
                              if (row["adjudication"].get("apiSelection")
                                  == "not-applicable")]
        citations = [row["dimensions"]["sourceAndDocumentCitations"] for row in arm_rows]
        behavior_denominator = sum(1 for row in arm_rows
                                   if row["behaviorRequired"])
        compile_states: dict[str, int] = {}
        for row in arm_rows:
            state = row["dimensions"]["consumerCompile"]
            compile_states[state] = compile_states.get(state, 0) + 1
        behavior_states: dict[str, int] = {}
        for row in arm_rows:
            if row["behaviorRequired"]:
                state = row["dimensions"]["consumerBehavior"]
                behavior_states[state] = behavior_states.get(state, 0) + 1
        totals[arm] = {
            "tasks": len(arm_rows),
            "dimensions": {
                "apiSelection": {
                    "sum": sum(row["dimensions"]["apiSelection"] for row in api_applicable),
                    "scored": len(api_applicable),
                    "denominator": len(arm_rows),
                    "notApplicable": api_not_applicable,
                    "unadjudicated": [row["task"] for row in arm_rows
                                      if row["adjudication"]["state"] != "complete"],
                },
                "wrongApiVersion": {
                    "sum": sum(row["dimensions"]["wrongApiVersion"] or 0 for row in arm_rows),
                    "denominator": len(arm_rows),
                    "unit": "incorrect selected or cited API scope",
                },
                "signatureAndNamedDefaults": {
                    "sum": sum(row["dimensions"]["signatureAndNamedDefaults"] or 0
                               for row in arm_rows),
                    "denominator": len(arm_rows),
                    "unit": "required signature fact",
                },
                "contractOmissions": {
                    "sum": sum(row["dimensions"]["contractOmissions"] or 0
                               for row in arm_rows),
                    "requiredFactDenominator": sum(row["adjudication"].get(
                        "requiredFactDenominator") or 0 for row in arm_rows),
                    "unit": "requiredFacts item",
                },
                "sourceAndDocumentCitations": {
                    "verified": sum(item["verified"] for item in citations),
                    "unverified": sum(item["unverified"] for item in citations),
                    "rejected": sum(item["rejected"] for item in citations),
                    "denominator": sum(item["denominator"] for item in citations),
                },
                "uncertaintyPreservation": {
                    "sum": sum(row["dimensions"]["uncertaintyPreservation"] or 0
                               for row in arm_rows),
                    "denominator": len(arm_rows),
                },
                "readBytes": _measured(arm_rows, "readBytes"),
                "toolCalls": _measured(arm_rows, "toolCalls"),
                "elapsedMs": _measured(arm_rows, "elapsedMs"),
                "consumerCompile": {
                    "compiled": compile_states.get("compiled", 0),
                    "failed": compile_states.get("failed", 0),
                    "missingCode": compile_states.get("missing-code", 0),
                    "notApplicable": compile_states.get("not-applicable", 0),
                    "outstanding": compile_states.get("verification-outstanding", 0),
                    "denominator": len(arm_rows),
                    "unit": "generated consumer",
                },
                "consumerBehavior": {
                    "verified": behavior_states.get("verified", 0),
                    "unverified": behavior_states.get(
                        "runtime-executed-behavior-unverified", 0),
                    "failed": sum(behavior_states.get(state, 0)
                                  for state in BEHAVIOR_FAILURE_STATES),
                    "outstanding": behavior_states.get("verification-outstanding", 0),
                    # Denominator is the behaviorRequired rows only, so a task that
                    # correctly declines code is excluded here and counted under
                    # consumerCompile as not-applicable instead.
                    "denominator": behavior_denominator,
                    "unit": "behaviorRequired consumer",
                },
            },
        }
    missing = [name for name in declare
               if name not in totals[next(iter(totals))]["dimensions"]] if totals else []
    require(not missing, "aggregate is missing rubric dimensions: " + ", ".join(missing))
    return totals


def _measured(rows: list[dict], key: str) -> dict:
    values = [row["dimensions"][key] for row in rows
              if isinstance(row["dimensions"].get(key), (int, float))
              and not isinstance(row["dimensions"][key], bool)]
    unmeasured = [row["task"] for row in rows
                  if not isinstance(row["dimensions"].get(key), (int, float))
                  or isinstance(row["dimensions"].get(key), bool)]
    return {"sum": sum(values), "measuredTasks": len(values),
            "denominator": len(rows), "unmeasured": unmeasured}
