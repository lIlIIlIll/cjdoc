from __future__ import annotations

import copy
import unittest

from publication_ir import project


def declaration(identity, visibility="public", owner=None, kind="function", **fields):
    return dict(id=identity, visibility=visibility, ownerId=owner, kind=kind, **fields)


def reference_document():
    texts, tags = [], []
    for kind in ("see", "throws"):
        for target, subject in (("hidden:first", "First"), ("hidden:second", "Second"), ("public-target", "Public")):
            identity = "owner:doc:" + kind + ":" + target
            state, bound = ("resolved", target) if target == "public-target" else ("unavailable", None)
            for language in ("en", "zh-CN"):
                texts.append(dict(kind=kind, subject=subject, language=language, text=subject,
                    fieldId=identity, state="valid", referenceState=state, targetSymbolId=bound))
            tags.append(dict(name=kind, subject=subject, description=subject, contentLanguage="en",
                fieldId=identity, referenceState=state, targetSymbolId=bound))
    return dict(configuration=dict(audience="external"), declarations=[
        declaration("owner", documentation=dict(localizedTexts=texts, tags=tags)),
        declaration("hidden:first", "private"), declaration("hidden:second", "private"),
        declaration("public-target")], packages=[], diagnostics=[], assets=[], pages=[])


class PublicationIrTests(unittest.TestCase):
    def test_macro_origins_only_retain_visible_symbol_ids(self):
        for macro_visibility in ("private", "internal", "public"):
            for audience in ("external", "package", "all"):
                with self.subTest(macro_visibility=macro_visibility, audience=audience):
                    value = dict(configuration=dict(audience=audience), declarations=[
                        declaration("macro-target", macro_visibility, kind="macro"),
                        declaration("generated", origin=dict(kind="macro", macroSymbolId="macro-target")),
                        declaration("ordinary", origin=dict(kind="source", macroSymbolId=None))],
                        packages=[dict(symbolIds=["macro-target", "generated", "ordinary"])],
                        diagnostics=[], assets=[], pages=[])
                    before = copy.deepcopy(value)
                    output = project(value)
                    self.assertEqual(value, before)
                    self.assertEqual(project(output), output)
                    kept = {item["id"] for item in output["declarations"]}
                    origin = next(item for item in output["declarations"] if item["id"] == "generated")["origin"]
                    self.assertEqual(origin, dict(kind="macro",
                        macroSymbolId="macro-target" if "macro-target" in kept else None))
                    ordinary = next(item for item in output["declarations"] if item["id"] == "ordinary")
                    self.assertEqual(ordinary["origin"], before["declarations"][2]["origin"])
                    if "macro-target" not in kept:
                        self.assertNotIn("macro-target", repr(output))

    def test_internal_reference_identity_is_censored_only_for_external_audience(self):
        value = reference_document()
        identity = "owner:doc:see:internal-target"
        value["declarations"].append(declaration("internal-target", "internal"))
        comment = value["declarations"][0]["documentation"]
        comment["localizedTexts"].append(dict(kind="see", subject="Internal", language="en",
            fieldId=identity, text="Internal author text", state="valid",
            referenceState="resolved", targetSymbolId="internal-target"))
        for audience in ("external", "package", "all"):
            with self.subTest(audience=audience):
                value["configuration"]["audience"] = audience
                before = copy.deepcopy(value)
                output = project(value)
                field = output["declarations"][0]["documentation"]["localizedTexts"][-1]
                self.assertEqual(value, before)
                self.assertEqual(field["fieldId"] == identity, audience != "external")
                self.assertEqual(field["targetSymbolId"], None if audience == "external" else "internal-target")
                self.assertEqual(field["referenceState"], "unavailable" if audience == "external" else "resolved")
                self.assertEqual(field["text"], "Internal author text")

    def test_hidden_reference_field_ids_preserve_grouping_and_projected_tags(self):
        value = reference_document()
        before = copy.deepcopy(value)
        output = project(value)
        self.assertEqual(value, before)
        self.assertEqual(project(output), output)
        for hidden in ("hidden:first", "hidden:second"):
            self.assertNotIn(hidden, repr(output))
        comment = output["declarations"][0]["documentation"]
        for kind in ("see", "throws"):
            identities = set()
            for subject in ("First", "Second", "Public"):
                fields = [field for field in comment["localizedTexts"]
                          if field["kind"] == kind and field["subject"] == subject]
                self.assertEqual({field["language"] for field in fields}, {"en", "zh-CN"})
                identity = fields[0]["fieldId"]
                self.assertEqual({field["fieldId"] for field in fields}, {identity})
                self.assertTrue(identity.startswith("owner:doc:" + kind + ":"))
                tag = next(tag for tag in comment["tags"] if tag["name"] == kind and tag["subject"] == subject)
                self.assertEqual(tag["fieldId"], identity)
                self.assertNotIn(identity, identities)
                identities.add(identity)
                for field in fields:
                    original = next(item for item in before["declarations"][0]["documentation"]["localizedTexts"]
                                    if (item["kind"], item["subject"], item["language"]) ==
                                    (field["kind"], field["subject"], field["language"]))
                    self.assertEqual({key: item for key, item in field.items() if key != "fieldId"},
                                     {key: item for key, item in original.items() if key != "fieldId"})
                if subject == "Public":
                    self.assertEqual(identity, "owner:doc:" + kind + ":public-target")
            self.assertEqual(len(identities), 3)
        value["configuration"]["audience"] = "all"
        self.assertEqual(project(value), value)

    def test_hidden_field_redaction_avoids_existing_ids_and_is_order_independent(self):
        value = reference_document()
        preferred = next(field["fieldId"] for field in project(value)["declarations"][0]["documentation"]["localizedTexts"]
                         if field["kind"] == "see" and field["subject"] == "First")
        comment = value["declarations"][0]["documentation"]
        for language in ("en", "zh-CN"):
            comment["localizedTexts"].append(dict(kind="see", subject="Existing", language=language,
                fieldId=preferred, text="Existing opaque field", state="valid", referenceState="unavailable", targetSymbolId=None))
        output = project(value)
        fields = output["declarations"][0]["documentation"]["localizedTexts"]
        hidden = next(field["fieldId"] for field in fields if field["kind"] == "see" and field["subject"] == "First")
        self.assertNotEqual(hidden, preferred)
        self.assertEqual({field["fieldId"] for field in fields if field["subject"] == "Existing"}, {preferred})
        reversed_value = copy.deepcopy(value)
        reversed_value["declarations"].reverse()
        for declaration in reversed_value["declarations"]:
            if declaration.get("documentation"):
                for name in ("localizedTexts", "tags"):
                    declaration["documentation"][name].reverse()
        reversed_output = project(reversed_value)
        reversed_fields = next(item for item in reversed_output["declarations"] if item["id"] == "owner")["documentation"]["localizedTexts"]
        self.assertEqual({(field["kind"], field["subject"], field["language"]): field["fieldId"] for field in fields},
                         {(field["kind"], field["subject"], field["language"]): field["fieldId"] for field in reversed_fields})

    def test_unbound_author_text_requires_the_all_audience(self):
        value = dict(configuration=dict(audience="external"), declarations=[declaration("visible")],
                     packages=[], diagnostics=[dict(code="CJDOC1009", severity="warning", symbolId=None,
                         message="PrivateMacroAuthorMarker")], assets=[], pages=[],
                     orphanDocComments=[dict(rawText="OrphanAuthorOnlyMarker")],
                     unsupportedDeclarations=[dict(name="PrivateConditionalMarker")],
                     macroInvocations=[dict(name="PrivateMacroAuthorMarker")],
                     unboundSemanticDeclarations=[dict(display="HiddenUnboundAuthorMarker")])
        for audience in ("external", "package", "all"):
            with self.subTest(audience=audience):
                value["configuration"]["audience"] = audience
                output = project(value)
                for field in ("orphanDocComments", "unsupportedDeclarations", "macroInvocations", "unboundSemanticDeclarations"):
                    self.assertEqual(output[field], value[field] if audience == "all" else [])
                self.assertEqual(output["diagnostics"][0]["code"], "CJDOC1009")
                self.assertEqual(output["diagnostics"][0]["message"] == "PrivateMacroAuthorMarker", audience == "all")
        self.assertEqual(value["orphanDocComments"][0]["rawText"], "OrphanAuthorOnlyMarker")

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
