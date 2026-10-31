#!/usr/bin/env python3
"""Exercise captured declaration metadata through real generation, query and replay."""
from __future__ import annotations

import argparse
import hashlib
import html
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import shutil
import string
import subprocess
import sys
from urllib.parse import parse_qs, urlsplit

from test_agent_artifacts import load_json, unique_keys


MALICIOUS_TITLE = "Catalog <img src=x onerror=alert(1)>"
METADATA = r'''

[[metadata.groups]]
package = "declaration_tags"
id = "10-query"
title = "目录查询"
order = 20
[metadata.groups.titles]
en = "Catalog Query"

[[metadata.groups]]
package = "declaration_tags"
owner = "declaration_tags.StreamReader"
id = "10-query"
title = "读取查询"
order = 10
[metadata.groups.titles]
en = "Reader Query"

[[metadata.groups]]
package = "declaration_tags"
owner = "declaration_tags.StreamReader"
id = "20-state"
title = "读取状态"
order = 0
[metadata.groups.titles]
en = "Reader State"

[[metadata.groups]]
package = "declaration_tags"
owner = "declaration_tags.OtherReader"
id = "10-query"
title = "其他查询"
order = 30
[metadata.groups.titles]
en = "Other Query"

[[metadata.groups]]
package = "declaration_tags"
owner = "declaration_tags.StreamReader"
id = "unused"
title = "Unused private catalog title"

[[metadata.groups]]
package = "declaration_tags.scopes"
owner = "declaration_tags.scopes.MetadataParent"
id = "shared"
title = "父作用域"
order = 0
[metadata.groups.titles]
en = "Parent Scope"

[[metadata.groups]]
package = "declaration_tags.scopes"
owner = "declaration_tags.scopes.MetadataChild"
id = "shared"
title = "子作用域"
order = 50
[metadata.groups.titles]
en = "Child Scope"

[[metadata.tags]]
id = "stream"
title = "流式"
[metadata.tags.titles]
en = "Catalog <img src=x onerror=alert(1)>"

[[metadata.tags]]
id = "stable"
title = "稳定"
[metadata.tags.titles]
en = "Stable"

[[metadata.tags]]
id = "secret"
title = "Hidden metadata title"
'''
SCOPED_SOURCE = '''package declaration_tags.scopes

/** The original declaration owner. */
public open class MetadataParent {
    /**
     * A member inherited from another source scope.
     * @group shared
     */
    public func baseMember(): Unit {}
}

/** A page containing two original declaration scopes. */
public class MetadataChild <: MetadataParent {
    /**
     * A member declared by the page's own owner.
     * @group shared
     */
    public func ownMember(): Unit {}
}
'''
SPECS = {
    "Reader": ("StreamReader", "public class StreamReader"),
    "Other": ("OtherReader", "public class OtherReader"),
    "readInt": ("StreamReader.read", "public func read(count: Int64): Int64"),
    "readText": ("StreamReader.read", "public func read(text: String): String"),
    "readBytes": ("StreamReader.read", "public func read(bytes: Array<UInt8>): Int64"),
    "otherRead": ("OtherReader.read", "public func read(count: Int64): Int64"),
    "name": ("StreamReader.name", "public prop name: String"),
    "untagged": ("StreamReader.untagged", "public func untagged(): Unit"),
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def require_markdown_metadata(text: str, classification: dict, label: str) -> None:
    # CommonMark backslash escapes cover every ASCII punctuation character.
    readable = html.unescape(re.sub(r"\\([" + re.escape(string.punctuation) + r"])", r"\1", text))
    values = classification["tags"] + ([classification["group"]] if classification["group"] else [])
    for value in values:
        if value["title"] == MALICIOUS_TITLE:
            require(MALICIOUS_TITLE not in text, f"{label}: metadata emitted raw executable HTML")
        require("`" + value["id"] + "`" in readable and value["title"] in readable,
                f"{label}: readable text lost captured classification metadata")


def bind(document: dict) -> dict:
    result = {}
    for ref, (name, signature) in SPECS.items():
        matches = [item for item in document["declarations"]
                   if item["qualifiedName"] == "declaration_tags." + name
                   and item["headerSpelling"] == signature]
        require(len(matches) == 1, f"source declaration {ref} is not uniquely captured")
        result[ref] = matches[0]
    return result


def expected_classifications(refs: dict, language: str) -> dict:
    english = language == "en"
    stream = MALICIOUS_TITLE if english else "流式"
    stable = "Stable" if english else "稳定"

    def classification(group, tags):
        return {"group": group, "tags": [{"id": key, "title": title} for key, title in tags]}

    def group(owner, key, title, order):
        return {"id": key, "packageName": "declaration_tags", "ownerId": owner,
                "title": title, "order": order}

    package = group(None, "10-query", "Catalog Query" if english else "目录查询", 20)
    reader = group(refs["Reader"]["id"], "10-query", "Reader Query" if english else "读取查询", 10)
    other = group(refs["Other"]["id"], "10-query", "Other Query" if english else "其他查询", 30)
    state = group(refs["Reader"]["id"], "20-state", "Reader State" if english else "读取状态", 0)
    return {
        "Reader": classification(package, [("stable", stable), ("stream", stream)]),
        "readInt": classification(reader, [("stable", stable), ("stream", stream)]),
        "readText": classification(reader, [("stream", stream)]),
        "readBytes": classification(reader, [("Stream", "Stream")]),
        "otherRead": classification(other, [("stream", stream)]),
        "name": classification(state, [("stable", stable)]),
        "untagged": classification(None, []),
    }


class TagLinks(HTMLParser):
    def __init__(self, text: str):
        super().__init__()
        self.links = []
        self.feed(text)

    def handle_starttag(self, tag, attributes):
        values = dict(attributes)
        if tag == "a" and "data-cjdoc-tag-link" in values:
            self.links.append(values)


class GroupHeadings(HTMLParser):
    def __init__(self, content: str):
        super().__init__()
        self.ids = []
        self.groups = []
        self.heading = None
        self.feed(content)

    def handle_starttag(self, tag, attributes):
        attributes = dict(attributes)
        identifier = attributes.get("id", "")
        if identifier:
            self.ids.append(identifier)
        if tag in ("h2", "h3", "h4") and identifier.startswith("api-group-"):
            self.heading = [tag, identifier, ""]

    def handle_data(self, value):
        if self.heading is not None:
            self.heading[2] += value

    def handle_endtag(self, tag):
        if self.heading is not None and self.heading[0] == tag:
            self.groups.append({"id": self.heading[1], "title": self.heading[2].strip()})
            self.heading = None


class Acceptance:
    def __init__(self, binary: Path, root: Path):
        self.binary = binary.resolve(strict=True)
        self.root = root.absolute()
        require(not self.root.exists() and not self.root.is_symlink(),
                "--output-root must be a new task-owned directory")
        self.root.mkdir(parents=True, mode=0o700)
        self.repo = Path(__file__).resolve().parent.parent
        self.project = self.root / "project"
        shutil.copytree(self.repo / "tests/fixtures/projects/declaration-tags", self.project,
                        ignore=shutil.ignore_patterns("target", ".git", "__pycache__"))
        self.config = self.project / "cjdoc.toml"
        self.config.write_text(self.config.read_text(encoding="utf-8") + METADATA, encoding="utf-8")
        scopes = self.project / "src/scopes"
        scopes.mkdir()
        (scopes / "lib.cj").write_text(SCOPED_SOURCE, encoding="utf-8")
        self.steps = []

    def run(self, name: str, arguments: list, *, environment=None, request=None):
        result = subprocess.run([str(value) for value in arguments], cwd=self.root,
                                input=request, capture_output=True, text=True,
                                env=environment, timeout=180, check=False)
        (self.root / (name + ".stdout")).write_text(result.stdout, encoding="utf-8")
        (self.root / (name + ".stderr")).write_text(result.stderr, encoding="utf-8")
        self.steps.append({"name": name, "exitCode": result.returncode})
        require(result.returncode == 0, f"{name} exited {result.returncode}; inspect its stderr evidence")
        return result.stdout

    def query(self, site: Path, name: str, request: dict, environment=None) -> dict:
        text = self.run(name, [self.binary, "query", "--snapshot", site / "agent/manifest.json",
                              "--request", "-"], environment=environment,
                        request=json.dumps(request, ensure_ascii=True) + "\n")
        return json.loads(text, object_pairs_hook=unique_keys)

    def generate(self, destination: str, *, html_site: bool):
        formats = ["json", "api-surface"] + (["html", "markdown"] if html_site else [])
        command = [self.binary, "generate", "--project", self.project, "--output", self.root / destination,
                   "--no-cache", "--jobs", "1"]
        for value in formats:
            command.extend(["--format", value])
        if html_site:
            command.extend(["--all-languages", "--agent-full"])
        self.run(destination, command)

    def inspect_site(self, site: Path, language: str, label: str, environment=None) -> dict:
        manifest = load_json(site / "agent/manifest.json")
        document = load_json(site / manifest["docIr"]["path"])
        require(document["schemaVersion"] == "cjdoc.doc-ir/17", "replay did not preserve current Doc IR")
        require(len(document["metadata"]["groups"]) == 6, "unused group definition leaked or used group disappeared")
        require({item["id"] for item in document["metadata"]["tags"]} == {"stable", "stream"},
                "hidden-only tag definition leaked or a visible tag definition disappeared")
        refs = bind(document)
        expected = expected_classifications(refs, language)
        representations = {item["id"]: item for item in manifest["representations"] if item["kind"] == "symbol"}
        for ref, classification in expected.items():
            representation = representations[refs[ref]["id"]]
            artifact = load_json(site / representation["json"])
            require(artifact["schemaVersion"] == "cjdoc.declaration/2", "declaration artifact is not current")
            require(artifact["classification"] == classification, f"{language}/{ref}: wrong captured classification")
            require_markdown_metadata((site / representation["markdown"]).read_text(encoding="utf-8"),
                                      classification, f"{language}/{ref}/Markdown")
            for preset in ("summary", "call", "reference"):
                answer = self.query(site, f"{label}-{ref}-{preset}",
                                    {"operation": "get_symbol", "symbolId": refs[ref]["id"], "preset": preset}, environment)
                require(answer["status"] == "ok", f"{language}/{ref}/{preset}: get_symbol failed")
                require(answer["result"]["items"][0]["classification"] == classification,
                        f"{language}/{ref}/{preset}: query lost classification outside section selection")
                require(answer["result"]["facets"] == {"tags": []}, "non-search facets must be empty")
                require_markdown_metadata(answer["text"], classification, f"{language}/{ref}/{preset}/text")
        self.check_search(site, manifest, refs, language, label, environment)
        self.check_links(site, manifest, refs)
        scoped_anchors = self.check_scoped_groups(site, document, representations, language)
        self.run(label + "-artifacts", [sys.executable, self.repo / "scripts/test_agent_artifacts.py",
                                        "--binary", self.binary, "--root", site], environment=environment)
        return {"snapshotId": manifest["snapshotId"], "metadata": document["metadata"],
                "representations": manifest["representations"], "resources": manifest["resources"],
                "scopedGroupAnchors": scoped_anchors}

    def check_scoped_groups(self, site, document, representations, language, *,
                            inherited=False, orders=(0, 50)):
        symbols = {}
        for name in ("MetadataParent", "MetadataChild", "MetadataParent.baseMember", "MetadataChild.ownMember"):
            matches = [item for item in document["declarations"]
                       if item["qualifiedName"] == "declaration_tags.scopes." + name]
            require(len(matches) == 1, f"scoped source declaration {name} was not uniquely captured")
            symbols[name] = matches[0]
        parent = symbols["MetadataParent"]
        child = symbols["MetadataChild"]
        parent_title = "Parent Scope" if language == "en" else "父作用域"
        child_title = "Child Scope" if language == "en" else "子作用域"
        for name, owner, title, order in (("MetadataParent.baseMember", parent, parent_title, orders[0]),
                                         ("MetadataChild.ownMember", child, child_title, orders[1])):
            artifact = load_json(site / representations[symbols[name]["id"]]["json"])
            require(artifact["classification"] == {
                "group": {"id": "shared", "packageName": "declaration_tags.scopes", "ownerId": owner["id"],
                          "title": title, "order": order}, "tags": []},
                "same-page group classification replaced the original declaration owner")
        child_html = (site / representations[child["id"]]["html"]).read_text(encoding="utf-8")
        parsed = GroupHeadings(child_html)
        require(len(parsed.ids) == len(set(parsed.ids)), "scoped group page contains duplicate anchors")
        groups = [group for group in parsed.groups if group["id"].startswith("api-group-shared")]
        if not inherited:
            require(len(groups) == 1 and groups[0]["id"] == "api-group-shared"
                    and groups[0]["title"].startswith(child_title),
                    "source capture lost the page owner's group or inferred an unsupported inherited member")
            return groups
        require(len(groups) == 2, "same-ID inherited and declared groups were merged")
        primary = [group for group in groups if group["id"] == "api-group-shared"]
        secondary = [group for group in groups if group["id"].startswith("api-group-shared--")]
        require(len(primary) == len(secondary) == 1, "group page lost primary or scope-specific old anchors")
        require(primary[0]["title"].startswith(child_title), "display order changed the own-container primary anchor")
        require(secondary[0]["title"].startswith(parent_title), "inherited scope lost its selected title")
        first_title = parent_title if orders[0] < orders[1] else child_title
        require(groups[0]["title"].startswith(first_title), "explicit group order was not respected")
        return groups

    def check_scoped_model(self, environment):
        # Syntax capture proves the base type, not inherited-member visibility.
        # Exercise the public SPI/Doc IR relationship input separately; never
        # relabel this model fixture as compiler-produced semantic evidence.
        document = load_json(self.root / "capture/docs.json")
        symbols = {item["qualifiedName"]: item for item in document["declarations"]}
        parent = symbols["declaration_tags.scopes.MetadataParent"]
        child = symbols["declaration_tags.scopes.MetadataChild"]
        member = symbols["declaration_tags.scopes.MetadataParent.baseMember"]
        require(any(item["kind"] == "superType" and item["state"] == "resolved"
                    and item["targetSymbolId"] == parent["id"]
                    for item in child["symbolRelationships"]),
                "model scenario has no source-captured base-type relationship")
        child["symbolRelationships"].append({
            "kind": "inheritedMember", "targetDisplay": member["qualifiedName"],
            "state": "resolved", "targetSymbolId": member["id"]})
        observed = {}
        for label, orders in (("base", (0, 50)), ("reordered", (100, 1))):
            for group in document["metadata"]["groups"]:
                if group["ownerId"] == parent["id"]:
                    group["order"] = orders[0]
                elif group["ownerId"] == child["id"]:
                    group["order"] = orders[1]
            model = self.root / ("scoped-model-" + label + ".json")
            model.write_text(json.dumps(document, ensure_ascii=False) + "\n", encoding="utf-8")
            destination = self.root / ("scoped-model-" + label)
            self.run("scoped-model-" + label, [self.binary, "render", "--input", model,
                     "--format", "html", "--format", "markdown", "--all-languages",
                     "--agent-full", "--output", destination], environment=environment)
            for language in ("zh-CN", "en"):
                site = destination / "html" / language
                manifest = load_json(site / "agent/manifest.json")
                captured = load_json(site / manifest["docIr"]["path"])
                representations = {item["id"]: item for item in manifest["representations"]
                                   if item["kind"] == "symbol"}
                groups = self.check_scoped_groups(site, captured, representations, language,
                                                  inherited=True, orders=orders)
                identities = {group["title"]: group["id"] for group in groups}
                if label == "base":
                    observed[language] = identities
                else:
                    require(identities == observed[language],
                            "display order changed scope-specific or primary group anchors")

    def check_search(self, site, manifest, refs, language, label, environment):
        expected_ids = {refs[key]["id"] for key in ("Reader", "readInt", "readText", "otherRead")}
        for profile in ("full-ir", "bounded-static"):
            answer = self.query(site, label + "-tag-" + profile,
                                {"operation": "search", "tags": ["stream"], "profile": profile}, environment)
            require(answer["status"] == "ok", "filter-only tag request failed")
            require({item["identity"]["symbolId"] for item in answer["result"]["items"]} == expected_ids,
                    "tag matching used inheritance, a prefix, a title, or the wrong owner")
            require(all(item["match"] == {"score": 0, "reason": "filter_only"}
                        for item in answer["result"]["items"]), "tags changed relevance")
            facets = answer["result"]["facets"]["tags"]
            require([(item["id"], item["title"], item["count"]) for item in facets] == [
                ("stable", "Stable" if language == "en" else "稳定", 2),
                ("stream", MALICIOUS_TITLE if language == "en" else "流式", 4)],
                "facets did not count the complete canonical matching set")
            require(all(item["scope"]["snapshotId"] == manifest["snapshotId"]
                        and item["scope"]["moduleId"] == refs["Reader"]["moduleId"] for item in facets),
                    "facet identity escaped its captured module/snapshot")
        answer = self.query(site, label + "-and", {"operation": "search", "tags": ["stream", "stable", "stream"]}, environment)
        require({item["identity"]["symbolId"] for item in answer["result"]["items"]} ==
                {refs["Reader"]["id"], refs["readInt"]["id"]}, "tag AND or duplicate normalization failed")

    def check_links(self, site, manifest, refs):
        for representation in manifest["representations"]:
            content = (site / representation["html"]).read_text(encoding="utf-8")
            require(MALICIOUS_TITLE not in content, "metadata title entered HTML without escaping")
            for link in TagLinks(content).links:
                query = parse_qs(urlsplit(link["href"]).query)
                require(query.get("snapshotId") == [manifest["snapshotId"]], "tag link has no exact captured snapshot")
                require(query.get("moduleId") == [refs["Reader"]["moduleId"]], "tag link lost module scope")
                require(query.get("tag") == [link["data-cjdoc-tag-id"]], "tag link used title or a prefix instead of exact ID")
        require(MALICIOUS_TITLE not in (site / "search-index.js").read_text(encoding="utf-8"),
                "metadata title entered the executable index without escaping")

    def check_documentation_only(self):
        self.config.write_text(self.config.read_text(encoding="utf-8").replace("Catalog Query", "Reordered Query")
                               .replace("order = 20", "order = 21"), encoding="utf-8")
        source = self.project / "src/lib.cj"
        text = source.read_text(encoding="utf-8")
        source.write_text(text.replace(" * @tag stable\n", " * @tag stable\n * @tag review\n", 1), encoding="utf-8")
        self.generate("changed", html_site=False)
        before = load_json(self.root / "capture/api-surface/api-surface.json")
        after = load_json(self.root / "changed/api-surface/api-surface.json")
        require({item["id"]: item["sourceFingerprint"] for item in before["declarations"]} ==
                {item["id"]: item["sourceFingerprint"] for item in after["declarations"]},
                "tag/title/order changed source API identity")
        report = json.loads(self.run("api-diff", [self.binary, "diff", "--baseline",
                    self.root / "capture/api-surface/api-surface.json", "--current",
                    self.root / "changed/api-surface/api-surface.json", "--format", "json",
                    "--deny-breaking-api", "--deny-potentially-breaking-api"]), object_pairs_hook=unique_keys)
        require(any(item["classification"] == "documentation-only" for item in report["entries"]),
                "changing an authored tag was not reported as documentation-only")
        require(not any(item["classification"] in ("breaking", "potentially-breaking") for item in report["entries"]),
                "declaration metadata was classified as breaking API")

    def frozen_environment(self):
        guard = self.root / "compiler-guards"
        guard.mkdir()
        body = '#!/bin/sh\nprintf "%s\\n" "$0" >> "$CJDOC_REPLAY_COMPILER_LOG"\nexit 91\n'
        for executable in ("cjc", "cjpm"):
            path = guard / executable
            path.write_text(body, encoding="utf-8")
            path.chmod(0o700)
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith(("CANGJIE", "CJDOC", "CJV"))}
        environment["PATH"] = str(guard) + os.pathsep + os.defpath
        environment["CJDOC_REPLAY_COMPILER_LOG"] = str(self.root / "compiler-calls.log")
        return environment

    def execute(self):
        self.generate("capture", html_site=True)
        before = {language: self.inspect_site(self.root / "capture/html" / language, language,
                                             "capture-" + language) for language in ("zh-CN", "en")}
        self.check_documentation_only()
        self.project.rename(self.root / "removed-source-and-config")
        require(not self.project.exists(), "source fixture is still available at its captured location")
        environment = self.frozen_environment()
        self.run("source-free-render", [self.binary, "render", "--input", self.root / "capture/docs.json",
                 "--format", "json", "--format", "html", "--format", "markdown", "--all-languages",
                 "--agent-full", "--output", self.root / "replay"], environment=environment)
        for language in ("zh-CN", "en"):
            after = self.inspect_site(self.root / "replay/html" / language, language,
                                      "replay-" + language, environment)
            require(after == before[language], f"{language}: source-free replay changed metadata or manifest integrity")
        self.check_scoped_model(environment)
        require(not (self.root / "compiler-calls.log").exists(), "source-free replay or queries invoked a compiler")
        receipt = {"schemaVersion": "cjdoc.metadata-acceptance/1",
                   "binarySha256": hashlib.sha256(self.binary.read_bytes()).hexdigest(),
                   "languages": ["zh-CN", "en"], "sourceFreeReplay": True,
                   "compilerCalls": 0, "scopeCollisionEvidence": "explicit-public-doc-ir-model",
                   "steps": self.steps}
        (self.root / "receipt.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print("declaration metadata capture/query/source-free replay passed (zh-CN, en)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    options = parser.parse_args()
    Acceptance(options.binary, options.output_root).execute()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
