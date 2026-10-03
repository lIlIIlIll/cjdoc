"""Synthetic contract tests, NOT native cjdoc or final-Pages browser evidence."""

from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from showcase_contract import ContractError, Site, resolve_plan, validate_evidence
from showcase_contract.contract import check_regressions, json_pointer, validate_plan
from showcase_contract.render import render_cards, render_home
from showcase_contract.site import canonical_json, load_json, relative_path

REVISION = "a" * 40
PROJECT = {"name": "synthetic_showcase", "audience": "external", "version": "demo-v2"}


def write(root: Path, name: str, content: object) -> Path:
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content if isinstance(content, str) else json.dumps(content, ensure_ascii=False),
                    encoding="utf-8")
    return path


class ContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.site = self.root / "site"
        self.evidence_root = self.root / "evidence"
        self.evidence_root.mkdir()
        write(self.repo, "examples/synthetic.cj", "// synthetic contract-test input, not a demo library\n")
        write(self.site, "index.html", '<html lang="en"><body id="home">Home</body></html>')
        self.page_name = "demo/types/generated-route.html"
        write(self.site, self.page_name,
              '<html lang="en"><body><a href="../../index.html">Home</a>'
              '<h1 id="add">Synthetic member</h1></body></html>')
        self.page = {"id": "page:synthetic", "kind": "symbol", "title": "Bag.add",
                     "href": "types/generated-route.html#add", "summary": "Synthetic fixture",
                     "symbolId": "symbol:synthetic", "moduleId": "demo-module",
                     "packageName": "demo.collections", "semanticState": "partial"}
        self.index = {"schemaVersion": "cjdoc.navigation-index/1", "project": copy.deepcopy(PROJECT),
                      "pages": [self.page]}
        self.index_name = "demo/navigation-index.json"
        self.save_index()
        self.target = {"id": "member-en-v2", "kind": "navigation", "locale": "en",
                       "version": "demo-v2", "instructions": "Open the synthetic member",
                       "index": self.index_name, "project": copy.deepcopy(PROJECT),
                       "match": {"kind": "symbol", "title": "Bag.add", "packageName": "demo.collections"},
                       "scenarios": [{"id": "homepage-member", "mode": "http"},
                                     {"id": "homepage-member", "mode": "file"}]}
        self.feature = {"id": "member", "title": "Synthetic member navigation",
                        "implementation": "partial", "demonstration": "available",
                        "reason": "Synthetic data tests the gate; it proves no cjdoc behavior.",
                        "trackingIssues": [50], "inputs": ["examples/synthetic.cj"],
                        "targets": [self.target]}
        self.plan = {"schemaVersion": "cjdoc.showcase-plan/1", "features": [self.feature]}

    def save_index(self) -> None:
        write(self.site, self.index_name, self.index)

    def resolve(self) -> dict:
        return resolve_plan(self.plan, Site(self.site), self.repo, REVISION)

    def evidence(self, manifest: dict) -> dict:
        image = self.evidence_root / "synthetic-screenshot.txt"
        image.write_text("unit-test attachment, deliberately not a browser screenshot", encoding="utf-8")
        result = {"featureId": "member", "targetId": "member-en-v2", "scenarioId": "homepage-member",
                  "locale": "en", "version": "demo-v2", "status": "passed", "entry": "index.html",
                  "href": self.page_name + "#add", "activations": 1, "documentNavigations": 1,
                  "assertions": ["Synthetic result used only to test evidence identity validation"],
                  "screenshot": {"path": image.name, "sha256": hashlib.sha256(image.read_bytes()).hexdigest()}}
        return {"schemaVersion": "cjdoc.showcase-evidence/1", "revision": REVISION,
                "manifestSha256": hashlib.sha256(canonical_json(manifest)).hexdigest(),
                "siteSha256": Site(self.site).digest(),
                "runner": {"name": "synthetic-unit-test", "version": "1", "browser": "none",
                           "browserVersion": "not-run"},
                "results": [{**result, "mode": "http"}, {**result, "mode": "file"}]}

    def test_deterministic_resolution_preserves_semantic_uncertainty(self) -> None:
        before = copy.deepcopy(self.plan)
        result = self.resolve()
        target = result["features"][0]["targets"][0]["resolved"]
        self.assertEqual(target["href"], self.page_name + "#add")
        self.assertEqual(target["semanticState"], "partial")
        self.assertEqual(result, self.resolve())
        self.assertEqual(before, self.plan)
        self.assertEqual(result["revision"], REVISION)

    def test_source_digest_tracks_input_bytes(self) -> None:
        before = self.resolve()
        write(self.repo, "examples/synthetic.cj", "// different source")
        after = self.resolve()
        self.assertNotEqual(before["features"][0]["inputs"], after["features"][0]["inputs"])

    def test_rejects_missing_source_input(self) -> None:
        (self.repo / "examples/synthetic.cj").unlink()
        with self.assertRaisesRegex(ContractError, "source input"):
            self.resolve()

    def test_rejects_source_symlinks(self) -> None:
        source = self.repo / "examples/synthetic.cj"
        source.unlink()
        source.symlink_to(self.site / "index.html")
        with self.assertRaisesRegex(ContractError, "symlink"):
            self.resolve()

    def test_full_revision_is_required(self) -> None:
        for revision in ("main", "abcd1234", "A" * 40, "", None):
            with self.subTest(revision=revision), self.assertRaises(ContractError):
                resolve_plan(self.plan, Site(self.site), self.repo, revision)

    def test_json_duplicate_keys_rejected(self) -> None:
        path = write(self.root, "duplicate.json", '{"features":[],"features":[1]}')
        with self.assertRaisesRegex(ContractError, "duplicate JSON key"):
            load_json(path)

    def test_json_nonfinite_numbers_and_nonobjects_rejected(self) -> None:
        for content in ('{"n":NaN}', '{"n":Infinity}', '[]', 'null', '{"n":'):
            with self.subTest(content=content), self.assertRaises(ContractError):
                load_json(write(self.root, "bad.json", content))

    def test_unknown_plan_fields_rejected(self) -> None:
        self.plan["demoState"] = "available"
        with self.assertRaisesRegex(ContractError, "unknown fields"):
            self.resolve()

    def test_unknown_schema_rejected(self) -> None:
        self.plan["schemaVersion"] = "cjdoc.showcase-plan/999"
        with self.assertRaisesRegex(ContractError, "schema"):
            self.resolve()

    def test_duplicate_feature_ids_rejected(self) -> None:
        self.plan["features"].append(copy.deepcopy(self.feature))
        with self.assertRaisesRegex(ContractError, "duplicate feature"):
            self.resolve()

    def test_duplicate_target_ids_rejected(self) -> None:
        self.feature["targets"].append(copy.deepcopy(self.target))
        with self.assertRaisesRegex(ContractError, "duplicate target"):
            self.resolve()

    def test_duplicate_scenarios_rejected(self) -> None:
        self.target["scenarios"].append(copy.deepcopy(self.target["scenarios"][0]))
        with self.assertRaisesRegex(ContractError, "duplicate scenario"):
            self.resolve()

    def test_available_requires_inputs_targets_and_scenarios(self) -> None:
        for field in ("inputs", "targets", "scenarios"):
            plan = copy.deepcopy(self.plan)
            owner = plan["features"][0]
            if field == "scenarios":
                owner = owner["targets"][0]
            owner[field] = []
            with self.subTest(field=field), self.assertRaises(ContractError):
                validate_plan(plan)

    def test_unimplemented_cannot_be_available(self) -> None:
        self.feature["implementation"] = "not-implemented"
        with self.assertRaisesRegex(ContractError, "cannot be available"):
            self.resolve()

    def test_partial_implementation_keeps_limitations_visible(self) -> None:
        manifest = self.resolve()
        self.assertIn(self.feature["reason"], render_cards(manifest))
        self.feature["reason"] = ""
        with self.assertRaisesRegex(ContractError, "reason"):
            self.resolve()

    def test_blocked_capability_needs_tracking_issue(self) -> None:
        self.feature.update(demonstration="blocked", inputs=[], targets=[], trackingIssues=[])
        with self.assertRaisesRegex(ContractError, "tracking issue"):
            self.resolve()
        self.feature["trackingIssues"] = [49]
        cards = render_cards(self.resolve())
        self.assertIn("演示阻塞", cards)
        self.assertIn("#49", cards)
        self.assertNotIn("href=", cards)

    def test_implementation_and_demo_states_are_independent(self) -> None:
        self.feature.update(implementation="complete", demonstration="uncovered", targets=[])
        cards = render_cards(self.resolve())
        self.assertIn("实现完成", cards)
        self.assertIn("演示未覆盖", cards)

    def test_boolean_issue_numbers_are_not_integer_ids(self) -> None:
        self.feature["trackingIssues"] = [True]
        with self.assertRaisesRegex(ContractError, "issue numbers"):
            self.resolve()

    def test_scoped_symbol_selector_required(self) -> None:
        del self.target["match"]["packageName"]
        with self.assertRaisesRegex(ContractError, "scope"):
            self.resolve()

    def test_hardcoded_symbol_ids_and_href_selectors_rejected(self) -> None:
        for key in ("symbolId", "href"):
            with self.subTest(key=key):
                self.target["match"][key] = "guessed-hash"
                with self.assertRaisesRegex(ContractError, "unknown fields"):
                    self.resolve()
                del self.target["match"][key]

    def test_missing_and_ambiguous_targets_fail_instead_of_downgrading(self) -> None:
        for pages in ([], [self.page, copy.deepcopy(self.page)]):
            with self.subTest(count=len(pages)):
                self.index["pages"] = pages
                self.save_index()
                with self.assertRaisesRegex(ContractError, "exactly one match"):
                    self.resolve()
                self.assertEqual(self.feature["demonstration"], "available")

    def test_scope_disambiguates_same_name(self) -> None:
        self.index["pages"].append({**self.page, "packageName": "another.collections"})
        self.save_index()
        self.assertEqual(self.resolve()["features"][0]["targets"][0]["resolved"]["pageId"], "page:synthetic")

    def test_route_changes_follow_authoritative_index(self) -> None:
        self.page["href"] = "types/new-generated-route.html#add"
        self.save_index()
        (self.site / self.page_name).rename(self.site / "demo/types/new-generated-route.html")
        self.assertEqual(self.resolve()["features"][0]["targets"][0]["resolved"]["href"],
                         "demo/types/new-generated-route.html#add")

    def test_navigation_version_mismatch_fails(self) -> None:
        self.index["project"]["version"] = "demo-v1"
        self.save_index()
        with self.assertRaisesRegex(ContractError, "project/version/audience mismatch"):
            self.resolve()

    def test_plan_target_and_project_version_mismatch_fails(self) -> None:
        self.target["version"] = "demo-v1"
        with self.assertRaisesRegex(ContractError, "target.version"):
            self.resolve()

    def test_wrong_html_locale_fails(self) -> None:
        self.target["locale"] = "zh"
        with self.assertRaisesRegex(ContractError, "language mismatch"):
            self.resolve()

    def test_navigation_schema_mismatch_fails(self) -> None:
        self.index["schemaVersion"] = "cjdoc.navigation-index/99"
        self.save_index()
        with self.assertRaisesRegex(ContractError, "navigation schema"):
            self.resolve()

    def test_missing_member_anchor_fails(self) -> None:
        self.page["href"] += "-removed"
        self.save_index()
        with self.assertRaisesRegex(ContractError, "missing anchor"):
            self.resolve()

    def test_unsafe_navigation_hrefs_rejected(self) -> None:
        for href in ("https://docs.example.test/t", "../index.html", "/index.html",
                     "//example.com/x", "types/x.html?mode=a", "types/%2e%2e/index.html"):
            with self.subTest(href=href):
                self.page["href"] = href
                self.save_index()
                with self.assertRaises(ContractError):
                    self.resolve()

    def test_all_local_href_and_src_links_checked(self) -> None:
        write(self.site, "index.html", '<a href="demo/types/generated-route.html#add">Member</a>'
              '<script src="assets/app.js"></script>')
        with self.assertRaisesRegex(ContractError, "missing published file"):
            Site(self.site).validate_links()
        write(self.site, "assets/app.js", "// synthetic")
        Site(self.site).validate_links()

    def test_in_tree_parent_navigation_and_encoded_anchor(self) -> None:
        write(self.site, "index.html", '<h1 id="中文">Home</h1>')
        site = Site(self.site)
        self.assertEqual(site.local_link(self.page_name, "../../index.html#%E4%B8%AD%E6%96%87"),
                         ("index.html", "中文"))

    def test_portable_directory_links_resolve_to_index(self) -> None:
        site = Site(self.site)
        self.assertEqual(site.local_link(self.page_name, "../../"), ("index.html", ""))
        self.assertEqual(site.local_link("index.html", "./"), ("index.html", ""))

    def test_unsafe_local_links_rejected(self) -> None:
        site = Site(self.site)
        for href in ("../secret", "%2e%2e/secret", "%2fetc/passwd", "/cjdoc/index.html",
                     "//example.com/index.html", "x\\y", "a%00b", "a%2500b", "javascript:alert(1)"):
            with self.subTest(href=href), self.assertRaises(ContractError):
                site.local_link("index.html", href)

    def test_placeholder_domains_not_published_and_external_sites_not_fetched(self) -> None:
        site = Site(self.site)
        with self.assertRaisesRegex(ContractError, "test-domain"):
            site.local_link("index.html", "https://docs.example.test/type.html")
        self.assertIsNone(site.local_link("index.html", "https://github.com/lIlIIlIll/cjdoc"))
        self.assertIsNone(site.local_link("index.html", "mailto:maintainer@example.org"))

    def test_duplicate_ids_and_base_element_rejected(self) -> None:
        for html, expected in (('<h1 id="x"></h1><p id="x"></p>', "duplicate IDs"),
                               ('<base href="https://example.org/">', "<base>")):
            with self.subTest(html=html):
                write(self.site, "index.html", html)
                with self.assertRaisesRegex(ContractError, expected):
                    Site(self.site).validate_links()

    def test_published_symlinks_rejected(self) -> None:
        (self.site / "linked.html").symlink_to(self.site / "index.html")
        with self.assertRaisesRegex(ContractError, "symlink"):
            Site(self.site)

    def test_case_colliding_names_rejected(self) -> None:
        write(self.site, "INDEX.html", "duplicate portable name")
        with self.assertRaisesRegex(ContractError, "case-colliding"):
            Site(self.site)

    def test_relative_inventory_paths_are_canonical(self) -> None:
        for name in ("/x", "../x", "x/./y", "x//y", "C:/x", "x\\y", "x%2fy", "x#fragment", "x?query"):
            with self.subTest(name=name), self.assertRaises(ContractError):
                relative_path(name)

    def test_report_identity_checks_use_emitted_fields_not_new_calculations(self) -> None:
        target = {key: value for key, value in self.target.items() if key not in ("index", "project", "match")}
        target.update(kind="artifact", path="reports/diff.json",
                      jsonChecks={"/schemaVersion": "cjdoc.api-diff/1", "/baseline/version": "demo-v1"})
        self.feature["targets"] = [target]
        write(self.site, "reports/diff.json", {"schemaVersion": "cjdoc.api-diff/1",
                                               "baseline": {"version": "demo-v1"}})
        self.assertEqual(self.resolve()["features"][0]["targets"][0]["resolved"]["href"], "reports/diff.json")
        write(self.site, "reports/diff.json", {"schemaVersion": "cjdoc.api-diff/1",
                                               "baseline": {"version": "unrelated"}})
        with self.assertRaisesRegex(ContractError, "report identity mismatch"):
            self.resolve()

    def test_json_pointers_are_exact_including_escapes_and_arrays(self) -> None:
        self.assertEqual(json_pointer({"a/b": [{"~": 7}]}, "/a~1b/0/~0"), 7)
        for pointer in ("/a~1b/01", "/a~1b/-", "/missing", "/a~1b/5"):
            with self.subTest(pointer=pointer), self.assertRaises(ContractError):
                json_pointer({"a/b": [1]}, pointer)

    def test_card_html_escapes_author_content(self) -> None:
        self.feature["title"] = '<script>alert("x")</script>'
        self.target["instructions"] = '<img src=x onerror="alert(1)">'
        cards = render_cards(self.resolve())
        self.assertNotIn("<script>", cards)
        self.assertNotIn("<img ", cards)
        self.assertIn("&lt;script&gt;", cards)
        self.assertIn('data-feature-id="member"', cards)
        self.assertIn(self.page_name + "#add", cards)

    def test_homepage_requires_exactly_one_marker(self) -> None:
        manifest = self.resolve()
        marker = "<!-- CJDOC_SHOWCASE_FEATURES -->"
        self.assertIn('id="feature-member"', render_home("<main>" + marker + "</main>", manifest))
        for template in ("no marker", marker + marker):
            with self.subTest(template=template), self.assertRaises(ContractError):
                render_home(template, manifest)

    def test_evidence_exact_identity_and_both_transport_scenarios(self) -> None:
        manifest = self.resolve()
        validate_evidence(manifest, self.evidence(manifest), Site(self.site), self.evidence_root)

    def test_stale_evidence_cannot_pass_after_tree_mutation(self) -> None:
        manifest = self.resolve()
        evidence = self.evidence(manifest)
        write(self.site, "new-file.txt", "a file added after browser tests")
        with self.assertRaisesRegex(ContractError, "stale"):
            validate_evidence(manifest, evidence, Site(self.site), self.evidence_root)

    def test_tree_fingerprint_includes_paths_and_bytes(self) -> None:
        before = Site(self.site).digest()
        path = write(self.site, "a.txt", "bytes")
        added = Site(self.site).digest()
        path.rename(self.site / "b.txt")
        renamed = Site(self.site).digest()
        write(self.site, "b.txt", "other bytes")
        changed = Site(self.site).digest()
        self.assertEqual(len({before, added, renamed, changed}), 4)

    def test_revision_and_manifest_mismatch_rejected(self) -> None:
        manifest = self.resolve()
        for key in ("revision", "manifestSha256"):
            evidence = self.evidence(manifest)
            evidence[key] = "b" * 64
            with self.subTest(key=key), self.assertRaises(ContractError):
                validate_evidence(manifest, evidence, Site(self.site), self.evidence_root)

    def test_missing_or_skipped_scenarios_cannot_count_as_passed(self) -> None:
        manifest = self.resolve()
        for status in ("skipped", "failed", "timedOut"):
            evidence = self.evidence(manifest)
            evidence["results"][0]["status"] = status
            with self.subTest(status=status), self.assertRaisesRegex(ContractError, "did not pass"):
                validate_evidence(manifest, evidence, Site(self.site), self.evidence_root)
        evidence = self.evidence(manifest)
        evidence["results"].pop()
        with self.assertRaisesRegex(ContractError, "missing browser scenarios"):
            validate_evidence(manifest, evidence, Site(self.site), self.evidence_root)

    def test_duplicate_or_unexpected_results_rejected(self) -> None:
        manifest = self.resolve()
        evidence = self.evidence(manifest)
        evidence["results"].append(copy.deepcopy(evidence["results"][0]))
        with self.assertRaisesRegex(ContractError, "duplicate browser"):
            validate_evidence(manifest, evidence, Site(self.site), self.evidence_root)
        evidence = self.evidence(manifest)
        evidence["results"][0]["version"] = "demo-v1"
        with self.assertRaisesRegex(ContractError, "unexpected browser"):
            validate_evidence(manifest, evidence, Site(self.site), self.evidence_root)

    def test_wrong_entry_target_and_no_activation_rejected(self) -> None:
        manifest = self.resolve()
        for field, value in (("entry", self.page_name), ("href", "demo/index.html"),
                             ("activations", 0), ("activations", True), ("documentNavigations", -1),
                             ("assertions", [])):
            evidence = self.evidence(manifest)
            evidence["results"][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ContractError):
                validate_evidence(manifest, evidence, Site(self.site), self.evidence_root)

    def test_screenshot_hash_change_rejected(self) -> None:
        manifest = self.resolve()
        evidence = self.evidence(manifest)
        (self.evidence_root / "synthetic-screenshot.txt").write_text("changed", encoding="utf-8")
        with self.assertRaisesRegex(ContractError, "screenshot"):
            validate_evidence(manifest, evidence, Site(self.site), self.evidence_root)

    def test_evidence_inside_site_rejected(self) -> None:
        manifest = self.resolve()
        evidence = self.evidence(manifest)
        with self.assertRaisesRegex(ContractError, "separate trees"):
            validate_evidence(manifest, evidence, Site(self.site), self.site)

    def test_removing_or_downgrading_available_feature_is_a_regression(self) -> None:
        previous = self.resolve()
        for change in ("remove", "uncovered", "blocked"):
            current = copy.deepcopy(previous)
            if change == "remove":
                current["features"] = []
            else:
                current["features"][0]["demonstration"] = change
            with self.subTest(change=change), self.assertRaises(ContractError):
                check_regressions(previous, current)

    def test_removing_a_locale_or_file_scenario_is_a_regression(self) -> None:
        previous = self.resolve()
        current = copy.deepcopy(previous)
        current["features"][0]["targets"][0]["scenarios"].pop()
        with self.assertRaises(ContractError):
            check_regressions(previous, current)
        check_regressions(previous, previous)

    def test_regression_check_on_a_valid_rebuilt_manifest(self) -> None:
        previous = self.resolve()
        self.feature.update(demonstration="uncovered", targets=[])
        current = self.resolve()
        with self.assertRaisesRegex(ContractError, "availability regressed"):
            check_regressions(previous, current)

    def test_resolved_manifest_plan_tampering_rejected(self) -> None:
        manifest = self.resolve()
        manifest["features"][0]["title"] = "Silently changed after resolution"
        with self.assertRaisesRegex(ContractError, "author-plan digest"):
            render_cards(manifest)

    def test_source_input_order_has_a_canonical_plan_digest(self) -> None:
        write(self.repo, "examples/a.cj", "// second synthetic input")
        self.feature["inputs"].append("examples/a.cj")
        manifest = self.resolve()
        render_cards(manifest)
        self.feature["inputs"].reverse()
        self.assertEqual(manifest["planSha256"], self.resolve()["planSha256"])

    def test_unsafe_resolved_href_rejected_by_card_renderer(self) -> None:
        manifest = self.resolve()
        manifest["features"][0]["targets"][0]["resolved"]["href"] = "javascript:alert(1)"
        with self.assertRaisesRegex(ContractError, "local published path"):
            render_cards(manifest)

    def test_cli_resolve_fingerprint_and_verify(self) -> None:
        plan = write(self.root, "plan.json", self.plan)
        template = write(self.root, "home.html", '<html lang="en"><body>'
                         '<!-- CJDOC_SHOWCASE_FEATURES --></body></html>')
        command = [sys.executable, "-m", "showcase_contract"]
        environment = {**os.environ, "PYTHONPATH": str(ROOT / "scripts"), "PYTHONDONTWRITEBYTECODE": "1"}
        resolved = subprocess.run(command + ["resolve", "--plan", str(plan), "--site", str(self.site),
                                  "--repository", str(self.repo), "--revision", REVISION,
                                  "--template", str(template)], capture_output=True, text=True, env=environment)
        self.assertEqual(resolved.returncode, 0, resolved.stderr)
        manifest = load_json(self.site / "showcase-features.json")
        evidence = self.evidence(manifest)
        evidence_path = write(self.evidence_root, "results.json", evidence)
        checked = subprocess.run(command + ["verify", "--site", str(self.site), "--evidence", str(evidence_path)],
                                 capture_output=True, text=True, env=environment)
        self.assertEqual(checked.returncode, 0, checked.stderr)
        fingerprint = subprocess.run(command + ["fingerprint", "--site", str(self.site)],
                                     capture_output=True, text=True, env=environment)
        self.assertEqual(fingerprint.stdout.strip(), Site(self.site).digest())
        write(self.site, "unvalidated.txt", "after evidence")
        stale = subprocess.run(command + ["verify", "--site", str(self.site), "--evidence", str(evidence_path)],
                               capture_output=True, text=True, env=environment)
        self.assertEqual(stale.returncode, 1)
        self.assertIn("stale", stale.stderr)

    def test_cli_bad_plan_does_not_overwrite_homepage(self) -> None:
        before = (self.site / "index.html").read_bytes()
        self.target["match"]["title"] = "Missing"
        plan = write(self.root, "bad-plan.json", self.plan)
        template = write(self.root, "home.html", "<!-- CJDOC_SHOWCASE_FEATURES -->")
        result = subprocess.run([sys.executable, "-m", "showcase_contract", "resolve",
                                 "--plan", str(plan), "--site", str(self.site), "--repository", str(self.repo),
                                 "--revision", REVISION, "--template", str(template)], capture_output=True,
                                text=True, env={**os.environ, "PYTHONPATH": str(ROOT / "scripts")})
        self.assertEqual(result.returncode, 1)
        self.assertEqual((self.site / "index.html").read_bytes(), before)
        self.assertFalse((self.site / "showcase-features.json").exists())


if __name__ == "__main__":
    unittest.main()
