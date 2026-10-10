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
from urllib.parse import urlsplit

from .localization import (DIFF_CLASSIFICATIONS, DIFF_MATCH_STATES, DIFF_RAW_LABEL,
                           DIFF_REASONS, DIFF_TABLE_HEADINGS, localize_ui)

from showcase_contract.site import ContractError, canonical_json, load_json, relative_path

IR = "cjdoc.doc-ir/11"
COVERAGE = "cjdoc.documentation-coverage/2"
DOCTEST = "cjdoc.doctest/1"
DIFF = "cjdoc.api-diff/1"
QUALITY = "cjdoc.documentation-quality/1"

FILTER_SCRIPT = '''"use strict";
for (const input of document.querySelectorAll("[data-report-filter]")) {
  const section = input.closest("section");
  const rows = [...section.querySelectorAll("[data-report-diagnostic]")];
  const status = section.querySelector("[data-report-filter-status]");
  input.addEventListener("input", () => {
    const words = input.value.trim().toLocaleLowerCase().split(/\\s+/).filter(Boolean);
    let count = 0;
    for (const row of rows) {
      const content = (row.dataset.search + " " + row.textContent).toLocaleLowerCase();
      row.hidden = !words.every(word => content.includes(word));
      if (!row.hidden) count++;
    }
    if (status) status.textContent = document.documentElement.lang === "zh-CN"
      ? `显示 ${count} / ${rows.length} 条诊断` : `${count} / ${rows.length} diagnostics shown`;
  });
}'''


def escaped(value: object) -> str:
    return html.escape(str(value), quote=True)


def source_text(value: object) -> str:
    """Separate source identities from translatable presentation labels."""
    return '<span data-report-source-text>' + escaped(value) + '</span>'


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

    def position(self) -> int:
        line, column = self.getpos()
        return self.offsets[line - 1] + column

    def handle_starttag(self, tag: str, attributes: list) -> None:
        if tag != "div":
            return
        attrs = dict(attributes)
        if self.depth:
            self.depth += 1
        elif "validation-page" in (attrs.get("class") or "").split():
            self.start = self.position() + len(self.get_starttag_text())
            self.depth = 1

    def handle_endtag(self, tag: str) -> None:
        if tag == "div" and self.depth:
            self.depth -= 1
            if self.depth == 0:
                self.regions.append((self.start, self.position()))


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
    return f'<a href="{escaped(href)}" data-report-symbol="{escaped(symbol_id)}">{escaped(label)}: {source_text(entry["qualifiedName"])}</a>'


# Evidence fields whose value is a `TAG:byteLength:text` token list. Their lengths
# let a token contain a `|` without corrupting the encoding, so they are decoded
# by length.
DIFF_ENCODED_FIELDS = {"sourceApiSignature", "genericParameters"}
# Source-visible fields that are not token lists and are shown verbatim.
DIFF_PLAIN_FIELDS = {"return", "visibility", "exposedName", "parameters"}
# Reader-facing labels for the field column. These are presentation, so they are
# localized by the page localizer; only values are protected source text.
DIFF_FIELD_LABELS = {
    "return": ("返回值", "return type"),
    "visibility": ("可见性", "visibility"),
    "exposedName": ("对外名称", "exposed name"),
    "genericParameters": ("泛型参数", "generic parameters"),
    "sourceApiSignature": ("源码签名", "source API signature"),
    "parameters": ("参数", "parameters"),
}


def _diff_absent() -> str:
    """A missing side of a change is shown as absent, never as a Python None."""
    return '<span data-report-absent>' + escaped("—") + '</span>'


def _diff_readable(field: str) -> bool:
    if field in DIFF_ENCODED_FIELDS or field in DIFF_PLAIN_FIELDS:
        return True
    # A parameter's name and default value are source-visible; its type field is
    # the opaque `name:typeState:type:defaultState:default` encoding.
    return (field.startswith("parameters[")
            and (field.endswith(".name") or field.endswith(".default")))


def _diff_parameter_index(field: str) -> int | None:
    if not field.startswith("parameters["):
        return None
    close = field.find("]")
    if close < 0:
        return None
    try:
        return int(field[len("parameters["):close])
    except ValueError:
        return None


