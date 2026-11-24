#!/usr/bin/env python3
"""Receipt validation and the two published products: report and observations.

A final report is only published when every captured task/arm has a complete
assessment and every consumer has a verified compile and behavior outcome.
Receipts are re-derived from the private files they describe, so a hand-edited
verification cannot claim a compile, an ELF witness or a sandbox policy that
never existed on disk.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import sys
import tempfile
from typing import Any

sys.dont_write_bytecode = True
try:
    from .strict_json import strict_load
except ImportError:  # Direct script execution.
    from strict_json import strict_load

try:
    import agent_evaluation as evaluation
except ImportError:  # Package execution.
    from . import agent_evaluation as evaluation

try:
    import agent_evaluation_runtime as consumer_runtime
except ImportError:
    from . import agent_evaluation_runtime as consumer_runtime

try:
    from .agent_evaluation_assessment import (
        ADJUDICATED_DIMENSIONS, ADJUDICATION_SCHEMA, validate_assessment)
    from .agent_evaluation_capture import (
        CONSUMER_DIRECTORY, SCOPE_TABLE, Capture, Labels, digest_of,
        digest_text, parsed_answer, privacy_violations, require,
        VERIFICATION_DIRECTORY, VERIFICATION_NAME)
    from .agent_evaluation_consumers import (
        VERIFICATION_SCHEMA, consumer_totals)
    from .agent_evaluation_evidence import Evidence
    from .agent_evaluation_states import (
        COMPILE_FAILURE_STATES, aggregate, consumer_behavior_state,
        consumer_compile_state, row_for)
except ImportError:  # Direct script execution.
    from agent_evaluation_assessment import (
        ADJUDICATED_DIMENSIONS, ADJUDICATION_SCHEMA, validate_assessment)
    from agent_evaluation_capture import (
        CONSUMER_DIRECTORY, SCOPE_TABLE, Capture, Labels, digest_of,
        digest_text, parsed_answer, privacy_violations, require,
        VERIFICATION_DIRECTORY, VERIFICATION_NAME)
    from agent_evaluation_consumers import (
        VERIFICATION_SCHEMA, consumer_totals)
    from agent_evaluation_evidence import Evidence
    from agent_evaluation_states import (
        COMPILE_FAILURE_STATES, aggregate, consumer_behavior_state,
        consumer_compile_state, row_for)


REPORT_SCHEMA = "cjdoc.agent-evaluation-final-report/1"
OBSERVATION_SCHEMA = "cjdoc.agent-evaluation-observations/1"
MAXIMUM_CAPTURED_STREAM_BYTES = consumer_runtime.STREAM_BYTES


def successful_process(process: dict | None) -> bool:
    return bool(process and process.get("exitCode") == 0 and
                process.get("timedOut") is False and process.get("launchError") is None)


def validate_process_receipt(process: dict, logs: Path, labels: Labels, where: str) -> None:
    require(isinstance(process, dict), where + ": missing process receipt")
    code = process.get("exitCode")
    require(code is None or type(code) is int, where + ": invalid exit code")
    require(type(process.get("timedOut")) is bool, where + ": missing timeout observation")
    launch = process.get("launchError")
    require(launch is None or isinstance(launch, str) and bool(launch), where + ": invalid launch error")
    require(not launch or code is None and not process["timedOut"], where + ": contradictory launch outcome")
    elapsed = process.get("elapsedMs")
    require(type(elapsed) in (int, float) and elapsed >= 0, where + ": invalid elapsed time")
    for name in ("stdout", "stderr"):
        stream = process.get(name)
        path = logs / name
        require(isinstance(stream, dict) and path.is_file() and not path.is_symlink(),
                where + ": missing captured " + name)
        size = path.stat().st_size
        require(size <= consumer_runtime.FILE_BYTES and type(stream.get("bytes")) is int
                and stream["bytes"] == size, where + ": stream byte count differs")
        require(stream.get("sha256") == consumer_runtime.sha(path), where + ": stream digest differs")
        require(stream.get("path") == labels.text(str(path)), where + ": stream path differs")
        with path.open("rb") as source:
            actual = labels.text(source.read(MAXIMUM_CAPTURED_STREAM_BYTES).decode("utf-8", "replace"))
        require(stream.get("text") == actual, where + ": stream text is not the captured output")
        require(stream.get("truncated") is (size > MAXIMUM_CAPTURED_STREAM_BYTES),
                where + ": stream truncation contradicts its bytes")
    sandbox = process.get("sandbox") or {}
    require(sandbox.get("provider") == "bwrap" and sandbox.get("network") == "unshared"
            and sandbox.get("inheritedEnvironment") is False and sandbox.get("hostHomeMounted") is False
            and sandbox.get("rootReadOnly") is True,
            where + ": process was not executed in the required isolated environment")


def validate_consumer_receipt(item: dict, task: dict, code: str,
                              root: Path, toolchain: dict, labels: Labels) -> None:
    where = task["id"] + ":" + item["arm"]
    expected_hash = digest_text(code)
    require(item.get("consumerCodeSha256") == expected_hash and
            type(item.get("consumerCodeBytes")) is int and item["consumerCodeBytes"] == len(code.encode("utf-8")),
            where + ": receipt consumer bytes differ from the captured raw answer")
    require(item.get("behaviorRequired") is task["behaviorRequired"],
            where + ": receipt changed behaviorRequired")
    scope = item.get("scope") or {}
    require(scope.get("scope") == task.get("scope"), where + ": requested source scope differs from the frozen task")
    require(item.get("integrityFailure") is None, where + ": captured input integrity failed")
    state = item.get("state")
    if code == "":
        expected_state = "missing-code" if task["behaviorRequired"] else "not-applicable"
        require(state == expected_state and item.get("compile") is None and item.get("packaging") is None
                and item.get("behavior") is None,
                where + ": absent consumer code cannot have compiler packaging or runtime evidence")
        return
    require(state in ("pending", "compiled", "compile-failed", "infrastructure-failed"),
            where + ": unsupported non-empty consumer outcome")
    process = item.get("compile")
    if process is None:
        require(state in ("pending", "infrastructure-failed"), where + ": compiled outcome has no compiler receipt")
        if state == "infrastructure-failed":
            require(isinstance(item.get("failure"), dict), where + ": infrastructure failure has no evidence")
        return
    require(scope.get("requestedVersion") == SCOPE_TABLE[task["scope"]].get("requestedVersion")
            and scope.get("locale") == SCOPE_TABLE[task["scope"]].get("locale"),
            where + ": requested version/language differs from the frozen source scope")
    binding = item.get("scopeBinding") or {}
    require(binding.get("state") in ("verified", "unavailable"),
            where + ": compiler receipt has no requested-library binding observation")
    if binding["state"] == "verified":
        require(binding.get("libraryState") in ("built", "not_required") and binding.get("failure") is None,
                where + ": verified library binding contradicts setup evidence")
    else:
        require(binding.get("libraryState") not in ("built", "not_required") and binding.get("failure") is not None
                and isinstance(item.get("failure"), dict),
                where + ": unavailable requested library has no retained failure")
    project = root / "tasks" / task["id"] / item["arm"] / CONSUMER_DIRECTORY
    project_label = labels.text(str(project))
    require(item.get("projectLabel") == project_label, where + ": consumer project identity differs")
    source = project / "input/main.cj"
    require(source.is_file() and not source.is_symlink() and source.read_bytes() == code.encode("utf-8"),
            where + ": executable input was not the exact captured consumerCode")
    packaging = item.get("packaging") or {}
    require(packaging.get("kind") == "verbatim" and packaging.get("prependedBytes") == 0
            and packaging.get("writtenBytes") == len(code.encode("utf-8"))
            and packaging.get("writtenSha256") == expected_hash
            and packaging.get("answerCodeSha256") == expected_hash,
            where + ": compiler input was repaired or its packaging evidence contradicts the capture")
    require(process.get("inputSha256") == expected_hash, where + ": compiler input digest differs")
    command = process.get("command")
    compiler = (toolchain.get("cjc") or {}).get("label")
    prefix = [compiler, "--static", "--output-type", "exe", "-O2",
              "--output-dir", project_label + "/out", "-o", "main"]
    require(isinstance(command, list) and command[:len(prefix)] == prefix
            and command[-1] == project_label + "/input/main.cj"
            and command.count("--output-type") == command.count("--output-dir") == command.count("-o") == 1,
            where + ": receipt does not describe one executable cjc compilation of this program")
    require(process.get("cwd") == project_label + "/scratch/work", where + ": compiler cwd differs")
    validate_process_receipt(process, project / "compile-logs", labels, where + ":compile")
    require(process["sandbox"].get("compilerMounted") is True, where + ": compiler SDK was not isolated")
    compiled = successful_process(process)
    if state == "compiled":
        require(compiled, where + ": compiled outcome contradicts compiler exit, timeout or launch error")
    if state == "compile-failed":
        require(not compiled and process.get("launchError") is None,
                where + ": compile-failed outcome contradicts the observed compiler failure")
    binary = project / "out/main"
    if state == "compiled":
        require(binary.is_file() and not binary.is_symlink() and os.access(binary, os.X_OK),
                where + ": successful compilation has no executable witness")
        with binary.open("rb") as executable:
            require(executable.read(4) == b"\x7fELF", where + ": executable witness is not native ELF")
        require(process.get("binarySha256") == consumer_runtime.sha(binary)
                and process.get("binaryLabel") == project_label + "/out/main",
                where + ": executable witness differs from the compiler receipt")
    behavior = item.get("behavior") or {}
    if behavior.get("state") == "runtime-executed":
        require(state == "compiled" and task["behaviorRequired"] and binding["state"] == "verified",
                where + ": runtime outcome contradicts compilation, source binding or task policy")
        run = behavior.get("run")
        validate_process_receipt(run, project / "run-logs", labels, where + ":run")
        require(run.get("command") == [process["binaryLabel"]]
                and run.get("binarySha256") == process["binarySha256"]
                and run.get("cwd") == project_label + "/run-scratch/work",
                where + ": a different program was executed")
        require(run["sandbox"].get("compilerMounted") is False
                and run["sandbox"].get("newProcessesAllowed") is False
                and run["sandbox"].get("writableFilesystemRoots") is False,
                where + ": generated program did not use the runtime-only read-only sandbox")
    elif behavior.get("state") == "not-required":
        require(state == "compiled" and not task["behaviorRequired"],
                where + ": required behavior was silently marked N/A")
    elif state == "compiled":
        require(isinstance(item.get("failure"), dict)
                and (task["behaviorRequired"] or binding["state"] == "unavailable"),
                where + ": compiled consumer has no runtime policy or retained infrastructure failure")


def load_verification(path: Path, capture: Capture) -> dict:
    receipt = strict_load(path, description="consumer verification")
    require(isinstance(receipt, dict) and receipt.get("schemaVersion") == VERIFICATION_SCHEMA,
            "unsupported consumer verification receipt")
    require((receipt.get("protocol") or {}).get("sha256") == capture.protocol_sha256
            and (receipt.get("rubric") or {}).get("sha256") == capture.rubric_sha256,
            "consumer verification uses different frozen inputs")
    require((receipt.get("run") or {}).get("manifestSha256") == digest_of(capture.manifest_path),
            "consumer verification belongs to a different capture")
    root = path.resolve().parent
    mapping = [(root, "<verification>"), (Path.home(), "$HOME"),
               (Path(tempfile.gettempdir()).resolve(), "$TMPDIR")]
    if os.environ.get("CANGJIE_HOME"):
        mapping.append((Path(os.environ["CANGJIE_HOME"]).resolve(), "<sdk>"))
    labels = Labels(mapping)
    consumers = receipt.get("consumers")
    require(isinstance(consumers, list), "verification has no complete consumer ledger")
    tasks = {task["id"]: task for task in capture.protocol["tasks"]}
    indexed = {}
    for item in consumers:
        require(isinstance(item, dict), "consumer receipt is not an object")
        key = (item.get("task"), item.get("arm"))
        require(key in capture.records and key not in indexed, "unknown or duplicate consumer session")
        record = capture.records[key]
        body = parsed_answer(record, capture.protocol).get("json") or {}
        code = body.get("consumerCode", "")
        code = code if isinstance(code, str) else ""
        cached = (record.get("answer") or {}).get("consumerCode")
        require(cached is None or cached == code, "cached code differs from the captured raw answer")
        validate_consumer_receipt(item, tasks[key[0]], code, root,
                                  receipt.get("toolchain") or {}, labels)
        indexed[key] = item
    require(set(indexed) == set(capture.records), "verification omitted captured task/arm rows")
    require(receipt.get("totals") == consumer_totals(consumers), "verification totals contradict its ledger")
    return {"receipt": receipt, "index": indexed}


def load_adjudication(path: Path, capture: Capture) -> dict:
    document = strict_load(path, description="adjudication")
    require(isinstance(document, dict), "adjudication must be one JSON object")
    require(document.get("schemaVersion") == ADJUDICATION_SCHEMA,
            f"adjudication schemaVersion must be {ADJUDICATION_SCHEMA}")
    require(document.get("protocolSha256") == capture.protocol_sha256,
            "adjudication was written against a different protocol digest")
    require(document.get("rubricSha256") == capture.rubric_sha256,
            "adjudication was written against a different rubric digest")
    assessments = document.get("assessments")
    require(isinstance(assessments, list), "adjudication needs an assessments list")
    return document


def _doc_ir_sources(values: list[str] | None) -> dict[str, Path]:
    doc_ir: dict[str, Path] = {}
    for item in values or []:
        label, separator, value = item.partition("=")
        require(bool(separator) and bool(label.strip()) and bool(value.strip()),
                f"--doc-ir requires LABEL=PATH: {item}")
        path = Path(os.path.abspath(value))
        require(path.is_file(), f"--doc-ir file does not exist: {value}")
        doc_ir[label.strip()] = path
    return doc_ir


def _indexed_assessments(document: dict, protocol: dict) -> dict[tuple[str, str], dict]:
    assessments: dict[tuple[str, str], dict] = {}
    for position, item in enumerate(document["assessments"]):
        require(isinstance(item, dict),
                f"adjudication assessments[{position}] must be an object")
        key = (item.get("task"), item.get("arm"))
        require(key[0] in {task["id"] for task in protocol["tasks"]},
                f"adjudication names an unknown task: {key[0]!r}")
        require(key[1] in evaluation.ARMS,
                f"adjudication names an unknown arm: {key[1]!r}")
        require(key not in assessments,
                f"adjudication judges {key[0]}:{key[1]} more than once")
        assessments[key] = item
    return assessments


def _row_gaps(task: dict, arm: str, errors: list[str], row: dict) -> list[dict]:
    gaps: list[dict] = []
    prefix = f"{task['id']}:{arm}: "
    for detail in errors:
        # The gap already names the task and arm; keep the message itself
        # free of the repeated location prefix.
        gaps.append({"kind": "adjudication", "task": task["id"],
                     "arm": arm,
                     "detail": detail[len(prefix):]
                     if detail.startswith(prefix) else detail})
    if row["consumer"]["compile"] == "verification-outstanding":
        gaps.append({"kind": "consumer-verification", "task": task["id"],
                     "arm": arm,
                     "detail": "no compile receipt for this consumer"})
    if task["behaviorRequired"] and \
            row["dimensions"]["consumerBehavior"] == \
            "runtime-executed-behavior-unverified":
        gaps.append({"kind": "consumer-behavior", "task": task["id"],
                     "arm": arm,
                     "detail": "consumer executed but no boundary assertion "
                               "was adjudicated"})
    elif task["behaviorRequired"] and \
            row["dimensions"]["consumerBehavior"] == \
            "verification-outstanding":
        gaps.append({"kind": "consumer-behavior", "task": task["id"],
                     "arm": arm,
                     "detail": "consumer behavior was never verified"})
    return gaps


def report_stage(args: argparse.Namespace, protocol: dict, rubric: dict,
                 capture: Capture) -> tuple[dict, list[dict]]:
    project_root = Path(os.path.abspath(args.project_root))
    verification_file = Path(os.path.abspath(
        args.verification or capture.output / VERIFICATION_DIRECTORY / VERIFICATION_NAME))
    verification = load_verification(verification_file, capture)
    doc_ir = _doc_ir_sources(args.doc_ir)
    evidence = Evidence(project_root, doc_ir, capture, verification)
    adjudication_path = Path(os.path.abspath(args.adjudications))
    adjudication = load_adjudication(adjudication_path, capture)
    assessments = _indexed_assessments(adjudication, protocol)
    rows = []
    gaps: list[dict] = []
    for task in protocol["tasks"]:
        for arm in evaluation.ARMS:
            key = (task["id"], arm)
            receipt = verification["index"].get(key)
            assessment = assessments.get(key)
            record = capture.records[key]
            adjudicated: dict | None = None
            errors: list[str] = []
            if assessment is None:
                errors = [f"{key[0]}:{key[1]}: no adjudication supplied"]
            else:
                behavior = (receipt or {}).get("behavior") or {}
                errors, adjudicated = validate_assessment(
                    assessment, task, arm, record, protocol, behavior, evidence,
                    f"{task['id']}:{arm}")
            row = row_for(capture, task, arm, receipt, assessment, errors,
                          adjudicated, protocol)
            gaps.extend(_row_gaps(task, arm, errors, row))
            rows.append(row)
    evidence.check_current_inputs()
    totals = aggregate(rows, protocol, rubric)
    registered_roots = [(verification_file.parent, "<verification>"),
        (capture.output, "<output>"), (project_root, "<repo>"),
        (Path(tempfile.gettempdir()).resolve(), "$TMPDIR"), (Path.home(), "$HOME")]
    sdk_root = os.environ.get("CANGJIE_HOME")
    if sdk_root:
        registered_roots.append((Path(sdk_root).resolve(), "<sdk>"))
    for label, source in doc_ir.items():
        registered_roots.append((source, "<doc-ir:" + label + ">"))
    labels = Labels(registered_roots)
    # Only a gap-free report may be published as a completed adjudication.
    report = {
        "schemaVersion": REPORT_SCHEMA,
        "status": "final" if not gaps else "incomplete",
        "claim": rubric.get("claim"),
        "denominator": rubric.get("taskDenominator"),
        "budgets": capture.budgets,
        "arms": list(evaluation.ARMS),
        "taskOrder": protocol["comparison"]["taskOrder"],
        "inputs": {
            "protocol": {"path": evaluation.repo_relative(args.protocol),
                         "sha256": capture.protocol_sha256},
            "rubric": {"path": evaluation.repo_relative(args.rubric),
                       "sha256": capture.rubric_sha256},
            "run": {"label": "<output>",
                    "manifestSha256": digest_of(capture.manifest_path),
                    "records": len(capture.records)},
            "verification": {"label": "<verification>/" + VERIFICATION_NAME,
                             "sha256": digest_of(verification_file),
                             "toolchain": verification["receipt"].get("toolchain"),
                             "scopes": verification["receipt"].get("scopes")},
            "adjudication": {"sha256": digest_of(adjudication_path),
                             "docIr": [{"label": label, "sha256": digest_of(path)}
                                       for label, path in sorted(doc_ir.items())]},
        },
        "completeness": {
            "frozenTasks": len(protocol["tasks"]),
            "frozenArms": len(evaluation.ARMS),
            "expectedRuns": len(protocol["tasks"]) * len(evaluation.ARMS),
            "observedRuns": len(rows),
            "completePair": len(rows) == len(protocol["tasks"]) * len(evaluation.ARMS),
            "repetitionsPerTaskPerPath": 1,
            "adjudicatedAssessments": sum(1 for row in rows
                                          if row["adjudication"]["state"] == "complete"),
            "outstandingGaps": len(gaps),
        },
        "selection": {"bestOf": False, "retries": 0, "budgetRelaxation": False,
                      "retainedFailures": [row["task"] + ":" + row["arm"]
                                           for row in rows
                                           if row["model"]["outcome"] == "failed"
                                           or row["dimensions"]["consumerCompile"]
                                           in COMPILE_FAILURE_STATES],
                      "policy": "every captured failure, budget overrun and failed "
                                "consumer remains in the report"},
        "records": rows,
        "totals": totals,
        "scoring": {
            "state": "adjudicated" if not gaps else "incomplete",
            "dimensions": list(protocol["scoreDimensions"]),
            "naturalLanguageScoring": "no keyword scoring: every requiredFact verdict "
                                      "is supplied with a verbatim answer quote and "
                                      "source/Doc IR evidence",
            "measuredDimensions": ["readBytes", "toolCalls", "elapsedMs", "consumerCompile"],
            "behaviorJudgment": "captured runtime plus an explicit manual source/control-flow audit; neither stdout nor exit zero alone is proof",
            "adjudicatedDimensions": list(ADJUDICATED_DIMENSIONS) + ["contractOmissions"],
        },
        "gaps": gaps,
        "privacy": {"labels": sorted({label for _, label in registered_roots}),
                    "policy": "registered capture, verification, source, SDK, temporary and home roots are normalized; raw-byte hashes refer to private original inputs",
                    "sourceAudit": "manual review and the publication privacy gate remain required for other identifiers"},
    }
    scrubbed = labels.scrub(report)
    forbidden = [str(source) for source, _ in registered_roots]
    leaks = privacy_violations(scrubbed, forbidden)
    require(not leaks, "refusing a report that leaks local paths: " + "; ".join(leaks[:5]))
    return scrubbed, gaps


def observations_stage(capture: Capture, verification_file: Path | None,
                       protocol: dict) -> dict:
    verification = None
    if verification_file is not None:
        verification = load_verification(verification_file, capture)["index"]
    rows = []
    for task in protocol["tasks"]:
        for arm in evaluation.ARMS:
            record = capture.records[(task["id"], arm)]
            classification = evaluation.classify(record)
            answer = record.get("answer") or {}
            receipt = (verification or {}).get((task["id"], arm))
            rows.append({
                "task": task["id"],
                "arm": arm,
                "outcome": classification["taskOutcome"],
                "causes": classification["causes"],
                "budgetFailure": classification["budgetFailure"],
                "answerPresent": bool(answer.get("present")),
                "consumerCodeBytes": len((answer.get("consumerCode") or "").encode()),
                "toolCalls": (record.get("toolUse") or {}).get("calls"),
                "resultBytes": (record.get("toolUse") or {}).get("resultBytes"),
                "elapsedMs": ((record.get("client") or {}).get("process") or {})
                .get("elapsedMs"),
                "consumerCompile": consumer_compile_state(receipt, task, record),
                "consumerBehavior": consumer_behavior_state(task, record, receipt, None),
                "adjudication": "unadjudicated",
            })
    return {
        "schemaVersion": OBSERVATION_SCHEMA,
        "status": "observations",
        "claim": "one complete paired observation; no score is assigned here",
        "capturedRun": {"manifestSha256": digest_of(capture.manifest_path),
                        "records": len(capture.records)},
        "budgets": capture.budgets,
        "records": rows,
        "scoring": {"state": "unadjudicated",
                    "reason": "observations contain measured and compiler-verified "
                              "facts only; requiredFacts, citations and API identity "
                              "judgments come from a separate adjudication"},
    }


def labels_scrub(value: Any, capture: Capture) -> Any:
    """Scrub a standalone observations document of its capture and home roots."""
    return Labels([(capture.output, "<output>"), (Path.home(), "$HOME")]).scrub(value)
