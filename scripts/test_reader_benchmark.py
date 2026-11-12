#!/usr/bin/env python3
"""Behavioral safeguards for reader evidence; native/browser observations are separate."""
from __future__ import annotations

import argparse
import hashlib
import json
from copy import deepcopy
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib
import unittest
from unittest.mock import patch

from reader_benchmark import file_digest, run, scrub, verify_corpus
from reader_compare import (EvidenceError, check_font_usage, check_native_ir, check_search_transition,
                            check_visuals, compare_browser, p95)
from reader_contract_review import (GUIDE_TASKS, copy_sources, extract_guide_programs,
                                    validate_guide_result)
from reader_corpus import digest, generate_corpus
from reader_process import measured_process
from reader_aria_transition import check_aria_pair, register_aria_transition, validate_aria_registration
from reader_ir_transition import (TRANSITION_NAME, compare_ir_transition, register_ir_observation,
                                 register_ir_transition)
from reader_register import register as register_reader, validate_transition_budget
from reader_search_identity import (compare_search_identities, projection_fingerprint,
                                    verify_search_identity)
from test_agent_artifacts import ContractError, publisher_snapshot_id


def ir_transition_pair():
    before = {
        "schemaVersion": "cjdoc.doc-ir/17",
        "generator": {"version": "0.7.3", "build": "fixture"},
        "metadata": {"project": "fixture-project"},
        "modules": [{"id": "module:fixture", "name": "fixture", "repositoryPath": None}],
        "files": [{"path": "src/api.cj", "moduleId": "module:fixture"}],
        "declarations": [{
            "id": "native:target",
            "signature": "public func target(): Unit",
            "documentation": {
                "summary": "API header",
                "description": "Author body",
                "tags": [{"name": "returns", "description": "Return text"}],
                "localizedTexts": [{"kind": "tag", "language": "en", "text": "Return text"}],
            },
        }],
    }
    after = deepcopy(before)
    after["schemaVersion"] = "cjdoc.doc-ir/18"
    del after["modules"][0]["repositoryPath"]
    after["files"][0]["provenance"] = {
        "state": "unavailable", "reason": "no_project_repository",
        "repository": None, "repositoryPath": None, "sourceDigest": None,
        "normalizedDigest": None, "evidenceIdentity": None, "evidenceKind": "none",
    }
    comment = after["declarations"][0]["documentation"]
    comment["localizationScope"] = "all"
    comment["tags"][0].update(entryId=None, source=None)
    comment["localizedTexts"][0]["entryId"] = None
    return before, after


def schema_example(schema, root):
    """Build a small schema-valid search contract for evidence-pair tests."""
    if "$ref" in schema:
        target = root
        for part in schema["$ref"][2:].split("/"):
            target = target[part]
        return schema_example(target, root)
    if "const" in schema:
        return deepcopy(schema["const"])
    if "enum" in schema:
        return deepcopy(schema["enum"][0])
    if "anyOf" in schema:
        return schema_example(schema["anyOf"][0], root)
    value_type = schema.get("type")
    if isinstance(value_type, list):
        value_type = next((item for item in value_type if item != "null"), "null")
    if value_type == "object":
        properties = schema.get("properties", {})
        return {name: schema_example(properties[name], root)
                for name in schema.get("required", [])}
    if value_type == "array":
        return [schema_example(schema["items"], root)
                for _ in range(schema.get("minItems", 0))]
    if value_type == "string":
        return "x" * schema.get("minLength", 1)
    if value_type == "integer":
        return schema.get("minimum", 0)
    if value_type == "boolean":
        return False
    if value_type == "null":
        return None
    raise AssertionError(f"test fixture cannot construct schema node: {schema!r}")


def raw_object_member(encoded, wanted):
    decoder = json.JSONDecoder()
    at = encoded.index("{") + 1
    while True:
        while encoded[at].isspace():
            at += 1
        name, at = decoder.raw_decode(encoded, at)
        while encoded[at].isspace():
            at += 1
        if encoded[at] != ":":
            raise AssertionError("malformed test JSON object")
        at += 1
        while encoded[at].isspace():
            at += 1
        start = at
        _, at = decoder.raw_decode(encoded, at)
        if name == wanted:
            return encoded[start:at]
        while encoded[at].isspace():
            at += 1
        if encoded[at] != ",":
            raise AssertionError(f"missing test JSON member {wanted}")
        at += 1


