package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private func memberBrowserTestSource(line: Int64): SourceRange {
    SourceRange("src/api.cj", SourcePosition(line, 1, line * 10),
        SourcePosition(line, 8, line * 10 + 7))
}

@Test
class HtmlMemberBrowserTest {
    @TestCase
    func memberOriginsRequireResolvedVisibleRelationships(): Unit {
        let moduleId = "cjdoc:module:v1:member-browser-test"
        let ownerId = "owner"
        let directId = "direct"
        let extensionId = "extension"
        let extensionMemberId = "extension-member"
        let baseId = "base"
        let inheritedId = "inherited"

        let direct = SymbolDoc(directId, "function", "direct", "fixture.Box.direct",
            "fixture", moduleId, "public", memberBrowserTestSource(2),
            "public func direct(): Unit", SemanticInfo("partial", "ast"),
            ownerId: Some(ownerId))
        let extensionMember = SymbolDoc(extensionMemberId, "function", "extra",
            "fixture.Box.extra", "fixture", moduleId, "public", memberBrowserTestSource(4),
            "public func extra(): Unit", SemanticInfo("partial", "ast"),
            ownerId: Some(extensionId))
        let extension = SymbolDoc(extensionId, "extend", "Box", "fixture.Box",
            "fixture", moduleId, "internal", memberBrowserTestSource(3),
            "extend Box", SemanticInfo("partial", "ast"), symbolRelationships: [
                SymbolRelationship("extensionTarget", "fixture.Box", "resolved",
                    targetSymbolId: Some(ownerId))
            ])
        let inherited = SymbolDoc(inheritedId, "function", "baseMember",
            "fixture.Base.baseMember", "fixture", moduleId, "public",
            memberBrowserTestSource(6), "public func baseMember(): Unit",
            SemanticInfo("partial", "ast"), ownerId: Some(baseId))
        let base = SymbolDoc(baseId, "class", "Base", "fixture.Base", "fixture",
            moduleId, "public", memberBrowserTestSource(5), "public class Base",
            SemanticInfo("partial", "ast"))
        let owner = SymbolDoc(ownerId, "class", "Box", "fixture.Box", "fixture",
            moduleId, "public", memberBrowserTestSource(1), "public class Box",
            SemanticInfo("partial", "ast"), symbolRelationships: [
                SymbolRelationship("extendedBy", "fixture.Box", "resolved",
                    targetSymbolId: Some(extensionId)),
                SymbolRelationship("inheritedMember", "fixture.Base.baseMember", "resolved",
                    targetSymbolId: Some(inheritedId))
            ])
        let documentation = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
            ProjectInfo("member-browser-test"), ConfigurationSnapshot(audience: "external"),
            modules: [ModuleDoc(moduleId, "member-browser-test", "root", "",
                packageNames: ["fixture"])],
            packages: [PackageDoc("fixture", moduleId,
                symbolIds: [ownerId, directId, extensionId, extensionMemberId, baseId, inheritedId])],
            declarations: [owner, direct, extension, extensionMember, base, inherited])
        let projection = RenderProjection(documentation)
        let browser = projection.members(owner)

        @Expect(browser.entries.size, 3)
        @Expect(browser.entries[0].origin == "declared" ||
            browser.entries[1].origin == "declared" ||
            browser.entries[2].origin == "declared", true)
        var extensionSeen = false
        var inheritedSeen = false
        for (entry in browser.entries) {
            if (entry.symbol.id == extensionMemberId) {
                extensionSeen = entry.origin == "extension" &&
                    entry.declaredBy.isSome() &&
                    entry.declaredBy.getOrThrow().id == extensionId
            }
            if (entry.symbol.id == inheritedId) {
                inheritedSeen = entry.origin == "inherited" &&
                    entry.declaredBy.isSome() &&
                    entry.declaredBy.getOrThrow().id == baseId
            }
        }
        @Expect(extensionSeen, true)
        @Expect(inheritedSeen, true)
        match (memberContextOwner(projection, extensionMember)) {
            case Some(contextOwner) => @Expect(contextOwner.id, ownerId)
            case None => @Expect(true, false)
        }
    }

    @TestCase
    func unresolvedExtensionRelationshipDoesNotInventMembers(): Unit {
        let moduleId = "cjdoc:module:v1:member-browser-safe"
        let owner = SymbolDoc("owner-safe", "class", "Box", "fixture.Box", "fixture",
            moduleId, "public", memberBrowserTestSource(1), "public class Box",
            SemanticInfo("partial", "ast"), symbolRelationships: [
                SymbolRelationship("extendedBy", "fixture.Box", "partial")
            ])
        let direct = SymbolDoc("direct-safe", "function", "direct", "fixture.Box.direct",
            "fixture", moduleId, "public", memberBrowserTestSource(2),
            "public func direct(): Unit", SemanticInfo("partial", "ast"),
            ownerId: Some("owner-safe"))
        let documentation = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
            ProjectInfo("member-browser-safe"), ConfigurationSnapshot(audience: "external"),
            modules: [ModuleDoc(moduleId, "member-browser-safe", "root", "",
                packageNames: ["fixture"])],
            packages: [PackageDoc("fixture", moduleId,
                symbolIds: ["owner-safe", "direct-safe"])],
            declarations: [owner, direct])
        let browser = RenderProjection(documentation).members(owner)
        @Expect(browser.entries.size, 1)
        @Expect(browser.entries[0].origin, "declared")
    }
}

