#!/usr/bin/env python3
"""Exercise native language publications, source-free rendering and version fallback."""
from __future__ import annotations

import argparse
import copy
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import shutil
import subprocess

import time
from urllib.parse import unquote, urlsplit


class HtmlIds(HTMLParser):
    def __init__(self, text: str) -> None:
        super().__init__()
        self.ids: set[str] = set()
        self.feed(text)

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        value = dict(attrs).get("id")
        if value:
            self.ids.add(value)


class VersionRoutes(HTMLParser):
    def __init__(self, text: str) -> None:
        super().__init__()
        self.maps: list[dict] = []
        self.feed(text)

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        value = dict(attrs).get("data-cjdoc-version-routes")
        if value:
            self.maps.append(json.loads(value))


def artifacts(root: Path) -> dict[str, str]:
    return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob("*")) if p.is_file() and p.name != ".cjdoc-output.json"}


def cost(root: Path) -> dict:
    files = [p for p in root.rglob("*") if p.is_file()]
    return {"files": len(files), "bytes": sum(p.stat().st_size for p in files),
            "searchIndexBytes": sum(p.stat().st_size for p in files if p.name == "search-index.json")}


def assert_identity_manifest(root: Path, controls: set[tuple]) -> dict:
    manifest = json.loads((root / "site-manifest.json").read_text())
    rows = manifest["routes"]
    identities = [(row["language"], row["pageId"], row["symbolId"], row["sectionId"]) for row in rows]
    assert len(identities) == len(set(identities)), "site manifest contains duplicate route identities"
    actual = {(*identity, row["href"]) for identity, row in zip(identities, rows)}
    assert controls <= actual, "author ids changed builtin page or symbol identities"
    for row in rows:
        url = urlsplit(row["href"])
        target = root / unquote(url.path)
        assert not url.scheme and target.resolve().is_relative_to(root.resolve())
        assert target.is_file(), row
        if url.fragment:
            assert unquote(url.fragment) in HtmlIds(target.read_text()).ids, row
    return manifest


