"""Synthetic negative/unit cases for the native-route projection (not E2E)."""
from __future__ import annotations

import copy
import unittest

import test_contract
from test_contract import write
from showcase_contract import ContractError
from showcase_contract.contract import validate_plan
from showcase_contract.routes import MemberLinks


class NativeRouteTests(unittest.TestCase):
    def setUp(self):
        self.fixture = f = test_contract.ContractTests()
        f.setUp()
        self.addCleanup(f.doCleanups)
        f.page["href"] = "types/generated-route.html"
        f.index["pages"] = [f.page, {**f.page, "id": "owner-page", "symbolId": "owner-id",
                                   "title": "Bag", "href": "types/generated-owner.html"}]
        self.other = {**f.page, "id": "other-page", "symbolId": "other-id",
                      "href": "types/other-overload.html"}
        f.index["pages"].append(self.other)
        f.save_index()
        write(f.site, "demo/types/other-overload.html", '<html lang="en"><h1>Other overload</h1></html>')
        self.owner = "demo/types/generated-owner.html"
        self.anchor = "native-not-a-symbolid-hash"
        self.owner_html = ('<html lang="en"><details data-cjdoc-member id="' + self.anchor + '">'
                           '<summary>add</summary><details><summary>More</summary></details>'
                           '<a class="member-permalink" href="generated-route.html">Permalink</a>'
                           '</details></html>')
        write(f.site, self.owner, self.owner_html)
        self.declaration = {"id": f.page["symbolId"], "ownerId": "owner-id", "name": "add",
                            "qualifiedName": "Bag.add", "packageName": "demo.collections",
                            "moduleId": "demo-module", "headerSpelling": "public func add(value: Int64): Unit"}
        self.ir = {"schemaVersion": "cjdoc.doc-ir/10", "project": {"name": "synthetic_showcase"},
                   "generator": {"name": "cjdoc"}, "configuration": {"audience": "external"},
                   "declarations": [self.declaration, {**self.declaration, "id": "other-id",
                         "headerSpelling": "public func add(value: String): Unit"}]}
        self.ir_path = "artifacts/docs.json"
        f.target.update(docIr=self.ir_path, signature=self.declaration["headerSpelling"], placement="member")
        self.save_ir()

    def save_ir(self):
        write(self.fixture.site, self.ir_path, self.ir)

    def resolved(self):
        return self.fixture.resolve()["features"][0]["targets"][0]["resolved"]

    def test_reads_native_anchor_without_hashing(self):
        result = self.resolved()
        self.assertEqual(result["href"], self.owner + "#" + self.anchor)
        self.assertEqual(result["symbolId"], self.declaration["id"])
        self.assertEqual(result["memberPageHref"], self.fixture.page_name)
        self.assertEqual(result["semanticState"], "partial")

    def test_same_title_overloads_join_by_full_signature_and_id(self):
        self.fixture.target["signature"] = "public func add(value: String): Unit"
        self.fixture.target["placement"] = "page"
        self.assertEqual(self.resolved()["symbolId"], "other-id")

    def test_missing_signature_does_not_pick_first_overload(self):
        del self.fixture.target["signature"]
        with self.assertRaisesRegex(ContractError, "exactly one declaration"):
            self.resolved()

    def test_changed_full_signature_fails(self):
        self.fixture.target["signature"] = "public func add(value: Int64, copy!: Bool = true): Unit"
        with self.assertRaisesRegex(ContractError, "exactly one declaration"):
            self.resolved()

    def test_scope_is_not_replaced_by_signature(self):
        self.declaration["packageName"] = "different.package"
        self.save_ir()
        with self.assertRaisesRegex(ContractError, "exactly one declaration"):
            self.resolved()

    def test_duplicate_declaration_identity_fails(self):
        self.ir["declarations"].append(copy.deepcopy(self.declaration))
        self.save_ir()
        with self.assertRaisesRegex(ContractError, "duplicate"):
            self.resolved()

    def test_wrong_ir_schema_fails(self):
        self.ir["schemaVersion"] = "cjdoc.doc-ir/9"
        self.save_ir()
        with self.assertRaisesRegex(ContractError, "doc-ir/10"):
            self.resolved()

    def test_wrong_ir_project_fails(self):
        self.ir["project"]["name"] = "other"
        self.save_ir()
        with self.assertRaisesRegex(ContractError, "project or audience"):
            self.resolved()

    def test_wrong_ir_audience_fails(self):
        self.ir["configuration"]["audience"] = "all"
        self.save_ir()
        with self.assertRaisesRegex(ContractError, "project or audience"):
            self.resolved()

    def test_wrong_generator_fails(self):
        self.ir["generator"]["name"] = "handwritten-demo"
        self.save_ir()
        with self.assertRaisesRegex(ContractError, "project or audience"):
            self.resolved()

    def test_missing_navigation_identity_fails(self):
        self.fixture.page["symbolId"] = "unrelated"
        self.fixture.save_index()
        with self.assertRaisesRegex(ContractError, "join exactly one"):
            self.resolved()

    def test_duplicate_navigation_identity_fails(self):
        self.fixture.index["pages"].append(copy.deepcopy(self.fixture.page))
        self.fixture.save_index()
        with self.assertRaisesRegex(ContractError, "join exactly one"):
            self.resolved()

    def test_missing_owner_does_not_infer_by_qualified_name(self):
        self.declaration["ownerId"] = None
        self.save_ir()
        with self.assertRaisesRegex(ContractError, "ownerId"):
            self.resolved()

    def test_unavailable_owner_page_fails(self):
        self.declaration["ownerId"] = "no-page"
        self.save_ir()
        with self.assertRaisesRegex(ContractError, "emitted owner page"):
            self.resolved()

    def test_owner_locale_is_checked(self):
        write(self.fixture.site, self.owner, self.owner_html.replace('lang="en"', 'lang="zh-CN"'))
        with self.assertRaisesRegex(ContractError, "language"):
            self.resolved()

    def test_nonmember_link_cannot_supply_inline_anchor(self):
        write(self.fixture.site, self.owner, '<html lang="en"><a class="member-permalink" '
                                           'href="generated-route.html">X</a></html>')
        with self.assertRaisesRegex(ContractError, "enclosing native anchor"):
            self.resolved()

    def test_wrong_overload_permalink_is_not_selected_by_name(self):
        write(self.fixture.site, self.owner, self.owner_html.replace("generated-route.html", "other-overload.html"))
        with self.assertRaisesRegex(ContractError, "native permalink"):
            self.resolved()

    def test_duplicate_member_permalinks_fail(self):
        write(self.fixture.site, self.owner, self.owner_html + self.owner_html)
        with self.assertRaisesRegex(ContractError, "native permalink"):
            self.resolved()

    def test_unclosed_details_are_rejected(self):
        with self.assertRaisesRegex(ContractError, "unclosed"):
            MemberLinks('<details id="x" data-cjdoc-member><summary>X</summary>')

    def test_signature_requires_docir(self):
        del self.fixture.target["docIr"]
        with self.assertRaisesRegex(ContractError, "require scoped symbols and docIr"):
            validate_plan(self.fixture.plan)

    def test_invalid_placement_is_rejected(self):
        self.fixture.target["placement"] = "first-match"
        with self.assertRaisesRegex(ContractError, "placement"):
            validate_plan(self.fixture.plan)
