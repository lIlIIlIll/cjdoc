"""Focused report entry pages derived from the one native validation component."""
from __future__ import annotations

from html.parser import HTMLParser
from pathlib import Path
from .reports import UtilityRegion
from showcase_contract.site import ContractError


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

    def offset(self) -> int:
        line, column = self.getpos()
        return self.offsets[line - 1] + column

    def handle_starttag(self, tag: str, attrs: list) -> None:
        if tag == "section":
            self.stack.append((dict(attrs).get("id"), self.offset()))

    def handle_endtag(self, tag: str) -> None:
        if tag == "section":
            if not self.stack:
                raise ContractError("unbalanced report section")
            key, start = self.stack.pop()
            if key in self.regions:
                raise ContractError("duplicate report section identity")
            self.regions[key] = (start, self.offset() + len("</section>"))


def publish(root: Path) -> None:
    text = (root / "validation.html").read_text(encoding="utf-8")
    start, end = UtilityRegion(text).regions[0]
    component = text[start:end]
    sections = Sections(component).regions
    for name, selected in {"doctest": ("doctest",), "diff": ("api-diff",),
                           "coverage": ("coverage", "diagnostics"),
                           "diagnostics": ("diagnostics", "doctest")}.items():
        body = '<p><a href="validation.html">全部验证结果 / All validation results</a></p>'
        for key in (*selected, "provenance"):
            if key not in sections:
                raise ContractError("missing report component: " + key)
            left, right = sections[key]
            body += component[left:right]
        (root / f"report-{name}.html").write_text(text[:start] + body + text[end:], encoding="utf-8")