def check_page_route_identities(author: dict, manifest: dict, work: Path, run) -> None:
    """Keep author ids opaque and distinct in native language/version inventories."""
    controls = {(row["language"], row["pageId"], row["symbolId"], row["sectionId"], row["href"])
                for row in manifest["routes"] if row["pageId"] == "api-home" or
                (row["pageId"] or "").startswith("package:") or (row["symbolId"] and row["pageId"] is None)}
    package_id = next(row["pageId"] for row in manifest["routes"]
                      if (row["pageId"] or "").startswith("package:") and row["symbolId"] is None)
    symbol_id = next(row["symbolId"] for row in manifest["routes"]
                     if row["symbolId"] and row["pageId"] is None and row["sectionId"] is None)
    languages = author["languageOptions"]["languages"]
    seeds = {language: next(page for page in author["pages"]
                           if page["language"] == language and page["sections"])
             for language in languages}
    specifications = [
        ("api-home", "home", None), (package_id, "package", None),
        ("symbol:" + symbol_id, "symbol-prefix", None),
        ("context:" + symbol_id, "context-prefix", None),
        ("conceptual:6170692d686f6d65", "conceptual-prefix", None),
        ("指南:section:使用", "unicode", "内容:section:子项"),
        ("topic", "topic", "part"),
        ("topic:section:part", "delimiter", "details:section:inner"),
    ]
    outputs = []
    for version in ("v1", "v2"):
        document = copy.deepcopy(author)
        document["pages"] = []
        for identity, name, section in specifications:
            for language in languages:
                page = copy.deepcopy(seeds[language])
                page.update(id=identity, route=f"concepts/guides/identity-{name}.html",
                            source=f"docs/identity-{name}-{language}.md", targetSymbolIds=[], bindings=[])
                page["sections"] = ([dict(id=section, anchor=seeds[language]["sections"][0]["anchor"])]
                                    if section else [])
                if version == "v2" and name == "delimiter":
                    page.update(route="concepts/guides/identity-renamed.html", sections=[])
                document["pages"].append(page)
        source = work / f"identity-{version}.json"
        source.write_text(json.dumps(document, ensure_ascii=False) + "\n")
        output = work / f"identity-{version}"
        run(f"identity-render-{version}", ["render", "--input", str(source), "--all-languages",
            "--format", "html", "--format", "json", "--doc-version", version, "--output", str(output)])
        rendered = json.loads((output / "docs.json").read_text())
        assert {(page["id"], page["language"]) for page in rendered["pages"]} == {
            (page["id"], page["language"]) for page in document["pages"]}
        assert {item["id"] for item in rendered["declarations"]} == {item["id"] for item in author["declarations"]}
        actual = assert_identity_manifest(output, controls)
        for language in languages:
            for _, name, section in specifications:
                route = ("concepts/guides/identity-renamed.html" if version == "v2" and name == "delimiter"
                         else f"concepts/guides/identity-{name}.html")
                rows = [row for row in actual["routes"] if row["language"] == language and
                        row["href"] == "html/" + language + "/" + route and row["sectionId"] is None]
                assert len(rows) == 1 and rows[0]["pageId"] is not None and rows[0]["symbolId"] is None
                if section and not (version == "v2" and name == "delimiter"):
                    assert any(row["pageId"] == rows[0]["pageId"] and row["sectionId"] == section
                               and row["language"] == language for row in actual["routes"])
        outputs.append(output)
    composed = work / "identity-composed"
    run("identity-compose", ["versions", "compose", "--version", "v1=" + str(outputs[0]),
        "--version", "v2=" + str(outputs[1]), "--latest", "v2", "--output", str(composed)])
    for language in languages:
        for name, target_name, missing in (("delimiter", "renamed", True), ("topic", "topic", False)):
            page = composed / "v1/html" / language / "concepts/guides" / f"identity-{name}.html"
            expected = composed / "v2/html" / language / "concepts/guides" / f"identity-{target_name}.html"
            source_href = "html/" + language + f"/concepts/guides/identity-{name}.html"
            section_id = next(section for _, label, section in specifications if label == name)
            original = json.loads((outputs[0] / "site-manifest.json").read_text())
            anchor = unquote(urlsplit(next(row["href"] for row in original["routes"]
                if row["language"] == language and row["sectionId"] == section_id and
                row["href"].split("#", 1)[0] == source_href)).fragment)
            targets = []
            for mapping in VersionRoutes(page.read_text()).maps:
                if anchor not in mapping:
                    continue
                href, fallback = mapping[anchor]
                url = urlsplit(href)
                target = (page.parent / unquote(url.path)).resolve()
                if target.is_relative_to((composed / "v2").resolve()):
                    targets.append((target, unquote(url.fragment), fallback))
            assert len(targets) == 1, (name, language, targets)
            target, fragment, fallback = targets[0]
            assert target == expected.resolve() and fallback is missing
            assert target.is_file()
            if missing:
                assert not fragment
            else:
                assert fragment in HtmlIds(target.read_text()).ids