def write_search_site(site, doc_ir, locale="en", *, body="Searchable body",
                      signature="public func target(): Unit", contract_change=False,
                      snapshot_override=None, projection_override=None, script_suffix="",
                      search_schema_version="cjdoc.search-index/11"):
    site = Path(site)
    (site / "agent").mkdir(parents=True, exist_ok=True)
    revision = "fixture-revision"
    doc_ir_bytes = json.dumps(doc_ir, ensure_ascii=False, sort_keys=True,
                              separators=(",", ":")).encode("utf-8")
    doc_ir_path = site / "agent/doc-ir.json"
    doc_ir_path.write_bytes(doc_ir_bytes)
    snapshot_id = publisher_snapshot_id(doc_ir_bytes.decode("utf-8"), revision)
    if snapshot_override is not None:
        snapshot_id = snapshot_override
    schema_path = Path(__file__).resolve().parent.parent / "docs/schema/search-index-v11.schema.json"
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    contract = schema_example(schema["$defs"]["searchContract"], schema)
    if contract_change:
        contract["defaultLimit"] += 1
    index = {
        "schemaVersion": search_schema_version,
        "profile": "bounded-static",
        "contract": contract,
        "projectionId": "pending",
        "scope": {
            "snapshotId": snapshot_id, "sourceSnapshotId": snapshot_id,
            "publicationRevision": revision, "project": "fixture",
            "language": locale, "audience": "external", "cfgProfile": "default",
            "apiCollectionState": "resolved",
        },
        "coverage": {
            "profile": "bounded-static", "projectionId": "pending",
            "bodyTextLimit": 2000, "bodyComplete": True, "truncatedEntries": 0,
        },
        "modules": [],
        "tags": [],
        "entries": [{
            "id": "native:target", "canonicalId": "native:target", "snapshotId": snapshot_id,
            "scope": -1, "concept": True, "genericArity": 0, "ownerId": None,
            "name": "Target", "packageName": None, "qualifiedName": None, "kind": "concept",
            "ownerName": None, "ownerQualifiedName": None, "symbolKey": None,
            "parameterTypes": [], "returnType": None, "returnCanonical": None,
            "summary": "Target summary", "summaryDisplay": "Target summary", "body": body,
            "bodyTruncated": False, "href": "concepts/target.html",
            "exposures": [], "externalDocs": [], "bindings": [], "sections": [],
            "classification": {"group": None, "tags": []},
        }],
    }
    encoded_index = json.dumps(index, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    raw_contract = raw_object_member(encoded_index, "contract")
    projection_id = projection_fingerprint(index, raw_contract)
    if projection_override is not None:
        projection_id = projection_override
    index["projectionId"] = projection_id
    index["coverage"]["projectionId"] = projection_id
    encoded_index = json.dumps(index, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    signatures = {"native:target": signature}
    encoded_script = (
        "globalThis.__CJDOC_SEARCH_INDEX__ = " + encoded_index +
        ";\nglobalThis.__CJDOC_SEARCH_SIGNATURES__ = " +
        json.dumps(signatures, ensure_ascii=False, sort_keys=True, separators=(",", ":")) +
        ";\n" + script_suffix
    )
    (site / "search-index.json").write_text(encoded_index, encoding="utf-8")
    (site / "search-index.js").write_bytes(encoded_script.encode("utf-8"))
    doc_ir_sha = hashlib.sha256(doc_ir_bytes).hexdigest()
    manifest = {
        "projection": "cjdoc.read/1", "pathBase": "document-root",
        "publicationRevision": revision, "snapshotId": snapshot_id,
        "scope": {
            "snapshotId": snapshot_id, "audience": "external", "cfgProfile": "default",
            "readingLanguage": locale, "apiCollectionState": "resolved",
            "publicationRevision": revision,
        },
        "docIr": {"path": "agent/doc-ir.json", "sha256": doc_ir_sha},
        "resources": [{"path": "agent/doc-ir.json", "sha256": doc_ir_sha}],
    }
    (site / "agent/manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":")),
        encoding="utf-8")
    return site, search_resource_receipts(site), index, signatures


def search_resource_receipts(site):
    receipts = {}
    for name in ("search-index.json", "search-index.js"):
        encoded = (Path(site) / name).read_bytes()
        receipts[name] = {"sha256": hashlib.sha256(encoded).hexdigest(), "bytes": len(encoded)}
    return receipts


def search_report(locale, resources):
    return {"environment": {"requestedUiLocale": locale}, "resources": resources}


def aria_fixture(root):
    root = Path(root)
    snapshot_root = root / "snapshots"
    snapshot_root.mkdir(parents=True)
    baseline = root / "baseline"
    baseline.mkdir()
    recipe, source_sha, tasks_sha = "fixture-reader-recipe", "a" * 64, "b" * 64
    profile = {
        "schemaVersion": "cjdoc.reader-aria-transition/1",
        "recipe": recipe, "sourceSha256": source_sha, "taskManifestSha256": tasks_sha,
        "locales": {},
    }
    native_locales = []
    for locale in ("en", "zh-CN"):
        profile["locales"][locale] = {}
        browser_name = f"browser-{locale}.json"
        native_locales.append({"locale": locale, "browserReport": browser_name})
        observations = {}
        for label in ("baseline", "after"):
            name = f"{label}-{locale}.aria.txt"
            tree = (f"document {locale}\n  navigation {label}\n  main content {locale}\n")
            encoded = tree.encode("utf-8")
            (snapshot_root / name).write_bytes(encoded)
            profile["locales"][locale][label] = {
                "snapshot": name, "sha256": hashlib.sha256(encoded).hexdigest(),
            }
            observations[label] = tree
        before_browser = {
            "recipe": recipe, "sourceSha256": source_sha, "taskManifestSha256": tasks_sha,
            "environment": {"requestedUiLocale": locale},
            "accessibility": {"noScript": {"accessibleTree": observations["baseline"]}},
        }
        (baseline / browser_name).write_text(
            json.dumps(before_browser, sort_keys=True), encoding="utf-8")
    profile_file = root / "aria-profile.json"
    profile_file.write_text(json.dumps(profile, ensure_ascii=False, sort_keys=True), encoding="utf-8")
    native = {
        "recipe": recipe, "sourceSha256": source_sha, "taskManifestSha256": tasks_sha,
        "locales": native_locales,
    }
    registration = register_aria_transition(profile_file, baseline, native, snapshot_root)
    return registration


def aria_observation(registration, locale, label):
    profile = registration["profile"]
    return {
        "recipe": profile["recipe"], "sourceSha256": profile["sourceSha256"],
        "taskManifestSha256": profile["taskManifestSha256"],
        "environment": {"requestedUiLocale": locale},
        "accessibility": {
            "status": "measured",
            "noScript": {"accessibleTree": registration["snapshots"][locale][label]},
        },
    }


def distribution(value):
    return {"samples": [value] * 20, "p50Ms": value, "p95Ms": value}


def evidence_pair():
    task = {"id": "target", "expected": [{"qualifiedName": "sample.Target"}], "expectedOutcome": "hit"}
    query = {"id": "target", "expectedIds": ["native:target"], "first20Hrefs": ["symbols/target.html"],
             "pass": True, "synchronous": distribution(10), "frame": distribution(20)}
    page = {"firstInteractiveProbeMs": 40}
    report = {"schemaVersion": "cjdoc.reader-browser/1", "recipe": "test", "sourceSha256": "source",
        "taskManifestSha256": "tasks", "harness": {"test": "same"}, "nativeIndexEntries": 1,
        "environment": {"fontFiles": [{"family": "Example", "status": "measured", "sha256": "font"}]},
        "resources": {name: {"sha256": "same", "bytes": 100, "gzipBytes": 50}
                      for name in ("search-index.json", "search-index.js", "search.js")},
        "failures": [], "visuals": [], "accessibility": {"status": "not-applicable", "screenReaderSpeech": None},
        "transports": [{"transport": "file", "queries": [query], "members": [], "overloads": [],
                        "loading": {"cold": page, "warm": page}, "queryLayout": {"jsHeapUsedBytes": 100}}]}
    budget = {"minimumSamples": 20, "transports": ["file"], "baselineQueryFailures": [], "requireScreenshots": False,
              "absolute": {"querySyncP95Ms": 100, "queryFrameP95Ms": 100,
                           "coldInteractiveMs": 200, "warmInteractiveMs": 200,
                           "queryHeapBytes": 1000, "bundleFileBytes": 1000},
              "relative": {name: {"factor": 1.25, "slack": 5} for name in ("latency", "loading", "memory", "bundle")}}
    return report, deepcopy(report), {"queries": [task], "members": [], "overloads": []}, budget


def register_presentation(budget, profile):
    encoded = json.dumps(profile, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    budget["presentation"] = {"profile": profile, "sha256": hashlib.sha256(encoded).hexdigest()}


def presentation_pair():
    a, b, manifest, budget = evidence_pair()
    for label, report in (("baseline", a), ("after", b)):
        report["environment"]["requestedUiLocale"] = "en"
        report["fontUsage"] = deepcopy(report["environment"]["fontFiles"])
        report["visuals"] = [{"viewport": "desktop", "theme": "light", "target": "member", "locale": "en",
            "metrics": {"horizontalOverflowPx": 0, "typography": {"bodyFont": "Example", "bodyFontSize": "15px" if label == "baseline" else "16px"}},
            "focus": {"positiveTabindex": 0, "mainLandmark": 1, "headingCount": 1}}]
        report["accessibility"] = {
            "screenReaderSpeech": {"status": "not-measured"},
            "noScript": {"accessibleTree": "heading and exact native contract " + label, "independentlyOpen": True},
            "print": {"contentVisible": True, "overflowPx": 0, "signatures": 2, "detailBodies": 2,
                      "visibleSignatureIds": ["one", "two"], "visibleDetailIds": ["one", "two"]},
            "printCounterexamples": [{"detected": True}] * 3}
    profile = {"schemaVersion": "cjdoc.reader-presentation/1", "recipe": "test",
        "generatorVersions": {"baseline": "0.7.3", "after": "0.7.5"},
        "typography": {label: report["visuals"][0]["metrics"]["typography"]
                       for label, report in (("baseline", a), ("after", b))},
        "locales": {"en": {label: {"fontFamilies": ["Example"], "noScriptTreeSha256":
            hashlib.sha256(report["accessibility"]["noScript"]["accessibleTree"].encode()).hexdigest()}
            for label, report in (("baseline", a), ("after", b))}}}
    register_presentation(budget, deepcopy(profile))
    return a, b, manifest, budget


class EvidenceIntegrityTests(unittest.TestCase):
    def test_percentiles_are_recomputed_from_raw_samples(self):
        raw = {"samples": list(range(1, 21)), "p50Ms": 10, "p95Ms": 19}
        self.assertEqual(p95(raw, 20, "query"), 19)
        for changed in ({**raw, "p95Ms": 1}, {**raw, "samples": [1] * 19},
                        {**raw, "samples": [float("nan")] * 20}):
            with self.subTest(changed=changed), self.assertRaises(EvidenceError):
                p95(changed, 20, "query")

    def test_pair_rejects_different_input_fonts_harness_and_missing_tasks(self):
        changes = [lambda r: r.update(sourceSha256="different"),
                   lambda r: r["environment"]["fontFiles"][0].update(sha256="different"),
                   lambda r: r["harness"].update(test="different"),
                   lambda r: r["transports"][0].update(queries=[]),
                   lambda r: r["transports"][0]["queries"][0].update(first20Hrefs=["symbols/wrong.html"]),
                   lambda r: r["resources"]["search-index.json"].update(sha256="truncated-body")]
        for change in changes:
            a, b, manifest, budget = evidence_pair()
            change(b)
            with self.subTest(change=changes.index(change)), self.assertRaises(EvidenceError):
                compare_browser(a, b, manifest, budget, [])

    def test_real_regressions_fail_even_when_aggregate_task_flag_is_true(self):
        a, b, manifest, budget = evidence_pair()
        b["transports"][0]["queries"][0]["frame"] = distribution(101)
        b["transports"][0]["queryLayout"]["jsHeapUsedBytes"] = 1001
        failures = []
        compare_browser(a, b, manifest, budget, failures)
        self.assertTrue(any("frame" in item for item in failures))
        self.assertTrue(any("queryHeapBytes" in item for item in failures))

    def test_query_failure_cannot_be_hidden_behind_fast_timings(self):
        a, b, manifest, budget = evidence_pair()
        b["transports"][0]["queries"][0]["pass"] = False
        failures = []
        compare_browser(a, b, manifest, budget, failures)
        self.assertIn("file/query/target: reader task failed", failures)

    def test_print_cannot_keep_counts_while_hiding_other_native_contracts(self):
        a, b, manifest, budget = evidence_pair()
        a["accessibility"] = {
            "screenReaderSpeech": {"status": "not-measured"},
            "noScript": {"accessibleTree": "native member order", "independentlyOpen": True},
            "print": {"contentVisible": True, "overflowPx": 0, "signatures": 2, "detailBodies": 2,
                      "visibleSignatureIds": ["one", "two"], "visibleDetailIds": ["one", "two"]},
            "printCounterexamples": [{"detected": True}] * 3}
        b["accessibility"] = deepcopy(a["accessibility"])
        b["accessibility"]["print"]["visibleDetailIds"] = ["one", "another"]
        with self.assertRaises(EvidenceError):
            compare_browser(a, b, manifest, budget, [])
        b["accessibility"] = deepcopy(a["accessibility"])
        b["accessibility"]["printCounterexamples"] = []
        with self.assertRaises(EvidenceError):
            compare_browser(a, b, manifest, budget, [])


    def test_registered_aria_hashes_match_reviewable_full_snapshots(self):
        repo = Path(__file__).resolve().parent.parent
        profile = json.loads((repo / "docs/maintainer/reader-scale-presentation.json").read_text())
        for locale, observations in profile["locales"].items():
            for label, expected in observations.items():
                path = repo / f"tests/fixtures/reader-presentation/{label}-{locale}.aria.txt"
                self.assertEqual(file_digest(path), expected["noScriptTreeSha256"])

    def test_registered_presentation_accepts_only_exact_expected_changes(self):
        a, b, manifest, budget = presentation_pair()
        failures = []
        compare_browser(a, b, manifest, budget, failures)
        self.assertEqual(failures, [])
        changes = [lambda r: r["visuals"][0]["metrics"]["typography"].update(bodyFontSize="14px"),
                   lambda r: r["visuals"][0]["metrics"]["typography"].update(bodyFont="Another"),
                   lambda r: r["fontUsage"][0].update(sha256="different"),
                   lambda r: r["accessibility"]["noScript"].update(accessibleTree="missing author contract"),
                   lambda r: r["transports"][0]["queries"][0].update(expectedIds=["wrong-api"])]
        for change in changes:
            altered = deepcopy(b)
            change(altered)
            with self.subTest(change=changes.index(change)), self.assertRaises(EvidenceError):
                compare_browser(a, altered, manifest, budget, [])
        budget["presentation"]["profile"]["typography"]["after"]["bodyFontSize"] = "14px"
        with self.assertRaises(EvidenceError):
            compare_browser(a, b, manifest, budget, [])

    def test_presentation_does_not_relax_performance_or_accessibility_gates(self):
        a, b, manifest, budget = presentation_pair()
        b["transports"][0]["queries"][0]["frame"] = distribution(101)
        b["visuals"][0]["focus"]["mainLandmark"] = 0
        failures = []
        compare_browser(a, b, manifest, budget, failures)
        self.assertTrue(any("frame" in item for item in failures))
        self.assertTrue(any("landmark" in item for item in failures))

    def test_native_provenance_exception_preserves_every_other_field(self):
        _, _, _, budget = presentation_pair()
        profile = budget["presentation"]["profile"]
        with tempfile.TemporaryDirectory() as directory:
            roots = [Path(directory) / label for label in ("baseline", "after")]
            receipts = []
            for label, root in zip(("baseline", "after"), roots):
                (root / "native-json").mkdir(parents=True)
                path = root / "native-json/docs.json"
                path.write_text(json.dumps({"generator": {"version": profile["generatorVersions"][label]},
                    "declarations": [{"id": "native:one", "signature": "exact", "contract": "author text"}]}))
                receipts.append({"nativeResult": {"docIrSha256": file_digest(path)}})
            check_native_ir(*roots, *receipts, profile)
            with self.assertRaises(EvidenceError):
                check_native_ir(*roots, *receipts, None)
            path = roots[1] / "native-json/docs.json"
            original = json.loads(path.read_text())
            for field in ("id", "signature", "contract"):
                altered = deepcopy(original)
                altered["declarations"][0][field] = "changed"
                path.write_text(json.dumps(altered))
                receipts[1]["nativeResult"]["docIrSha256"] = file_digest(path)
                with self.subTest(field=field), self.assertRaises(EvidenceError):
                    check_native_ir(*roots, *receipts, profile)
            path.write_text(json.dumps(original))
            with self.assertRaises(EvidenceError):
                check_native_ir(*roots, *receipts, profile)

    def test_corpus_changes_and_unlisted_source_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / "project"
            manifest = generate_corpus(project, 1000)
            verify_corpus(project, manifest)
            extra = project / "src/unlisted.cj"
            extra.write_text("package reader_scale\npublic class Unlisted {}\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                verify_corpus(project, manifest)
            extra.unlink()
            source = next(project / row["path"] for row in manifest["sources"] if row["path"].endswith(".cj"))
            source.write_text(source.read_text(encoding="utf-8") + "\npublic class Changed {}\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                verify_corpus(project, manifest)

    def test_contract_inventory_identifies_copied_bytes_during_original_edits(self):
        paths = ("examples/pocketkit/demo-v2/cjpm.toml",
                 "examples/pocketkit/demo-v2/src/value.cj",
                 "examples/pocketkit/demo-v2/cjdoc.toml",
                 "examples/pocketkit/demo-v2/docs/guide.md",
                 "examples/pocketkit/demo-v2/docs/en/guide.md",
                 "examples/pocketkit/contract_review.cj")
        for relative in paths:
            with self.subTest(source=relative), tempfile.TemporaryDirectory() as directory:
                repo, output = Path(directory) / "repo", Path(directory) / "evidence"
                output.mkdir()
                for version in ("demo-v2", "support-v1"):
                    project = repo / "examples/pocketkit" / version
                    (project / "src").mkdir(parents=True)
                    (project / "cjpm.toml").write_text('[package]\nname = "pocketkit"\n', encoding="utf-8")
                    (project / "src/value.cj").write_text(
                        "package pocketkit\npublic func value(): Int64 { 7 }\n", encoding="utf-8")
                project = repo / "examples/pocketkit/demo-v2"
                for guide_input in ("cjdoc.toml", "docs/guide.md", "docs/en/guide.md"):
                    path = project / guide_input
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text("# copied caller input\n", encoding="utf-8")
                consumer = repo / "examples/pocketkit/contract_review.cj"
                consumer.write_text("package contract_probe\nmain(): Int64 { 0 }\n", encoding="utf-8")
                original = repo / relative
                original_bytes = original.read_bytes()
                actual_copy = shutil.copyfile

                def copy_then_edit(source, destination):
                    result = actual_copy(source, destination)
                    if source == original:
                        original.write_bytes(original_bytes + b"\n")
                    return result

                with patch("reader_contract_review.shutil.copyfile", side_effect=copy_then_edit):
                    inventory = copy_sources(repo, output)
                copied = (output / "contract_review.cj" if original == consumer else
                          output / "sources/demo-v2" / original.relative_to(repo / "examples/pocketkit/demo-v2"))
                recorded = next(row["sha256"] for row in inventory if row["path"] == relative)
                self.assertEqual(copied.read_bytes(), original_bytes)
                self.assertEqual(recorded, digest(original_bytes))

    def test_guide_parser_preserves_complete_localized_fence_bytes(self):
        manifest = ('[package]\nname = "guide_caller"\noutput-type = "executable"\n'
                    '[dependencies]\npocketkit = { path = "../demo-v2", output-type = "static" }\n')
        sections = {section: "任务 " + section for section in ("caller-setup", *GUIDE_TASKS)}
        programs = {section: f'package guide_caller\n// 文本 {section}\nmain() {{ println("PASS guide-{section}") }}\n'
                    for section in GUIDE_TASKS}
        text = ("# Caller\n\n## 任务 caller-setup\n\n```toml\n" + manifest +
                '```\n\n```sh\ncjpm run --build-args "--jobs 1"\n```\n')
        for section, program in programs.items():
            text += "\n## " + sections[section] + "\n\n```cangjie\n" + program + "```\n"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "guide.md"
            path.write_bytes(text.replace("\n", "\r\n").encode("utf-8"))
            actual = extract_guide_programs(path, sections)
        self.assertEqual(actual.manifest, manifest.replace("\n", "\r\n").encode("utf-8"))
        self.assertEqual(actual.programs, {section: code.replace("\n", "\r\n").encode("utf-8")
                                         for section, code in programs.items()})
        self.assertEqual(actual.command, ["cjpm", "run", "--build-args", "--jobs 1"])

    def test_guide_parser_rejects_incomplete_or_ambiguous_programs(self):
        repo = Path(__file__).resolve().parents[1]
        project = repo / "examples/pocketkit/demo-v2"
        config = tomllib.loads((project / "cjdoc.toml").read_text(encoding="utf-8"))
        page = next(page for page in config["docs"]["pages"]
                    if page.get("id") == "first-catalogue" and page.get("language") == "en")
        text = (project / page["source"]).read_text(encoding="utf-8")
        variants = {
            "missing program": text.replace("```cangjie", "```text", 1),
            "duplicate program": text + '\n```cangjie\nmain() {}\n```\n',
            "unclosed program": text + '\n```cangjie\nmain() {}\n',
            "missing manifest": text.replace("```toml", "```text", 1),
            "wrong command": text.replace('--jobs 1', '--jobs 2', 1),
            "unknown section": text.replace("## Store and read text", "## Unmapped task", 1),
            "duplicate section": text + "\n## Store and read text\n",
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "guide.md"
            for reason, altered in variants.items():
                with self.subTest(reason=reason):
                    path.write_text(altered, encoding="utf-8")
                    with self.assertRaises(ValueError):
                        extract_guide_programs(path, page["sections"])

    def test_guide_evidence_rejects_wrong_extra_or_failed_success_output(self):
        completed = {"exitCode": 0, "timedOut": False}
        marker = "PASS guide-store-read"
        validate_guide_result(completed, "cjpm build success\n" + marker + "\n", "", "store-read")
        for stdout, stderr in (("", ""), ("PASS guide-index-errors\n", ""),
                               (marker + "\n" + marker, ""), (marker, "PASS unexpected"),
                               ("prefix " + marker, ""), (marker + " extra", "")):
            with self.subTest(stdout=stdout, stderr=stderr), self.assertRaises(ValueError):
                validate_guide_result(completed, stdout, stderr, "store-read")
        for result in ({"exitCode": 1, "timedOut": False}, {"exitCode": 0, "timedOut": True}):
            with self.subTest(result=result), self.assertRaises(ValueError):
                validate_guide_result(result, marker, "", "store-read")

    def test_existing_corpus_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "owned.txt"
            marker.write_text("preserve", encoding="utf-8")
            with self.assertRaises(FileExistsError):
                generate_corpus(root, 1000)
            self.assertEqual(marker.read_text(encoding="utf-8"), "preserve")


class ReaderTransitionEvidenceTests(unittest.TestCase):
    def test_registration_freezes_release_version_before_after_capture(self):
        before, after = ir_transition_pair()
        before["generator"]["version"] = "0.7.7"
        for model in (before, after):
            model["generator"].update(name="cjdoc", toolchain="")
        repo = Path(__file__).resolve().parent.parent
        after["generator"]["version"] = tomllib.loads(
            (repo / "cjpm.toml").read_text())["package"]["version"]
        with tempfile.TemporaryDirectory() as directory:
            baseline, candidate = [Path(directory) / label for label in ("baseline", "after")]
            before_path = baseline / "native-json/docs.json"
            before_path.parent.mkdir(parents=True)
            before_path.write_text(json.dumps(before), encoding="utf-8")
            old = {"label": "baseline", "status": "measured",
                   "rendererRevision": "a" * 40, "sourceSha256": "b" * 64,
                   "nativeResult": {"docIrSha256": file_digest(before_path)}, "locales": []}
            (baseline / "reader-generation.json").write_text(json.dumps(old), encoding="utf-8")
            budget = register_reader(
                baseline, repo / "docs/maintainer/reader-scale-budgets.json",
                doc_ir_transition=TRANSITION_NAME)
            frozen = deepcopy(budget)
            after_path = candidate / "native-json/docs.json"
            after_path.parent.mkdir(parents=True)
            after_path.write_text(json.dumps(after), encoding="utf-8")
            new = {"nativeResult": {"docIrSha256": file_digest(after_path)}}
            check_native_ir(baseline, candidate, old, new, None, budget["docIrTransition"])
            self.assertEqual(file_digest(after_path), new["nativeResult"]["docIrSha256"])
            for field in ("version", "name", "toolchain", "build"):
                changed = deepcopy(after)
                changed["generator"][field] = "unregistered"
                after_path.write_text(json.dumps(changed), encoding="utf-8")
                new["nativeResult"]["docIrSha256"] = file_digest(after_path)
                with self.subTest(field=field), self.assertRaises(ValueError):
                    check_native_ir(baseline, candidate, old, new, None, budget["docIrTransition"])
            self.assertEqual(budget, frozen)

    def test_ir_registration_accepts_only_the_exact_v17_v18_defaults(self):
        before, after = ir_transition_pair()
        registration = register_ir_observation(before, "a" * 64, after["generator"]["version"])
        before_copy, after_copy = deepcopy(before), deepcopy(after)
        compare_ir_transition(before, after, registration, "a" * 64)
        self.assertEqual(before, before_copy)
        self.assertEqual(after, after_copy)

        invalid_baselines = [
            ("wrong version", lambda document: document.update(schemaVersion="cjdoc.doc-ir/16")),
            ("missing module field", lambda document: document["modules"][0].pop("repositoryPath")),
            ("non-null module field", lambda document: document["modules"][0].update(repositoryPath="src")),
            ("preexisting provenance", lambda document: document["files"][0].update(provenance={})),
            ("preexisting localization scope",
             lambda document: document["declarations"][0]["documentation"].update(localizationScope="all")),
            ("preexisting tag identity",
             lambda document: document["declarations"][0]["documentation"]["tags"][0].update(entryId=None)),
            ("preexisting tag source",
             lambda document: document["declarations"][0]["documentation"]["tags"][0].update(source=None)),
            ("preexisting localized identity",
             lambda document: document["declarations"][0]["documentation"]["localizedTexts"][0].update(entryId=None)),
            ("authored admonition",
             lambda document: document["declarations"][0]["documentation"].update(
                 markdown={"kind": "admonition", "children": [{"kind": "paragraph"}]})),
        ]
        for label, change in invalid_baselines:
            invalid = deepcopy(before)
            change(invalid)
            with self.subTest(baseline=label), self.assertRaises(ValueError):
                register_ir_observation(invalid, "a" * 64, after["generator"]["version"])

        invalid_after = [
            ("wrong version", lambda document: document.update(schemaVersion="cjdoc.doc-ir/17")),
            ("obsolete module field", lambda document: document["modules"][0].update(repositoryPath=None)),
            ("missing source provenance", lambda document: document["files"][0].pop("provenance")),
            ("missing source digest", lambda document: document["files"][0]["provenance"].pop("sourceDigest")),
            ("missing evidence kind", lambda document: document["files"][0]["provenance"].pop("evidenceKind")),
            ("source provenance state",
             lambda document: document["files"][0]["provenance"].update(state="declared")),
            ("source provenance reason",
             lambda document: document["files"][0]["provenance"].update(reason="other")),
            ("source provenance repository",
             lambda document: document["files"][0]["provenance"].update(repository={})),
            ("source provenance repository path",
             lambda document: document["files"][0]["provenance"].update(repositoryPath="src/api.cj")),
            ("source provenance raw digest",
             lambda document: document["files"][0]["provenance"].update(sourceDigest="sha256:" + "0" * 64)),
            ("source provenance normalized digest",
             lambda document: document["files"][0]["provenance"].update(normalizedDigest="sha256:" + "0" * 64)),
            ("source provenance receipt identity",
             lambda document: document["files"][0]["provenance"].update(evidenceIdentity="0" * 64)),
            ("source provenance kind",
             lambda document: document["files"][0]["provenance"].update(evidenceKind="caller_pinned_receipt")),
            ("missing localization scope",
             lambda document: document["declarations"][0]["documentation"].pop("localizationScope")),
            ("nondefault localization scope",
             lambda document: document["declarations"][0]["documentation"].update(localizationScope="admonitions")),
            ("missing tag identity",
             lambda document: document["declarations"][0]["documentation"]["tags"][0].pop("entryId")),
            ("non-null tag identity",
             lambda document: document["declarations"][0]["documentation"]["tags"][0].update(entryId="notice")),
            ("missing tag source",
             lambda document: document["declarations"][0]["documentation"]["tags"][0].pop("source")),
            ("non-null tag source",
             lambda document: document["declarations"][0]["documentation"]["tags"][0].update(source={})),
            ("missing localized identity",
             lambda document: document["declarations"][0]["documentation"]["localizedTexts"][0].pop("entryId")),
            ("non-null localized identity",
             lambda document: document["declarations"][0]["documentation"]["localizedTexts"][0].update(
                 entryId="notice")),
            ("authored admonition",
             lambda document: document["declarations"][0]["documentation"].update(
                 markdown={"kind": "admonition", "children": [{"kind": "paragraph"}]})),
            ("generator drift", lambda document: document["generator"].update(version="0.7.4")),
            ("metadata drift", lambda document: document["metadata"].update(project="other-project")),
            ("signature drift",
             lambda document: document["declarations"][0].update(signature="public func target(): Int64")),
            ("header drift",
             lambda document: document["declarations"][0]["documentation"].update(summary="other header")),
            ("body drift",
             lambda document: document["declarations"][0]["documentation"].update(description="other body")),
        ]
        for label, change in invalid_after:
            altered = deepcopy(after)
            change(altered)
            with self.subTest(after=label), self.assertRaises(ValueError):
                compare_ir_transition(before, altered, registration, "a" * 64)
        with self.assertRaises(ValueError):
            compare_ir_transition(before, after, registration, "b" * 64)

    def test_register_freezes_artifact_receipts_consumed_by_compare(self):
        before_ir, after_ir = ir_transition_pair()
        repo = Path(__file__).resolve().parent.parent
        after_ir["generator"]["version"] = tomllib.loads(
            (repo / "cjpm.toml").read_text())["package"]["version"]
        template = repo / "docs/maintainer/reader-scale-budgets.json"
        with tempfile.TemporaryDirectory() as directory:
            baseline = Path(directory) / "baseline"
            baseline.mkdir()
            native_dir = baseline / "native-json"
            native_dir.mkdir()
            native_path = native_dir / "docs.json"
            native_path.write_text(json.dumps(before_ir, ensure_ascii=False), encoding="utf-8")
            locales = []
            browser_resources = {}
            for locale in ("en", "zh-CN"):
                site_name = f"sites/{locale}"
                site, resources, _, _ = write_search_site(baseline / site_name, before_ir, locale)
                browser_name = f"browser/{locale}.json"
                browser = {"failures": [], "resources": resources, "transports": []}
                browser_path = baseline / browser_name
                browser_path.parent.mkdir(parents=True, exist_ok=True)
                browser_path.write_text(json.dumps(browser), encoding="utf-8")
                browser_resources[locale] = (site, resources)
                locales.append({"locale": locale, "browserReport": browser_name, "site": site_name})
            # This is a structural receipt fixture with no timing samples; it exercises registration
            # and comparison identity binding only, not performance acceptance.
            generation = {
                "label": "baseline", "schemaVersion": "cjdoc.reader-generation/1",
                "status": "measured", "rendererRevision": "a" * 40, "sourceSha256": "b" * 64,
                "nativeResult": {"docIrSha256": file_digest(native_path)},
                "locales": locales,
            }
            (baseline / "reader-generation.json").write_text(
                json.dumps(generation), encoding="utf-8")
            budget = register_reader(baseline, template, doc_ir_transition=TRANSITION_NAME)
            self.assertEqual(set(budget["docIrTransition"]["published"]), {"en", "zh-CN"})
            self.assertNotIn("presentation", budget)
            self.assertEqual(budget["transitionTemplate"]["sha256"], file_digest(template))

            baseline_site, baseline_resources = browser_resources["en"]
            changed_site, changed_resources, _, _ = write_search_site(
                Path(directory) / "after/sites/en", after_ir, "en", body="changed published body")
            before_browser = {
                "schemaVersion": "cjdoc.reader-browser/1", "recipe": "fixture",
                "sourceSha256": "b" * 64, "taskManifestSha256": "c" * 64,
                "harness": {"browser": "fixture"},
                "environment": {"requestedUiLocale": "en",
                                "fontFiles": [{"family": "Fixture", "status": "measured"}]},
                "nativeIndexEntries": 1, "failures": [], "resources": baseline_resources,
            }
            after_browser = deepcopy(before_browser)
            after_browser["resources"] = changed_resources
            with self.assertRaises(ValueError):
                compare_browser(before_browser, after_browser, {}, budget, [],
                                (baseline_site, changed_site))

    def test_cli_reports_corrupt_search_schema_as_invalid_evidence(self):
        before_ir, after_ir = ir_transition_pair()
        repo = Path(__file__).resolve().parent.parent
        after_ir["generator"]["version"] = tomllib.loads(
            (repo / "cjpm.toml").read_text())["package"]["version"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "tasks.json"
            manifest.write_text("{}", encoding="utf-8")
            for label, model in (("baseline", before_ir), ("after", after_ir)):
                observation = root / label
                native = observation / "native-json/docs.json"
                native.parent.mkdir(parents=True)
                native.write_text(json.dumps(model), encoding="utf-8")
                locales = []
                for locale in ("en", "zh-CN"):
                    site_name = f"sites/{locale}"
                    _, resources, _, _ = write_search_site(
                        observation / site_name, model, locale,
                        search_schema_version="cjdoc.search-index/10" if label == "after" else "cjdoc.search-index/11")
                    browser_name = f"browser-{locale}.json"
                    browser = {"schemaVersion": "cjdoc.reader-browser/1", "recipe": "fixture",
                               "sourceSha256": "b" * 64, "taskManifestSha256": file_digest(manifest),
                               "harness": {"browser": "fixture"}, "nativeIndexEntries": 1,
                               "environment": {"requestedUiLocale": locale,
                                               "fontFiles": [{"status": "measured"}]},
                               "failures": [], "transports": [], "resources": resources}
                    (observation / browser_name).write_text(json.dumps(browser), encoding="utf-8")
                    locales.append({"locale": locale, "browserReport": browser_name, "site": site_name})
                toolchain = {key: "fixture" for key in ("CJDOC_TOOLCHAIN_FINGERPRINT", "CJDOC_STDX_DIGEST",
                                                       "CJDOC_TOOLCHAIN_VERSION", "CJDOC_TOOLCHAIN_TARGET")}
                toolchain.update({name: {"version": "fixture", "sha256": "a" * 64} for name in ("cjc", "cjpm")})
                generation = {"label": label, "schemaVersion": "cjdoc.reader-generation/1", "status": "measured",
                              "rendererRevision": "a" * 40, "sourceSha256": "b" * 64, "recipe": "fixture",
                              "taskManifestSha256": file_digest(manifest), "configuration": {}, "sources": [],
                              "toolchain": toolchain, "nativeResult": {"docIrSha256": file_digest(native),
                                                                     "status": "complete"}, "locales": locales}
                (observation / "reader-generation.json").write_text(json.dumps(generation), encoding="utf-8")
            budget = register_reader(root / "baseline", repo / "docs/maintainer/reader-scale-budgets.json",
                                     doc_ir_transition=TRANSITION_NAME)
            budget_path, result_path = root / "budget.json", root / "comparison.json"
            budget_path.write_text(json.dumps(budget), encoding="utf-8")
            command = [sys.executable, str(repo / "scripts/reader_compare.py"), "--baseline", str(root / "baseline"),
                       "--after", str(root / "after"), "--manifest", str(manifest),
                       "--budgets", str(budget_path), "--output", str(result_path)]
            result = subprocess.run(command, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 1)
            comparison = json.loads(result_path.read_text(encoding="utf-8"))
            self.assertEqual(comparison["status"], "invalid-evidence")
            self.assertFalse(comparison["pass"])

    def test_native_comparison_consumes_raw_receipts_and_keeps_default_strictness(self):
        before, after = ir_transition_pair()
        with tempfile.TemporaryDirectory() as directory:
            roots = [Path(directory) / label for label in ("baseline", "after")]
            receipts = []
            for root, document in zip(roots, (before, after)):
                native = root / "native-json"
                native.mkdir(parents=True)
                path = native / "docs.json"
                path.write_text(json.dumps(document, ensure_ascii=False), encoding="utf-8")
                receipts.append({"nativeResult": {"docIrSha256": file_digest(path)}})
            registration = register_ir_transition(
                roots[0] / "native-json/docs.json", receipts[0]["nativeResult"]["docIrSha256"],
                after["generator"]["version"])
            check_native_ir(roots[0], roots[1], receipts[0], receipts[1], None,
                            {"native": registration})
            with self.assertRaises(EvidenceError):
                check_native_ir(roots[0], roots[1], receipts[0], receipts[1], None)
            with self.assertRaises(ValueError):
                register_ir_transition(roots[0] / "native-json/docs.json", "0" * 64,
                                       after["generator"]["version"])
            wrong_receipt = deepcopy(receipts[0])
            wrong_receipt["nativeResult"]["docIrSha256"] = "0" * 64
            with self.assertRaises(EvidenceError):
                check_native_ir(roots[0], roots[1], wrong_receipt, receipts[1], None,
                                {"native": registration})

            altered = deepcopy(after)
            altered["declarations"][0]["documentation"]["description"] = "different captured body"
            after_path = roots[1] / "native-json/docs.json"
            after_path.write_text(json.dumps(altered, ensure_ascii=False), encoding="utf-8")
            receipts[1]["nativeResult"]["docIrSha256"] = file_digest(after_path)
            with self.assertRaises(ValueError):
                check_native_ir(roots[0], roots[1], receipts[0], receipts[1], None,
                                {"native": registration})

    def test_verified_search_pair_allows_only_proven_identity_tokens(self):
        before_ir, after_ir = ir_transition_pair()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            publisher_pairs = {}
            for locale in ("en", "zh-CN"):
                before_site, before_resources, _, _ = write_search_site(
                    root / f"before-{locale}", before_ir, locale)
                after_site, after_resources, _, _ = write_search_site(
                    root / f"after-{locale}", after_ir, locale)
                before_proof = verify_search_identity(before_site, before_resources)
                after_proof = verify_search_identity(after_site, after_resources)
                self.assertNotEqual(before_proof["snapshotId"], after_proof["snapshotId"])
                self.assertNotEqual(before_proof["projectionId"], after_proof["projectionId"])
                compare_search_identities(before_proof, after_proof)
                publisher_pairs[locale] = (
                    before_site, after_site, before_resources, after_resources, before_proof, after_proof)
            registrations = {
                locale: register_ir_observation(pair[4]["docIr"], pair[4]["docIrSha256"],
                                                after_ir["generator"]["version"])
                for locale, pair in publisher_pairs.items()
            }
            transition = {"published": registrations}
            for locale, pair in publisher_pairs.items():
                check_search_transition(search_report(locale, pair[2]), search_report(locale, pair[3]),
                                        transition, (pair[0], pair[1]))
            before_site, after_site, before_resources, after_resources, before_proof, _ = \
                publisher_pairs["en"]
            transition_for_browser = {
                "name": TRANSITION_NAME, "native": {}, "published": registrations,
            }

            before_browser = {
                "schemaVersion": "cjdoc.reader-browser/1", "recipe": "fixture",
                "sourceSha256": "source", "taskManifestSha256": "tasks",
                "harness": {"browser": "fixture"},
                "environment": {"requestedUiLocale": "en",
                                "fontFiles": [{"family": "Fixture", "status": "measured"}]},
                "nativeIndexEntries": 1, "failures": [], "resources": before_resources,
            }
            after_browser = deepcopy(before_browser)
            after_browser["resources"] = after_resources
            with self.assertRaises(EvidenceError):
                compare_browser(before_browser, after_browser, {}, {"transports": []}, [])

            changed_body_site, changed_body_resources, _, _ = write_search_site(
                root / "changed-body", after_ir, body="Changed indexed content")
            changed_body_proof = verify_search_identity(changed_body_site, changed_body_resources)
            with self.assertRaises(ValueError):
                compare_search_identities(before_proof, changed_body_proof)
            with self.assertRaises(ValueError):
                check_search_transition(search_report("en", before_resources),
                                        search_report("en", changed_body_resources),
                                        transition, (before_site, changed_body_site))
            after_browser["resources"] = changed_body_resources
            with self.assertRaises(ValueError):
                compare_browser(before_browser, after_browser, {},
                                {"docIrTransition": transition_for_browser}, [],
                                (before_site, changed_body_site))


    def test_search_receipts_reject_forged_ids_stale_bodies_and_script_content(self):
        before_ir, after_ir = ir_transition_pair()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            forged_snapshot, resources, _, _ = write_search_site(
                root / "forged-snapshot", after_ir,
                snapshot_override="cjdoc:snapshot:v1:" + "0" * 64)
            with self.assertRaises(ValueError):
                verify_search_identity(forged_snapshot, resources)

            forged_projection, resources, _, _ = write_search_site(
                root / "forged-projection", after_ir, projection_override="0" * 64)
            with self.assertRaises(ValueError):
                verify_search_identity(forged_projection, resources)

            stale_site, _, index, signatures = write_search_site(root / "stale-body", after_ir)
            index["entries"][0]["body"] = "changed without a new projection identity"
            encoded_index = json.dumps(index, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            encoded_script = (
                "globalThis.__CJDOC_SEARCH_INDEX__ = " + encoded_index +
                ";\nglobalThis.__CJDOC_SEARCH_SIGNATURES__ = " +
                json.dumps(signatures, ensure_ascii=False, sort_keys=True, separators=(",", ":")) +
                ";\n"
            )
            (stale_site / "search-index.json").write_text(encoded_index, encoding="utf-8")
            (stale_site / "search-index.js").write_bytes(encoded_script.encode("utf-8"))
            with self.assertRaises(ValueError):
                verify_search_identity(stale_site, search_resource_receipts(stale_site))

            for label, options in (
                ("executable suffix", {"script_suffix": "globalThis.injected = true;\n"}),
                ("wrong search schema", {"search_schema_version": "cjdoc.search-index/10"}),
                ("changed contract", {"contract_change": True}),
                ("changed signatures", {"signature": "different signature"}),
            ):
                site, site_resources, _, _ = write_search_site(
                    root / label.replace(" ", "-"), after_ir, **options)
                with self.subTest(change=label):
                    if label in ("executable suffix", "wrong search schema"):
                        with self.assertRaises((ValueError, ContractError)):
                            verify_search_identity(site, site_resources)
                        continue
                    before_site, before_resources, _, _ = write_search_site(
                        root / (label.replace(" ", "-") + "-before"), before_ir)
                    before_proof = verify_search_identity(before_site, before_resources)
                    changed_proof = verify_search_identity(site, site_resources)
                    with self.assertRaises(ValueError):
                        compare_search_identities(before_proof, changed_proof)

            split_script_site, _, index, signatures = write_search_site(root / "split-script", after_ir)
            script_index = deepcopy(index)
            script_index["entries"][0]["body"] = "script payload differs from JSON receipt"
            encoded_script = (
                "globalThis.__CJDOC_SEARCH_INDEX__ = " +
                json.dumps(script_index, ensure_ascii=False, sort_keys=True, separators=(",", ":")) +
                ";\nglobalThis.__CJDOC_SEARCH_SIGNATURES__ = " +
                json.dumps(signatures, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + ";\n"
            )
            (split_script_site / "search-index.js").write_bytes(encoded_script.encode("utf-8"))
            with self.assertRaises(ValueError):
                verify_search_identity(split_script_site, search_resource_receipts(split_script_site))

            tampered_doc_site, resources, _, _ = write_search_site(root / "tampered-doc-ir", after_ir)
            packaged_doc_ir = tampered_doc_site / "agent/doc-ir.json"
            packaged_doc_ir.write_bytes(packaged_doc_ir.read_bytes() + b"\n")
            with self.assertRaises(ValueError):
                verify_search_identity(tampered_doc_site, resources)

            valid_site, _, _, _ = write_search_site(root / "wrong-receipt", after_ir)
            for name in ("search-index.json", "search-index.js"):
                valid_resources = search_resource_receipts(valid_site)
                valid_resources[name]["sha256"] = "0" * 64
                with self.subTest(receipt=name), self.assertRaises(ValueError):
                    verify_search_identity(valid_site, valid_resources)

    def test_aria_registration_binds_complete_pairs_corpus_and_locale(self):
        with tempfile.TemporaryDirectory() as directory:
            registration = aria_fixture(directory)
            profile = validate_aria_registration(registration)
            self.assertEqual(set(profile["locales"]), {"en", "zh-CN"})
            for locale in ("en", "zh-CN"):
                check_aria_pair(aria_observation(registration, locale, "baseline"),
                                aria_observation(registration, locale, "after"), registration)

            changed_profile = deepcopy(registration)
            changed_profile["profile"]["recipe"] += "-tampered"
            with self.assertRaises(ValueError):
                validate_aria_registration(changed_profile)
            changed_snapshot = deepcopy(registration)
            changed_snapshot["snapshots"]["en"]["after"] += "unregistered"
            with self.assertRaises(ValueError):
                validate_aria_registration(changed_snapshot)

            before = aria_observation(registration, "en", "baseline")
            after = aria_observation(registration, "en", "after")
            for label, change in (
                ("corpus", lambda report: report.update(taskManifestSha256="different")),
                ("locale", lambda report: report["environment"].update(requestedUiLocale="fr")),
                ("tree", lambda report: report["accessibility"]["noScript"].update(
                    accessibleTree="incomplete tree")),
                ("no-JS observation", lambda report: report["accessibility"].update(status="not-applicable")),
            ):
                altered = deepcopy(after)
                change(altered)
                with self.subTest(change=label), self.assertRaises(ValueError):
                    check_aria_pair(before, altered, registration)

    def test_aria_only_transition_does_not_waive_typography_fonts_or_fixed_budgets(self):
        with tempfile.TemporaryDirectory() as directory:
            registration = aria_fixture(directory)
            before, after = [], []
            for label, collection in (("baseline", before), ("after", after)):
                observation = aria_observation(registration, "en", label)
                observation["visuals"] = [{
                    "viewport": "desktop", "theme": "light", "target": "member", "locale": "en",
                    "metrics": {"horizontalOverflowPx": 0,
                                "typography": {"bodyFont": "Fixture Sans", "bodyFontSize": "16px"}},
                    "focus": {"positiveTabindex": 0, "mainLandmark": 1, "headingCount": 1},
                }]
                observation["accessibility"].update(
                    screenReaderSpeech={"status": "not-measured"},
                    noScript={**observation["accessibility"]["noScript"], "independentlyOpen": True},
                    print={"contentVisible": True, "overflowPx": 0, "signatures": 1,
                           "detailBodies": 1, "visibleSignatureIds": ["target"],
                           "visibleDetailIds": ["target"]},
                    printCounterexamples=[{"detected": True}] * 3)
                observation["fontUsage"] = [{"family": "Fixture Sans", "sha256": "font"}]
                collection.append(observation)
            check_visuals(before[0], after[0], False, [], aria_registration=registration)
            check_font_usage(before[0], after[0], None)

            changed_typography = deepcopy(after[0])
            changed_typography["visuals"][0]["metrics"]["typography"]["bodyFontSize"] = "14px"
            with self.assertRaises(EvidenceError):
                check_visuals(before[0], changed_typography, False, [],
                              aria_registration=registration)
            changed_font = deepcopy(after[0])
            changed_font["fontUsage"][0]["sha256"] = "other-font"
            with self.assertRaises(EvidenceError):
                check_font_usage(before[0], changed_font, None)

            repo = Path(__file__).resolve().parent.parent
            template = repo / "docs/maintainer/reader-scale-budgets.json"
            budget = json.loads(template.read_text(encoding="utf-8"))
            budget["ariaTransition"] = registration
            budget["transitionTemplate"] = {"sha256": file_digest(template)}
            validate_transition_budget(budget, template)
            relaxed = deepcopy(budget)
            relaxed["absolute"]["querySyncP95Ms"] += 1
            with self.assertRaises(ValueError):
                validate_transition_budget(relaxed, template)
            # A redesign registers typography and the accessible tree beside the
            # exact IR/ARIA transitions; each difference stays explicitly stated.
            presentation = deepcopy(budget)
            presentation["presentation"] = {"profile": {}}
            validate_transition_budget(presentation, template)

            altered_template = deepcopy(budget)
            with tempfile.TemporaryDirectory() as altered_directory:
                altered_path = Path(altered_directory) / "budgets.json"
                changed_core = json.loads(template.read_text(encoding="utf-8"))
                changed_core["relative"]["latency"]["factor"] += 0.01
                altered_path.write_text(json.dumps(changed_core), encoding="utf-8")
                with self.assertRaises(ValueError):
                    validate_transition_budget(altered_template, altered_path)
                altered_template["transitionTemplate"]["sha256"] = file_digest(altered_path)
                with self.assertRaises(ValueError):
                    validate_transition_budget(altered_template, altered_path)

            with tempfile.TemporaryDirectory() as registration_directory:
                missing_baseline = Path(registration_directory) / "not-captured"
                missing_presentation = Path(registration_directory) / "presentation.json"
                # A presentation profile is read before the baseline, so an
                # absent profile is rejected even when transitions are given.
                with self.assertRaises((ValueError, FileNotFoundError)):
                    register_reader(missing_baseline, template, missing_presentation,
                                    doc_ir_transition=TRANSITION_NAME)
                with self.assertRaises((ValueError, FileNotFoundError)):
                    register_reader(missing_baseline, template, missing_presentation,
                                    aria_transition=missing_presentation)
                modified_template = json.loads(template.read_text(encoding="utf-8"))
                modified_template["absolute"]["querySyncP95Ms"] += 1
                modified_template_path = Path(registration_directory) / "modified-budgets.json"
                modified_template_path.write_text(json.dumps(modified_template), encoding="utf-8")
                with self.assertRaises(ValueError):
                    register_reader(missing_baseline, modified_template_path,
                                    doc_ir_transition=TRANSITION_NAME)


@unittest.skipUnless(os.name == "posix" and hasattr(os, "wait4"), "POSIX process-tree evidence only")
class ProcessLifetimeTests(unittest.TestCase):
    def test_exit_and_cpu_rss_belong_to_the_measured_process(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            # A long-lived unittest runner can have a larger resident set than
            # either child. Isolate the controller so pre-exec fork RSS does not
            # mask the allocation difference or make this depend on test order.
            controller = (
                "import json,sys; from pathlib import Path; "
                "from reader_process import measured_process; root=Path(sys.argv[1]); "
                "heavy=measured_process([sys.executable,'-c',"
                "'buffer=bytearray(64*1024*1024); assert buffer[-1]==0'],"
                "root/'heavy-out',root/'heavy-err',10); "
                "light=measured_process([sys.executable,'-c',"
                "'raise SystemExit(7 if sum(range(1000000))==499999500000 else 9)'],"
                "root/'out',root/'err',10); print(json.dumps([heavy,light]))"
            )
            completed = subprocess.run([sys.executable, "-c", controller, str(root)],
                cwd=Path(__file__).parent, capture_output=True, text=True, check=True, timeout=30)
            heavy, result = json.loads(completed.stdout)
            self.assertEqual(result["exitCode"], 7)
            self.assertFalse(result["timedOut"])
            self.assertGreater(result["userCpuMs"] + result["systemCpuMs"], 0)
            self.assertGreater(heavy["peakRssBytes"] - result["peakRssBytes"], 32 * 1024 * 1024)

    def test_parent_exit_cleans_up_running_descendants_on_success_and_failure(self):
        for exit_code in (0, 7):
            with self.subTest(exit_code=exit_code), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                ready, marker = root / "child-started", root / "leaked-child"
                child = ("import time,pathlib; pathlib.Path(" + repr(str(ready)) +
                         ").write_text('started'); time.sleep(.5); pathlib.Path(" +
                         repr(str(marker)) + ").write_text('leaked')")
                parent = ("import subprocess,sys,time,pathlib; subprocess.Popen([sys.executable,'-c'," +
                          repr(child) + "]); ready=pathlib.Path(" + repr(str(ready)) + "); " +
                          "\nwhile not ready.exists(): time.sleep(.005)\nraise SystemExit(" + str(exit_code) + ")")
                result = measured_process([sys.executable, "-c", parent], root / "out", root / "err", 2)
                self.assertTrue(ready.exists(), "the descendant must actually be running before parent exit")
                self.assertEqual(result["exitCode"], exit_code)
                self.assertFalse(result["timedOut"])
                time.sleep(.7)
                self.assertFalse(marker.exists(), "parent exit leaked a descendant past the measurement")

    def test_timeout_terminates_descendants_not_just_the_parent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "leaked-child"
            ready = root / "descendant-started"
            child = "import time,pathlib; time.sleep(1.5); pathlib.Path(" + repr(str(marker)) + ").write_text('leaked')"
            parent = ("import subprocess,sys,time,pathlib; subprocess.Popen([sys.executable,'-c'," +
                      repr(child) + "]); pathlib.Path(" + repr(str(ready)) + ").write_text('ready'); time.sleep(30)")
            result = measured_process([sys.executable, "-c", parent], root / "out", root / "err", .8)
            self.assertTrue(ready.exists(), "the descendant path must actually be exercised")
            self.assertTrue(result["timedOut"])
            self.assertLess(result["exitCode"], 0)
            time.sleep(1.8)
            self.assertFalse(marker.exists(), "deadline left a descendant alive")


class PublicationSafetyTests(unittest.TestCase):
    def test_runtime_thread_and_local_home_are_not_published(self):
        raw = ("2000-01-01 01:02:03.000004 123 E total: 536870912 B\n" +
               str(Path.home() / "private-sdk") + "\nOut of memory\n")
        clean = scrub(raw, {Path.home(): "$HOME"})
        self.assertNotIn(str(Path.home()), clean)
        self.assertNotRegex(clean, r"2000-01-01.*123 E")
        self.assertIn("536870912 B", clean)


@unittest.skipUnless(os.name == "posix" and os.environ.get("CJDOC_READER_TEST_BINARY") and os.environ.get("CJDOC_READER_TEST_REVISION"),
                     "source-bound POSIX native candidate required; the observation workflow runs this case")
class NativeResourceBoundaryTests(unittest.TestCase):
    def test_successful_native_exit_with_bounded_fallback_is_not_a_supported_scale_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = root / "corpus"
            manifest = generate_corpus(project, 1000)
            # Tighten the author-configurable budget for this negative case;
            # never relax the fixed performance cohort's application limits.
            with (project / "cjdoc.toml").open("a", encoding="utf-8") as config:
                config.write("\n[limits]\nmax-doc-ir-mib = 1\n")
            for source in manifest["sources"]:
                source["sha256"] = file_digest(project / source["path"])
            manifest["sourceSha256"] = digest(json.dumps(manifest["sources"], sort_keys=True, separators=(",", ":")).encode())
            manifest_file = project / "reader-corpus.json"
            manifest_file.write_text(json.dumps(manifest, ensure_ascii=False, sort_keys=True) + "\n", encoding="utf-8")
            output = root / "evidence"
            options = argparse.Namespace(binary=Path(os.environ["CJDOC_READER_TEST_BINARY"]),
                project=project, manifest=manifest_file, output=output,
                revision=os.environ["CJDOC_READER_TEST_REVISION"], label="baseline",
                locales=["en"], samples=20, transports="file", screenshots=False, no_browser=True,
                timeout=1800, browser_timeout=1800)
            code = run(options)
            report = json.loads((output / "reader-generation.json").read_text(encoding="utf-8"))
            self.assertEqual(report["stages"][0]["exitCode"], 0)
            self.assertEqual(code, 1)
            self.assertEqual(report["status"], "resource-limited")
            self.assertEqual(report["locales"], [])
            self.assertIn("CJDOC3027", [item["code"] for item in report["nativeResult"]["diagnostics"]])

    def test_real_native_deadline_is_failure_not_an_unsupported_scale(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = root / "corpus"
            generate_corpus(project, 1000)
            output = root / "evidence"
            options = argparse.Namespace(binary=Path(os.environ["CJDOC_READER_TEST_BINARY"]),
                project=project, manifest=project / "reader-corpus.json", output=output,
                revision=os.environ["CJDOC_READER_TEST_REVISION"], label="baseline",
                locales=["en"], samples=20, transports="file", screenshots=False, no_browser=True,
                timeout=.001, browser_timeout=1800)
            self.assertEqual(run(options), 1)
            report = json.loads((output / "reader-generation.json").read_text(encoding="utf-8"))
            self.assertTrue(report["stages"][0]["timedOut"])
            self.assertEqual(report["status"], "failed")
            self.assertEqual(report["locales"], [])


if __name__ == "__main__":
    unittest.main()
