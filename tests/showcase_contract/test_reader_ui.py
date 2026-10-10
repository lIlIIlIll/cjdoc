"""Reader-facing publication regressions; raw native report semantics stay unchanged."""
from __future__ import annotations

import copy
import html
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from report_views.localization import localize_ui
from report_views.pages import PageTitle
from report_views.reports import (FILTER_SCRIPT, coverage_view, declaration_link,
                                  diagnostics_view, diff_view)
from showcase_build.homepage import cards, getting_started
from showcase_build.navigation import SCRIPT, VersionLinks
from showcase_contract.browser_reports import expected_coverage_rows


class ReaderUiTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_coverage_labels_explain_denominators_without_recalculating_values(self) -> None:
        raw = {"audience": "external", "packages": [], "modules": [], "metrics": {
            "symbols": {"documented": 2, "total": 3, "percent": 66},
            "semanticLinks": {"documented": 8, "total": 8, "percent": 100},
            "deprecated": {"documented": 0, "total": 0, "percent": 100}}}
        original = copy.deepcopy(raw)
        result = localize_ui(coverage_view(raw), "zh-CN")
        self.assertIn("66%", result)
        self.assertIn("注释引用解析率", result)
        self.assertIn("签名类型链接另列在诊断中", result)
        self.assertIn('data-reported-percent="100">无适用项', result)
        self.assertEqual(raw, original)

    def test_browser_coverage_contract_keeps_each_raw_number_and_localizes_only_labels(self) -> None:
        raw = {"metrics": {"symbols": {"documented": 2, "total": 3, "percent": 17},
                           "deprecated": {"documented": 0, "total": 0, "percent": 93}},
               "packages": [{"name": "fixture", "metrics": {"parameters": {"documented": 1, "total": 5, "percent": 19}}}],
               "modules": []}
        original = copy.deepcopy(raw)
        self.assertEqual(expected_coverage_rows(raw, True), [
            ["项目", "全部", "声明摘要", "2", "3", "17%"],
            ["项目", "全部", "弃用说明", "0", "0", "无适用项"],
            ["包", "fixture", "参数说明", "1", "5", "19%"]])
        self.assertEqual(expected_coverage_rows(raw, False), [
            ["project", "all", "symbols", "2", "3", "17%"],
            ["project", "all", "deprecated", "0", "0", "Not applicable"],
            ["packages", "fixture", "parameters", "1", "5", "19%"]])
        self.assertEqual(raw, original)

    def test_diagnostics_link_exact_native_identity_and_source_without_guessing(self) -> None:
        (self.root / "symbols").mkdir()
        (self.root / "symbols/api.html").write_text('<p class="source-action"><a href="https://github.com/o/r/blob/revision/src/a.cj#L7-L9">Source</a></p>', encoding="utf-8")
        entry = {"qualifiedName": "fixture.BeforeClass", "href": "symbols/api.html"}
        diagnostic = {"code": "CJDOC3035", "severity": "warning", "message": 'missing <summary>',
                      "symbolId": "symbol:real", "source": {"path": "src/a.cj", "start": {"line": 7}}}
        raw = {"status": "complete", "configuration": {"audience": "external"}, "diagnostics": [diagnostic,
               {"code": "CJDOC1001", "severity": "warning", "message": "project input", "symbolId": None, "source": None}]}
        result = localize_ui(diagnostics_view(raw, self.root, {"symbol:real": entry}), "zh-CN")
        self.assertIn('data-report-diagnostic', result)
        self.assertIn('href="symbols/api.html"', result)
        self.assertIn('href="https://github.com/o/r/blob/revision/src/a.cj#L7-L9"', result)
        self.assertIn('fixture.BeforeClass', result)
        self.assertIn('missing &lt;summary&gt;', result)
        self.assertIn('<details><summary>原始诊断 JSON</summary><pre>', result)
        self.assertNotIn('<details open', result)
        self.assertNotIn('<h3>', result)
        self.assertIn('aria-labelledby="diagnostic-title-0"', result)
        self.assertIn('项目诊断', result)
        self.assertEqual(result.count('data-report-symbol='), 1)

    def test_localization_keeps_raw_json_and_author_examples_exact(self) -> None:
        evidence = '<pre><code>{&quot;message&quot;:&quot;Before: absent&quot;}</code></pre>'
        result = localize_ui('<h2>文档覆盖 / Coverage</h2>' + evidence, "zh-CN")
        self.assertTrue(result.endswith(evidence))
        self.assertIn('<h2>文档覆盖</h2>', result)
        self.assertIn('<h2>Coverage</h2>', localize_ui('<h2>文档覆盖 / Coverage</h2>', "en"))

    def test_report_localization_preserves_real_names_that_match_ui_labels(self) -> None:
        metric = {"symbols": {"documented": 1, "total": 2, "percent": 50}}
        raw = {"audience": "external", "metrics": metric,
               "packages": [{"name": "all", "metrics": metric}],
               "modules": [{"name": "symbols", "metrics": metric}]}
        rendered = localize_ui(coverage_view(raw), "zh-CN")
        self.assertIn('<span data-report-source-text>all</span>', rendered)
        self.assertIn('<span data-report-source-text>symbols</span>', rendered)
        link = declaration_link(self.root, self.root, {"symbol": {"href": "api.html", "qualifiedName": "Source API"}}, "symbol", "Source API")
        self.assertIn('对应 API: <span data-report-source-text>Source API</span>', localize_ui(link, "zh-CN"))
        expected = expected_coverage_rows(raw, True)
        self.assertEqual(expected[1][1], "all")
        self.assertEqual(expected[2][1], "symbols")

    def test_api_diff_view_localizes_labels_and_keeps_evidence_lines(self) -> None:
        baseline = self.root / "baseline"
        current = self.root / "current"
        for root, version in ((baseline, "1.0.0"), (current, "1.1.0")):
            (root / "machine").mkdir(parents=True)
            (root / "symbols").mkdir(parents=True)
            (root / "symbols" / "changed.html").write_text("page", encoding="utf-8")
            (root / "symbol-index.json").write_text(json.dumps({
                "schemaVersion": "cjdoc.symbol-index/1",
                "project": {"name": "fixture", "audience": "external"},
                "version": version,
                "entries": [{"id": "sym", "href": "symbols/changed.html",
                             "qualifiedName": "fixture.changed"}]}), encoding="utf-8")
            (root / "machine" / "api-surface.json").write_text(json.dumps({
                "schemaVersion": "cjdoc.api-surface/2", "project": "fixture",
                "audience": "external", "cfgProfile": "default", "collectionState": "complete"}),
                encoding="utf-8")
        identity = {"project": "fixture", "audience": "external", "cfgProfile": "default",
                    "schemaVersion": "cjdoc.api-surface/2", "collectionState": "complete"}
        raw = {"baseline": dict(identity), "current": dict(identity),
               "comparisonState": "complete", "summary": {},
               "entries": [{"classification": "potentially-breaking", "matchState": "fallback",
                            "oldId": "sym", "newId": "sym",
                            "reasons": ["Parameter type changed"],
                            "evidence": [{"field": "parameterTypes", "state": "changed",
                                          "before": "String|Int64", "after": "String"}]}]}
        view = diff_view(raw, self.root, baseline, current, locale="zh-CN")
        # Reader-facing wording replaces the native vocabulary, which stays in
        # the data-* attribute and the raw evidence block.
        self.assertIn('data-diff-label="classification">潜在不兼容变化<', view)
        self.assertIn('data-diff-label="matchState">按名称回退匹配<', view)
        self.assertIn('data-diff-classification="potentially-breaking"', view)
        # Each evidence segment is its own line in the cell.
        # Each segment is its own protected source line; segments are not
        # translated and the break is explicit.
        self.assertIn('<span data-report-source-text>String</span><br>', view)
        self.assertIn('<span data-report-source-text>Int64</span>', view)

    def test_report_version_links_keep_category_and_expose_missing_report(self) -> None:
        for version in ("demo-v1", "demo-v2"):
            (self.root / version).mkdir()
        (self.root / "demo-v1/report-coverage.html").write_text("old", encoding="utf-8")
        (self.root / "demo-v2/report-diff.html").write_text("diff", encoding="utf-8")
        source = '<nav class="cjdoc-version-selector"><a href="../demo-v1/validation.html">demo-v1</a><a href="../demo-v2/validation.html" aria-current="page">demo-v2</a><a href="../demo-v2/api-diff.json">Changes</a></nav>'
        result = VersionLinks(source, self.root / "demo-v2/report-coverage.html", "zh-CN").result()
        self.assertIn('href="../demo-v1/report-coverage.html"', result)
        self.assertIn('aria-disabled="true">demo-v2 — 无对应报告', result)
        self.assertIn('href="../demo-v2/report-diff.html">版本变化', result)
        self.assertIn('href="../demo-v2/api-diff.json">原始 JSON', result)

    @unittest.skipUnless(shutil.which("node"), "Node is required for publication JavaScript runtime checks")
    def test_native_version_script_keeps_published_report_route(self) -> None:
        (self.root / "demo-v1").mkdir()
        (self.root / "demo-v2").mkdir()
        (self.root / "demo-v1/report-coverage.html").write_text("report", encoding="utf-8")
        routes = html.escape(json.dumps({"symbol-real": ["../demo-v1/symbols/owner.html#symbol-real", False]}), quote=True)
        source = '<nav class="cjdoc-version-selector"><a data-cjdoc-version-link data-cjdoc-version-label="demo-v1" data-cjdoc-version-missing=" unavailable" data-cjdoc-version-routes="' + routes + '" href="../demo-v1/validation.html">demo-v1</a></nav>'
        rendered = VersionLinks(source, self.root / "demo-v2/report-coverage.html", "en").result()
        from html.parser import HTMLParser
        class Anchor(HTMLParser):
            def handle_starttag(self, tag: str, attrs: list) -> None:
                if tag == "a": self.attrs = dict(attrs)
        anchor = Anchor(); anchor.feed(rendered)
        native = (ROOT / "src/version_navigation.cj").read_text(encoding="utf-8").split('internal let VERSION_NAVIGATION_SCRIPT = #"', 1)[1].split('"#', 1)[0]
        harness = 'const attrs=' + json.dumps(anchor.attrs) + ''';
const handlers={};const link={textContent:"demo-v1",getAttribute:k=>attrs[k],setAttribute:(k,v)=>attrs[k]=v};
global.document={querySelectorAll:()=>[link]};global.location={hash:"#diagnostics"};global.addEventListener=(name,fn)=>handlers[name]=fn;
''' + native + '''
if(attrs.href!=="../demo-v1/report-coverage.html")throw Error("native script reset report category");
location.hash="#coverage";handlers.hashchange();if(attrs.href!=="../demo-v1/report-coverage.html")throw Error("hash changed report category");'''
        result = subprocess.run(["node", "-e", harness], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_report_title_identifies_the_focused_page(self) -> None:
        page = '<title>Validation</title><h1>Validation</h1><h2>Section</h2>'
        self.assertEqual(PageTitle(page, "Coverage").result(), '<title>Coverage</title><h1>Coverage</h1><h2>Section</h2>')

    def test_task_groups_preserve_all_features_and_local_entry_targets(self) -> None:
        features = json.loads((ROOT / "site/showcase-catalog.json").read_text(encoding="utf-8"))["features"]
        manifest = {"features": [{**feature, "targets": [
            {"id": feature["id"] + "-" + locale, "locale": locale, "version": "demo-v2", "resolved": {"href": locale + "/api.html"}}
            for locale in ("zh-CN", "en")] if feature["targets"] else []} for feature in features]}
        for locale in ("zh-CN", "en"):
            result = cards(manifest, locale)
            self.assertEqual(result.count('class="feature-card"'), 17)
            self.assertEqual(result.count('class="feature-group"'), 4)
            self.assertEqual(result.count('data-target-id='), 16)
            self.assertIn('href="showcase-features.json"', result)
            self.assertNotIn(' / 实现', result)
            self.assertNotIn('<details open', result)
            other = 'en' if locale == 'zh-CN' else 'zh-CN'
            self.assertNotIn('href="' + other + '/api.html"', result)

    def test_own_project_route_contains_install_generate_and_open_steps(self) -> None:
        content = getting_started("zh-CN", "https://github.com/o/r")
        self.assertIn('https://github.com/o/r/releases', content)
        self.assertIn('cjdoc generate --project /path/to/your-project --format html', content)
        self.assertIn('target/doc/html/index.html', content)
        self.assertIn('api/concepts/manual/advanced-usage.html', content)

    @unittest.skipUnless(shutil.which("node"), "Node is required for publication JavaScript runtime checks")
    def test_language_href_tracks_hash_before_activation_and_clears_stale_hash(self) -> None:
        script = '''const handlers = {}; const link = {dataset:{localeAnchors:'["member","other"]'},hash:""};
global.location={hash:"#member"};global.addEventListener=(name,fn)=>handlers[name]=fn;
global.document={querySelectorAll:s=>s==="[data-showcase-locale]"?[link]:[]};
''' + SCRIPT + '''
if(link.hash!=="#member") throw Error("initial member was lost");
location.hash="#other";handlers.hashchange();if(link.hash!=="#other") throw Error("hash changed after activation only");
location.hash="#missing";handlers.hashchange();if(link.hash!=="") throw Error("stale member persisted");
location.hash="#bad%";handlers.hashchange();if(link.hash!=="") throw Error("invalid encoding persisted");'''
        result = subprocess.run(["node", "-e", script], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(shutil.which("node"), "Node is required for publication JavaScript runtime checks")
    def test_report_filter_matches_localized_messages_and_source_then_resets(self) -> None:
        script = '''let filter;
const rows=[{dataset:{search:"a.cj CJDOC3035 first missing summary"},textContent:"缺少文档摘要"},{dataset:{search:"b.cj CJDOC3038 last missing example"},textContent:"缺少示例"}];
const status={textContent:""};const section={querySelectorAll:()=>rows,querySelector:()=>status};
const input={value:"",closest:()=>section,addEventListener:(name,fn)=>filter=fn};
global.document={documentElement:{lang:"zh-CN"},querySelectorAll:()=>[input]};
''' + FILTER_SCRIPT + '''
input.value="a.cj 摘要";filter();if(rows[0].hidden||!rows[1].hidden)throw Error("localized source filter failed");
if(status.textContent!=="显示 1 / 2 条诊断")throw Error("count failed");
input.value="no match";filter();if(rows.some(row=>!row.hidden))throw Error("no-match failed");
input.value="";filter();if(rows.some(row=>row.hidden))throw Error("reset failed");'''
        result = subprocess.run(["node", "-e", script], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(shutil.which("node"), "Node is required for publication JavaScript runtime checks")
    def test_showcase_restores_native_theme_and_toggles_the_shared_key(self) -> None:
        bootstrap = (ROOT / "site/theme-bootstrap.js").read_text(encoding="utf-8")
        script = (ROOT / "site/showcase.js").read_text(encoding="utf-8")
        harness = '''const storage={"cjdoc-theme":"terminal"};let click;
global.localStorage={getItem:k=>storage[k]||null,setItem:(k,v)=>storage[k]=v};
global.matchMedia=()=>({matches:false});global.location={protocol:"https:"};
global.document={documentElement:{lang:"zh-CN",dataset:{}},querySelector:s=>s==='[data-showcase-theme]'?{addEventListener:(name,fn)=>click=fn}:null,querySelectorAll:()=>[]};
''' + bootstrap + '\n' + script + '''
if(document.documentElement.dataset.theme!=="terminal")throw Error("native theme lost");
click();if(storage["cjdoc-theme"]!=="light")throw Error("theme not shared with native pages");'''
        result = subprocess.run(["node", "-e", harness], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
