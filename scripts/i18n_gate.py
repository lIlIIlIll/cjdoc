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
import sys
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
    with (validation_project / "cjdoc.toml").open("a") as configuration:
        configuration.write('\n[doctest]\nmode = "warn"\n')
    validation = work / "validation"
    run("multi-validation", ["generate", "--project", str(validation_project), "--all-languages",
                             "--format", "html", "--lint-profile", "off", "--output", str(validation)])
    evidence = validation / "doctest/results.json"
    assert evidence.is_file()
    for language in ("en", "zh-CN"):
        page = validation / "html" / language / "validation.html"
        assert 'href="../../doctest/results.json"' in page.read_text()
        assert (page.parent / "../../doctest/results.json").resolve() == evidence.resolve()

        members = list((page.parent / "symbols").glob("*.html"))
        evidence_pages = [member for member in members if 'class="example-evidence"' in member.read_text()]
        assert evidence_pages, "native example evidence was not rendered"
        for member in evidence_pages:
            assert 'href="../../../doctest/results.json"' in member.read_text()
            assert (member.parent / "../../../doctest/results.json").resolve() == evidence.resolve()

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
                 targetSymbolId=None, contentLanguage="en", fieldId=symbol["id"] + ":doc:description:")
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

    highlight_project = work / "highlight-project"
    (highlight_project / "src").mkdir(parents=True)
    (highlight_project / "docs").mkdir()
    (highlight_project / "cjpm.toml").write_text('[package]\nname = "highlight_fixture"\nversion = "1.0.0"\noutput-type = "static"\n')
    (highlight_project / "src/api.cj").write_text("package highlight_fixture\npublic func api(): Unit {}\n")
    (highlight_project / "docs/guide.md").write_text("# Guide\n\n```python\nTrue\n```\n")
    (highlight_project / "cjdoc.toml").write_text(
        '[i18n]\ndefault-language = "en"\nlanguages = ["en"]\n' +
        '[[docs.pages]]\nid = "guide"\nlanguage = "en"\nsource = "docs/guide.md"\nroute = "concepts/guide.html"\n' +
        '[highlight]\nmode = "static"\nlanguages = ["python"]\n')
    adapter = work / "adapter.py"
    adapter.write_text("import sys,json,hashlib\nr=json.load(sys.stdin)\nb=r['code'].encode()\n" +
        "print(json.dumps(dict(protocol=r['protocol'],id=r['id'],language=r['language']," +
        "engine=dict(id='highlight.js',revision='11.11.1/cjdoc-map-1'),state='complete'," +
        "byteLength=len(b),sourceHash=hashlib.sha256(b).hexdigest(),spans=[dict(startByte=0,endByte=4,kind='literal')])))\n")
    highlighted = work / "highlighted"
    run("captured-highlighting", ["generate", "--project", str(highlight_project), "--all-languages",
        "--format", "html", "--format", "json", "--output", str(highlighted), "--lint-profile", "off",
        "--highlight-adapter", str(adapter), "--highlight-node", str(Path(sys.executable).resolve())])
    marker = '<span class="code-literal">True</span>'
    assert marker in (highlighted / "html/en/concepts/guide.html").read_text()
    shutil.rmtree(highlight_project)
    highlighted_import = work / "highlighted-import"
    run("captured-highlighting-source-free", ["render", "--input", str(highlighted / "docs.json"),
        "--all-languages", "--format", "html", "--output", str(highlighted_import)])
    assert marker in (highlighted_import / "html/en/concepts/guide.html").read_text()

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