def _diff_field(field: str, locale: str = "en") -> str:
    """A localized label for the field. A parameter keeps its position, so two
    changed parameters are not shown as two identical `name` rows."""
    index = _diff_parameter_index(field)
    if index is not None:
        suffix = field[field.find("]") + 1:].lstrip(".")
        if locale == "zh-CN":
            return f"参数 {index + 1} {suffix}"
        return f"parameter {index + 1} {suffix}" if suffix else f"parameter {index + 1}"
    entry = DIFF_FIELD_LABELS.get(field)
    if entry is not None:
        return entry[0] if locale == "zh-CN" else entry[1]
    return field


def _diff_value(field: str, value) -> str:
    """Render one evidence value on its own lines. Every rendered part stays
    protected source text, so localization never rewrites identifiers."""
    if value is None:
        return _diff_absent()
    text = str(value)
    if field == "parameters":
        return "<br>".join(source_text(part) for part in _diff_parameter_list(text))
    if field in DIFF_ENCODED_FIELDS:
        parts = _diff_token_segments(text)
    else:
        parts = [text]
    return "<br>".join(source_text(part) for part in parts)


def _diff_parameter_list(text: str) -> list[str]:
    """The native list is `name:typeState:type:defaultState:default` joined by
    `|`, but a default expression can itself contain `|`. Only split where the
    following fragment looks like a fresh entry (it has a colon); otherwise the
    fragment continues the current default. If the shape still cannot be read,
    the whole value is shown verbatim rather than as phantom parameters."""
    fragments = text.split("|")
    entries, current = [], fragments[0]
    for fragment in fragments[1:]:
        if ":" in fragment:
            entries.append(current)
            current = fragment
        else:
            current = current + "|" + fragment
    entries.append(current)
    rendered = []
    for entry in entries:
        pieces = entry.split(":")
        # A well-formed entry has name, typeState, type, defaultState, default.
        if len(pieces) >= 3 and entry.count(":") >= 4:
            rendered.append(pieces[0] + ": " + pieces[2])
        else:
            return [text]
    return rendered


def _diff_token_segments(text: str) -> list[str]:
    """Decode a `TAG:byteLength:text` token list. The length counts UTF-8 bytes,
    so the value is walked as bytes; a token whose own text is `|` (such as the
    BITOR operator) then survives without splitting on it."""
    data = text.encode("utf-8")
    parts, index = [], 0
    while index < len(data):
        tag_end = data.find(b":", index)
        length_end = data.find(b":", tag_end + 1) if tag_end >= 0 else -1
        if tag_end < 0 or length_end < 0 or not data[tag_end + 1:length_end].isdigit():
            return [part for part in text.split("|") if part]
        start = length_end + 1
        end = start + int(data[tag_end + 1:length_end])
        if end > len(data):
            return [part for part in text.split("|") if part]
        parts.append(data[start:end].decode("utf-8", "replace"))
        index = end + 1 if end < len(data) and data[end:end + 1] == b"|" else end
    return parts


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
            percent = (escaped(value["percent"]) + "%") if value["total"] else '<span data-reported-percent="' + escaped(value["percent"]) + '">Not applicable</span>'
            display_name = escaped(name) if kind == "project" else source_text(name)
            rows.append([escaped(kind), display_name, escaped(metric), escaped(value["documented"]),
                         escaped(value["total"]), percent])
    return '<section id="coverage"><h2>文档覆盖 / Coverage</h2><p>Audience: <code>' + escaped(raw["audience"]) + (
        '</code>。分子、分母和百分比均来自原报告；覆盖率不证明契约正确。 '
        'All values come from the native report; coverage is not correctness.</p>'
        '<p>semanticLinks counts explicit comment references and @see links only; signature type links are reported separately in diagnostics. '
        'A zero denominator means no applicable items; the original percentage remains in the raw report.</p>'
        '<p><a href="machine/coverage.json">Raw coverage JSON</a></p>') + table(
            ("Scope", "Name", "Metric", "Documented", "Total", "Percent"), rows) + '</section>'


