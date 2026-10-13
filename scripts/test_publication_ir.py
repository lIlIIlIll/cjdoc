from __future__ import annotations

import copy
import unittest

from publication_ir import project


def declaration(identity, visibility="public", owner=None, kind="function", **fields):
    return dict(id=identity, visibility=visibility, ownerId=owner, kind=kind, **fields)


class PublicationIrTests(unittest.TestCase):
    def test_visible_extension_members_survive_without_exposing_hidden_targets(self):
        declarations = [declaration("type", kind="class"), declaration("hidden", "private", kind="class")]
        for identity, target, state in (("extension", "type", "resolved"),
                                        ("hidden-extension", "hidden", "resolved"),
                                        ("unknown-extension", "type", "unavailable")):
            declarations += [declaration(identity, "internal", kind="extend", symbolRelationships=[
                dict(kind="extensionTarget", state=state, targetSymbolId=target)]),
                declaration(identity + "-member", owner=identity)]
        value = dict(configuration=dict(audience="external"), declarations=declarations,
                     packages=[dict(symbolIds=[item["id"] for item in declarations])], diagnostics=[], assets=[], pages=[])
        before = copy.deepcopy(value)
        self.assertEqual({item["id"] for item in project(value)["declarations"]},
                         {"type", "extension", "extension-member"})
        self.assertEqual(value, before)

    def test_public_children_of_private_owners_and_hidden_binding_metadata_are_removed(self):
        value = dict(configuration=dict(audience="external"), declarations=[
            declaration("visible"), declaration("hidden", "private"), declaration("child", owner="hidden")],
            packages=[], diagnostics=[], assets=[], pages=[dict(targetSymbolIds=["hidden"], bindings=[
                dict(target="HiddenGuideKeyword", selector="HiddenSelector", state="resolved", targetSymbolId="hidden")])])
        output = project(value)
        self.assertEqual([item["id"] for item in output["declarations"]], ["visible"])
        self.assertEqual(output["pages"][0]["targetSymbolIds"], [])
        self.assertEqual(output["pages"][0]["bindings"][0],
                         dict(target="", selector="", state="unavailable", targetSymbolId=None))
