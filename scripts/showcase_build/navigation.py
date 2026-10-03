"""Publication navigation joined by native identities, with portable local links."""
from __future__ import annotations

import html
import json
import os
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit

from showcase_contract.site import ContractError, HtmlDocument, load_json, relative_path

STYLE = '.showcase-tools{display:flex;flex-wrap:wrap;gap:.5rem 1rem;border-top:1px solid currentColor;margin:2rem 1rem 0;padding:1rem;max-width:100%;font-size:.875rem}.showcase-tools a,.showcase-tools span{overflow-wrap:anywhere}.showcase-tools a:focus-visible{outline:2px solid currentColor;outline-offset:3px}'
SCRIPT = '''"use strict";
(() => {
  const updateLanguageLinks = () => {
    let anchor = "";
    try { anchor = decodeURIComponent(location.hash.slice(1)); } catch (_) {}
    for (const link of document.querySelectorAll("[data-showcase-locale]")) {
      const allowed = JSON.parse(link.dataset.localeAnchors || "[]");
      link.hash = anchor && allowed.includes(anchor) ? location.hash : "";
    }
  };
  updateLanguageLinks();
  addEventListener("hashchange", updateLanguageLinks);
})();'''


class VersionLinks(HTMLParser):
    """Patch only publication version navigation, preserving native page content."""
    def __init__(self, text: str, page: Path, locale: str) -> None:
        super().__init__(convert_charrefs=True)
        self.text, self.page, self.locale = text, page, locale
        self.offsets = [0]
        for line in text.splitlines(keepends=True):
            self.offsets.append(self.offsets[-1] + len(line))
        self.active = False
        self.anchor = None
        self.edits = []
        self.feed(text)

    def position(self) -> int:
        line, column = self.getpos()
        return self.offsets[line - 1] + column

    def handle_starttag(self, tag: str, attrs: list) -> None:
        values = dict(attrs)
        if tag == "nav":
            self.active = "cjdoc-version-selector" in values.get("class", "").split()
        if tag == "a" and self.active:
            self.anchor = (self.position(), values)

    def handle_endtag(self, tag: str) -> None:
        if tag == "nav":
            self.active = False
        if tag != "a" or self.anchor is None:
            return
        start, attrs = self.anchor
        self.anchor = None
        end = self.position() + len("</a>")
        target = attrs.get("href", "")
        parsed = urlsplit(target)
        if parsed.scheme or parsed.netloc:
            return
        destination = self.page.parent / parsed.path
        if destination.name == "api-diff.json" and destination.with_name("report-diff.html").is_file():
            readable = target.rsplit("api-diff.json", 1)[0] + "report-diff.html"
            label, raw = ("版本变化", "原始 JSON") if self.locale == "zh-CN" else ("Changes", "Raw JSON")
            replacement = f'<a href="{html.escape(readable, quote=True)}">{label}</a> <a class="version-raw-diff" href="{html.escape(target, quote=True)}">{raw}</a>'
            self.edits.append((start, end, replacement))
        elif self.page.name.startswith("report-") and destination.name == "validation.html":
            report = destination.with_name(self.page.name)
            if report.is_file():
                attrs["href"] = target.rsplit("validation.html", 1)[0] + self.page.name
                opening = '<a ' + ' '.join(f'{key}="{html.escape(value or "", quote=True)}"' for key, value in attrs.items()) + '>'
                inner = self.text[start:end].split('>', 1)[1]
                self.edits.append((start, end, opening + inner))
            else:
                label = self.text[start:end].split('>', 1)[1].rsplit('</a>', 1)[0]
                note = "无对应报告" if self.locale == "zh-CN" else "Report unavailable"
                self.edits.append((start, end, f'<span class="version-unavailable" aria-disabled="true">{label} — {note}</span>'))

    def result(self) -> str:
        text = self.text
        for start, end, replacement in reversed(self.edits):
            text = text[:start] + replacement + text[end:]
        return text


def markdown_declarations(root: Path) -> dict[tuple[str, str], Path]:
    """Index exact emitted Markdown headings/signatures, without parsing Cangjie."""
    result = {}
    for path in sorted((root / "machine/markdown").rglob("*.md")):
        lines = path.read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines[:-1]):
            if not line.startswith('<a id="') or not HtmlDocument(line).ids:
                continue
            heading = lines[index + 1].lstrip('#').strip()
            if not heading.startswith('`') or not heading.endswith('`'):
                continue
            qualified = heading[1:-1]
            for number in range(index + 2, len(lines)):
                opening = lines[number]
                if opening.startswith('<a id="'):
                    break
                if not opening.endswith("cangjie"):
                    continue
                fence = opening[:-len("cangjie")]
                if len(fence) < 3 or set(fence) != {'`'}:
                    continue
                end = number + 1
                while end < len(lines) and lines[end] != fence:
                    end += 1
                if end == len(lines):
                    raise ContractError("unterminated native Markdown signature")
                key = (qualified, '\n'.join(lines[number + 1:end]))
                if key in result:
                    raise ContractError("ambiguous native Markdown declaration: " + qualified)
                result[key] = path
                break
    return result