@Test
class HtmlMemberSectionsTest {
    private func entry(id: String, kind: String, role: String, origin: String,
        owner: SymbolDoc): HtmlMemberEntry {
        let documentation: ?DocComment = if (role.isEmpty()) { None } else {
            Some(DocComment("raw", "Summary", "", MarkdownNode("document"),
                tags: [DocTag("group", role, "Group " + role)]))
        }
        let symbol = SymbolDoc(id, kind, "sameName", "fixture.Box.sameName", "fixture",
            "module", "public", memberBrowserTestSource(2), "public func sameName(): Unit",
            SemanticInfo("partial", "ast"), ownerId: Some(owner.id),
            documentation: documentation)
        HtmlMemberEntry(symbol, origin, Some(owner))
    }

    private func owner(): SymbolDoc {
        SymbolDoc("owner", "class", "Box", "fixture.Box", "fixture", "module", "public",
            memberBrowserTestSource(1), "public class Box", SemanticInfo("partial", "ast"))
    }

    @TestCase
    func distinctGroupsPartitionRatherThanRepeatEveryMember(): Unit {
        let entries = ArrayList<HtmlMemberEntry>()
        let declaredBy = owner()
        // One group per member is the adversarial case: section inputs must
        // total N entries, rather than N entries for each of the N groups.
        for (index in 0..512) {
            entries.add(entry("member-${index}", "function", "group-${index}", "declared", declaredBy))
        }
        let sections = HtmlMemberSections(entries)
        @Expect(sections.roles.size, 512)
        var sectionInputCount: Int64 = 0
        let seen = HashSet<String>()
        for (role in sections.roles) {
            let values = sections.entries(role.key, "Functions")
            @Expect(values.size, 1)
            sectionInputCount += values.size
            for (value in values) {
                @Expect(declarationGroupKey(value.symbol), role.key)
                @Expect(seen.add(value.symbol.id))
            }
            @Expect(sections.entries(role.key, "Properties").isEmpty())
        }
        @Expect(sectionInputCount, 512)
        @Expect(seen.size, 512)
    }

    @TestCase
    func partitionsPreserveUngroupedKindsOriginsOwnersAndOverloadOrder(): Unit {
        let declaredBy = owner()
        let direct = entry("direct", "function", "application", "declared", declaredBy)
        let overload = entry("overload", "function", "application", "declared", declaredBy)
        let inherited = entry("inherited", "function", "application", "inherited", declaredBy)
        let extension = entry("extension", "function", "spi", "extension", declaredBy)
        let property = entry("property", "property", "application", "declared", declaredBy)
        let ungrouped = entry("ungrouped", "macro", "", "declared", declaredBy)
        let alias = entry("alias", "typeAlias", "", "declared", declaredBy)
        let sections = HtmlMemberSections(ArrayList<HtmlMemberEntry>([
            direct, overload, inherited, extension, property, ungrouped, alias]))
        @Expect(sections.roles.size, 3)
        @Expect(sections.roles[0].key, "application")
        @Expect(sections.roles[1].key, "spi")
        @Expect(sections.roles[2].key, "")
        let functions = sections.entries("application", "Functions")
        @Expect(functions.size, 3)
        @Expect(functions[0].symbol.id, "direct")
        @Expect(functions[1].symbol.id, "overload")
        @Expect(functions[0].groupKey, functions[1].groupKey)
        @Expect(functions[2].origin, "inherited")
        @Expect(functions[2].declaredBy.getOrThrow().id, declaredBy.id)
        @Expect(sections.entries("spi", "Functions")[0].origin, "extension")
        @Expect(sections.entries("application", "Properties")[0].symbol.id, "property")
        @Expect(sections.entries("", "Macros")[0].symbol.id, "ungrouped")
        @Expect(sections.entries("", "Other members")[0].symbol.id, "alias")
        @Expect(sections.entries("missing", "Functions").isEmpty())
        @Expect(HtmlMemberSections(ArrayList<HtmlMemberEntry>()).roles.isEmpty())
    }
}
