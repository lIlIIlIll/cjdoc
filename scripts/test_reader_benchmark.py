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
from reader_compare import EvidenceError, check_native_ir, compare_browser, p95
from reader_contract_review import copy_sources
from reader_corpus import digest, generate_corpus
from reader_process import measured_process


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

    def test_registered_after_version_matches_current_candidate(self):
        repo = Path(__file__).resolve().parent.parent
        profile = json.loads((repo / "docs/maintainer/reader-scale-presentation.json").read_text())
        package = tomllib.loads((repo / "cjpm.toml").read_text())
        self.assertEqual(profile["generatorVersions"]["after"], package["package"]["version"])

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

    def test_existing_corpus_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "owned.txt"
            marker.write_text("preserve", encoding="utf-8")
            with self.assertRaises(FileExistsError):
                generate_corpus(root, 1000)
            self.assertEqual(marker.read_text(encoding="utf-8"), "preserve")


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