def quality_view(raw: dict, root: Path, mapping: dict) -> str:
    output = '<section id="quality"><h2>文档内容质量 / Documentation quality</h2>'
    output += '<p>Audience: ' + escaped(raw["audience"]) + '; assessment: <code>' + escaped(raw["assessment"]) + '</code>.</p>'
    output += '<p>这是原生保守占位文本启发式，不是语义正确性证明。 Values and findings come directly from the native report.</p>'
    output += '<p><a href="machine/quality.json">Raw quality JSON</a></p>'
    output += table(("Scope", "Meaningful", "Total", "Percent"), [
        [escaped(name), escaped(raw[name]["meaningful"]), escaped(raw[name]["total"]), escaped(raw[name]["percent"])]
        for name in ("symbols", "parameters")])
    for finding in raw["findings"]:
        output += '<article class="report-diagnostic"><h3>' + escaped(finding["code"]) + '</h3><p>'
        output += declaration_link(root, root, mapping, finding["symbolId"], "Source API")
        output += '</p><p>' + escaped(finding["message"]) + '</p></article>'
    return output + '</section>'


def native_check_view(root: Path) -> str:
    path = root / "check-modes/native-check.json"
    if not path.is_file():
        return ''
    raw = checked(path, "cjdoc.showcase-native-check/1")
    if raw.get("exitCode") != 0 or not raw.get("sources"):
        raise ContractError("native check evidence must retain a successful command and exact inputs")
    if raw.get("scope") != "aggregate command evidence; no per-example result claim":
        raise ContractError("unsupported native check evidence scope")
    for item in raw["sources"]:
        source = root / "check-modes" / relative_path(item["path"])
        if not source.is_file() or hashlib.sha256(source.read_bytes()).hexdigest() != item["sha256"]:
            raise ContractError("native check evidence source hash mismatch")
    output = '<section id="native-check"><h2>原生指令检查 / Native directive checks</h2>'
    output += '<p>Compile, run, expected compile failure and skipped source examples are checked by the native CLI. '
    output += '这是整次命令证据；当前引擎没有逐例结果报告，因此不宣称每个示例的独立通过状态。</p>'
    output += '<p><a href="check-modes/native-check.json">Raw native check evidence</a> · <a href="check-modes/src/api.cj" download>View / download exact checked source</a></p>'
    output += '<p>Exit code: <code>' + escaped(raw["exitCode"]) + '</code></p>'
    output += '<pre>' + escaped(json.dumps(raw, ensure_ascii=False, indent=2)) + '</pre></section>'
    return output


