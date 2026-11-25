"""Native source and frozen-render regression for transitive public imports (#208)."""
from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = "reexport_probe"
MANIFEST = ('[package]\nname = "reexport_probe"\ncjc-version = "1.2.0"\n'
            'version = "1.0.0"\noutput-type = "static"\n')


def write_project(root: Path, root_file: str, *, cycle=False):
    (root / "src").mkdir(parents=True)
    (root / "cjpm.toml").write_text(MANIFEST, encoding="utf-8")
    modules = {
        "": [f"public import {PACKAGE}.relay.value", f"public import {PACKAGE}.hop.aliasValue",
             f"public import {PACKAGE}.selection.{{firstChoice, secondChoice}}",
             f"public import {PACKAGE}.stars.*"],
        "relay": [f"public import {PACKAGE}.origin.value"],
        "hop": [f"public import {PACKAGE}.alias_hop.aliasValue"],
        "alias_hop": [f"public import {PACKAGE}.origin.sourceAlias as aliasValue"],
        "selection": [f"public import {PACKAGE}.origin.{{firstChoice, secondChoice}}"],
        "stars": [f"public import {PACKAGE}.star_origin.*"],
        "origin": [f"public func {name}(): Int64 {{ 1 }}" for name in
                   ("value", "sourceAlias", "firstChoice", "secondChoice", "nearby")]
                  + ["private func hiddenValue(): Int64 { 1 }"],
        "star_origin": ["public func wildcardValue(): Int64 { 1 }"],
        "unrelated": ["public func unrelatedValue(): Int64 { 1 }"],
    }
    if cycle:
        # This is a source-analysis input, not a claim that cjc accepts circular
        # package imports. No backing declaration may be invented for the cycle.
        modules.update({"": [f"public import {PACKAGE}.left.missing"],
                        "left": [f"public import {PACKAGE}.right.missing"],
                        "right": [f"public import {PACKAGE}.left.missing"]})
    for name, lines in modules.items():
        package = f"{PACKAGE}.{name}" if name else PACKAGE
        out = root / "src" / name / ("api.cj" if name else root_file)
        out.parent.mkdir(exist_ok=True)
        out.write_text("\n".join([f"package {package}", *lines, ""]), encoding="utf-8")


def run(command, *, cwd=None, expect=0, input=None):
    process = subprocess.run([str(arg) for arg in command], cwd=cwd, capture_output=True,
                             encoding="utf-8", timeout=100, input=input)
    if process.returncode != expect:
        raise AssertionError(f"{Path(command[0]).name}: expected exit {expect}, got {process.returncode}\n"
                             f"{process.stderr[:3000]}")
    return process


def exports(doc, package=PACKAGE):
    return next(item["reExports"] for item in doc["packages"] if item["name"] == package)


def selected_bindings(doc):
    return {(record["targetPackageName"], binding["exposedName"], binding["importedName"],
             tuple(sorted(binding["targetSymbolIds"])))
            for record in exports(doc) for binding in record["bindings"]}


class ReExportReachabilityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary = Path(os.environ.get("CJDOC_BINARY", ROOT / "target/release/bin/main"))
        if os.name == "nt" and cls.binary.with_suffix(".exe").is_file():
            cls.binary = cls.binary.with_suffix(".exe")
        cls.binary = cls.binary.resolve(strict=True)

    def generate(self, project, *options):
        return json.loads(run([self.binary, "generate", "--project", project, "--semantic", "source",
                               "--lint-profile", "off", "--audience", "all", "--format", "json",
                               "--stdout", *options]).stdout)

    def test_source_order_parallelism_cache_and_strict_render(self):
        with tempfile.TemporaryDirectory(prefix="cjdoc-reexport-") as temp:
            root = Path(temp)
            pristine = None
            for name, filename in (("early", "api.cj"), ("late", "zz_api.cj")):
                project = root / name
                write_project(project, filename)
                run(["cjpm", "build", "--jobs", "1"], cwd=project)
                cache = root / f"cache-{name}"
                for options in (("--no-cache", "--jobs", "1"), ("--cache-dir", cache, "--jobs", "4"),
                                ("--cache-dir", cache, "--jobs", "2")):
                    with self.subTest(filename=filename, mode=options[0], jobs=options[-1]):
                        doc = self.generate(project, *options)
                        self.assertEqual({item["state"] for item in exports(doc)}, {"resolved"})
                        self.assertFalse({"CJDOC1029", "CJDOC1030", "CJDOC1031"} &
                                         {item["code"] for item in doc["diagnostics"]})
                        by_name = {decl["name"]: decl for decl in doc["declarations"]}
                        expected = {("relay", "value", "value", "value"),
                                    ("hop", "aliasValue", "aliasValue", "sourceAlias"),
                                    ("selection", "firstChoice", "firstChoice", "firstChoice"),
                                    ("selection", "secondChoice", "secondChoice", "secondChoice"),
                                    ("stars", "wildcardValue", "wildcardValue", "wildcardValue")}
                        self.assertEqual(selected_bindings(doc), {
                            (f"{PACKAGE}.{pkg}", exposed, imported, (by_name[origin]["id"],))
                            for pkg, exposed, imported, origin in expected})
                        alias, = exports(doc, f"{PACKAGE}.alias_hop")
                        self.assertEqual(alias["bindings"][0]["importedName"], "sourceAlias")
                        if pristine is None:
                            pristine = doc
                        else:
                            self.assertEqual(selected_bindings(doc), selected_bindings(pristine))
                shutil.rmtree(project)
                capture = root / f"{name}.json"
                capture.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
                replay = run([self.binary, "render", "--input", capture, "--format", "json", "--stdout"])
                self.assertEqual(selected_bindings(json.loads(replay.stdout)), selected_bindings(doc))
                output = root / f"rendered-{name}"
                run([self.binary, "render", "--input", capture, "--format", "html", "--output", output])
                self.assertTrue((output / "html" / "index.html").is_file())
                pages = (output / "html" / "agent" / "packages").glob("*.json")
                packages = (json.loads(page.read_bytes()) for page in pages)
                package = next(page for page in packages if page["package"]["name"] == PACKAGE)
                self.assertEqual(package["schemaVersion"], "cjdoc.page/2")
                rows = [binding for entry in package["package"]["reExports"] for binding in entry["bindings"]]
                self.assertEqual(len(rows), 5)
                self.assertTrue(all(set(row) == {"exposedName", "targetSymbolIds"} for row in rows))
                request = {"schemaVersion": "cjdoc.query-request/4", "operation": "get_symbol",
                           "symbolId": by_name["sourceAlias"]["id"], "sections": ["relations"]}
                result = json.loads(run([self.binary, "query", "--snapshot", capture, "--request", "-"],
                                        input=json.dumps(request)).stdout)
                self.assertEqual(result["schemaVersion"], "cjdoc.query-result/5")
                item, = result["result"]["items"]
                alias_context = [row for row in item["exposures"]
                                 if row["exposedName"] == "aliasValue" and row["declaringPackage"] == PACKAGE]
                self.assertEqual(len(alias_context), 1)
                exact, = alias_context[0]["reExport"]["bindings"]
                self.assertEqual(exact, {"exposedName": "aliasValue",
                                         "targetSymbolIds": [by_name["sourceAlias"]["id"]]})
            self.reject_nonexposed_targets(root, pristine)

    def reject_nonexposed_targets(self, root, pristine):
        declarations = {decl["name"]: decl["id"] for decl in pristine["declarations"]}
        capture = root / "forged.json"
        for forged in ("nearby", "hiddenValue", "unrelatedValue", "absent_symbol"):
            with self.subTest(forged=forged):
                changed = copy.deepcopy(pristine)
                relay = next(entry for entry in exports(changed) if entry["targetPackageName"].endswith(".relay"))
                relay["bindings"][0]["targetSymbolIds"] = [declarations[forged] if forged != "absent_symbol"
                                                            else declarations["value"].replace("function:value", "function:absent_symbol")]
                capture.write_text(json.dumps(changed, ensure_ascii=False), encoding="utf-8")
                result = run([self.binary, "render", "--input", capture, "--format", "json", "--stdout"],
                             expect=2)
                self.assertIn("reExports", result.stderr)
                self.assertIn("target", result.stderr)
        for package in ("alias_hop", "selection"):
            with self.subTest(package=package):
                changed = copy.deepcopy(pristine)
                entry, = exports(changed, f"{PACKAGE}.{package}")
                entry["bindings"][0]["importedName"] = "missing"
                capture.write_text(json.dumps(changed), encoding="utf-8")
                result = run([self.binary, "render", "--input", capture, "--format", "json", "--stdout"],
                             expect=2)
                self.assertIn("re-export target must be", result.stderr)
        changed = copy.deepcopy(pristine)
        alias, = exports(changed, f"{PACKAGE}.alias_hop")
        del alias["bindings"][0]["importedName"]
        capture.write_text(json.dumps(changed), encoding="utf-8")
        result = run([self.binary, "render", "--input", capture, "--format", "json", "--stdout"], expect=2)
        self.assertIn("importedName", result.stderr)

    def test_long_chain_proves_each_suffix_without_blessing_sibling_edges(self):
        with tempfile.TemporaryDirectory(prefix="cjdoc-reexport-chain-") as temp:
            root = Path(temp)
            project = root / "chain"
            source = project / "src"
            source.mkdir(parents=True)
            (project / "cjpm.toml").write_text(MANIFEST, encoding="utf-8")
            packages = [PACKAGE, *(f"{PACKAGE}.p{index:04d}" for index in range(1000))]
            for package, backing in zip(packages, packages[1:] + [None]):
                directory = source if package == PACKAGE else source / package.rsplit(".", 1)[1]
                directory.mkdir(exist_ok=True)
                declaration = (f"public import {backing}.value" if backing else
                               "public func value(): Int64 { 42 }")
                (directory / "api.cj").write_text(f"package {package}\n{declaration}\n",
                                                   encoding="utf-8")

            doc = self.generate(project, "--no-cache", "--jobs", "4")
            target = next(decl["id"] for decl in doc["declarations"] if decl["name"] == "value")
            bindings = [(entry["state"], binding["targetSymbolIds"])
                        for package in doc["packages"] for entry in package["reExports"]
                        for binding in entry["bindings"]]
            self.assertEqual(bindings, [("resolved", [target])] * 1000)
            shutil.rmtree(project)
            capture = root / "chain.json"
            capture.write_text(json.dumps(doc), encoding="utf-8")
            render = [self.binary, "render", "--input", capture, "--format", "json", "--stdout"]
            self.assertEqual(selected_bindings(json.loads(run(render).stdout)), selected_bindings(doc))

            # A sibling with the same exposure and ID is visited along with the
            # valid branch, but its backing package does not export this spelling.
            relay = exports(doc, packages[1])
            forged = copy.deepcopy(relay[0])
            forged.update(id="cjdoc:reexport:v1:" + "f" * 64, kind="alias",
                          alias="value", targetPackageName=packages[-1])
            forged["bindings"][0]["importedName"] = "nonexistent"
            relay.insert(0, forged)
            capture.write_text(json.dumps(doc), encoding="utf-8")
            self.assertIn("re-export target must be", run(render, expect=2).stderr)

    def test_backing_declaration_is_required_even_through_cycles(self):
        with tempfile.TemporaryDirectory(prefix="cjdoc-reexport-cycle-") as temp:
            root = Path(temp)
            project = root / "cyclic"
            write_project(project, "api.cj", cycle=True)
            doc = self.generate(project, "--no-cache")
            for package in (PACKAGE, f"{PACKAGE}.left", f"{PACKAGE}.right"):
                exported, = exports(doc, package)
                self.assertEqual(exported["state"], "unavailable")
                self.assertEqual(exported["bindings"], [])
            forged_id = next(decl["id"] for decl in doc["declarations"] if decl["name"] == "unrelatedValue")
            for package in (f"{PACKAGE}.left", f"{PACKAGE}.right"):
                exported, = exports(doc, package)
                exported["state"] = "resolved"
                exported["bindings"] = [{"exposedName": "missing", "importedName": "missing",
                                         "targetSymbolIds": [forged_id]}]
            capture = root / "cycle.json"
            capture.write_text(json.dumps(doc), encoding="utf-8")
            rejection = run([self.binary, "render", "--input", capture, "--format", "json", "--stdout"],
                            expect=2)
            self.assertIn("re-export target must be", rejection.stderr)


if __name__ == "__main__":
    unittest.main()
