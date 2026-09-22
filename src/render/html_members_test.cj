package cjdoc.render

import cjdoc.model.*
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
            "fixture", moduleId, "public", memberBrowserTestSource(3),
            "extend Box", SemanticInfo("partial", "ast"))
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
