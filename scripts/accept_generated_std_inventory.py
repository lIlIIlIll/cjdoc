#!/usr/bin/env python3
"""Consume actual cjdoc-generated std/stdx source-subset indexes with real SDK inputs.

Run serially in the explicitly selected SDK environment. No generator rebuild,
network access, SDK modification, or hand-written symbol entries occur here.
This script compiles only its private consumer project under --output.
"""
from __future__ import annotations

import argparse
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import urllib.parse

from accept_official_dependency_links import navigation_facts
from prepare_std_source_snapshot import PINNED, verify_prepared

EXPECTED = {
    "std": ["std.collection.ArrayDeque|class|1()", "std.collection.ArrayDeque.capacity|property|0()"],
    "stdx": ["stdx.encoding.json.JsonArray|class|0()", "stdx.encoding.json.JsonArray.add|function|0(JsonValue)"],
}


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def save(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Page(HTMLParser):
    def __init__(self, path: Path):
        super().__init__()
        self.ids = set()
        self.links = []
        self.feed(path.read_text(encoding="utf-8"))

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.add(attrs["id"])
        if tag == "a":
            self.links.append(attrs.get("href", ""))


def local_target(root: Path, href: str) -> tuple[Path, str]:
    parsed = urllib.parse.urlsplit(href)
    if parsed.scheme or parsed.netloc or parsed.query or "\\" in parsed.path:
        raise AssertionError("generated target is not local")
    path = urllib.parse.unquote(parsed.path).removeprefix("./")
    if PurePosixPath(path).is_absolute() or ".." in PurePosixPath(path).parts:
        raise AssertionError("generated target escapes local snapshot")
    resolved = root / path
    if not resolved.is_file():
        raise AssertionError("generated target page does not exist")
    fragment = urllib.parse.unquote(parsed.fragment)
    if fragment and fragment not in Page(resolved).ids:
        raise AssertionError("generated target fragment does not exist")
    return resolved, fragment


class Acceptance:
    def __init__(self, args):
        self.args = args
        self.repo = Path(__file__).resolve().parents[1]
        self.output = args.output.resolve()
        self.sources = args.sources.resolve(strict=True)
        self.binary = args.binary.resolve(strict=True)
        self.sdk = args.sdk.resolve(strict=True)
        self.stdx = args.stdx.resolve(strict=True)
        if self.output.exists():
            raise ValueError("output must be new")
        self.output.mkdir(parents=True, mode=0o700)
        self.evidence = self.output / "evidence"
        self.evidence.mkdir()
        self.commands = []
        self.generated = {}
        self.provenance = verify_prepared(self.sources)

    def run(self, name, command, cwd=None):
        result = subprocess.run([str(item) for item in command], cwd=cwd or self.repo,
                                capture_output=True, text=True, timeout=600)
        text = result.stdout + result.stderr
        for original, portable in sorted([(str(self.output), "<acceptance>"), (str(self.sources), "<source-subset>"),
                                          (str(self.repo), "<repo>"), (str(self.sdk), "<sdk>"),
                                          (str(self.stdx), "<stdx>"), (str(Path.home()), "$HOME")],
                                         key=lambda pair: -len(pair[0])):
            text = text.replace(original, portable)
        (self.evidence / (name + ".log")).write_text(text, encoding="utf-8")
        self.commands.append({"name": name, "exitCode": result.returncode})
        if result.returncode:
            raise RuntimeError(name + " failed; see sanitized evidence log")
        return result

    def produce(self, library):
        project = self.sources / library
        destination = self.output / ("producer-" + library)
        # Real unmodified Cangjie source is parsed by the current binary. The
        # preparation script has no symbol-index construction capability.
        self.run("produce-" + library, [self.binary, "generate", "--project", project,
                 "--format", "json", "--format", "html", "--format", "symbol-index",
                 "--output", destination, "--doc-version", "source-subset-documentation",
                 "--lint-profile", "off", "--no-cache"])
        path = destination / "html/symbol-index.json"
        inventory = load(path)
        assert inventory["schemaVersion"] == "cjdoc.symbol-index/2"
        document = load(destination / "docs.json")
        by_key = {entry["symbolKey"]: entry for entry in inventory["entries"]}
        observed = []
        for key in EXPECTED[library]:
            assert key in by_key, "actual upstream declaration not generated: " + key
            entry = by_key[key]
            local_target(destination / "html", entry["href"])
            observed.append(entry)
        sets = {item["id"]: item for item in inventory["documentSets"]}
        identities = {entry["identity"] for entry in observed}
        assert len(identities) == 1 and "" not in identities
        metadata = sets[observed[0]["documentSetId"]]
        assert all(entry["documentSetId"] == metadata["id"] for entry in observed)
        assert metadata["library"] == library and metadata["source"] == "source-snapshot"
        assert metadata["identity"] in identities
        assert metadata["apiVersion"] == "", "wrapper invented an upstream API version"
        assert metadata["revision"] == "", "unsupplied API revision must remain unknown"
        assert metadata["documentationRevision"] == "source-subset-documentation"
        self.generated[library] = {"path": path, "directory": destination / "html", "inventory": inventory,
                                   "metadata": metadata, "observed": observed, "document": document}

    def consumer(self):
        project = self.output / "consumer"
        (project / "src").mkdir(parents=True)
        (project / "cjpm.toml").write_text(
            '[package]\ncjc-version = "1.2.0"\nname = "generated_std_consumer"\nversion = "0.1.0"\noutput-type = "static"\n' +
            '[target.' + self.args.target + '.bin-dependencies]\npath-option = [' + json.dumps(str(self.stdx)) + ']\n',
            encoding="utf-8")
        (project / "src/api.cj").write_text('''package generated_std_consumer
import std.collection as stdCollection
import stdx.encoding.json as stdxJson
/** The real target standard-library type; {@link std.collection.ArrayDeque.capacity}. */
public func deque(value: stdCollection.ArrayDeque<Int64>): stdCollection.ArrayDeque<Int64> { value }
/** The independently selected extension type.
 * @see stdx.encoding.json.JsonArray.add(JsonValue) Source-subset member reference.
 */
public func json(value: stdxJson.JsonArray): stdxJson.JsonArray { value }
private func actualMemberWitness(queue: stdCollection.ArrayDeque<Int64>, values: stdxJson.JsonArray): Int64 {
    values.add(stdxJson.JsonString("value"))
    queue.capacity
}
''', encoding="utf-8")
        cjpm = self.sdk / "tools/bin/cjpm"
        if not cjpm.is_file():
            cjpm = self.sdk / "bin/cjpm"
        self.run("actual-consumer-build", [cjpm, "build"], project)
        std = self.sdk / "modules" / self.args.module_target / "std/std.collection.cjo"
        extension = self.stdx / "stdx.encoding.json.cjo"
        assert std.is_file() and extension.is_file()
        context = self.output / "build-context.json"
        self.run("capture-actual-inputs", [sys.executable, self.repo / "scripts/capture_build_context.py",
                 "--project", project, "--output", context, "--target", self.args.target,
                 "--dependency", "generated_std_consumer:toolchain:toolchain=" + str(self.sdk / "bin/cjc"),
                 "--dependency", "generated_std_consumer:std:std=" + str(std),
                 "--dependency", "generated_std_consumer:stdx:stdx=" + str(extension)])
        record = load(context)
        selected = {item["kind"]: item for item in record["modules"][0]["dependencies"]}
        assert selected["std"]["identity"] != selected["stdx"]["identity"]
        self.project, self.context, self.selected = project, context, selected

    def catalog(self, name, *, wrong_target=False):
        documents = []
        for library, generated in self.generated.items():
            mapping = {"fromIdentity": self.selected[library]["identity"],
                       "toIdentity": generated["metadata"]["identity"],
                       "target": "unselected-target" if wrong_target else self.args.target, "cfg": "",
                       "evidence": "Explicit scoped reference mapping: actual consumer compiled against selected SDK artifact; target inventory generated by cjdoc from three pinned upstream Cangjie source files. Not a release mapping or full API/ABI/behavior equivalence."}
            documents.append({"index": generated["path"].relative_to(self.output).as_posix(),
                              "baseUrl": "./generated-" + library, "compatibilityMappings": [mapping]})
        path = self.output / (name + ".json")
        save(path, {"schemaVersion": "cjdoc.doc-sources/1", "documents": documents})
        return path

    def generate(self, name, catalog, compatible):
        destination = self.output / name
        command = [self.binary, "generate", "--project", self.project, "--build-context", self.context,
                   "--doc-source", catalog, "--format", "json", "--format", "html", "--format", "markdown",
                   "--output", destination, "--lint-profile", "off", "--no-cache"]
        for generated in self.generated.values():
            command += ["--doc-inventory-pin", str(generated["path"]) + "=" + sha(generated["path"])]
        if compatible:
            command.append("--link-compatible")
        self.run(name, command)
        return load(destination / "docs.json"), destination

    def validate(self, document, site):
        components = {item["kind"]: item for item in document["dependencies"] if item["kind"] in ("std", "stdx", "toolchain")}
        assert all(components[k]["state"] == "verified" for k in ("std", "stdx", "toolchain"))
        assert all(components[k]["identity"] == self.selected[k]["identity"] for k in ("std", "stdx"))
        public = [item for item in document["declarations"] if item["name"] in ("deque", "json")]
        assert len(public) == 2
        for declaration in public:
            for reference in [*(item["type"] for item in declaration["parameters"]), declaration["returnType"]]:
                nav = reference["navigation"]
                assert nav["state"] == "resolved" and nav["matchLevel"] == "compatible"
        decisions = [nav for declaration in public for nav in navigation_facts(declaration)
                     if nav.get("symbolKey") in {key for keys in EXPECTED.values() for key in keys}]
        assert {nav["symbolKey"] for nav in decisions} == {key for keys in EXPECTED.values() for key in keys}
        for library, generated in self.generated.items():
            shutil.copytree(generated["directory"], site / "html" / ("generated-" + library))
        for nav in decisions:
            assert nav["state"] == "resolved" and nav["matchLevel"] == "compatible"
            library = "stdx" if nav["symbolKey"].startswith("stdx.") else "std"
            assert nav["apiIdentity"] == self.generated[library]["metadata"]["identity"]
            local_target(site / "html", nav["url"])
        links = [href for path in (site / "html/symbols").glob("*.html") for href in Page(path).links]
        for nav in decisions:
            assert "../" + nav["url"].removeprefix("./") in links, "resolved type/member navigation not rendered"
        encoded = (site / "docs.json").read_text(encoding="utf-8")
        assert all(str(path) not in encoded for path in [self.sdk, self.stdx, self.sources, self.output])
        return decisions

    def execute(self):
        for library in PINNED:
            self.produce(library)
        self.consumer()
        catalog = self.catalog("documents")
        document, site = self.generate("site", catalog, True)
        decisions = self.validate(document, site)
        negatives = {}
        expected_keys = {key for keys in EXPECTED.values() for key in keys}
        for name, selected, opted_in in [("not-opted-in", catalog, False),
                                        ("wrong-target", self.catalog("wrong-target-documents", wrong_target=True), True)]:
            negative, _ = self.generate(name, selected, opted_in)
            facts = [nav for nav in navigation_facts(negative) if nav.get("symbolKey") in expected_keys]
            assert not any(nav["state"] == "resolved" and nav["documentSetId"] for nav in facts)
            negatives[name] = {"externalResolved": 0, "facts": len(facts)}
        summary = {"state": "passed", "binarySha256": sha(self.binary), "inventoryProducer": "current cjdoc generate",
                   "sourceScope": self.provenance, "sourceDeclarationRewriting": False, "manualInventoryEntries": False,
                   "sourceSubsetsCompiled": False, "actualConsumerCompiled": True,
                   "installedSdkSourceEquivalence": "not claimed", "releaseMapping": "none",
                   "matchLevel": "compatible", "browserVerification": "not run; exercise site/html separately",
                   "selectedArtifacts": {kind: {"identity": self.selected[kind]["identity"]} for kind in ("std", "stdx")},
                   "producerIndexes": {library: {"sha256": sha(item["path"]), "metadata": item["metadata"],
                                       "entryCount": len(item["inventory"]["entries"]),
                                       "checkedSymbolKeys": EXPECTED[library]} for library, item in self.generated.items()},
                   "decisions": decisions, "negativeCases": negatives, "commands": self.commands}
        save(self.output / "summary.json", summary)
        print("PASS: cjdoc-generated real std/stdx source-subset indexes, independent actual artifacts, compatible-only links and negative opt-in/platform cases")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--sources", type=Path, required=True)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--stdx", type=Path, required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--module-target", default="linux_x86_64_cjnative")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    Acceptance(args).execute()


if __name__ == "__main__":
    main()
