"""Focused report entry pages derived from the one native validation component."""
from __future__ import annotations

from html.parser import HTMLParser
from pathlib import Path
from .reports import UtilityRegion
from .localization import localize_ui
from showcase_contract.site import ContractError, load_json


class PageTitle(HTMLParser):
    def __init__(self, source: str, title: str) -> None:
        super().__init__(convert_charrefs=True)
        self.source, self.title, self.edits, self.active = source, title, [], None
        self.offsets = [0]
        for line in source.splitlines(keepends=True):
            self.offsets.append(self.offsets[-1] + len(line))
        self.feed(source)

    def position(self) -> int:
        line, column = self.getpos()
        return self.offsets[line - 1] + column

    def handle_starttag(self, tag: str, attrs: list) -> None:
        if tag in {"title", "h1"}:
            self.active = (tag, self.position() + len(self.get_starttag_text()))

    def handle_endtag(self, tag: str) -> None:
        if self.active and self.active[0] == tag:
            self.edits.append((self.active[1], self.position()))
            self.active = None

    def result(self) -> str:
        source = self.source
        for start, end in reversed(self.edits):
            source = source[:start] + self.title + source[end:]
        return source


class Sections(HTMLParser):
    def __init__(self, text: str) -> None:
        super().__init__(convert_charrefs=True)
        self.offsets = [0]
        for line in text.splitlines(keepends=True):
            self.offsets.append(self.offsets[-1] + len(line))
        self.stack = []
        self.regions = {}
        self.feed(text)
        if self.stack:
            raise ContractError("unbalanced report section")

    def position(self) -> int:
        line, column = self.getpos()
        return self.offsets[line - 1] + column

    def handle_starttag(self, tag: str, attrs: list) -> None:
        if tag == "section":
            self.stack.append((dict(attrs).get("id"), self.position()))

    def handle_endtag(self, tag: str) -> None:
        if tag == "section":
            if not self.stack:
                raise ContractError("unbalanced report section")
            key, start = self.stack.pop()
            if key in self.regions:
                raise ContractError("duplicate report section identity")
            self.regions[key] = (start, self.position() + len("</section>"))


def publish(root: Path) -> None:
    text = (root / "validation.html").read_text(encoding="utf-8")
    start, end = UtilityRegion(text).regions[0]
    component = text[start:end]
    sections = Sections(component).regions
    check = ("native-check",) if "native-check" in sections else ()
    locale = load_json(root / "report-provenance.json")["locale"]
    titles = {"doctest": ("示例验证", "Doctest results"), "diff": ("API 变化", "API changes"),
              "coverage": ("文档覆盖与缺项", "Coverage and documentation gaps"),
              "diagnostics": ("诊断与边界示例", "Diagnostics and boundary examples")}
    for name, selected in {"doctest": ("doctest", *check), "diff": ("api-diff",),
                           "coverage": ("coverage", "quality", "diagnostics"),
                           "diagnostics": ("diagnostics", "doctest", *check)}.items():
        body = '<p><a href="validation.html">全部验证结果 / All validation results</a></p>'
        for key in (*selected, "provenance"):
            if key not in sections:
                raise ContractError("missing report component: " + key)
            left, right = sections[key]
            body += component[left:right]
        body = localize_ui(body, locale)
        page = PageTitle(text[:start] + body + text[end:], titles[name][0 if locale == "zh-CN" else 1]).result()
        (root / f"report-{name}.html").write_text(page, encoding="utf-8")
