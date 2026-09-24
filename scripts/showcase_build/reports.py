"""Read-only views of native, versioned reports in the native utility-page shell.

This module does not execute examples, classify API changes or calculate
coverage. Report provenance binds every presentation to exact raw input bytes.
"""
from __future__ import annotations

import hashlib
import html
from html.parser import HTMLParser
import json
import os
from pathlib import Path

from showcase_contract.site import ContractError, canonical_json, load_json, relative_path

IR = "cjdoc.doc-ir/10"
COVERAGE = "cjdoc.documentation-coverage/2"
DOCTEST = "cjdoc.doctest/1"
DIFF = "cjdoc.api-diff/1"


def escaped(value: object) -> str:
    return html.escape(str(value), quote=True)


def checked(path: Path, schema: str) -> dict:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 64 * 1024 * 1024:
        raise ContractError(f"missing, unsafe or oversized report: {path.name}")
    value = load_json(path)
    if value.get("schemaVersion") != schema:
        raise ContractError(f"unsupported report schema: {path.name}")
    return value


class UtilityRegion(HTMLParser):
    """Locate exactly one native validation component without regex HTML edits."""
    def __init__(self, source: str) -> None:
        super().__init__(convert_charrefs=True)
        self.offsets = [0]
        for line in source.splitlines(keepends=True):
            self.offsets.append(self.offsets[-1] + len(line))
        self.depth = 0
        self.start = None
        self.regions = []
        self.feed(source)
        self.close()
        if self.depth or len(self.regions) != 1:
            raise ContractError("expected exactly one balanced native validation component")

    def offset(self) -> int:
        line, column = self.getpos()
        return self.offsets[line - 1] + column

    def handle_starttag(self, tag: str, attributes: list) -> None:
        if tag != "div":
            return
        attrs = dict(attributes)
        if self.depth:
            self.depth += 1
        elif "validation-page" in (attrs.get("class") or "").split():
            self.start = self.offset() + len(self.get_starttag_text())
            self.depth = 1

    def handle_endtag(self, tag: str) -> None:
        if tag == "div" and self.depth:
            self.depth -= 1
            if self.depth == 0:
                self.regions.append((self.start, self.offset()))


def index(root: Path, version: str | None = None) -> tuple[dict, dict]:
    raw = checked(root / "symbol-index.json", "cjdoc.symbol-index/1")
    if version is not None and raw.get("version") != version:
        raise ContractError("report/index documentation version mismatch")
    entries = raw["entries"]
    mapping = {entry["id"]: entry for entry in entries}
    if len(mapping) != len(entries):
        raise ContractError("duplicate native report symbol identity")
    for entry in entries:
        path = root / relative_path(entry["href"])
        if not path.is_file():
            raise ContractError("report index points to a missing native page")
    return raw, mapping


def declaration_link(root: Path, origin: Path, mapping: dict, symbol_id: str | None, label: str) -> str:
    if symbol_id is None:
        return escaped(label + ": absent")
    if symbol_id not in mapping:
        raise ContractError("report symbol has no native declaration route")
    entry = mapping[symbol_id]
    href = os.path.relpath(root / relative_path(entry["href"]), origin).replace(os.sep, "/")
    return f'<a href="{escaped(href)}" data-report-symbol="{escaped(symbol_id)}">{escaped(label)}: {escaped(entry["qualifiedName"])}</a>'


def table(headers: tuple[str, ...], rows: list[list[str]]) -> str:
    return '<div class="report-table-scroll"><table><thead><tr>' + ''.join(
        '<th scope="col">' + escaped(title) + '</th>' for title in headers
    ) + '</tr></thead><tbody>' + ''.join('<tr>' + ''.join('<td>' + cell + '</td>' for cell in row) + '</tr>'
                                      for row in rows) + '</tbody></table></div>'


def coverage_view(raw: dict) -> str:
    rows = []
    scopes = [("project", "all", raw["metrics"])]
    for kind in ("packages", "modules"):
        scopes.extend((kind, item.get("name", item.get("id", "")), item["metrics"]) for item in raw[kind])
    for kind, name, metrics in scopes:
        for metric, value in metrics.items():
            rows.append([escaped(kind), escaped(name), escaped(metric), escaped(value["documented"]),
                         escaped(value["total"]), escaped(value["percent"]) + "%"])
    return '<section id="coverage"><h2>文档覆盖 / Coverage</h2><p>Audience: <code>' + escaped(raw["audience"]) + (
        '</code>。分子、分母和百分比均来自原报告；覆盖率不证明契约正确。 '
        'All values come from the native report; coverage is not correctness.</p>'
        '<p><a href="machine/coverage.json">Raw coverage JSON</a></p>') + table(
            ("Scope", "Name", "Metric", "Documented", "Total", "Percent"), rows) + '</section>'


