"""User-facing report assertions against the exact native raw reports."""
from __future__ import annotations

import json
import hashlib

from .browser_support import Journey, click_and_return, require_text


def doctest(journey: Journey):
    page = journey.page
    raw = journey.raw('#doctest a[href$="results.json"]', "cjdoc.doctest/1")
    if not raw["results"]:
        raise AssertionError("doctest demonstration contains no real execution results")
    summary = json.loads(page.locator('[data-report-summary="doctest"]').inner_text())
    if summary != raw["summary"]:
        raise AssertionError("doctest displayed summary differs from raw results")
    cases = page.locator("[data-doctest-status]")
    if cases.count() != len(raw["results"]):
        raise AssertionError("doctest view drops a native result")
    for index, result in enumerate(raw["results"]):
        case = cases.nth(index)
        if case.get_attribute("data-doctest-status") != result["status"]:
            raise AssertionError("doctest presentation changed the native status")
        require_text(case, result["id"], "exitCode: " + str(result["exitCode"]), "Source @example")
        if not case.locator("pre code").inner_text().strip():
            raise AssertionError("doctest result is missing its exact source example")
    source = cases.first.locator("[data-report-symbol]")
    click_and_return(journey, source, raw["results"][0]["qualifiedName"].split(".")[-1], journey.target["version"])
    check = journey.raw('#native-check a[href$="native-check.json"]', "cjdoc.showcase-native-check/1")
    if check.get("exitCode") != 0 or check.get("scope") != "aggregate command evidence; no per-example result claim":
        raise AssertionError("native check does not provide successful aggregate command evidence")
    selector = '#native-check a[href$="src/api.cj"]'
    # Chromium displays local text files even when the link has `download`.
    # Exercise that real offline navigation and compare its exact source bytes.
    source = (journey.raw(selector).encode("utf-8") if journey.mode == "file"
              else journey.download(selector))
    records = [item for item in check["sources"] if item["path"] == "src/api.cj"]
    if len(records) != 1 or hashlib.sha256(source).hexdigest() != records[0]["sha256"]:
        raise AssertionError("native check source does not match its execution input digest")
    journey.assertions.append("native compile/run/expected-failure checks retain aggregate exit status and exact source inputs opened offline or downloaded over HTTP")
    journey.assertions.append("every displayed doctest status/id/exit code matches raw execution, with a source example and native API backlink")


def diff(journey: Journey):
    page = journey.page
    raw = journey.raw('#api-diff a[href$="api-diff.json"]', "cjdoc.api-diff/1")
    require_text(page.locator("#api-diff"), "demo-v1", "demo-v2", raw["comparisonState"])
    displayed = json.loads(page.locator('[data-report-summary="diff"]').inner_text())
    if displayed != raw["summary"]:
        raise AssertionError("diff view differs from the native diff summary")
    expected = [entry for entry in raw["entries"] if entry["classification"] != "unchanged"]
    rows = page.locator("[data-diff-classification]")
    if not expected or rows.count() != len(expected):
        raise AssertionError("diff view omits native changes")
    for number, entry in enumerate(expected):
        if rows.nth(number).get_attribute("data-diff-classification") != entry["classification"]:
            raise AssertionError("diff view reclassified a native change")
        require_text(rows.nth(number), entry["matchState"])
    links = page.locator("#api-diff [data-report-symbol]")
    for label, version in (("Before", "demo-v1"), ("After", "demo-v2")):
        link = links.filter(has_text=label).first
        symbol = link.inner_text().split(":", 1)[-1].strip().split(".")[-1]
        click_and_return(journey, link, symbol, version)
    journey.assertions.append("the native diff's versions, comparison state and change classifications match raw evidence and open before/after APIs")


def quality(journey: Journey):
    page = journey.page
    raw = journey.raw('#coverage a[href$="coverage.json"]', "cjdoc.documentation-coverage/2")
    require_text(page.locator("#coverage"), raw["audience"], "coverage is not correctness")
    rows = page.locator("#coverage tbody tr")
    expected = []
    scopes = [("project", "all", raw["metrics"])]
    for scope in ("packages", "modules"):
        scopes += [(scope, item.get("name", item.get("id", "")), item["metrics"]) for item in raw[scope]]
    for scope, name, metrics in scopes:
        for metric, value in metrics.items():
            expected.append([scope, name, metric, str(value["documented"]), str(value["total"]), str(value["percent"]) + "%"])
    actual = [row.locator("td").all_text_contents() for row in rows.all()]
    if actual != expected:
        raise AssertionError("coverage scope/numerators/denominators differ from native raw metrics")
    ir = journey.raw('#diagnostics a[href$="docs.json"]', "cjdoc.doc-ir/11")
    if page.locator("#diagnostics .report-diagnostic").count() != len(ir["diagnostics"]):
        raise AssertionError("quality page dropped native diagnostics")
    lint = journey.raw('#quality a[href$="quality.json"]', "cjdoc.documentation-quality/1")
    require_text(page.locator("#quality"), lint["audience"], lint["assessment"])
    displayed = [row.locator("td").all_text_contents() for row in page.locator("#quality tbody tr").all()]
    expected_quality = [[name, str(lint[name]["meaningful"]), str(lint[name]["total"]), str(lint[name]["percent"])]
                        for name in ("symbols", "parameters")]
    if displayed != expected_quality:
        raise AssertionError("quality view changed native heuristic metrics")
    findings = page.locator("#quality .report-diagnostic")
    if findings.count() != len(lint["findings"]):
        raise AssertionError("quality view dropped native findings")
    for number, finding in enumerate(lint["findings"]):
        require_text(findings.nth(number), finding["code"], finding["message"])
    journey.assertions.append("coverage retains every native audience/scope/numerator/denominator and raw diagnostic source record")


def diagnostics(journey: Journey):
    page = journey.page
    ir = journey.raw('#diagnostics a[href$="docs.json"]', "cjdoc.doc-ir/11")
    native = ir["diagnostics"]
    if not native or page.locator("#diagnostics .report-diagnostic").count() != len(native):
        raise AssertionError("boundary demonstration has no complete native diagnostics")
    for number, diagnostic in enumerate(native):
        shown = json.loads(page.locator("#diagnostics .report-diagnostic").nth(number).locator("pre").inner_text())
        if shown != diagnostic:
            raise AssertionError("boundary view changed the native diagnostic or source range")
    raw = journey.raw('#doctest a[href$="results.json"]', "cjdoc.doctest/1")
    states = {result["status"] for result in raw["results"]}
    if not {"failed", "skipped"}.issubset(states):
        raise AssertionError("boundary demonstration needs actual failed and skipped examples")
    for result in raw["results"]:
        article = page.locator("[data-doctest-status]").filter(has_text=result["id"])
        if article.count() != 1 or article.get_attribute("data-doctest-status") != result["status"]:
            raise AssertionError("boundary presentation disguised a failed/skipped result")
    journey.assertions.append("isolated negative samples keep native diagnostic ranges and actual failed/skipped doctest statuses")


JOURNEYS = {"doctest": doctest, "diff": diff, "quality": quality, "diagnostics": diagnostics}
