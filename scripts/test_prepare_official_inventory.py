#!/usr/bin/env python3
"""Offline public-behavior tests for pinned official inventory preparation."""
from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from html.parser import HTMLParser

SCRIPT = Path(__file__).with_name("prepare_official_inventory.py")
FIXTURE = SCRIPT.parent.parent / "tests/fixtures/external_docs/official83"
SPEC = importlib.util.spec_from_file_location("official_inventory", SCRIPT)
adapter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(adapter)


class Anchors(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = []
        self.scripts = 0

    def handle_starttag(self, tag, attrs):
        if tag == "script":
            self.scripts += 1
        self.ids.extend(value for key, value in attrs if key == "id")


class OfficialInventoryTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="official-inventory-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bundle = self.root / "bundle"
        shutil.copytree(FIXTURE, self.bundle)
        self.manifest = self.bundle / "manifest.json"
        self.output = self.root / "inventory.json"
        self.original = json.loads(self.manifest.read_text(encoding="utf-8"))

    def save(self, value):
        self.manifest.write_text(json.dumps(value), encoding="utf-8")

    def prepare(self, **kwargs):
        return adapter.prepare(self.manifest, self.bundle, self.output, **kwargs)

    def bundle_with_ancestor_alias(self):
        parent = self.root / "real"
        nested = parent / "nested"
        nested.mkdir(parents=True)
        shutil.copytree(self.bundle, nested / "bundle")
        alias = self.root / "ancestor-alias"
        alias.symlink_to(parent.resolve(), target_is_directory=True)
        return alias / "nested" / "bundle"

    def reject(self, mutate, message):
        self.prepare()
        previous = self.output.read_bytes()
        value = copy.deepcopy(self.original)
        mutate(value)
        self.save(value)
        with self.assertRaisesRegex(adapter.InventoryError, message):
            self.prepare()
        self.assertEqual(self.output.read_bytes(), previous)
        self.assertFalse(list(self.root.glob(".official-*")))

    def test_real_pinned_std_and_stdx_types_and_members_offline(self):
        with mock.patch.object(adapter, "fetch_source", side_effect=AssertionError("offline must not fetch")):
            result = self.prepare()
        self.assertEqual(result["schemaVersion"], "cjdoc.symbol-index/2")
        self.assertEqual(len(result["entries"]), 4)
        self.assertEqual({d["library"] for d in result["documentSets"]}, {"std", "stdx"})
        by_key = {entry["symbolKey"]: entry for entry in result["entries"]}
        self.assertIn("std.collection.ArrayDeque|class|1()", by_key)
        self.assertIn("std.collection.ArrayDeque.capacity|property|0()", by_key)
        member = by_key["stdx.encoding.json.JsonArray.add|function|0(JsonValue)"]
        owner = by_key["stdx.encoding.json.JsonArray|class|0()"]
        self.assertEqual(member["ownerId"], owner["id"])
        self.assertTrue(member["href"].endswith("?plain=1#L55"))
        self.assertTrue(all(".md?plain=1#L" in entry["href"] for entry in result["entries"]))
        self.assertEqual({d["state"] for d in result["documentSets"]}, {"declared"})
        self.assertEqual({d["target"] for d in result["documentSets"]}, {""})
        self.assertEqual({d["cfg"] for d in result["documentSets"]}, {""})
        self.assertEqual({d["apiVersion"] for d in result["documentSets"]}, {""})
        self.assertEqual({d["revision"] for d in result["documentSets"]}, {""})
        self.assertEqual({d["documentationRevision"] for d in result["documentSets"]},
                         {source["revision"] for source in self.original["sources"]})
        self.assertTrue(all(p["sdkMapping"] == "none" for p in result["provenance"]))
        self.assertTrue(all(entry["semanticState"] == "partial" for entry in result["entries"]))
        documents = {d["id"]: d for d in result["documentSets"]}
        for entry in result["entries"]:
            self.assertEqual(entry["identity"], documents[entry["documentSetId"]]["identity"])

    def test_local_category_pages_have_every_type_and_member_anchor(self):
        pages = self.root / "official-pages"
        result = self.prepare(html_output=pages)
        for entry in result["entries"]:
            filename, fragment = entry["href"].split("#")
            parser = Anchors()
            content = (pages / filename).read_text(encoding="utf-8")
            parser.feed(content)
            self.assertEqual(parser.ids.count(fragment), 1)
            self.assertEqual(parser.scripts, 0)
            self.assertIn("Pinned upstream source", content)
            self.assertIn("CC-BY-4.0", content)
            self.assertIn("not an SDK compatibility claim", content)
        self.assertTrue(all(d["baseUrl"] == "./official-pages" for d in result["documentSets"]))

    def test_bundle_ancestor_alias_preserves_inventory_pages_and_anchors(self):
        pages = self.root / "official-pages"
        expected = self.prepare(html_output=pages)
        inventory = self.output.read_bytes()
        old_pages = {page.name: page.read_bytes() for page in pages.glob("*.html")}
        bundle = self.bundle_with_ancestor_alias()
        result = adapter.prepare(bundle / "manifest.json", bundle, self.output, html_output=pages)
        self.assertEqual(result, expected)
        self.assertEqual(self.output.read_bytes(), inventory)
        self.assertEqual({page.name: page.read_bytes() for page in pages.glob("*.html")}, old_pages)
        for entry in result["entries"]:
            filename, fragment = entry["href"].split("#")
            parser = Anchors()
            parser.feed((pages / filename).read_text(encoding="utf-8"))
            self.assertEqual(parser.ids.count(fragment), 1)

    def test_verified_system_output_alias_preserves_publication_and_anchors(self):
        canonical = self.root.resolve() / "system-location"
        workspace = canonical / "workspace"
        workspace.mkdir(parents=True)
        alias = self.root.resolve() / "system-alias"
        alias.symlink_to(canonical, target_is_directory=True)
        output = alias / "workspace" / "inventory.json"
        pages = alias / "workspace" / "official-pages"
        outside = self.root.resolve() / "outside-system-location"
        (outside / "nested").mkdir(parents=True)
        victim = outside / "nested" / "inventory.json"
        victim.write_bytes(b"previous inventory")
        (workspace / "user-link").symlink_to(outside, target_is_directory=True)
        with mock.patch.object(adapter.safe_output_root.sys, "platform", "darwin"), \
                mock.patch.object(adapter.safe_output_root, "_DARWIN_SYSTEM_ALIASES", {alias: canonical}):
            result = adapter.prepare(self.manifest, self.bundle, output, html_output=pages)
            with self.assertRaisesRegex(adapter.InventoryError, "symlink output parent"):
                adapter.prepare(self.manifest, self.bundle,
                                alias / "workspace" / "user-link" / "nested" / "inventory.json")
        self.assertEqual(victim.read_bytes(), b"previous inventory")
        self.assertEqual(json.loads((workspace / "inventory.json").read_bytes()), result)
        for entry in result["entries"]:
            filename, fragment = entry["href"].split("#")
            parser = Anchors()
            parser.feed((workspace / "official-pages" / filename).read_text(encoding="utf-8"))
            self.assertEqual(parser.ids.count(fragment), 1)

    def test_deterministic_reordering(self):
        self.prepare()
        first = self.output.read_bytes()
        value = copy.deepcopy(self.original)
        value["sources"].reverse()
        # Source ordering is not identity-bearing; per-source entry ordering is.
        self.save(value)
        self.prepare()
        self.assertEqual(first, self.output.read_bytes())

    def test_duplicate_json_keys_preserve_previous_snapshot(self):
        self.prepare()
        previous = self.output.read_bytes()
        self.manifest.write_text('{"schemaVersion":"cjdoc.official-source/1","sources":[],"sources":[]}', encoding="utf-8")
        with self.assertRaisesRegex(adapter.InventoryError, "duplicate JSON key"):
            self.prepare()
        self.assertEqual(previous, self.output.read_bytes())

    def test_unsafe_urls_and_unpinned_revisions(self):
        for field, value in [("sourceUri", "http://192.0.2.1/source"),
                             ("sourceUri", "https://user:password@raw.githubusercontent.com/source"),
                             ("sourceUri", "file:///etc/passwd"),
                             ("targetUri", "javascript:alert(1)"),
                             ("revision", "main")]:
            with self.subTest(field=field, value=value):
                self.reject(lambda m: m["sources"][0].__setitem__(field, value), "unsafe|immutable")
                self.save(self.original)

    def test_unsafe_bundle_paths(self):
        for path in ["../outside.md", "/outside.md", "nested/../../outside.md", "a\\b.md", "a//b.md",
                     "nested/../std-collection.md", "a/./b.md", "C:/outside.md", "a:b.md"]:
            with self.subTest(path=path):
                self.reject(lambda m: m["sources"][0].__setitem__("path", path), "unsafe")
                self.save(self.original)

    def test_symlink_source_rejected(self):
        original = self.bundle / "std-collection.md"
        outside = self.root / "outside.md"
        original.rename(outside)
        try:
            original.symlink_to(outside)
        except OSError as error:
            self.skipTest(str(error))
        with self.assertRaisesRegex(adapter.InventoryError, "symlink"):
            self.prepare()

    def test_internal_leaf_and_parent_links_preserve_inventory_and_pages(self):
        pages = self.root / "official-pages"
        self.prepare(html_output=pages)
        previous = self.output.read_bytes()
        old_pages = {page.name: page.read_bytes() for page in pages.glob("*.html")}
        for kind in ("leaf", "parent"):
            for destination in ("inside", "outside"):
                with self.subTest(kind=kind, destination=destination):
                    label = kind + "-" + destination
                    bundle = self.root / label
                    shutil.copytree(self.bundle, bundle)
                    value = copy.deepcopy(self.original)
                    source = bundle / value["sources"][0]["path"]
                    content = (bundle if destination == "inside" else self.root / (label + "-outside")) / "content"
                    content.mkdir(parents=True)
                    target = content / source.name
                    source.rename(target)
                    if kind == "leaf":
                        source.symlink_to(target.resolve())
                    else:
                        (bundle / "linked").symlink_to(content.resolve(), target_is_directory=True)
                        value["sources"][0]["path"] = "linked/" + source.name
                    manifest = bundle / "manifest.json"
                    manifest.write_text(json.dumps(value), encoding="utf-8")
                    with self.assertRaisesRegex(adapter.InventoryError, "symlink"):
                        adapter.prepare(manifest, bundle, self.output, html_output=pages)
                    self.assertEqual(self.output.read_bytes(), previous)
                    self.assertEqual({page.name: page.read_bytes() for page in pages.glob("*.html")}, old_pages)
                    self.assertFalse(list(self.root.rglob(".official-*")))

    def test_bundle_root_link_remains_rejected(self):
        self.prepare()
        previous = self.output.read_bytes()
        alias = self.root / "bundle-root-alias"
        alias.symlink_to(self.bundle.resolve(), target_is_directory=True)
        with self.assertRaisesRegex(adapter.InventoryError, "symlink"):
            adapter.prepare(self.manifest, alias, self.output)
        self.assertEqual(self.output.read_bytes(), previous)

    def test_output_leaf_link_preserves_target(self):
        self.prepare()
        victim = self.root / "previous-inventory.json"
        self.output.rename(victim)
        previous = victim.read_bytes()
        self.output.symlink_to(victim.resolve())
        with self.assertRaisesRegex(adapter.InventoryError, "symlink output"):
            self.prepare()
        self.assertEqual(victim.read_bytes(), previous)
        self.assertTrue(self.output.is_symlink())

    def test_non_system_output_ancestor_link_preserves_target(self):
        directory = self.root / "output-location"
        (directory / "nested").mkdir(parents=True)
        alias = self.root / "output-alias"
        alias.symlink_to(directory.resolve(), target_is_directory=True)
        victim = directory / "nested" / "inventory.json"
        victim.write_bytes(b"previous inventory")
        with self.assertRaisesRegex(adapter.InventoryError, "symlink output parent"):
            adapter.prepare(self.manifest, self.bundle, alias / "nested" / "inventory.json")
        self.assertEqual(victim.read_bytes(), b"previous inventory")
        self.assertFalse(list(directory.rglob(".official-*")))

    def test_html_directory_link_preserves_inventory_and_pages(self):
        pages = self.root / "official-pages"
        self.prepare(html_output=pages)
        previous = self.output.read_bytes()
        victim = self.root / "previous-pages"
        pages.rename(victim)
        old_pages = {page.name: page.read_bytes() for page in victim.glob("*.html")}
        pages.symlink_to(victim.resolve(), target_is_directory=True)
        with self.assertRaisesRegex(adapter.InventoryError, "symlink HTML output"):
            self.prepare(html_output=pages)
        self.assertEqual(self.output.read_bytes(), previous)
        self.assertEqual({page.name: page.read_bytes() for page in victim.glob("*.html")}, old_pages)

    def test_corrupted_excerpt_and_invented_anchor_rejected(self):
        self.reject(lambda m: m["sources"][0]["excerpt"].__setitem__("sha256", "0" * 64), "digest mismatch")
        self.save(self.original)
        self.reject(lambda m: m["sources"][0]["entries"][0].__setitem__("line", 4), "heading not present")
        self.save(self.original)
        self.reject(lambda m: m["sources"][1]["entries"][1].__setitem__("declaration", "public func add(x: String): Unit"), "declaration not present")

    def test_duplicate_symbol_and_source_ids_rejected(self):
        self.reject(lambda m: m["sources"][0]["entries"].append(copy.deepcopy(m["sources"][0]["entries"][0])), "duplicate symbol")
        self.save(self.original)
        self.reject(lambda m: m["sources"].append(copy.deepcopy(m["sources"][0])), "duplicate source id")

    def test_entry_and_byte_limits_preserve_snapshot(self):
        self.prepare()
        previous = self.output.read_bytes()
        with mock.patch.object(adapter, "MAX_ENTRIES", 1):
            with self.assertRaisesRegex(adapter.InventoryError, "entry count"):
                self.prepare()
        with mock.patch.object(adapter, "MAX_SOURCE_BYTES", 32):
            with self.assertRaisesRegex(adapter.InventoryError, "byte limit"):
                self.prepare()
        with mock.patch.object(adapter, "MAX_MANIFEST_BYTES", 32):
            with self.assertRaisesRegex(adapter.InventoryError, "byte limit"):
                self.prepare()
        self.assertEqual(previous, self.output.read_bytes())

    def test_explicit_download_checks_full_digest_before_publication(self):
        self.prepare()
        previous = self.output.read_bytes()
        with mock.patch.object(adapter, "fetch_source", return_value=b"untrusted") as fetch:
            with self.assertRaisesRegex(adapter.InventoryError, "upstream source digest mismatch"):
                self.prepare(download=True)
        fetch.assert_called_once()
        self.assertEqual(previous, self.output.read_bytes())

    def test_explicit_download_success_uses_both_source_and_excerpt_digests(self):
        value = copy.deepcopy(self.original)
        sources = {}
        for source in value["sources"]:
            content = (self.bundle / source["path"]).read_bytes()
            source["sha256"] = adapter.digest(content)
            sources[source["sourceUri"]] = content
        self.save(value)
        with mock.patch.object(adapter, "fetch_source", side_effect=lambda url: sources[url]) as fetch:
            result = self.prepare(download=True)
        self.assertEqual(fetch.call_count, 2)
        self.assertEqual(len(result["entries"]), 4)

    def test_redirect_is_fail_closed(self):
        with self.assertRaisesRegex(adapter.InventoryError, "redirects are forbidden"):
            adapter.NoRedirect().redirect_request(None, None, 302, "Found", {}, "https://example.test/")

    def test_atomic_publish_failure_preserves_previous_inventory(self):
        self.prepare()
        previous = self.output.read_bytes()
        with mock.patch.object(adapter.os, "replace", side_effect=OSError("publish failed")):
            with self.assertRaises(OSError):
                self.prepare()
        self.assertEqual(previous, self.output.read_bytes())
        self.assertFalse(list(self.root.glob(".official-*")))

    def test_false_package_owner_and_signature_rejected(self):
        self.reject(lambda m: m["sources"][0]["entries"][0].__setitem__("packageName", "std.unproven"), "package mapping")
        self.save(self.original)
        self.reject(lambda m: m["sources"][1]["entries"][1].__setitem__("parameterTypes", ["String"]), "parameter evidence")
        self.save(self.original)
        self.reject(lambda m: m["sources"][0]["entries"].pop(0), "owner missing")

    def test_untrusted_source_markup_is_escaped_in_local_pages(self):
        value = copy.deepcopy(self.original)
        source = value["sources"][0]
        location = self.bundle / source["path"]
        data = location.read_bytes() + b'<script>alert("unsafe")</script>\n'
        location.write_bytes(data)
        source["excerpt"]["endLine"] += 1
        source["excerpt"]["sha256"] = adapter.digest(data)
        self.save(value)
        pages = self.root / "official-pages"
        self.prepare(html_output=pages)
        for page in pages.glob("*.html"):
            content = page.read_text(encoding="utf-8")
            self.assertNotIn("<script>", content)
        self.assertTrue(any("&lt;script&gt;" in page.read_text(encoding="utf-8") for page in pages.glob("*.html")))

    def test_page_update_failure_preserves_previous_inventory_and_anchors(self):
        pages = self.root / "official-pages"
        self.prepare(html_output=pages)
        previous = self.output.read_bytes()
        old_pages = {page: page.read_bytes() for page in pages.glob("*.html")}
        value = copy.deepcopy(self.original)
        value["sources"][0]["entries"].pop()
        self.save(value)
        replace = adapter.os.replace

        def fail_inventory(source, destination):
            if Path(destination).resolve() == self.output.resolve():
                raise OSError("inventory publication failed")
            return replace(source, destination)

        with mock.patch.object(adapter.os, "replace", side_effect=fail_inventory):
            with self.assertRaises(OSError):
                self.prepare(html_output=pages)
        self.assertEqual(previous, self.output.read_bytes())
        self.assertTrue(all(page.read_bytes() == data for page, data in old_pages.items()))

    def test_cli_offline_and_sanitized_failure(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--manifest", str(self.manifest),
                                 "--bundle", str(self.bundle), "--output", str(self.output)],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        missing = self.root / "private-local-name" / "missing.json"
        result = subprocess.run([sys.executable, str(SCRIPT), "--manifest", str(missing),
                                 "--bundle", str(self.bundle), "--output", str(self.output)],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn(str(self.root), result.stderr)

    def test_cli_accepts_bundle_ancestor_alias_with_real_local_pages(self):
        bundle = self.bundle_with_ancestor_alias()
        pages = self.root / "official-pages"
        result = subprocess.run([sys.executable, str(SCRIPT), "--manifest", str(bundle / "manifest.json"),
                                 "--bundle", str(bundle), "--output", str(self.output),
                                 "--html-output", str(pages)], capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        inventory = json.loads(self.output.read_bytes())
        self.assertEqual(len(inventory["entries"]), 4)
        self.assertEqual(len(inventory["documentSets"]), 2)
        for entry in inventory["entries"]:
            filename, fragment = entry["href"].split("#")
            parser = Anchors()
            parser.feed((pages / filename).read_text(encoding="utf-8"))
            self.assertEqual(parser.ids.count(fragment), 1)


if __name__ == "__main__":
    unittest.main()
