#!/usr/bin/env python3
"""Check unlocalized external snapshots and the existing Markdown adapter."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


URL = "https://docs.example.test/support-v1/symbols/box.html"


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise AssertionError(f"duplicate JSON field: {key}")
        result[key] = value
    return result


def load(path):
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)


def external_entry(output, symbol_id):
    return next(entry for entry in load(output / "html/search-index.json")["entries"]
                if entry.get("canonicalId") == symbol_id)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--workdir", required=True, type=Path)
    args = parser.parse_args()
    work = args.workdir.resolve()
    work.mkdir(mode=0o700, parents=True)
    project = work / "project"
    (project / "src").mkdir(parents=True)
    (project / "docs").mkdir()
    (project / "cjpm.toml").write_text(
        '[package]\nname = "fixture"\nversion = "1.0.0"\noutput-type = "static"\n', encoding="utf-8")
    (project / "src/api.cj").write_text(
        'package fixture\n/** Box. */\npublic class Box {}\n/** Hidden. */\nprivate class Hidden {}\n', encoding="utf-8")
    (project / "cjdoc.toml").write_text(
        '[external-docs.support]\nindex = "docs/support.json"\n'
        'base-url = "https://docs.example.test/support-v1"\nversion = "support-v1"\n', encoding="utf-8")
    (project / "docs/support.json").write_text(json.dumps({
        "schemaVersion": "cjdoc.symbol-index/1", "version": "support-v1", "symbols": [
            {"qualifiedName": "fixture.Box", "href": "symbols/box.html"},
            {"qualifiedName": "fixture.Hidden", "href": "symbols/hidden.html"},
        ],
    }) + "\n", encoding="utf-8")
    binary = args.binary.resolve()
    environment = dict(os.environ, TMPDIR=str(work), TMP=str(work), TEMP=str(work))

    def run(name, arguments):
        result = subprocess.run([str(binary), *arguments], env=environment, capture_output=True, timeout=120)
        (work / f"{name}.stdout").write_bytes(result.stdout)
        (work / f"{name}.stderr").write_bytes(result.stderr)
        assert result.returncode == 0, (name, result.returncode, result.stderr.decode(errors="replace"))

    direct = work / "direct"
    run("direct", ["generate", "--project", str(project), "--no-cache", "--lint-profile", "off",
                   "--format", "html", "--format", "json", "--format", "markdown",
                   "--locale", "en", "--output", str(direct)])
    document = load(direct / "docs.json")
    symbol = next(value for value in document["declarations"] if value["qualifiedName"] == "fixture.Box")
    direct_entry = external_entry(direct, symbol["id"])
    html_page = direct / "html" / direct_entry["href"]
    html = html_page.read_text(encoding="utf-8")
    assert html.count(f'href="{URL}"') == 1
    assert html.count('class="external-documentation"') == 1
    assert len(direct_entry["externalDocs"]) == 1
    markdown = [path for path in (direct / "markdown").rglob("*.md")
                if URL in path.read_text(encoding="utf-8")]
    assert len(markdown) == 1, markdown
    assert markdown[0].read_text(encoding="utf-8").count(URL) == 1
    summary = {"binarySha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
               "directHtmlLinkCount": 1, "directSearchReferenceCount": 1,
               "legacyMarkdownReferenceCount": 1}
    (work / "before-summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    assert "languageOptions" not in document
    assert not document.get("pages")
    references = document.get("externalDocumentation", [])
    assert len(references) == 1, "unlocalized external references were not captured"
    reference = references[0]
    assert reference["symbolId"] == symbol["id"]
    assert reference["name"] == "support" and reference["state"] == "available"
    assert reference["url"] == URL and reference["version"] == "support-v1"
    assert reference["index"] == "docs/support.json" and reference["format"] == "cjdoc.symbol-index/1"
    assert len(reference["fingerprint"]) == 64
    assert direct_entry["externalDocs"] == [{key: value for key, value in reference.items() if key != "symbolId"}]
    shutil.rmtree(project)
    assert not project.exists()
    imported = work / "source-free"
    run("source-free", ["render", "--input", str(direct / "docs.json"),
                        "--format", "html", "--format", "json", "--locale", "en",
                        "--output", str(imported)])
    imported_entry = external_entry(imported, symbol["id"])
    assert imported_entry["externalDocs"] == direct_entry["externalDocs"]
    imported_html = (imported / "html" / imported_entry["href"]).read_text(encoding="utf-8")
    assert imported_html.count(f'href="{URL}"') == 1
    assert imported_html.count('class="external-documentation"') == 1
    assert load(imported / "docs.json")["externalDocumentation"] == references
    summary.update(sourceDeleted=True, sourceFreeHtmlLinkCount=1, metadataPreserved=True, status="passed")
    (work / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print("PASS: unlocalized source-free external snapshot; direct HTML/search and legacy Markdown remain singular")


if __name__ == "__main__":
    main()
