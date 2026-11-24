#!/usr/bin/env python3
"""Adjudication policy: what a reviewer must supply and what invalidates a claim.

The rules here decide whether a submitted assessment is admissible. They are
deliberately separate from capture and compilation: a stage may reuse them
without rebuilding consumers, and an invalid assessment can never promote a
consumer to verified behavior or a selected API.
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
        Capture, answer_citations, digest_text, parsed_answer)
    from .agent_evaluation_evidence import Evidence
except ImportError:  # Direct script execution.
    from agent_evaluation_capture import (
        Capture, answer_citations, digest_text, parsed_answer)
    from agent_evaluation_evidence import Evidence

ADJUDICATION_SCHEMA = "cjdoc.agent-evaluation-adjudication/1"
ADJUDICATED_DIMENSIONS = ("apiSelection", "wrongApiVersion",
                          "signatureAndNamedDefaults", "uncertaintyPreservation")
IDENTITY_DIMENSIONS = ("apiSelection", "wrongApiVersion", "signatureAndNamedDefaults")
FACT_VERDICTS = ("supported", "contradicted", "omitted")
CITATION_VERDICTS = ("verified", "unverified", "rejected")
ASSERTION_VERDICTS = ("observed", "not-observed", "unverified")
EVIDENCE_KINDS = ("source", "doc-ir", "answer")


def check_dimension(name: str, entry: Any, where: str,
                    evidence: Evidence, task: dict) -> list[str]:
    if not isinstance(entry, dict):
        return [f"{where}: dimension {name} must be an object"]
    problems = []
    items = entry.get("evidence")
    if not isinstance(items, list) or not items:
        problems.append(f"{where}: dimension {name} needs explicit evidence")
        items = []
    for position, item in enumerate(items):
        problems.extend(evidence.check(item, f"{where}: dimension {name} evidence[{position}]"))
    kinds = {item.get("kind") for item in items if isinstance(item, dict)}
    if name in IDENTITY_DIMENSIONS and not ({"source", "doc-ir"} & kinds):
        problems.append(f"{where}: dimension {name} is an identity judgment and needs "
                        "source or Doc IR evidence")
    value = entry.get("value")
    if name == "apiSelection":
        if not (type(value) is int and value in (0, 1) or value == "not-applicable"):
            problems.append(f"{where}: apiSelection value must be 1, 0 or not-applicable")
        if value == "not-applicable" and not str(entry.get("reason") or "").strip():
            problems.append(f"{where}: apiSelection not-applicable needs a reason")
        if value == 1 and not evidence.selects_primary(items, task):
            problems.append(where + ": API selection evidence does not bind the requested primary library/version")
    elif name == "uncertaintyPreservation":
        if type(value) is not int or value not in (0, 1):
            problems.append(f"{where}: uncertaintyPreservation value must be 1 or 0")
    else:
        if not (isinstance(value, int) and not isinstance(value, bool) and value >= 0):
            problems.append(f"{where}: {name} value must be a non-negative count")
    return problems


def check_assertion_evidence(item: Any, behavior: dict, where: str) -> list[str]:
    if not isinstance(item, dict):
        return [f"{where}: assertion evidence must be an object"]
    kind = item.get("kind")
    run = behavior.get("run") or {}
    if kind == "stdout":
        quote = item.get("quote")
        text = (run.get("stdout") or {}).get("text") or ""
        if not isinstance(quote, str) or not quote.strip() or quote not in text:
            return [f"{where}: stdout quote does not occur in the captured consumer output"]
        return []
    if kind == "stderr":
        quote = item.get("quote")
        text = (run.get("stderr") or {}).get("text") or ""
        if not isinstance(quote, str) or not quote.strip() or quote not in text:
            return [f"{where}: stderr quote does not occur in the captured consumer output"]
        return []
    if kind == "exit-code":
        expected = item.get("exitCode")
        if type(expected) is not int or expected != run.get("exitCode"):
            return [f"{where}: claimed exit code {expected!r} is not the observed "
                    f"{run.get('exitCode')!r}"]
        return []
    return [f"{where}: assertion evidence kind must be stdout, stderr or exit-code"]


def check_behavior_review(review: Any, code: str, where: str) -> list[str]:
    if not isinstance(review, dict):
        return [where + ": runtime behavior requires a separate source/control-flow review"]
    problems = []
    if review.get("method") != "manual-source-and-control-flow-audit":
        problems.append(where + ": behavior review must identify its manual audit boundary")
    if review.get("consumerCodeSha256") != digest_text(code):
        problems.append(where + ": behavior review describes different consumer bytes")
    if review.get("verdict") not in ("adequate", "inadequate", "unverified"):
        problems.append(where + ": behavior review verdict is invalid")
    quote = review.get("codeQuote")
    if not isinstance(quote, str) or not quote.strip() or quote not in code:
        problems.append(where + ": behavior review needs an actual consumer-code excerpt")
    if not isinstance(review.get("reason"), str) or not review["reason"].strip():
        problems.append(where + ": behavior review needs its source-backed adequacy rationale")
    if review.get("verdict") == "adequate" and review.get("coversTaskBoundaries") is not True:
        problems.append(where + ": an adequate review must cover the frozen task boundaries")
    return problems


def check_behavior_assertion(item: Any, code: str, behavior: dict,
                             evidence: Evidence, where: str) -> list[str]:
    if not isinstance(item, dict):
        return [where + ": assertion must be an object"]
    problems = []
    if not isinstance(item.get("assertion"), str) or not item["assertion"].strip():
        problems.append(where + ": assertion text is required")
    if item.get("verdict") not in ASSERTION_VERDICTS:
        problems.append(where + ": assertion verdict is invalid")
    for field in ("exerciseCode", "checkCode"):
        quote = item.get(field)
        if not isinstance(quote, str) or not quote.strip() or quote not in code:
            problems.append(where + ": " + field + " must quote the exact consumer program")
    sources = item.get("sourceEvidence")
    if not isinstance(sources, list) or not sources:
        problems.append(where + ": behavior assertion needs implementation-source evidence")
        sources = []
    for index, source in enumerate(sources):
        if not isinstance(source, dict) or source.get("kind") != "source":
            problems.append(where + ": implementation evidence must name frozen source")
        else:
            problems.extend(evidence.check(source, where + ":source[" + str(index) + "]"))
    problems.extend(check_assertion_evidence(item.get("evidence"), behavior, where))
    return problems


def _check_facts(facts: Any, task: dict, raw_text: str, has_answer: bool,
                 evidence: Evidence, where: str) -> tuple[list[str], list[dict]]:
    problems: list[str] = []
    frozen = list(task["requiredFacts"])
    summaries = []
    if not isinstance(facts, list):
        problems.append(f"{where}: requiredFacts must be a list")
        facts = []
    seen: dict[str, int] = {}
    for position, item in enumerate(facts):
        entry_where = f"{where}: requiredFacts[{position}]"
        if not isinstance(item, dict):
            problems.append(f"{entry_where}: must be an object")
            continue
        fact = item.get("fact")
        if fact not in frozen:
            problems.append(f"{entry_where}: {fact!r} is not a frozen required fact")
            continue
        if fact in seen:
            problems.append(f"{entry_where}: duplicate judgment for {fact!r}")
            continue
        seen[fact] = position
        verdict = item.get("verdict")
        if verdict not in FACT_VERDICTS:
            problems.append(f"{entry_where}: verdict must be one of {list(FACT_VERDICTS)}")
        quote = item.get("answerQuote")
        if has_answer:
            if not isinstance(quote, str) or not quote.strip():
                problems.append(f"{entry_where}: supported/contradicted/omitted judgments "
                                "need a verbatim answer quote")
            elif quote not in raw_text:
                problems.append(f"{entry_where}: answer quote does not occur verbatim in "
                                "the captured answer")
        else:
            if quote not in (None, ""):
                problems.append(f"{entry_where}: there is no captured answer to quote")
            if verdict != "omitted":
                problems.append(f"{entry_where}: without a captured answer the fact "
                                "can only be omitted")
        items = item.get("evidence")
        if verdict in ("supported", "contradicted"):
            if not isinstance(items, list) or not items:
                problems.append(f"{entry_where}: {verdict} needs source/Doc IR evidence")
                items = []
        elif items is None:
            items = []
        elif not isinstance(items, list):
            problems.append(f"{entry_where}: evidence must be a list")
            items = []
        for index, item_evidence in enumerate(items):
            problems.extend(evidence.check(item_evidence,
                                           f"{entry_where}: evidence[{index}]"))
        summaries.append({"fact": fact, "verdict": verdict,
                          "answerQuote": quote if isinstance(quote, str) else "",
                          "evidence": items})
    missing = [fact for fact in frozen if fact not in seen]
    if missing:
        problems.append(f"{where}: no judgment for frozen facts: "
                        + "; ".join(missing))
    return problems, summaries


def _check_citations(judged: Any, citations: list[Any],
                     evidence: Evidence, where: str) -> tuple[list[str], list[dict]]:
    problems: list[str] = []
    summaries = []
    if not isinstance(judged, list):
        problems.append(f"{where}: citations must be a list (may be empty)")
        judged = []
    indices = []
    for position, item in enumerate(judged):
        entry_where = f"{where}: citations[{position}]"
        if not isinstance(item, dict):
            problems.append(f"{entry_where}: must be an object")
            continue
        index = item.get("index")
        if not (isinstance(index, int) and not isinstance(index, bool)):
            problems.append(f"{entry_where}: index must be an integer")
            continue
        if not (0 <= index < len(citations)):
            problems.append(f"{entry_where}: index {index} is outside the "
                            f"{len(citations)} captured citations")
            continue
        if index in indices:
            problems.append(f"{entry_where}: duplicate judgment for citation {index}")
            continue
        indices.append(index)
        verdict = item.get("verdict")
        if verdict not in CITATION_VERDICTS:
            problems.append(f"{entry_where}: verdict must be one of "
                            f"{list(CITATION_VERDICTS)}")
        items = item.get("evidence")
        if verdict in ("verified", "rejected"):
            if not isinstance(items, list) or not items:
                problems.append(f"{entry_where}: {verdict} citations need evidence")
                items = []
        elif items is None:
            items = []
        elif not isinstance(items, list):
            problems.append(f"{entry_where}: evidence must be a list")
            items = []
        for offset, item_evidence in enumerate(items):
            problems.extend(evidence.check(item_evidence,
                                           f"{entry_where}: evidence[{offset}]"))
        summaries.append({"index": index, "verdict": verdict,
                          "evidence": items,
                          "citation": citations[index]})
    absent = [index for index in range(len(citations)) if index not in indices]
    if absent:
        problems.append(f"{where}: citations not judged: "
                        + ", ".join(str(index) for index in absent))
    return problems, summaries


def _check_dimensions(dimensions: Any, task: dict,
                      evidence: Evidence, where: str) -> tuple[list[str], dict]:
    problems: list[str] = []
    if not isinstance(dimensions, dict):
        problems.append(f"{where}: dimensions must be an object")
        dimensions = {}
    for name in ADJUDICATED_DIMENSIONS:
        problems.extend(check_dimension(name, dimensions.get(name), where, evidence, task))
    extra_dimensions = sorted(set(dimensions) - set(ADJUDICATED_DIMENSIONS))
    if extra_dimensions:
        problems.append(f"{where}: measured dimensions must not be adjudicated: "
                        + ", ".join(extra_dimensions))
    return problems, dimensions


def _check_behavior(assertions: Any, review: Any, task: dict, behavior: dict,
                    parsed: dict, evidence: Evidence,
                    where: str) -> tuple[list[str], list[dict]]:
    problems: list[str] = []
    summaries = []
    if task["behaviorRequired"] and behavior.get("state") == "runtime-executed":
        body = parsed.get("json") or {}
        code = body.get("consumerCode", "")
        code = code if isinstance(code, str) else ""
        problems.extend(check_behavior_review(review, code, where))
        if not isinstance(assertions, list):
            problems.append(where + ": behaviorAssertions must be a list")
            assertions = []
        if isinstance(review, dict) and review.get("verdict") == "adequate" and not assertions:
            problems.append(where + ": an adequate behavior claim needs executed boundary checks")
        for position, item in enumerate(assertions):
            problems.extend(check_behavior_assertion(item, code, behavior, evidence,
                where + ":behaviorAssertions[" + str(position) + "]"))
            if isinstance(item, dict):
                summaries.append(item)
    elif assertions not in (None, []) and not isinstance(assertions, list):
        problems.append(where + ": behaviorAssertions must be a list")
    return problems, summaries


def validate_assessment(assessment: Any, task: dict, arm: str, record: dict,
                        protocol: dict, behavior: dict, evidence: Evidence,
                        where: str) -> tuple[list[str], dict | None]:
    """Validate one (task, arm) assessment completely; return gaps and a summary.

    Each section is checked in submission order and appends its own gaps, so the
    reported list stays in the same sequence as the assessment document.
    """
    if not isinstance(assessment, dict):
        return [f"{where}: assessment must be an object"], None
    parsed = parsed_answer(record, protocol)
    raw = (record.get("answer") or {}).get("raw")
    raw_text = raw if isinstance(raw, str) else ""
    has_answer = bool(parsed.get("present"))
    frozen = list(task["requiredFacts"])

    problems, summaries = _check_facts(
        assessment.get("requiredFacts"), task, raw_text, has_answer, evidence, where)

    citations = answer_citations(record, protocol)
    citation_problems, citation_summaries = _check_citations(
        assessment.get("citations"), citations, evidence, where)
    problems.extend(citation_problems)

    dimensions = assessment.get("dimensions")
    dimension_problems, dimensions = _check_dimensions(dimensions, task, evidence, where)
    problems.extend(dimension_problems)

    assertions = assessment.get("behaviorAssertions")
    review = assessment.get("behaviorReview")
    behavior_problems, assertion_summaries = _check_behavior(
        assertions, review, task, behavior, parsed, evidence, where)
    problems.extend(behavior_problems)

    contract_omissions = sum(1 for item in summaries if item["verdict"] != "supported")
    summary = {
        "requiredFacts": summaries,
        "contractOmissions": contract_omissions,
        "requiredFactDenominator": len(frozen),
        "citations": citation_summaries,
        "citationDenominator": len(citations),
        "dimensions": dimensions,
        "behaviorAssertions": assertion_summaries,
        "behaviorReview": review,
    }
    return problems, summary


def template_stage(capture: Capture, protocol: dict) -> dict:
    """Write an empty adjudication skeleton; it scores nothing."""
    assessments = []
    for task in protocol["tasks"]:
        for arm in evaluation.ARMS:
            record = capture.records[(task["id"], arm)]
            citations = answer_citations(record, protocol)
            code = (parsed_answer(record, protocol).get("json") or {}).get("consumerCode", "")
            code = code if isinstance(code, str) else ""
            assessments.append({
                "task": task["id"],
                "arm": arm,
                "scope": task.get("scope"),
                "behaviorRequired": task["behaviorRequired"],
                "capturedAnswer": (record.get("answer") or {}).get("raw"),
                "requiredFacts": [{"fact": fact, "verdict": "", "answerQuote": "",
                                   "evidence": []}
                                  for fact in task["requiredFacts"]],
                "citations": [{"index": index, "citation": citation,
                               "verdict": "", "evidence": []}
                              for index, citation in enumerate(citations)],
                "dimensions": {name: {"value": None, "evidence": [], "note": ""}
                               for name in ADJUDICATED_DIMENSIONS},
                "behaviorAssertions": [],
                "behaviorReview": {"method": "manual-source-and-control-flow-audit",
                    "consumerCodeSha256": digest_text(code),
                    "verdict": "unverified", "coversTaskBoundaries": False,
                    "codeQuote": "", "reason": ""} if task["behaviorRequired"] else None,
            })
    return {
        "schemaVersion": ADJUDICATION_SCHEMA,
        "status": "template",
        "protocolSha256": capture.protocol_sha256,
        "rubricSha256": capture.rubric_sha256,
        "note": "Fill every verdict with source/Doc IR evidence and a verbatim "
                "answerQuote; this template scores nothing.",
        "assessments": assessments,
    }
