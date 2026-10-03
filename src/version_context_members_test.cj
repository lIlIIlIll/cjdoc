package cjdoc

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class VersionContextMemberTest {
    @TestCase
    func contextMembershipBudgetRejectsExpansionButDoesNotChargeDuplicates(): Unit {
        let index = VersionSymbolIndex(limit: 2)
        index.add("owner", "symbols/owner.html", kind: "class")
        index.add("extension", "symbols/extension.html", kind: "extend")
        index.add("extra", "symbols/extra.html", owner: Some("extension"))
        index.addContextRelation("owner", "extendedBy", "resolved", "extension")
        index.addContextRelation("owner", "extendedBy", "resolved", "extension")
        index.resolveContextMembers()
        index.resolveContextMembers()
        @Expect(index.membersByOwner["owner"].size, 1)
        @Expect(index.membersByOwner["extension"].size, 1)
        index.add("another", "symbols/another.html")
        index.addContextRelation("owner", "inheritedMember", "resolved", "another")
        @ExpectThrows[IllegalArgumentException](index.resolveContextMembers())
        @Expect(index.membersByOwner["owner"].size, 1)
        @ExpectThrows[IllegalArgumentException](VersionSymbolIndex(limit: 0))
    }

    @TestCase
    func versionSelectorsMapDeclaredExtendedAndInheritedInlineMembers(): Unit {
        let source = """
{"schemaVersion":"cjdoc.symbol-index/1","entries":[
 {"id":"box","href":"symbols/box.html","kind":"class","relations":[
  {"kind":"extendedBy","state":"resolved","targetId":"extension"},
  {"kind":"inheritedMember","state":"resolved","targetId":"inherited"},
  {"kind":"inherits-member","state":"resolved","targetId":"inherited"}]},
 {"id":"direct","href":"symbols/direct.html","kind":"function","ownerId":"box"},
 {"id":"extra","href":"symbols/extra.html","kind":"function","ownerId":"extension"},
 {"id":"inherited","href":"symbols/inherited.html","kind":"function","ownerId":"base"},
 {"id":"extension","href":"symbols/extension.html","kind":"extend"},
 {"id":"base","href":"symbols/base.html","kind":"class"}
]}
"""
        let currentIndex = loadVersionSymbols(ArrayList<VersionSourceFile>([
            VersionSourceFile("symbol-index.json", "application/json", source.toArray())]))
        let members = currentIndex.membersByOwner["box"]
        @Expect(members.size, 3)
        @Expect(currentIndex.ownerById["extra"], "extension")
        @Expect(currentIndex.ownerById["inherited"], "base")
        let targetIndex = VersionSymbolIndex()
        targetIndex.add("box", "symbols/old-box.html")
        targetIndex.add("direct", "symbols/old-direct.html")
        targetIndex.add("extra", "symbols/old-extra.html")
        targetIndex.add("inherited", "symbols/old-inherited.html")
        let current = VersionSite(VersionComposeSpec("new", "unused"), currentIndex)
        let target = VersionSite(VersionComposeSpec("old", "unused"), targetIndex)
        let selector = versionSelector(current, "new/symbols/box.html", "symbols/box.html",
            ArrayList<VersionSite>([current, target]))
        for (id in ["direct", "extra", "inherited"]) {
            @Expect(selector.contains(versionSymbolAnchor(id)), true)
            @Expect(selector.contains("../../old/symbols/old-${id}.html"), true)
        }
        let missing = VersionSite(VersionComposeSpec("missing", "unused"), VersionSymbolIndex())
        let unavailable = versionSelector(current, "new/symbols/box.html", "symbols/box.html",
            ArrayList<VersionSite>([current, missing]))
        @Expect(unavailable.contains(versionSymbolAnchor("extra")), true)
        @Expect(unavailable.contains("../../missing/index.html"), true)
    }

    @TestCase
    func unresolvedOrInvisibleRelationsNeverInventContextMembers(): Unit {
        let index = VersionSymbolIndex()
        index.add("owner", "symbols/owner.html", kind: "class")
        index.add("extension", "symbols/extension.html", kind: "extend")
        index.add("extra", "symbols/extra.html", owner: Some("extension"))
        index.add("base", "symbols/base.html", kind: "class")
        index.add("baseMember", "symbols/base-member.html", owner: Some("base"))
        index.addContextRelation("owner", "extendedBy", "partial", "extension")
        index.addContextRelation("owner", "extendedBy", "resolved", "base")
        index.addContextRelation("owner", "inheritedMember", "resolved", "missing")
        index.addContextRelation("owner", "inheritedMember", "unavailable", "baseMember")
        index.addContextRelation("missingOwner", "inheritedMember", "resolved", "baseMember")
        index.resolveContextMembers()
        @Expect(index.membersByOwner.contains("owner"), false)
        @Expect(index.membersByOwner.contains("missingOwner"), false)
        @Expect(index.membersByOwner["extension"].size, 1)
        @Expect(index.membersByOwner["base"].size, 1)
        index.addContextRelation("extension", "inheritedMember", "resolved", "baseMember")
        index.addContextRelation("owner", "extendedBy", "resolved", "extension")
        index.resolveContextMembers()
        @Expect(index.membersByOwner["owner"].size, 1)
        @Expect(index.membersByOwner["owner"][0], "extra")
        @Expect(index.membersByOwner["extension"].size, 2)
    }
}