def doctest_view(raw: dict | None, ir: dict, root: Path, mapping: dict) -> str:
    output = '<section id="doctest"><h2>示例验证 / Doctest</h2>'
    if raw is None:
        return output + '<p>Not attached. No execution claim is made.</p></section>'
    output += '<p>Mode: <code>' + escaped(raw["mode"]) + '</code>; timeout-ms: ' + escaped(raw["timeoutMs"])
    output += '; memory-mb: ' + escaped(raw["memoryMb"]) + '; jobs: ' + escaped(raw["jobs"]) + '</p>'
    output += '<p>Summary: <code data-report-summary="doctest">' + escaped(json.dumps(raw["summary"], sort_keys=True)) + '</code></p>'
    output += ('<p>此 legacy doctest/results.json 执行器记录编译后运行与跳过；不提供 compile-only 或 expected-failure 成功转换。 '
               'New native directive checks are shown separately as aggregate command evidence. '
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
        output += '<h3>' + source_text(result["qualifiedName"]) + ': ' + escaped(result["status"]) + '</h3>'
        output += '<p>' + declaration_link(root, root, mapping, result["symbolId"], "Source API") + '</p>'
        output += '<p>id: <code>' + escaped(result["id"]) + '</code></p>'
        output += '<p>exitCode: ' + escaped(result["exitCode"]) + '; durationMs: ' + escaped(result["durationMs"]) + '</p>'
        output += '<h4>Source @example</h4><pre><code>' + escaped(tags[0]["description"]) + '</code></pre>'
        for key in ("message", "stdout", "stderr"):
            if result[key]:
                output += '<details><summary>' + escaped(key) + '</summary><pre>' + escaped(result[key]) + '</pre></details>'
        output += '</article>'
    return output + '</section>'


class SourceAction(HTMLParser):
    """Use the native renderer's verified source URL; never invent source mappings."""
    def __init__(self, text: str) -> None:
        super().__init__(convert_charrefs=True)
        self.active = False
        self.href = None
        self.feed(text)

    def handle_starttag(self, tag: str, attrs: list) -> None:
        values = dict(attrs)
        if tag == "p":
            self.active = "source-action" in values.get("class", "").split()
        elif tag == "a" and self.active:
            candidate = values.get("href", "")
            parsed = urlsplit(candidate)
            if parsed.scheme == "https" and parsed.netloc == "github.com":
                self.href = candidate

    def handle_endtag(self, tag: str) -> None:
        if tag == "p":
            self.active = False


def diagnostics_view(ir: dict, root: Path, mapping: dict) -> str:
    output = '<section id="diagnostics"><h2>诊断与缺口 / Diagnostics</h2><p>Collection state: <code>'
    output += escaped(ir["status"]) + '</code>; audience: ' + escaped(ir["configuration"]["audience"]) + '</p>'
    output += '<p><a href="machine/docs.json">Raw Doc IR with diagnostic source ranges</a></p>'
    if not ir["diagnostics"]:
        output += '<p>No diagnostics were emitted. This is not a proof of semantic completeness.</p>'
    else:
        output += '<label class="report-filter">Filter diagnostics <input type="search" data-report-filter placeholder="API, file, code or message"></label>'
        output += '<p data-report-filter-status role="status">' + str(len(ir["diagnostics"])) + ' diagnostics</p>'
    sources = {}
    for number, diagnostic in enumerate(ir["diagnostics"]):
        symbol_id = diagnostic.get("symbolId")
        entry = mapping.get(symbol_id)
        name = entry["qualifiedName"] if entry else "Project diagnostic"
        source = diagnostic.get("source") or {}
        location = source.get("path", "")
        if source.get("start"):
            location += ':' + str(source["start"]["line"])
        search = ' '.join(str(value) for value in (name, location, diagnostic["code"], diagnostic["severity"], diagnostic["message"]))
        output += '<article class="report-diagnostic" data-report-diagnostic data-search="' + escaped(search) + '" id="diagnostic-' + str(number) + '" aria-labelledby="diagnostic-title-' + str(number) + '">'
        output += '<p><strong id="diagnostic-title-' + str(number) + '">' + escaped(diagnostic["code"]) + ' / ' + escaped(diagnostic["severity"]) + '</strong></p><p>'
        output += declaration_link(root, root, mapping, symbol_id, "Source API") if entry else escaped(name)
        if location:
            if entry and symbol_id not in sources:
                page = root / relative_path(entry["href"])
                sources[symbol_id] = SourceAction(page.read_text(encoding="utf-8")).href if page.is_file() else None
            source_url = sources.get(symbol_id)
            output += ' · ' + (f'<a href="{escaped(source_url)}" rel="noreferrer">{source_text(location)}</a>' if source_url else source_text(location))
        output += '</p><p>' + escaped(diagnostic["message"]) + '</p><details><summary>Raw diagnostic JSON</summary><pre>'
        output += escaped(json.dumps(diagnostic, ensure_ascii=False, indent=2)) + '</pre></details></article>'
    return output + '</section>'


def _diff_label(mapping: dict, value: str, locale: str) -> str:
    """Reader-facing wording for a native diff value, falling back to the raw
    value when the vocabulary gains a term the mapping does not know yet."""
    entry = mapping.get(value)
    if entry is None:
        return escaped(value)
    return escaped(entry[0] if locale == "zh-CN" else entry[1])


def diff_view(raw: dict | None, origin: Path, baseline: Path | None, current: Path | None,
              locale: str = "en") -> str:
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
    for name, root in (("baseline", baseline), ("current", current)):
        snapshot = checked(root / "machine/api-surface.json", "cjdoc.api-surface/2")
        identity = {key: snapshot[key] for key in ("project", "audience", "cfgProfile", "schemaVersion", "collectionState")}
        if raw[name] != identity:
            raise ContractError("API diff snapshot identity mismatch: " + name)
    output += '<p>' + escaped(before["version"]) + ' → ' + escaped(after["version"]) + '; comparisonState: <code>' + escaped(raw["comparisonState"]) + '</code></p>'
    output += '<p>Summary: <code data-report-summary="diff">' + escaped(json.dumps(raw["summary"], sort_keys=True)) + '</code></p>'
    output += '<p>分类、匹配状态与证据直接来自原生 diff，不在展示层重新判定。版本通过本次真实输入快照与原生文档索引绑定。 <a href="machine/api-diff.json">Raw API diff JSON</a> · <a href="machine/diff-baseline.json">Baseline snapshot</a> · <a href="machine/diff-current.json">Current snapshot</a></p>'
    for number, entry in enumerate(raw["entries"]):
        if entry["classification"] == "unchanged":
            continue
        output += f'<article id="api-change-{number}" class="report-change" data-diff-classification="{escaped(entry["classification"])}"><h3 data-diff-label="classification">{_diff_label(DIFF_CLASSIFICATIONS, entry["classification"], locale)}</h3>'
        output += '<p>' + declaration_link(baseline, origin, old, entry["oldId"], "Before") + '<br>' + declaration_link(current, origin, new, entry["newId"], "After") + '</p>'
        output += ('<p>matchState: <span data-diff-label="matchState" data-diff-match-state="'
                   + escaped(entry["matchState"]) + '">'
                   + _diff_label(DIFF_MATCH_STATES, entry["matchState"], locale) + '</span></p>'
                   )
        # Reader path: the native reason sentences and the changed fields are
        # shown as text. Raw evidence stays behind a disclosure for traceability.
        if entry["reasons"]:
            output += '<ul data-diff-reasons>' + ''.join(
                '<li data-diff-reason="' + escaped(reason) + '">'
                + _diff_label(DIFF_REASONS, reason, locale) + '</li>'
                for reason in entry["reasons"]) + '</ul>'
        changed = [item for item in entry["evidence"]
                   if _diff_readable(item["field"])
                   and (item.get("state") != "resolved" or item.get("before") != item.get("after"))]
        if changed:
            rows = [[escaped(_diff_field(item["field"], locale)),
                     _diff_value(item["field"], item.get("before")),
                     _diff_value(item["field"], item.get("after"))] for item in changed]
            output += table((DIFF_TABLE_HEADINGS[0 if locale == "zh-CN" else 1][0],
                             DIFF_TABLE_HEADINGS[0 if locale == "zh-CN" else 1][1],
                             DIFF_TABLE_HEADINGS[0 if locale == "zh-CN" else 1][2]), rows)
        output += '<details data-diff-evidence><summary>' + escaped(DIFF_RAW_LABEL[0 if locale == "zh-CN" else 1]) + '</summary><pre>' + escaped(json.dumps({"reasons": entry["reasons"], "evidence": entry["evidence"]}, ensure_ascii=False, indent=2)) + '</pre></details></article>'
    return output + '</section>'


def publish(root: Path, revision: str, version: str, locale: str, *, baseline: Path | None = None,
            current: Path | None = None, diff_path: Path | None = None) -> None:
    root = root.resolve()
    inputs = {"machine/docs.json": IR, "machine/coverage.json": COVERAGE,
              "machine/quality.json": QUALITY,
              "symbol-index.json": "cjdoc.symbol-index/1"}
    if (root / "doctest/results.json").is_file():
        inputs["doctest/results.json"] = DOCTEST
    if (root / "check-modes/native-check.json").is_file():
        inputs["check-modes/native-check.json"] = "cjdoc.showcase-native-check/1"
    if diff_path is not None:
        checked(diff_path, DIFF)
        (root / "machine/api-diff.json").write_bytes(diff_path.read_bytes())
        inputs["machine/api-diff.json"] = DIFF
        for name, source in (("baseline", baseline), ("current", current)):
            if source is None:
                raise ContractError("diff presentation requires both exact snapshot directories")
            destination = "machine/diff-" + name + ".json"
            (root / destination).write_bytes((source / "machine/api-surface.json").read_bytes())
            inputs[destination] = "cjdoc.api-surface/2"
    data = {name: checked(root / name, schema) for name, schema in inputs.items()}
    ir = data["machine/docs.json"]
    raw_index, mapping = index(root, version)
    if ir["project"]["name"] != raw_index["project"]["name"] or ir["configuration"]["audience"] != raw_index["project"]["audience"]:
        raise ContractError("report/index project or audience mismatch")
    if data["machine/coverage.json"]["audience"] != ir["configuration"]["audience"]:
        raise ContractError("coverage audience mismatch")
    if data["machine/quality.json"]["audience"] != ir["configuration"]["audience"]:
        raise ContractError("quality audience mismatch")
    provenance = {"schemaVersion": "cjdoc.report-view/1", "revision": revision,
                  "version": version, "locale": locale, "project": raw_index["project"],
                  "generator": ir["generator"], "inputs": {
                      name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in inputs}}
    (root / "report-provenance.json").write_bytes(canonical_json(provenance))
    body = '<h1>验证与变化 / Validation and changes</h1><nav aria-label="Report sections">'
    body += ' · '.join(f'<a href="#{part}">{part}</a>' for part in ("doctest", "api-diff", "coverage", "diagnostics", "provenance")) + '</nav>'
    body += doctest_view(data.get("doctest/results.json"), ir, root, mapping)
    body += native_check_view(root)
    body += diff_view(data.get("machine/api-diff.json"), root, baseline, current, locale)
    body += coverage_view(data["machine/coverage.json"]) + quality_view(data["machine/quality.json"], root, mapping)
    body += diagnostics_view(ir, root, mapping)
    body += '<section id="provenance"><h2>构建来源 / Provenance</h2><p><a href="report-provenance.json">Exact input hashes</a></p><details><summary>Input hashes and build metadata</summary><pre>' + escaped(json.dumps(provenance, ensure_ascii=False, indent=2)) + '</pre></details></section>'
    body = localize_ui(body, locale)
    page = root / "validation.html"
    original = page.read_text(encoding="utf-8")
    start, end = UtilityRegion(original).regions[0]
    updated = original[:start] + body + original[end:]
    updated = updated.replace('</head>', '<link rel="stylesheet" href="report.css"><script defer src="report.js"></script></head>', 1)
    page.write_text(updated, encoding="utf-8")
    (root / "report.js").write_text(FILTER_SCRIPT, encoding="utf-8")
    (root / "report.css").write_text('.validation-page{min-width:0}.validation-page section{scroll-margin-top:5rem;margin-block:2rem}.validation-page pre{white-space:pre-wrap;overflow-wrap:anywhere}.validation-page code{overflow-wrap:anywhere}.report-table-scroll{max-width:100%;overflow:auto}.report-case,.report-change,.report-diagnostic{border:1px solid var(--border-color,currentColor);padding:1rem;margin-block:1rem;border-radius:.5rem}.report-diagnostic[hidden]{display:none}.report-diagnostic h3,.report-diagnostic p{margin-block:.35rem}.report-filter{display:flex;flex-wrap:wrap;align-items:center;gap:.5rem}.report-filter input{flex:1;min-width:12rem;padding:.5rem}.validation-page table{width:100%;border-collapse:collapse}.validation-page td,.validation-page th{text-align:start;vertical-align:top;padding:.5rem;border-bottom:1px solid currentColor}.report-change td{white-space:pre-line}.report-change td{white-space:pre-line}', encoding="utf-8")


def verify(root: Path, revision: str) -> None:
    metadata = checked(root / "report-provenance.json", "cjdoc.report-view/1")
    if metadata["revision"] != revision:
        raise ContractError("stale report presentation revision")
    index(root, metadata["version"])
    for name, digest in metadata["inputs"].items():
        path = root / relative_path(name)
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ContractError("stale or missing raw input behind report presentation")
