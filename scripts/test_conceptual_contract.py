#!/usr/bin/env python3
"""End-to-end CLI contracts for conceptual configuration, inline semantic links and route encoding.

Each scenario builds a throwaway project outside the repository, runs the real
`generate` command, and asserts on the published site rather than on an internal
helper. Issue citations:

* F05 - a valid trailing comment on `[[docs.pages]]` must register the same page.
* F06 - an unusable `{@link }` before a valid link must not delete author text.
* F07 - an author page route containing spaces/non-ASCII must stay clickable in
  body prose, encoded exactly once, and survive a detached Doc IR replay.

The script also leaves the published output roots and the expected anchor
targets on disk so a browser acceptance step can open them over `file://` and an
HTTP subpath without touching the source tree.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

from safe_output_root import verify_directory_chain

MANIFEST = (
    '[package]\nname = "{name}"\nversion = "1.0.0"\ncjc-version = "1.2.0"\n'
    'output-type = "static"\n'
)

SPACE_ROUTE = "concepts/my guide.html"
SPACE_HREF = "concepts/my%20guide.html"
UNICODE_ROUTE = "concepts/指南 (zh).html"
UNICODE_HREF = "concepts/%E6%8C%87%E5%8D%97%20%28zh%29.html"


class Failure(AssertionError):
    """A published behaviour diverged from the recorded contract."""


def run(args, expected=0, cwd=None):
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=300)
    if result.returncode != expected:
        raise Failure(f"{args} exited {result.returncode} (expected {expected})\n"
                      f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}")
    return result


def write(project: Path, files: dict[str, str]) -> None:
    for name, content in files.items():
        path = project / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8", newline="\n")


def page_configuration(suffix: str = "") -> str:
    return ('[[docs.pages]]' + suffix + '\nsource = "docs/guide.md"\n'
            'route = "concepts/guide"\n')


def header_scenario(binary: Path, root: Path) -> dict:
    """F05: a header comment may not make a registered guide disappear."""
    outputs = {}
    for name, suffix in (("plain", ""), ("commented", " # Guide registration")):
        project = root / "header" / name
        write(project, {
            "cjpm.toml": MANIFEST.format(name="docs_header_probe"),
            "src/api.cj": ("package docs_header_probe\n/** Value. */\n"
                           "public func value(): Int64 { 1 }\n"),
            "docs/guide.md": "# Guide\n\nThis page explains the API.\n",
            "cjdoc.toml": page_configuration(suffix),
        })
        result = run([binary, "generate", "--project", project, "--semantic", "source",
                      "--lint-profile", "off", "--no-cache", "--format", "json", "--stdout"])
        outputs[name] = json.loads(result.stdout)
    plain, commented = outputs["plain"], outputs["commented"]
    plain_pages = [(page["id"], page["route"], page["source"]) for page in plain.get("pages", [])]
    commented_pages = [(page["id"], page["route"], page["source"])
                       for page in commented.get("pages", [])]
    if not plain_pages:
        raise Failure("the plain [[docs.pages]] header registered no page")
    if plain_pages != commented_pages:
        raise Failure(f"header comment changed registered pages:\n{plain_pages}\n{commented_pages}")
    guides = [page for page in commented.get("pages", []) if page["source"] == "docs/guide.md"]
    if len(guides) != 1 or "This page explains the API." not in guides[0]["text"]:
        raise Failure(f"registered guide missing its authored body: {guides}")
    # A quoted '#' is a value, not the start of a comment.
    project = root / "header" / "quoted"
    write(project, {
        "cjpm.toml": MANIFEST.format(name="docs_header_probe"),
        "src/api.cj": ("package docs_header_probe\n/** Value. */\n"
                       "public func value(): Int64 { 1 }\n"),
        "docs/guide.md": "# Guide\n\nThis page explains the API.\n",
        "cjdoc.toml": ('[[docs.pages]] # registration\nsource = "docs/guide.md"\n'
                       'route = "concepts/guide"\ntitle = "Guide # kept"\n'),
    })
    result = run([binary, "generate", "--project", project, "--semantic", "source",
                  "--lint-profile", "off", "--no-cache", "--format", "json", "--stdout"])
    document = json.loads(result.stdout)
    guide = [page for page in document.get("pages", []) if page["source"] == "docs/guide.md"]
    if len(guide) != 1 or guide[0]["title"] != "Guide # kept":
        raise Failure(f"quoted '#' in a value was treated as a comment: {guide}")
    # A page registration without its required source still fails loudly.
    broken = root / "header" / "broken"
    write(broken, {
        "cjpm.toml": MANIFEST.format(name="docs_header_probe"),
        "src/api.cj": "package docs_header_probe\n/** Value. */\npublic func value(): Int64 { 1 }\n",
        "cjdoc.toml": "[[docs.pages]] # missing source\nroute = \"concepts/guide\"\n",
    })
    run([binary, "generate", "--project", broken, "--semantic", "source",
         "--lint-profile", "off", "--no-cache", "--format", "json", "--stdout"], expected=2)
    return {"scenario": "docs-pages-header-comment", "pages": plain_pages}


def concatenate_text(node: dict) -> str:
    text = node["literal"] if node["kind"] == "text" else ""
    if node["kind"] == "semantic_link":
        text = node["literal"]
    return text + "".join(concatenate_text(child) for child in node.get("children", []))


def collect_semantic_links(node: dict, found: list[dict]) -> None:
    if node["kind"] == "semantic_link":
        found.append(node)
    for child in node.get("children", []):
        collect_semantic_links(child, found)


def semantic_link_scenario(binary: Path, root: Path) -> dict:
    """F06: text before an unusable marker survives, and the next link still binds."""
    project = root / "semantic-link"
    body = "Prefix {@link } middle {@link value} tail."
    write(project, {
        "cjpm.toml": MANIFEST.format(name="semantic_link_probe"),
        "src/api.cj": ('package semantic_link_probe\n/** ' + body +
                       ' */\npublic func value(): Int64 { 1 }\n'),
    })
    result = run([binary, "generate", "--project", project, "--semantic", "source",
                  "--lint-profile", "off", "--no-cache", "--format", "json", "--stdout"])
    document = json.loads(result.stdout)
    symbol = next(item for item in document["declarations"] if item["name"] == "value")
    comment = symbol["documentation"]
    if comment["rawText"] != body:
        raise Failure(f"rawText changed: {comment['rawText']!r}")
    if concatenate_text(comment["markdown"]) != body:
        raise Failure(f"Markdown text lost author characters: "
                      f"{concatenate_text(comment['markdown'])!r}")
    links: list[dict] = []
    collect_semantic_links(comment["markdown"], links)
    if len(links) != 1 or links[0]["metadata"]["semanticState"] != "resolved":
        raise Failure(f"valid link did not resolve: {links}")
    site = root / "semantic-link-site"
    run([binary, "generate", "--project", project, "--semantic", "source",
         "--lint-profile", "off", "--no-cache", "--format", "html", "--output", site])
    page = next(path for path in (site / "html").rglob("index.html")
                if 'data-cjdoc-symbol-id="' in path.read_text(encoding="utf-8")
                and ">value</a>" in path.read_text(encoding="utf-8"))
    html = page.read_text(encoding="utf-8")
    if "Prefix {@link } middle " not in html or " tail." not in html:
        raise Failure(f"HTML lost the author prefix or suffix: {page}")
    return {"scenario": "inline-semantic-link-text", "root": site.relative_to(root).as_posix(),
            "page": page.relative_to(site).as_posix(), "anchorText": "value"}


def route_project(root: Path, *, multi_language: bool) -> Path:
    project = root / "route-encoding" / ("multi" if multi_language else "single")
    configuration = ""
    if multi_language:
        configuration = ('[i18n]\ndefault-language = "en"\nlanguages = ["en", "zh-CN"]\n\n')
    configuration += (
        '[[docs.pages]]\nid = "guide"\nlanguage = "en"\nsource = "docs/guide.md"\n'
        f'route = "{SPACE_ROUTE.removesuffix(".html")}"\n\n'
        '[[docs.pages]]\nid = "unicode"\nlanguage = "en"\nsource = "docs/unicode.md"\n'
        f'route = "{UNICODE_ROUTE.removesuffix(".html")}"\n\n'
        '[[docs.pages]]\nid = "other"\nlanguage = "en"\nsource = "docs/other.md"\n'
        'route = "concepts/other"\n')
    write(project, {
        "cjpm.toml": MANIFEST.format(name="routesample"),
        "src/api.cj": "package routesample\n/** A value. */\npublic func value(): Int64 { 1 }\n",
        "cjdoc.toml": configuration,
        "docs/guide.md": "# Route space\n\n## Topic\n\nBody.\n",
        "docs/unicode.md": "# Unicode route\n\nBody.\n",
        "docs/other.md": ("# Other guide\n\n[Read route guide](guide.md)\n\n"
                          "[Read section](guide.md#topic)\n\n"
                          "[Read unicode](unicode.md)\n"),
    })
    return project


def verify_route_site(site: Path, root: Path, *, prefix: str, expect_sources: bool) -> None:
    other = site / prefix / "concepts/other.html"
    guide = site / prefix / SPACE_ROUTE
    if not other.is_file():
        raise Failure(f"missing published page {other}")
    if expect_sources and not guide.is_file():
        raise Failure(f"target page was not published at its authored route: {guide}")
    html = other.read_text(encoding="utf-8")
    expected = [
        f'href="../concepts/my%20guide.html">Read route guide</a>',
        f'href="../concepts/my%20guide.html#standalone--doc-topic">Read section</a>',
        f'href="../concepts/%E6%8C%87%E5%8D%97%20%28zh%29.html">Read unicode</a>',
    ]
    for fragment in expected:
        if fragment not in html:
            raise Failure(f"{other} is missing body link {fragment}")
    if "%2520" in html:
        raise Failure(f"{other} encoded the captured route twice")
    if expect_sources and 'id="standalone--doc-topic"' not in guide.read_text(encoding="utf-8"):
        raise Failure("fragment target id missing in the target page")


def route_scenario(binary: Path, root: Path) -> list[dict]:
    """F07: body links stay reachable for author routes with spaces/non-ASCII."""
    receipts = []
    project = route_project(root, multi_language=False)
    site = root / "route-site"
    run([binary, "generate", "--project", project, "--semantic", "source", "--no-cache",
         "--lint-profile", "off", "--format", "html", "--output", site])
    verify_route_site(site, root, prefix="html", expect_sources=True)
    receipts.append({"scenario": "route-encoding-body-links",
                     "root": site.relative_to(root).as_posix(), "page": "html/concepts/other.html",
                     "anchorText": "Read route guide",
                     "href": "../concepts/my%20guide.html",
                     "target": "html/" + SPACE_ROUTE,
                     "fragmentId": "standalone--doc-topic"})
    # Same links after the source project is gone: render only from Doc IR.
    document = root / "route-detached.json"
    run([binary, "generate", "--project", project, "--semantic", "source", "--no-cache",
         "--lint-profile", "off", "--format", "json", "--output", root / "route-ir"])
    shutil.copyfile(root / "route-ir" / "docs.json", document)
    shutil.rmtree(project)
    detached = root / "route-detached-site"
    run([binary, "render", "--input", document, "--format", "html", "--output", detached])
    verify_route_site(detached, root, prefix="html", expect_sources=True)
    receipts.append({"scenario": "route-encoding-detached-ir",
                     "root": detached.relative_to(root).as_posix(), "page": "html/concepts/other.html",
                     "anchorText": "Read route guide",
                     "href": "../concepts/my%20guide.html",
                     "target": "html/" + SPACE_ROUTE})
    multi = route_project(root, multi_language=True)
    multi_site = root / "route-multi-site"
    run([binary, "generate", "--project", multi, "--semantic", "source", "--no-cache",
         "--lint-profile", "off", "--format", "html", "--format", "markdown",
         "--all-languages", "--output", multi_site])
    for language in ("en", "zh-CN"):
        verify_route_site(multi_site, root, prefix=f"html/{language}", expect_sources=True)
        markdown = multi_site / "markdown" / language / "concepts/other.md"
        text = markdown.read_text(encoding="utf-8")
        for fragment in ("](../concepts/my%20guide.md)", "](../concepts/my%20guide.md#topic)",
                         "](../concepts/%E6%8C%87%E5%8D%97%20%28zh%29.md)"):
            if fragment not in text:
                raise Failure(f"{markdown} is missing Markdown link {fragment}")
        if ".md.md" in text:
            raise Failure(f"{markdown} appended a second extension")
        receipts.append({"scenario": f"route-encoding-{language}-root",
                         "root": multi_site.relative_to(root).as_posix(),
                         "page": f"html/{language}/concepts/other.html",
                         "anchorText": "Read route guide",
                         "href": "../concepts/my%20guide.html",
                         "target": f"html/{language}/" + SPACE_ROUTE,
                         "unicodeHref": "../concepts/%E6%8C%87%E5%8D%97%20%28zh%29.html"})
    # An untrusted destination still stays plain text.
    hostile = root / "route-hostile"
    write(hostile, {
        "cjpm.toml": MANIFEST.format(name="routesample"),
        "src/api.cj": "package routesample\n/** A value. */\npublic func value(): Int64 { 1 }\n",
        "cjdoc.toml": ('[[docs.pages]]\nsource = "docs/other.md"\nroute = "concepts/other"\n'),
        "docs/other.md": "# Other guide\n\n[Bad](javascript:alert(1))\n",
    })
    hostile_site = root / "route-hostile-site"
    run([binary, "generate", "--project", hostile, "--semantic", "source", "--no-cache",
         "--lint-profile", "off", "--format", "html", "--output", hostile_site])
    html = (hostile_site / "html/concepts/other.html").read_text(encoding="utf-8")
    if "javascript:" in html or ">Bad</a>" in html:
        raise Failure("an unsafe author destination became a link")
    return receipts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True,
                        help="directory that receives the throwaway projects and published sites")
    options = parser.parse_args()
    binary = options.binary.resolve()
    if not binary.is_file():
        raise SystemExit(f"cjdoc binary not found: {binary}")
    try:
        output = verify_directory_chain(options.output.parent) / options.output.name
        output.mkdir()
    except (OSError, ValueError) as error:
        parser.error(f"--output must be a new directory under an existing safe parent: {error}")
    receipts = [header_scenario(binary, output), semantic_link_scenario(binary, output)]
    receipts.extend(route_scenario(binary, output))
    (output / "conceptual-contract-receipt.json").write_text(
        json.dumps(receipts, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"PASS: {len(receipts)} conceptual contract scenarios")
    for receipt in receipts:
        print("browser: " + json.dumps(receipt, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