def run_gate(binary: Path, repo: Path, work: Path) -> dict:
    if work.exists():
        raise ValueError("i18n gate workdir must be fresh")
    work.mkdir(mode=0o700, parents=True)
    timings = {}

    def run(name: str, args: list[str], expected: int = 0) -> None:
        start = time.perf_counter()
        result = subprocess.run([str(binary), *args], capture_output=True, timeout=300)
        timings[name] = round(time.perf_counter() - start, 6)
        (work / f"{name}.stdout").write_bytes(result.stdout)
        (work / f"{name}.stderr").write_bytes(result.stderr)
        if result.returncode != expected:
            raise AssertionError(f"{name}: expected exit {expected}, got {result.returncode}; inspect its stderr")

    project = work / "project"
    shutil.copytree(repo / "tests/fixtures/projects/i18n", project,
                    ignore=shutil.ignore_patterns("target"))
    # Preserve explicit cross-page and translated section identities in both readers.
    for language, heading in (("en", "Details"), ("zh-CN", "详情")):
        (project / "docs" / language / "reference.md").write_text(f"# Reference\n\n## {heading}\n\nDetails.\n")
        start = project / "docs" / language / "start.md"
        start.write_text(start.read_text() + "\n[Cross-page section](../en/reference.md#details)\n" +
                         "[Self section](../en/start.md#usage)\n")
        with (project / "cjdoc.toml").open("a") as configuration:
            configuration.write(f'\n[[docs.pages]]\nid = "reference"\nlanguage = "{language}"\n' +
                                f'source = "docs/{language}/reference.md"\nroute = "concepts/guides/reference.html"\n' +
                                f'[docs.pages.sections]\ndetails = "{heading.lower()}"\n')
    formats = ["--format", "html", "--format", "json", "--format", "markdown",
               "--format", "api-surface", "--format", "coverage"]
    common = ["generate", "--project", str(project), "--lint-profile", "off", *formats]
    single, multi, warm, imported = (work / name for name in ("single", "multi", "warm", "imported"))
    run("single-cold", [*common, "--locale", "en", "--cache-dir", str(work / "single-cache"), "--output", str(single)])
    run("multi-cold", [*common, "--all-languages", "--cache-dir", str(work / "multi-cache"), "--output", str(multi)])
    run("multi-warm", [*common, "--all-languages", "--cache-dir", str(work / "multi-cache"), "--output", str(warm)])
    assert artifacts(multi) == artifacts(warm), "cold/warm language publications differ"
    assert (single / "docs.json").read_bytes() == (multi / "docs.json").read_bytes()
    run("required-language", ["check", "--project", str(project), "--lint-profile", "off",
                              "--require-language", "en", "--no-cache"], expected=1)
    assert b"CJDOC3111" in (work / "required-language.stderr").read_bytes()
    page_only_project = work / "page-only-project"
    shutil.copytree(project, page_only_project, ignore=shutil.ignore_patterns("target"))
    configuration = page_only_project / "cjdoc.toml"
    page_configuration = configuration.read_text()
    configuration.write_text(page_configuration[page_configuration.index("[[docs.pages]]"):])
    (page_only_project / "src/api.cj").write_text(
        "package language_fixture\n/** Legacy author text. */\n"
        "public func add(left: Int64, right: Int64): Int64 { left + right }\n")
    page_only = work / "page-only"
    run("page-only-language", ["generate", "--project", str(page_only_project), "--locale", "en",
        "--format", "html", "--format", "json", "--lint-profile", "off", "--no-cache", "--output", str(page_only)])
    assert "This guide demonstrates" in (page_only / "html/concepts/guides/start.html").read_text()
    assert "这份指南演示" not in (page_only / "html/concepts/guides/start.html").read_text()
    assert "languageOptions" not in json.loads((page_only / "docs.json").read_text())
    for name, options in (("locale-conflict", ["--all-languages", "--locale", "en"]),
                          ("stdout-conflict", ["--all-languages", "--stdout"]),
                          ("unsupported-locale", ["--locale", "en-US"])):
        run(name, ["generate", "--project", str(project), *options], expected=2)

    run("serve-multilingual-rejected", ["serve", "--project", str(project), "--all-languages"], expected=2)
    validation_project = work / "validation-project"
    shutil.copytree(project, validation_project, ignore=shutil.ignore_patterns("target"))
    (validation_project / "src/api.cj").write_text(
        "package language_fixture\n/** Validation fixture.\n * @example Explanation without executable code.\n */\n"
        "public func add(left: Int64, right: Int64): Int64 { left + right }\n")
    validation = work / "validation"
    run("multi-validation", ["generate", "--project", str(validation_project), "--all-languages",
                             "--format", "html", "--format", "json", "--check-examples",
                             "--lint-profile", "off", "--output", str(validation)])
    assert b"CJDOC3032" in (work / "multi-validation.stderr").read_bytes()
    validation_ir = json.loads((validation / "docs.json").read_text())
    assert any(item["code"] == "CJDOC3032" for item in validation_ir["diagnostics"])
    assert not (validation / "doctest").exists()
    for language in ("en", "zh-CN"):
        page = validation / "html" / language / "index.html"
        assert "CJDOC3032" in page.read_text()
        members = list((page.parent / "symbols").glob("*.html"))
        assert any("Explanation without executable code." in member.read_text() for member in members)
        assert all('class="example-evidence"' not in member.read_text() for member in members)

    author = json.loads((multi / "docs.json").read_text())
    routes = json.loads((multi / "site-manifest.json").read_text())["routes"]
    symbol_route = next(route["href"].removeprefix("html/en/").split("#")[0] for route in routes
                        if route["language"] == "en" and route["symbolId"] and route["sectionId"] is None)
    package_route = next((multi / "html/en/packages").glob("*.html")).relative_to(multi / "html/en").as_posix()
    alias_route = next(path for path in (multi / "html/en/symbols").glob("*.html")
                       if not path.name.startswith("symbol-")).relative_to(multi / "html/en").as_posix()
    english = next(index for index, page in enumerate(author["pages"]) if page["id"] == "start" and page["language"] == "en")
    for name, route in (("home", "index.html"), ("validation", "validation.html"),
                        ("symbol", symbol_route), ("package", package_route), ("alias", alias_route),
                        ("scheme", "javascript:payload.html"), ("encoded", "%2e%2e/payload.html")):
        invalid = copy.deepcopy(author)
        invalid["pages"][english]["route"] = route
        source = work / f"reserved-{name}.json"
        source.write_text(json.dumps(invalid, ensure_ascii=False))
        run(f"reject-reserved-{name}", ["render", "--input", str(source), "--format", "json", "--stdout"], expected=2)
    for name in ("exact", "fallback"):
        invalid = copy.deepcopy(author)
        if name == "exact":
            extra = copy.deepcopy(invalid["pages"][english]); extra["id"] = "independent"
            invalid["pages"].append(extra)
        else:
            invalid["pages"][english]["id"] = "independent"
        source = work / f"collision-{name}.json"; source.write_text(json.dumps(invalid, ensure_ascii=False))
        run(f"reject-page-collision-{name}", ["render", "--input", str(source), "--format", "json", "--stdout"], expected=2)
    tagged = copy.deepcopy(author)
    symbol = next(symbol for symbol in tagged["declarations"] if symbol.get("documentation"))
    field = dict(name="description", subject="", description="Portable tag", referenceState="unavailable",
                 targetSymbolId=None, navigation=None, contentLanguage="en",
                 fieldId=symbol["id"] + ":doc:description:")
    fields = [dict(field), dict(field), dict(field)]
    fields[0].pop("fieldId")
    fields[1].pop("contentLanguage")
    symbol["documentation"]["tags"].extend(fields)
    source = work / "tag-metadata.json"; source.write_text(json.dumps(tagged, ensure_ascii=False))
    run("tag-metadata-roundtrip", ["render", "--input", str(source), "--format", "json", "--stdout"])
    decoded = json.loads((work / "tag-metadata-roundtrip.stdout").read_text())
    output_tags = next(item for item in decoded["declarations"] if item["id"] == symbol["id"])["documentation"]["tags"][-len(fields):]
    assert output_tags == fields
    invalid = copy.deepcopy(author)
    comment = next(symbol["documentation"] for symbol in invalid["declarations"] if symbol.get("documentation"))
    duplicate = next(text for text in comment["localizedTexts"] if text["kind"] == "summary" and text["language"] == "en" and text["state"] == "valid")
    comment["localizedTexts"].append(copy.deepcopy(duplicate))
    source = work / "duplicate-field.json"; source.write_text(json.dumps(invalid, ensure_ascii=False))
    run("reject-duplicate-valid-field", ["render", "--input", str(source), "--format", "json", "--stdout"], expected=2)
    for text in comment["localizedTexts"]:
        if text["fieldId"] == duplicate["fieldId"] and text["language"] == "en":
            text["state"] = "conflict"
    source = work / "duplicate-conflict.json"; source.write_text(json.dumps(invalid, ensure_ascii=False))
    run("preserve-duplicate-conflict", ["render", "--input", str(source), "--format", "json", "--stdout"])
    for language, fragment, self_fragment in (("en", "details", "usage"), ("zh-CN", "详情", "开始使用")):
        html = (multi / "html" / language / "concepts/guides/start.html").read_text()
        markdown = (multi / "markdown" / language / "concepts/guides/start.md").read_text()
        assert f'reference.html#standalone--doc-{fragment}' in html
        assert f'start.html#standalone--doc-{self_fragment}' in html
        assert f'reference.md#{fragment}' in unquote(markdown)
        assert f'start.md#{self_fragment}' in unquote(markdown)

    # The imported IR must own every author variant and guide used below.
    shutil.rmtree(project)
    run("source-free", ["render", "--input", str(multi / "docs.json"), *formats,
                        "--all-languages", "--output", str(imported)])
    assert artifacts(multi) == artifacts(imported), "source-free render differs from native generate"
    search = {lang: json.loads((multi / "html" / lang / "search-index.json").read_text())
              for lang in ("en", "zh-CN")}
    for lang, value in search.items():
        assert value["schemaVersion"] == "cjdoc.search-index/9"
        text = json.dumps(value, ensure_ascii=False)
        assert "HiddenArithmeticalKeyword" not in text
        assert "私有中文标记" not in text
        assert ("Sapphire arithmetic marker" in text) == (lang == "en")
    add = next(item for item in search["en"]["entries"] if item["name"] == "add")
    right = next(item for item in add["fields"] if item["kind"] == "param" and item["subject"] == "right")
    assert right["actualLanguage"] == "zh-CN" and right["state"] == "fallback"
    manifest = json.loads((multi / "site-manifest.json").read_text())
    from publication_ir import project as publication_projection
    published = publication_projection(json.loads((multi / "docs.json").read_text()))
    publication = work / "publication.docs.json"
    publication.write_text(json.dumps(published, ensure_ascii=False) + "\n")
    assert "HiddenArithmeticalKeyword" not in publication.read_text()
    run("publication-ir", ["render", "--input", str(publication), "--format", "json", "--stdout"])
    for route in manifest["routes"]:
        url = urlsplit(route["href"])
        target = multi / unquote(url.path)
        assert target.is_file(), route
        if url.fragment:
            assert unquote(url.fragment) in HtmlIds(target.read_text()).ids, route

    check_page_route_identities(author, manifest, work, run)

    second_project = work / "second-project"
    shutil.copytree(repo / "tests/fixtures/projects/i18n", second_project,
                    ignore=shutil.ignore_patterns("target"))
    config = second_project / "cjdoc.toml"
    config.write_text(config.read_text().replace('languages = ["zh-CN", "en"]', 'languages = ["en"]'))
    with config.open("a") as configuration:
        configuration.write('\n[[docs.pages]]\nid = "reference"\nlanguage = "en"\n' +
                            'source = "docs/en/reference.md"\nroute = "concepts/guides/reference.html"\n')
    (second_project / "docs/en/reference.md").write_text("# Reference\n\nNo matching details section.\n")
    source = second_project / "src/api.cj"
    source.write_text(source.read_text().replace("public func increment(value: String): Int64 { value.size }", ""))
    second = work / "second"
    run("second-version", ["generate", "--project", str(second_project), *formats,
                           "--lint-profile", "off", "--no-cache", "--all-languages", "--output", str(second)])
    composed = work / "composed"
    run("compose", ["versions", "compose", "--version", "v1=" + str(multi),
                    "--version", "v2=" + str(second), "--latest", "v2", "--output", str(composed)])
    versions = json.loads((composed / "versions.json").read_text())
    assert versions["schemaVersion"] == "cjdoc.versions/2"
    assert {v["id"] for v in versions["versions"]} == {"v1", "v2"}
    english_member = next(item for item in search["en"]["entries"]
                          if item["name"] == "increment" and item["parameterTypes"] == ["String"])
    page = composed / "v1/html/en" / english_member["href"]
    assert "symbol unavailable" in page.read_text(), "removed overload must have explicit fallback"
    reference = composed / "v1/html/zh-CN/concepts/guides/reference.html"
    maps = VersionRoutes(reference.read_text()).maps
    assert maps
    targets = [target[0] for mapping in maps for target in mapping.values() if "/v2/" in target[0]]
    assert targets and all(target.endswith("v2/html/en/concepts/guides/reference.html") for target in targets)
    mapped = 0
    for document in composed.rglob("*.html"):
        for routes in VersionRoutes(document.read_text()).maps:
            assert list(routes) == sorted(routes), "version section routes must be serialized in sorted order"
            if len(routes) > 1:
                mapped += 1
    assert mapped > 0, "determinism regression needs a real multi-anchor selector"

    compiler = subprocess.run(["cjc", "-v"], text=True, capture_output=True, timeout=30)
    sdk = next((line.strip() for line in compiler.stdout.splitlines() if "Cangjie Compiler:" in line), "unknown")
    result = {"schemaVersion": "cjdoc.i18n-gate/1", "sdk": sdk,
              "binarySha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "results": {name: "PASS" for name in timings}, "seconds": timings,
              "cost": {"single": cost(single), "multi": cost(multi)}}
    (work / "evidence.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--workdir", type=Path, required=True)
    args = parser.parse_args()
    result = run_gate(args.binary.resolve(), args.repo.resolve(), args.workdir.resolve())
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
