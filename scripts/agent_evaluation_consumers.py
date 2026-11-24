#!/usr/bin/env python3
"""One executable compilation and run of every captured consumer, verbatim.

The verification stage never repairs generated code: each non-empty consumer is
compiled once from its exact UTF-8 bytes and executed once when the frozen task
requires behavior. Every task/arm row is checkpointed, including missing code
and infrastructure failures, so an unavailable SDK or source closure can never
shrink the comparison.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import sys
import tempfile

sys.dont_write_bytecode = True
try:
    import agent_evaluation as evaluation
except ImportError:  # Package execution.
    from . import agent_evaluation as evaluation

try:
    import agent_evaluation_runtime as consumer_runtime
except ImportError:
    from . import agent_evaluation_runtime as consumer_runtime

try:
    from .agent_evaluation_assessment import template_stage
    from .agent_evaluation_capture import (
        ADJUDICATION_TEMPLATE_NAME, CONSUMER_DIRECTORY, Capture, Labels, digest_of,
        digest_text, frozen_sources, parsed_answer, require, resolve_scopes,
        VERIFICATION_DIRECTORY, VERIFICATION_NAME)
except ImportError:  # Direct script execution.
    from agent_evaluation_assessment import template_stage
    from agent_evaluation_capture import (
        ADJUDICATION_TEMPLATE_NAME, CONSUMER_DIRECTORY, Capture, Labels, digest_of,
        digest_text, frozen_sources, parsed_answer, require, resolve_scopes,
        VERIFICATION_DIRECTORY, VERIFICATION_NAME)


VERIFICATION_SCHEMA = "cjdoc.agent-evaluation-consumer-verification/1"
DEFAULT_COMPILE_SECONDS = 300
DEFAULT_RUN_SECONDS = 60


def initial_consumer(capture: Capture, task: dict, arm: str) -> dict:
    record = capture.records[(task["id"], arm)]
    answer = parsed_answer(record, capture.protocol).get("json") or {}
    code = answer.get("consumerCode", "")
    code = code if isinstance(code, str) else ""
    cached = (record.get("answer") or {}).get("consumerCode")
    entry = {"task": task["id"], "arm": arm,
             "behaviorRequired": task["behaviorRequired"],
             "scope": {"scope": task.get("scope")},
             "consumerCodeBytes": len(code.encode("utf-8")),
             "consumerCodeSha256": digest_text(code),
             "packaging": None, "compile": None, "behavior": None,
             "failure": None, "integrityFailure": None, "state": "pending"}
    if cached is not None and cached != code:
        entry["integrityFailure"] = "cached consumerCode differs from captured raw answer"
    if code == "":
        entry["state"] = "missing-code" if task["behaviorRequired"] else "not-applicable"
        if task["behaviorRequired"]:
            entry["failure"] = {"kind": "missing-consumer-code",
                                "reason": "required task produced no identifiable consumerCode"}
    return entry


def consumer_totals(consumers: list[dict]) -> dict:
    return {"compiled": sum(item["state"] == "compiled" for item in consumers),
            "compileFailed": sum(item["state"] == "compile-failed" for item in consumers),
            "infrastructureFailed": sum(item["state"] == "infrastructure-failed" for item in consumers),
            "missingCode": sum(item["state"] == "missing-code" for item in consumers),
            "notApplicable": sum(item["state"] == "not-applicable" for item in consumers),
            "pending": sum(item["state"] == "pending" for item in consumers),
            "runtimeExecuted": sum((item.get("behavior") or {}).get("state") == "runtime-executed"
                                   for item in consumers),
            "runFailed": sum((item.get("failure") or {}).get("kind") in
                             {"run-failed", "run-timeout", "run-launch-failed", "binary-missing"}
                             for item in consumers)}


def build_consumer(capture: Capture, task: dict, arm: str, scope: dict,
                   root: Path, runtime, library: dict, entry: dict,
                   compile_seconds: float, run_seconds: float) -> None:
    if entry["state"] != "pending":
        return
    answer = parsed_answer(capture.records[(task["id"], arm)], capture.protocol).get("json") or {}
    code = answer.get("consumerCode", "")
    require(isinstance(code, str) and digest_text(code) == entry["consumerCodeSha256"],
            "captured consumer code changed before verification")
    project = root / "tasks" / task["id"] / arm / CONSUMER_DIRECTORY
    project.mkdir(mode=0o700, parents=True)
    entry["scope"].update({"requestedVersion": scope["requestedVersion"], "locale": scope["locale"]})
    entry["dependencies"] = {"sources": library.get("sources", []),
                             "exports": library.get("exports", {}).get("pins", [])}
    bound = library["state"] in ("built", "not_required")
    entry["scopeBinding"] = {"state": "verified" if bound else "unavailable",
        "libraryState": library["state"],
        "failure": None if bound else library.get("failure") or library.get("receipt")}
    if not bound:
        entry["failure"] = {"kind": "requested-library-unavailable",
            "reason": "Exact consumer compilation is still attempted with the SDK; "
                      "it cannot establish compatibility with the requested library."}
    exports = library.get("exports") or {"directories": [], "libraries": [], "pins": []}
    entry["projectLabel"] = runtime.labels.text(str(project))
    compiled = consumer_runtime.compile_consumer(runtime, code, project, exports, compile_seconds)
    entry["packaging"] = compiled["packaging"]
    entry["compile"] = compiled["compile"]
    entry["elapsedMs"] = entry["compile"]["elapsedMs"]
    receipt = entry["compile"]
    if receipt["launchError"]:
        entry["state"] = "infrastructure-failed"
        entry["failure"] = {"kind": "compile-launch-failed", "reason": receipt["launchError"]}
        return
    if receipt["timedOut"] or receipt["exitCode"] != 0:
        entry["state"] = "compile-failed"
        entry["failure"] = {"kind": "compile-timeout" if receipt["timedOut"] else "compile-failed",
                            "reason": "the one executable cjc compilation did not succeed"}
        return
    binary = compiled["binary"]
    if binary is None:
        entry["state"] = "infrastructure-failed"
        entry["failure"] = {"kind": "binary-missing", "reason": "successful compiler exit produced no executable"}
        return
    receipt["binarySha256"] = digest_of(binary)
    receipt["binaryLabel"] = runtime.labels.text(str(binary))
    entry["state"] = "compiled"
    if not bound:
        entry["behavior"] = {"state": "not-attempted", "reason": "requested library binding unavailable"}
        return
    if not task["behaviorRequired"]:
        entry["behavior"] = {"state": "not-required"}
        return
    entry["behavior"] = consumer_runtime.run_consumer(runtime, binary, project, run_seconds)
    run = entry["behavior"]["run"]
    run["binaryLabel"] = runtime.labels.text(str(binary))
    entry["elapsedMs"] += run["elapsedMs"]
    if run["launchError"]:
        entry["failure"] = {"kind": "run-launch-failed", "reason": run["launchError"]}
    elif run["timedOut"]:
        entry["failure"] = {"kind": "run-timeout", "reason": "consumer exceeded its recorded deadline"}
    elif run["exitCode"] != 0:
        entry["failure"] = {"kind": "run-failed", "reason": "consumer exited " + str(run["exitCode"])}


def verify_stage(args: argparse.Namespace, protocol: dict, rubric: dict,
                 capture: Capture) -> dict:
    project_root = Path(args.project_root).resolve(strict=True)
    root = Path(os.path.abspath(args.verification or capture.output / VERIFICATION_DIRECTORY))
    require(not root.exists() or root.is_dir() and not any(root.iterdir()),
            "refusing to reuse a non-empty verification directory")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    sdk_value = args.sdk_root or os.environ.get("CANGJIE_HOME")
    sdk = Path(sdk_value).resolve() if sdk_value else None
    labels = Labels([(root, "<verification>"), (capture.output.resolve(), "<output>"),
                     (project_root, "<repo>"), (Path.home(), "$HOME"),
                     (Path(tempfile.gettempdir()).resolve(), "$TMPDIR")] +
                    ([(sdk, "<sdk>")] if sdk else []))
    consumers = [initial_consumer(capture, task, arm)
                 for task in protocol["tasks"] for arm in evaluation.ARMS]
    rows = {(row["task"], row["arm"]): row for row in consumers}
    path = root / VERIFICATION_NAME
    receipt = {"schemaVersion": VERIFICATION_SCHEMA,
        "generatedBy": "scripts/agent_evaluation_proof.py verify", "state": "in-progress",
        "attemptPolicy": "one executable compilation of each non-empty verbatim consumerCode; "
                         "one run when behaviorRequired; no retries or source repairs",
        "protocol": {"path": evaluation.repo_relative(args.protocol), "sha256": capture.protocol_sha256},
        "rubric": {"path": evaluation.repo_relative(args.rubric), "sha256": capture.rubric_sha256},
        "run": {"label": "<output>", "manifestSha256": digest_of(capture.manifest_path),
                "records": len(capture.records), "budgets": capture.budgets},
        "toolchain": {"sdkRoot": "<sdk>" if sdk else None,
            "environmentPolicy": "explicit allowlist; no inherited environment or credentials",
            "compileTimeoutSeconds": args.compile_seconds, "runTimeoutSeconds": args.run_seconds},
        "scopes": {}, "frozenSources": {}, "consumers": consumers,
        "totals": consumer_totals(consumers), "setupFailures": []}

    def checkpoint():
        receipt["totals"] = consumer_totals(consumers)
        evaluation.write_json(path, labels.scrub(receipt))

    checkpoint()
    runtime = None
    try:
        require(sdk is not None, "pass the pinned SDK with --sdk-root or CANGJIE_HOME")
        runtime = consumer_runtime.ConsumerRuntime(sdk, labels)
        preflight = root / "preflight"
        preflight.mkdir(mode=0o700)
        receipt["toolchain"]["preflight"] = runtime.preflight(preflight)
        for name, executable in (("cjc", runtime.cjc), ("cjpm", runtime.cjpm)):
            probe_root = root / ("tool-" + name)
            probe_root.mkdir(mode=0o700)
            probe = runtime.execute([str(executable), "-v"], cwd=probe_root,
                scratch=probe_root / "scratch", readonly=[], writable=[], compiler=True,
                seconds=30, logs=probe_root / "logs")
            receipt["toolchain"][name] = {"label": labels.text(str(executable)),
                "sha256": digest_of(executable), "version":
                (probe["stdout"]["text"] + probe["stderr"]["text"]).strip().splitlines()[0]
                if (probe["stdout"]["text"] + probe["stderr"]["text"]).strip() else None,
                "probe": {key: probe[key] for key in ("exitCode", "timedOut", "launchError")}}
            require(probe["exitCode"] == 0 and not probe["timedOut"] and not probe["launchError"],
                    name + " namespace tool probe failed")
    except Exception as error:
        receipt["setupFailures"].append({"stage": "toolchain", "reason": labels.text(str(error))})
        runtime = None
    checkpoint()
    scopes, libraries, library_keys = {}, {}, {}
    for task in protocol["tasks"]:
        name = task.get("scope") or ""
        if name not in scopes:
            try:
                scope = resolve_scopes({"tasks": [task]}, project_root)[name]
                scopes[name] = scope
                closure = consumer_runtime.source_closure(project_root,
                    [dependency["root"] for dependency in scope["dependencies"]])
                receipt["scopes"][name] = {"requestedVersion": scope["requestedVersion"],
                    "locale": scope["locale"], "dependencies": [
                        {key: labels.text(str(value)) if isinstance(value, Path) else value
                         for key, value in dependency.items()} for dependency in scope["dependencies"]],
                    "sourceIdentities": [{"path": item["relative"].as_posix(), "name": item["name"],
                        "version": item["version"], "identity": item["identity"]} for item in closure]}
                library_keys[name] = tuple(sorted((str(item["root"]), item["identity"]) for item in closure))
            except Exception as error:
                scopes[name] = None
                receipt["setupFailures"].append({"stage": "scope", "scope": name,
                                                 "reason": labels.text(str(error))})
            checkpoint()
        scope = scopes[name]
        for arm in evaluation.ARMS:
            row = rows[(task["id"], arm)]
            if row["state"] != "pending":
                continue
            try:
                require(runtime is not None and scope is not None, "toolchain or source-scope setup failed")
                key = library_keys[name]
                if key not in libraries:
                    library_root = root / "libraries" / str(len(libraries))
                    library_root.mkdir(mode=0o700, parents=True)
                    try:
                        built = consumer_runtime.build_libraries(runtime, scope, project_root,
                                                               library_root, float(args.compile_seconds))
                    except Exception as error:
                        built = {"state": "setup-failed", "failure": labels.text(str(error))}
                    libraries[key] = built
                library = libraries[key]
                build_consumer(capture, task, arm, scope, root, runtime, library, row,
                               float(args.compile_seconds), float(args.run_seconds))
            except Exception as error:
                if row["state"] != "compiled":
                    row["state"] = "infrastructure-failed"
                row["failure"] = {"kind": "verification-infrastructure", "reason": labels.text(str(error))}
            finally:
                checkpoint()
    receipt["libraries"] = [{key: value for key, value in library.items() if key != "exports"}
                            | ({"exports": library["exports"]["pins"]} if "exports" in library else {})
                            for library in libraries.values()]
    receipt["frozenSources"] = frozen_sources(protocol, project_root)
    receipt["state"] = "complete"
    checkpoint()
    template_path = root / ADJUDICATION_TEMPLATE_NAME
    evaluation.write_json(template_path, template_stage(capture, protocol))
    return {"path": path, "receipt": labels.scrub(receipt), "template": template_path}