def doctest_view(raw: dict | None, ir: dict, root: Path, mapping: dict) -> str:
    output = '<section id="doctest"><h2>示例验证 / Doctest</h2>'
    if raw is None:
        return output + '<p>Not attached. No execution claim is made.</p></section>'
    output += '<p>Mode: <code>' + escaped(raw["mode"]) + '</code>; timeout-ms: ' + escaped(raw["timeoutMs"])
    output += '; memory-mb: ' + escaped(raw["memoryMb"]) + '; jobs: ' + escaped(raw["jobs"]) + '</p>'
    output += '<p>Summary: <code data-report-summary="doctest">' + escaped(json.dumps(raw["summary"], sort_keys=True)) + '</code></p>'
    output += ('<p>编译后运行与跳过是当前模式；没有 compile-only 或 expected-failure 成功转换。 '
               'Failed remains failed, including deliberately invalid diagnostic examples.</p>'
               '<p><a href="doctest/results.json">Raw doctest JSON</a></p>')
    symbols = {decl["id"]: decl for decl in ir["declarations"]}
    seen = set()
    for number, result in enumerate(raw["results"]):
        if result["id"] in seen or result["symbolId"] not in symbols:
            raise ContractError("duplicate or orphaned doctest result")
        seen.add(result["id"])
        if result["status"] not in {"passed", "failed", "timeout", "skipped"}:
            raise ContractError("unknown native doctest status")
        declaration = symbols[result["symbolId"]]
        tags = [tag for tag in (declaration.get("documentation") or {}).get("tags", [])
                if tag["name"] == "example" and tag["subject"] == result["title"]]
        if len(tags) != 1:
            raise ContractError("doctest result cannot be traced to one source example")
        output += f'<article class="report-case" id="doctest-case-{number}" data-doctest-status="{escaped(result["status"])}">'
        output += '<h3>' + escaped(result["qualifiedName"]) + ': ' + escaped(result["status"]) + '</h3>'
        output += '<p>' + declaration_link(root, root, mapping, result["symbolId"], "Source API") + '</p>'
        output += '<p>id: <code>' + escaped(result["id"]) + '</code></p>'
        output += '<p>exitCode: ' + escaped(result["exitCode"]) + '; durationMs: ' + escaped(result["durationMs"]) + '</p>'
        output += '<h4>Source @example</h4><pre><code>' + escaped(tags[0]["description"]) + '</code></pre>'
        for key in ("message", "stdout", "stderr"):
            if result[key]:
                output += '<details><summary>' + escaped(key) + '</summary><pre>' + escaped(result[key]) + '</pre></details>'
        output += '</article>'
    return output + '</section>'


def diagnostics_view(ir: dict, root: Path, mapping: dict) -> str:
    output = '<section id="diagnostics"><h2>诊断与缺口 / Diagnostics</h2><p>Collection state: <code>'
    output += escaped(ir["status"]) + '</code>; audience: ' + escaped(ir["configuration"]["audience"]) + '</p>'
    output += '<p><a href="machine/docs.json">Raw Doc IR with diagnostic source ranges</a></p>'
    if not ir["diagnostics"]:
        output += '<p>No diagnostics were emitted. This is not a proof of semantic completeness.</p>'
    for diagnostic in ir["diagnostics"]:
        output += '<article class="report-diagnostic"><h3>' + escaped(diagnostic["code"]) + ' / ' + escaped(diagnostic["severity"]) + '</h3>'
        output += '<p>' + escaped(diagnostic["message"]) + '</p><pre>' + escaped(json.dumps(diagnostic, ensure_ascii=False, indent=2)) + '</pre></article>'
    return output + '</section>'