def href(origin: Path, target: Path) -> str:
    return html.escape(os.path.relpath(target, origin.parent).replace(os.sep, "/"), quote=True)


def native_pages(root: Path) -> dict[str, str]:
    index = load_json(root / "navigation-index.json")
    if index.get("schemaVersion") != "cjdoc.navigation-index/1":
        raise ContractError("unsupported navigation index while mounting publication links")
    result = {}
    for page in index["pages"]:
        key = page.get("symbolId") or page["id"]
        if key in result:
            raise ContractError("ambiguous native language navigation identity")
        result[key] = relative_path(page["href"])
    return result


def mount(root: Path, site: Path, locale: str, alternate: Path | None = None) -> None:
    pages = native_pages(root)
    other = native_pages(alternate) if alternate else {}
    markdown_symbols = markdown_declarations(root)
    ir_path = root / "machine/docs.json"
    declarations = {item["id"]: item for item in load_json(ir_path)["declarations"]} if ir_path.is_file() else {}
    identities = {path: key for key, path in pages.items()}
    counterparts = {path: alternate / other[key] for key, path in pages.items() if key in other}
    # These are explicit report-view identities produced by report_views, not API routes.
    for name in ("report-doctest.html", "report-diff.html", "report-coverage.html", "report-diagnostics.html"):
        if alternate is not None and (alternate / name).is_file():
            counterparts[name] = alternate / name
    for page in sorted(root.rglob("*.html")):
        relative = page.relative_to(root)
        if "dependencies" in relative.parts or "machine" in relative.parts:
            continue
        content = page.read_text(encoding="utf-8")
        if 'data-showcase-tools' in content or content.count('</body>') != 1:
            raise ContractError("native page has no unique unmodified body: " + str(page))
        nav = '<nav class="showcase-tools" data-showcase-tools aria-label="Showcase and machine outputs">'
        home = site / ("index.html" if locale == "zh-CN" else "en.html")
        nav += '<a data-showcase-home href="' + href(page, home) + '">' + ('展示首页' if locale == 'zh-CN' else 'Showcase') + '</a>'
        counterpart = counterparts.get(relative.as_posix())
        if counterpart is not None:
            anchors = sorted(HtmlDocument(counterpart.read_text(encoding="utf-8")).ids)
            nav += '<a data-showcase-locale data-locale-anchors="' + html.escape(json.dumps(anchors), quote=True) + '" href="' + href(page, counterpart) + '">' + ('English' if locale == 'zh-CN' else '中文') + '</a>'
        else:
            nav += '<span data-showcase-locale-unavailable>' + ('无对应语言页面' if locale == 'zh-CN' else 'No exact language counterpart') + '</span>'
        machine = {"json": ("machine/docs.json", "Doc IR JSON"),
                   "navigation": ("navigation-index.json", "Navigation JSON"),
                   "symbols": ("symbol-index.json", "Symbol JSON"),
                   "markdown": ("machine/markdown/index.md", "Markdown"),
                   "llms": ("llms.txt", "llms.txt"), "llms-full": ("llms-full.txt", "llms-full.txt")}
        declaration = declarations.get(identities.get(relative.as_posix()))
        if declaration is not None:
            key = (declaration["qualifiedName"], declaration["headerSpelling"].rstrip('\n'))
            if key not in markdown_symbols:
                raise ContractError("missing exact native Markdown declaration: " + declaration["qualifiedName"])
            machine["markdown"] = (markdown_symbols[key].relative_to(root).as_posix(), "Markdown")
        for kind, (path, label) in machine.items():
            if (root / path).is_file():
                nav += '<a data-machine-format="' + kind + '" href="' + href(page, root / path) + '">' + label + '</a>'
        if (root / "validation.html").is_file():
            nav += '<a data-report-link href="' + href(page, root / "validation.html") + '">' + ('验证与变化' if locale == 'zh-CN' else 'Reports') + '</a>'
        nav += '<a data-authoring-evidence href="' + href(page, site / "artifacts/authoring.json") + '">' + ('本地编写验证' if locale == 'zh-CN' else 'Local authoring check') + '</a>'
        nav += '<a data-build-provenance href="' + href(page, site / "build.json") + '">' + ('构建来源与 SDK' if locale == 'zh-CN' else 'Build and SDK') + '</a></nav>'
        content = VersionLinks(content, page, locale).result()
        content = content.replace('</head>', '<link rel="stylesheet" href="' + href(page, site / "publication.css") + '"><script defer src="' + href(page, site / "publication.js") + '"></script></head>', 1)
        page.write_text(content.replace('</body>', nav + '</body>'), encoding="utf-8")


def publish(site: Path) -> None:
    (site / "publication.css").write_text(STYLE, encoding="utf-8")
    (site / "publication.js").write_text(SCRIPT, encoding="utf-8")
    from .manifest import roots
    documents = {locale: roots(site, locale) for locale in ("zh-CN", "en")}
    for locale, sets in documents.items():
        other = documents["en" if locale == "zh-CN" else "zh-CN"]
        for version, root in sets.items():
            mount(root, site, locale, other[version])
            for dependency in (root / "dependencies").glob("*"):
                if dependency.is_dir():
                    mount(dependency, site, locale)
    mount(site / "api", site, "en")
