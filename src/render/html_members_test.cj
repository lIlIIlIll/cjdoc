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
    func toolbarFollowsProjectedMemberCountWithoutCollapsingOverloads(): Unit {
        let moduleId = "member-counts"
        let owner = SymbolDoc("count-owner", "class", "Box", "fixture.Box", "fixture",
            moduleId, "public", memberBrowserTestSource(1), "public class Box",
            SemanticInfo("partial", "ast"))
        for (count in [0, 1, 2, 50, 500]) {
            let declarations = ArrayList<SymbolDoc>([owner])
            for (index in 0..count) {
                declarations.add(SymbolDoc("count-member-${index}", "function", "read",
                    "fixture.Box.read", "fixture", moduleId, "public", memberBrowserTestSource(index + 2),
                    "public func read(value: Int64 = ${index}): Unit", SemanticInfo("partial", "ast"),
                    ownerId: Some(owner.id)))
            }
            let documentation = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
                ProjectInfo("member-counts"), ConfigurationSnapshot(audience: "external"),
                modules: [ModuleDoc(moduleId, "member-counts", "root", "", packageNames: ["fixture"])],
                packages: [PackageDoc("fixture", moduleId)], declarations: declarations.toArray())
            let projection = RenderProjection(documentation)
            let html = renderSymbolPage(documentation, projection, projection.visibleIndex, owner,
                HashMap<String, String>(), HtmlTypeLinkIndex(documentation, projection))
            @Expect(html.contains("member-browser-toolbar"), count >= 2)
            @Expect(html.contains("data-cjdoc-members-expand"), count >= 2)
            @Expect(!html.contains("data-cjdoc-member-origin"))
            @Expect(html.split("data-cjdoc-member data-member-name=").size - 1, count)
            @Expect(html.contains("data-cjdoc-member-browser"), count > 0)
        }
    }

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
        let html = renderSymbolPage(documentation, projection, projection.visibleIndex, owner,
            HashMap<String, String>(), HtmlTypeLinkIndex(documentation, projection))
        @Expect(browser.origins.toArray(), ["declared", "inherited", "extension"])
        @Expect(html.contains("data-cjdoc-member-filter"))
        @Expect(html.contains("<option value=\"declared\">"))
        @Expect(html.contains("<option value=\"inherited\">"))
        @Expect(html.contains("<option value=\"extension\">"))
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
        let projection = RenderProjection(documentation)
        let browser = projection.members(owner)
        @Expect(browser.entries.size, 1)
        @Expect(browser.entries[0].origin, "declared")
        let html = renderSymbolPage(documentation, projection, projection.visibleIndex, owner,
            HashMap<String, String>(), HtmlTypeLinkIndex(documentation, projection))
        @Expect(!html.contains("member-browser-toolbar"))
        @Expect(!html.contains("data-cjdoc-member-filter"))
        @Expect(!html.contains("data-cjdoc-members-expand"))
        @Expect(html.contains("data-cjdoc-member "))
        @Expect(html.contains(symbolAnchor(direct)))
    }
}

@Test
class HtmlMemberSectionsTest {
    private func symbol(id: String, kind: String, role: String, owner: SymbolDoc): SymbolDoc {
        let documentation: ?DocComment = if (role.isEmpty()) { None } else {
            Some(DocComment("raw", "Summary", "", MarkdownNode("document"),
                tags: [DocTag("group", role, "Group " + role)]))
        }
        SymbolDoc(id, kind, "sameName", "fixture.Box.sameName", "fixture",
            "module", "public", memberBrowserTestSource(2), "public func sameName(): Unit",
            SemanticInfo("partial", "ast"), ownerId: Some(owner.id),
            documentation: documentation)
    }

    private func entry(symbol: SymbolDoc, origin: String, owner: SymbolDoc,
        catalog: DeclarationGroupCatalog): HtmlMemberEntry {
        let groupId = match (catalog.groupFor(symbol)) {
            case Some(group) => group.id
            case None => ""
        }
        HtmlMemberEntry(symbol, origin, Some(owner), groupId)
    }

    private func makeCatalog(symbols: ArrayList<SymbolDoc>): DeclarationGroupCatalog {
        DeclarationGroupCatalog(DocumentationMetadata(), symbols, "en")
    }

    private func owner(): SymbolDoc {
        SymbolDoc("owner", "class", "Box", "fixture.Box", "fixture", "module", "public",
            memberBrowserTestSource(1), "public class Box", SemanticInfo("partial", "ast"))
    }

    @TestCase
    func distinctGroupsPartitionRatherThanRepeatEveryMember(): Unit {
        let symbols = ArrayList<SymbolDoc>()
        let declaredBy = owner()
        // One group per member is the adversarial case: section inputs must
        // total N entries, rather than N entries for each of the N groups.
        for (index in 0..512) {
            symbols.add(symbol("member-${index}", "function", "group-${index}", declaredBy))
        }
        let catalog = makeCatalog(symbols)
        let entries = ArrayList<HtmlMemberEntry>()
        for (value in symbols) { entries.add(entry(value, "declared", declaredBy, catalog)) }
        let sections = HtmlMemberSections(entries, catalog)
        @Expect(sections.roles.size, 512)
        var sectionInputCount: Int64 = 0
        let seen = HashSet<String>()
        for (role in sections.roles) {
            let values = sections.entries(role, "Functions")
            @Expect(values.size, 1)
            sectionInputCount += values.size
            for (value in values) {
                @Expect(catalog.groupFor(value.symbol).getOrThrow().id, role.id)
                @Expect(seen.add(value.symbol.id))
            }
            @Expect(sections.entries(role, "Properties").isEmpty())
        }
        @Expect(sectionInputCount, 512)
        @Expect(seen.size, 512)
    }

