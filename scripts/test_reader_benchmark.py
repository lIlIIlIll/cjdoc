#!/usr/bin/env python3
"""Behavioral safeguards for reader evidence; native/browser observations are separate."""
from __future__ import annotations

import argparse
import json
from copy import deepcopy
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest

from reader_benchmark import file_digest, run, scrub, verify_corpus
from reader_compare import EvidenceError, compare_browser, p95
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
            heavy = measured_process([sys.executable, "-c", "buffer = bytearray(64 * 1024 * 1024); assert buffer[-1] == 0"],
                                     root / "heavy-out", root / "heavy-err", 10)
            result = measured_process([sys.executable, "-c", "raise SystemExit(7 if sum(range(1000000)) == 499999500000 else 9)"],
                                      root / "out", root / "err", 10)
            self.assertEqual(result["exitCode"], 7)
            self.assertFalse(result["timedOut"])
            self.assertGreater(result["userCpuMs"] + result["systemCpuMs"], 0)
            self.assertGreater(heavy["peakRssBytes"] - result["peakRssBytes"], 32 * 1024 * 1024)

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


if __name__ == "__main__":
    unittest.main()