def diff_view(raw: dict | None, origin: Path, baseline: Path | None, current: Path | None) -> str:
    output = '<section id="api-diff"><h2>API 变化 / API diff</h2>'
    if raw is None:
        return output + '<p>Not attached for this version. This is not a completed diff demonstration.</p></section>'
    if baseline is None or current is None:
        raise ContractError("API diff requires both exact native documentation sets")
    before, old = index(baseline)
    after, new = index(current)
    if raw["baseline"]["project"] != before["project"]["name"] or raw["current"]["project"] != after["project"]["name"]:
        raise ContractError("API diff project identity mismatch")
    if before["project"] != after["project"] or before["version"] == after["version"]:
        raise ContractError("API diff must compare two versions of the same project/audience")
    output += '<p>' + escaped(before["version"]) + ' → ' + escaped(after["version"]) + '; comparisonState: <code>' + escaped(raw["comparisonState"]) + '</code></p>'
    output += '<p>Summary: <code data-report-summary="diff">' + escaped(json.dumps(raw["summary"], sort_keys=True)) + '</code></p>'
    output += '<p>分类、匹配状态与证据直接来自原生 diff，不在展示层重新判定。 <a href="machine/api-diff.json">Raw API diff JSON</a></p>'
    for number, entry in enumerate(raw["entries"]):
        if entry["classification"] == "unchanged":
            continue
        output += f'<article id="api-change-{number}" class="report-change" data-diff-classification="{escaped(entry["classification"])}"><h3>{escaped(entry["classification"])}</h3>'
        output += '<p>' + declaration_link(baseline, origin, old, entry["oldId"], "Before") + '<br>' + declaration_link(current, origin, new, entry["newId"], "After") + '</p>'
        output += '<p>matchState: ' + escaped(entry["matchState"]) + '</p><pre>' + escaped(json.dumps({"reasons": entry["reasons"], "evidence": entry["evidence"]}, ensure_ascii=False, indent=2)) + '</pre></article>'
    return output + '</section>'


def publish(root: Path, revision: str, version: str, locale: str, *, baseline: Path | None = None,
            current: Path | None = None, diff_path: Path | None = None) -> None:
    root = root.resolve()
    inputs = {"machine/docs.json": IR, "machine/coverage.json": COVERAGE,
              "symbol-index.json": "cjdoc.symbol-index/1"}
    if (root / "doctest/results.json").is_file():
        inputs["doctest/results.json"] = DOCTEST
    if diff_path is not None:
        raw = checked(diff_path, DIFF)
        (root / "machine/api-diff.json").write_bytes(canonical_json(raw))
        inputs["machine/api-diff.json"] = DIFF
    data = {name: checked(root / name, schema) for name, schema in inputs.items()}
    ir = data["machine/docs.json"]
    raw_index, mapping = index(root, version)
    if ir["project"]["name"] != raw_index["project"]["name"] or ir["configuration"]["audience"] != raw_index["project"]["audience"]:
        raise ContractError("report/index project or audience mismatch")
    if data["machine/coverage.json"]["audience"] != ir["configuration"]["audience"]:
        raise ContractError("coverage audience mismatch")
    provenance = {"schemaVersion": "cjdoc.report-view/1", "revision": revision,
                  "version": version, "locale": locale, "project": raw_index["project"],
                  "generator": ir["generator"], "inputs": {
                      name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in inputs}}
    (root / "report-provenance.json").write_bytes(canonical_json(provenance))
    body = '<h1>验证与变化 / Validation and changes</h1><nav aria-label="Report sections">'
    body += ' · '.join(f'<a href="#{part}">{part}</a>' for part in ("doctest", "api-diff", "coverage", "diagnostics", "provenance")) + '</nav>'
    body += doctest_view(data.get("doctest/results.json"), ir, root, mapping)
    body += diff_view(data.get("machine/api-diff.json"), root, baseline, current)
    body += coverage_view(data["machine/coverage.json"]) + diagnostics_view(ir, root, mapping)
    body += '<section id="provenance"><h2>构建来源 / Provenance</h2><p><a href="report-provenance.json">Exact input hashes</a></p><pre>' + escaped(json.dumps(provenance, ensure_ascii=False, indent=2)) + '</pre></section>'
    page = root / "validation.html"
    original = page.read_text(encoding="utf-8")
    start, end = UtilityRegion(original).regions[0]
    updated = original[:start] + body + original[end:]
    updated = updated.replace('</head>', '<link rel="stylesheet" href="report.css"></head>', 1)
    page.write_text(updated, encoding="utf-8")
    (root / "report.css").write_text('.validation-page{min-width:0}.validation-page section{scroll-margin-top:5rem;margin-block:2rem}.validation-page pre{white-space:pre-wrap;overflow-wrap:anywhere}.validation-page code{overflow-wrap:anywhere}.report-table-scroll{max-width:100%;overflow:auto}.report-case,.report-change,.report-diagnostic{border:1px solid var(--border-color,currentColor);padding:1rem;margin-block:1rem;border-radius:.5rem}.validation-page table{width:100%;border-collapse:collapse}.validation-page td,.validation-page th{text-align:start;vertical-align:top;padding:.5rem;border-bottom:1px solid currentColor}', encoding="utf-8")


def verify(root: Path, revision: str) -> None:
    metadata = checked(root / "report-provenance.json", "cjdoc.report-view/1")
    if metadata["revision"] != revision:
        raise ContractError("stale report presentation revision")
    index(root, metadata["version"])
    for name, digest in metadata["inputs"].items():
        path = root / relative_path(name)
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ContractError("stale or missing raw input behind report presentation")