    @TestCase
    func partitionsPreserveUngroupedKindsOriginsOwnersAndOverloadOrder(): Unit {
        let declaredBy = owner()
        let directSymbol = symbol("direct", "function", "application", declaredBy)
        let overloadSymbol = symbol("overload", "function", "application", declaredBy)
        let inheritedSymbol = symbol("inherited", "function", "application", declaredBy)
        let extensionSymbol = symbol("extension", "function", "spi", declaredBy)
        let propertySymbol = symbol("property", "property", "application", declaredBy)
        let ungroupedSymbol = symbol("ungrouped", "macro", "", declaredBy)
        let aliasSymbol = symbol("alias", "typeAlias", "", declaredBy)
        let symbols = ArrayList<SymbolDoc>([directSymbol, overloadSymbol, inheritedSymbol,
            extensionSymbol, propertySymbol, ungroupedSymbol, aliasSymbol])
        let catalog = makeCatalog(symbols)
        let direct = entry(directSymbol, "declared", declaredBy, catalog)
        let overload = entry(overloadSymbol, "declared", declaredBy, catalog)
        let inherited = entry(inheritedSymbol, "inherited", declaredBy, catalog)
        let extension = entry(extensionSymbol, "extension", declaredBy, catalog)
        let property = entry(propertySymbol, "declared", declaredBy, catalog)
        let ungrouped = entry(ungroupedSymbol, "declared", declaredBy, catalog)
        let alias = entry(aliasSymbol, "declared", declaredBy, catalog)
        let sections = HtmlMemberSections(ArrayList<HtmlMemberEntry>([
            direct, overload, inherited, extension, property, ungrouped, alias]), catalog)
        @Expect(sections.roles.size, 3)
        @Expect(sections.roles[0].id, "application")
        @Expect(sections.roles[1].id, "spi")
        @Expect(sections.roles[2].id, "")
        let functions = sections.entries(sections.roles[0], "Functions")
        @Expect(functions.size, 3)
        @Expect(functions[0].symbol.id, "direct")
        @Expect(functions[1].symbol.id, "overload")
        @Expect(functions[0].groupKey, functions[1].groupKey)
        @Expect(functions[2].origin, "inherited")
        @Expect(functions[2].declaredBy.getOrThrow().id, declaredBy.id)
        @Expect(sections.entries(sections.roles[1], "Functions")[0].origin, "extension")
        @Expect(sections.entries(sections.roles[0], "Properties")[0].symbol.id, "property")
        @Expect(sections.entries(sections.roles[2], "Macros")[0].symbol.id, "ungrouped")
        @Expect(sections.entries(sections.roles[2], "Other members")[0].symbol.id, "alias")
        @Expect(sections.entries(sections.roles[0], "Missing").isEmpty())
        @Expect(HtmlMemberSections(ArrayList<HtmlMemberEntry>(), catalog).roles.isEmpty())
    }
    @TestCase
    func scopedGroupAnchorsKeepPageOwnerPrimaryAndIgnoreTitleOrder(): Unit {
        let pageOwner = SymbolDoc("owner-a", "class", "Box", "fixture.Box", "fixture",
            "module", "public", memberBrowserTestSource(1), "public class Box",
            SemanticInfo("partial", "ast"))
        let inheritedOwner = SymbolDoc("owner-b", "class", "Base", "fixture.Base", "fixture",
            "module", "public", memberBrowserTestSource(2), "public class Base",
            SemanticInfo("partial", "ast"))
        let symbols = ArrayList<SymbolDoc>([
            symbol("member-a", "function", "shared", pageOwner),
            symbol("member-b", "function", "shared", inheritedOwner)
        ])
        let metadata = DocumentationMetadata(groups: [
            DocumentationGroupDefinition("module", "fixture", "shared", "Page group",
                ownerId: Some(pageOwner.id), order: Some(50)),
            DocumentationGroupDefinition("module", "fixture", "shared", "Base group",
                ownerId: Some(inheritedOwner.id), order: Some(1))
        ])
        let catalog = DeclarationGroupCatalog(metadata, symbols, "en")
        let groups = partitionDeclarationGroups(symbols, catalog)
        @Expect(groups.size, 2)
        @Expect(groups[0].title, "Base group")
        @Expect(groups[1].title, "Page group")
        prepareDeclarationGroupAnchors(groups, "module", "fixture", Some(pageOwner.id))
        @Expect(groups[0].anchor.startsWith("api-group-shared--"), true)
        @Expect(groups[1].anchor, "api-group-shared")
        @Expect(groups[1].kindPrefix, "api-kind-6-shared-")
        let anchorsByScope = HashMap<String, String>()
        for (group in groups) { anchorsByScope[group.scopeKey] = group.anchor }

        let reordered = DocumentationMetadata(groups: [
            DocumentationGroupDefinition("module", "fixture", "shared", "Renamed page group",
                ownerId: Some(pageOwner.id), order: Some(1)),
            DocumentationGroupDefinition("module", "fixture", "shared", "Renamed base group",
                ownerId: Some(inheritedOwner.id), order: Some(50))
        ])
        let reorderedGroups = partitionDeclarationGroups(symbols,
            DeclarationGroupCatalog(reordered, symbols, "en"))
        prepareDeclarationGroupAnchors(reorderedGroups, "module", "fixture", Some(pageOwner.id))
        for (group in reorderedGroups) {
            @Expect(anchorsByScope[group.scopeKey], group.anchor)
        }

        let inlineOnly = partitionDeclarationGroups(symbols, makeCatalog(symbols))
        @Expect(inlineOnly.size, 1)
        @Expect(inlineOnly[0].title, "Group shared")
        @Expect(inlineOnly[0].symbols.size, 2)
    }
}

