package cjdoc

import cjdoc.model.*
import cjdoc.model as api_model
import cjdoc.render as publication_render
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private let PROJECTION_MODULE = "cjdoc:module:v1:publication"
private let PROJECTION_SYMBOL = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Apublication::fixture::"
private let PROJECTION_HOST = PROJECTION_SYMBOL + "class:Host#g0()"
private let PROJECTION_VISIBLE = PROJECTION_SYMBOL + "function:visible#g0()"
private let PROJECTION_HELPER = PROJECTION_SYMBOL + "function:hiddenHelper#g0()"
private let PROJECTION_INTERNAL = PROJECTION_SYMBOL + "class:Internal#g0()"
private let PROJECTION_INTERNAL_MEMBER = PROJECTION_SYMBOL + "function:value#g0()"
private let PROJECTION_EXTEND = PROJECTION_SYMBOL + "extend:Host#g0()"
private let PROJECTION_EXTENSION_MEMBER = PROJECTION_SYMBOL + "function:extra#g0()"
private let PROJECTION_REEXPORT_ID = "cjdoc:reexport:v1:" + "0123456789abcdef" +
    "0123456789abcdef" + "0123456789abcdef" + "0123456789abcdef"
private let PROJECTION_VISIBLE_ASSET =
    "sha256-c47dd9465c00e9a0c8b85e9ea58d3034a0d23b9cf926113602f3460752a4eb96"
private let PROJECTION_HIDDEN_ASSET =
    "sha256-e878950f8091ec010cf5cc723bdea027a8539cf7147cfea199c2f666232dcd4e"
private let PROJECTION_OMITTED_DIAGNOSTIC =
    "Details omitted because this diagnostic has no visible declaration binding."

private func projectionRange(line: Int64): SourceRange {
    SourceRange("src/api.cj", SourcePosition(line, 1, line * 20),
        SourcePosition(line, 21, line * 20 + 20))
}

// A private declaration still names its own local references in author text.
// Publication must keep the prose and remove the identity behind it.
private func projectionDocument(): MarkdownNode {
    let link = MarkdownNode("semantic_link",
        MarkdownNodeMetadata.forSemanticLink("hiddenHelper", "resolved",
            targetSymbolId: Some(PROJECTION_HELPER)),
        children: [MarkdownNode("text", literal: "hiddenHelper")])
    let image = MarkdownNode("image", literal: PROJECTION_VISIBLE_ASSET,
        children: [MarkdownNode("text", literal: "Public diagram")])
    return MarkdownNode("document", children: [
        MarkdownNode("paragraph", children: [
            MarkdownNode("text",
                literal: "Calls hiddenHelper for internal bookkeeping; the published prose is author text."),
            link,
            image])])
}

private func projectionHiddenDocument(): MarkdownNode {
    return MarkdownNode("document", children: [
        MarkdownNode("paragraph", children: [
            MarkdownNode("image", literal: PROJECTION_HIDDEN_ASSET,
                children: [MarkdownNode("text", literal: "Private diagram")])])])
}

private func projectionVisibleComment(): api_model.DocComment {
    let summary = DocumentationText(PROJECTION_VISIBLE + ":doc:summary:", "summary", "",
        Some("en"), "Public entry point.", MarkdownNode("document"))
    let reference = DocumentationText(PROJECTION_VISIBLE + ":doc:see:" + PROJECTION_HELPER,
        "see", "hiddenHelper", Some("en"), "See hiddenHelper for details.", MarkdownNode("document"),
        referenceState: "resolved", targetSymbolId: Some(PROJECTION_HELPER))
    let tag = api_model.DocTag("see", "hiddenHelper", "See hiddenHelper", referenceState: "resolved",
        targetSymbolId: Some(PROJECTION_HELPER),
        fieldId: PROJECTION_VISIBLE + ":doc:see:" + PROJECTION_HELPER)
    return api_model.DocComment("Public entry point.", "Public entry point.", "", projectionDocument(),
        tags: [tag], defaultLanguage: Some("en"), localizedTexts: [summary, reference])
}

private func publicationProjectionFixture(audience: String): api_model.DocumentationSet {
    let host = api_model.SymbolDoc(PROJECTION_HOST, "class", "Host", "fixture.Host", "fixture",
        PROJECTION_MODULE, "public", projectionRange(1), "public class Host",
        SemanticInfo("partial", "ast"))
    let visible = api_model.SymbolDoc(PROJECTION_VISIBLE, "function", "visible", "fixture.visible",
        "fixture", PROJECTION_MODULE, "public", projectionRange(2), "public func visible(): Unit",
        SemanticInfo("partial", "ast"), documentation: Some(projectionVisibleComment()))
    let helper = api_model.SymbolDoc(PROJECTION_HELPER, "function", "hiddenHelper",
        "fixture.hiddenHelper", "fixture", PROJECTION_MODULE, "private", projectionRange(3),
        "private func hiddenHelper(): Unit", SemanticInfo("partial", "ast"),
        documentation: Some(api_model.DocComment("Hidden", "Hidden", "", projectionHiddenDocument())))
    let internalClass = api_model.SymbolDoc(PROJECTION_INTERNAL, "class", "Internal", "fixture.Internal",
        "fixture", PROJECTION_MODULE, "internal", projectionRange(4), "class Internal",
        SemanticInfo("partial", "ast"))
    let internalMember = api_model.SymbolDoc(PROJECTION_INTERNAL_MEMBER, "function", "value",
        "fixture.Internal.value", "fixture", PROJECTION_MODULE, "public", projectionRange(5),
        "public func value(): Unit", SemanticInfo("partial", "ast"),
        ownerId: Some(PROJECTION_INTERNAL))
    // A private extension container of a published type still publishes the
    // members the renderer shows; publication must not contradict rendering.
    let extension = api_model.SymbolDoc(PROJECTION_EXTEND, "extend", "Host", "fixture.Host", "fixture",
        PROJECTION_MODULE, "private", projectionRange(6), "extend Host",
        SemanticInfo("partial", "ast"),
        symbolRelationships: [api_model.SymbolRelationship("extensionTarget", "Host", "resolved",
            targetSymbolId: Some(PROJECTION_HOST))])
    let extensionMember = api_model.SymbolDoc(PROJECTION_EXTENSION_MEMBER, "function", "extra",
        "fixture.Host.extra", "fixture", PROJECTION_MODULE, "public", projectionRange(7),
        "public func extra(): Unit", SemanticInfo("partial", "ast"),
        ownerId: Some(PROJECTION_EXTEND))
    let page = DocumentationPage("guide", "docs/guide.md",
        "concepts/guides/publication.html", "Publication guide", "guide", "Guide text",
        MarkdownNode("document", children: [MarkdownNode("paragraph",
            children: [MarkdownNode("text", literal: "Guide")])]),
        targetSymbolIds: [PROJECTION_HOST, PROJECTION_HELPER],
        bindings: [
            DocumentationPageBinding("Host", "Host", "frontmatter", "", 1,
                state: "resolved", targetSymbolId: Some(PROJECTION_HOST)),
            DocumentationPageBinding("hiddenHelper", "", "frontmatter", "", 2,
                state: "resolved", targetSymbolId: Some(PROJECTION_HELPER))])
    return api_model.DocumentationSet(GeneratorInfo("cjdoc", "test"), "partial",
        ProjectInfo("publication-projection"),
        ConfigurationSnapshot(audience: audience, lintProfile: "off"),
        providers: [ProviderInfo("ast", "builtin", PROJECTION_MODULE, "partial",
            api_model.SemanticCapabilities(true, true, true, true, true, relationships: true))],
        modules: [api_model.ModuleDoc(PROJECTION_MODULE, "publication", "root", "",
            packageNames: ["fixture"])],
        packages: [api_model.PackageDoc("fixture", PROJECTION_MODULE, sourceFiles: ["src/api.cj"],
            symbolIds: [PROJECTION_HOST, PROJECTION_VISIBLE, PROJECTION_HELPER,
                PROJECTION_INTERNAL, PROJECTION_INTERNAL_MEMBER, PROJECTION_EXTEND,
                PROJECTION_EXTENSION_MEMBER],
            reExports: [api_model.ReExportDoc(PROJECTION_REEXPORT_ID, "single", "fixture", "resolved",
                projectionRange(9), targetModuleId: Some(PROJECTION_MODULE),
                bindings: [api_model.ReExportBinding("Host", targetSymbolIds: [PROJECTION_HOST])])])],
        files: [FileDoc("src/api.cj", PROJECTION_MODULE, "fixture")],
        declarations: [host, visible, helper, internalClass, internalMember, extension,
            extensionMember],
        assets: [
            AssetDoc(PROJECTION_VISIBLE_ASSET, "image/png", "docs/images/public.png",
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC"),
            AssetDoc(PROJECTION_HIDDEN_ASSET, "image/png", "docs/images/private.png",
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4//8/AAX+Av4N70a4AAAAAElFTkSuQmCC")],
        orphanDocComments: [api_model.OrphanDocComment("/// Hidden entry point.", projectionRange(10))],
        diagnostics: [
            api_model.Diagnostic("warning", "CJDOC3001", "reference to " + PROJECTION_HELPER,
                source: projectionRange(2), symbolId: Some(PROJECTION_HELPER)),
            api_model.Diagnostic("warning", "CJDOC3002", "unbound reference to " + PROJECTION_HELPER)],
        pages: [page],
        externalDocumentation: [
            ExternalDocumentationReference(PROJECTION_HOST, "Host reference", "available",
                "https://docs.example.test/host.html"),
            ExternalDocumentationReference(PROJECTION_HELPER, "Hidden reference",
                "unavailable", "")])
}

// A capture whose visible declaration carries navigation for both a published
// and an unpublished target, as a producer that resolved links before applying
// the audience boundary would record.
private func publicationNavigationFixture(): api_model.DocumentationSet {
    let captured = publicationProjectionFixture("external")
    let hidden = TypeNavigation("resolved", "manual", "Explicit hidden reference",
        symbolKey: PROJECTION_HELPER, url: "dependencies/fixture.html")
    let published = TypeNavigation("resolved", "manual", "Explicit public reference",
        symbolKey: PROJECTION_HOST, url: "dependencies/fixture.html")
    let visible = api_model.SymbolDoc(PROJECTION_VISIBLE, "function", "visible", "fixture.visible",
        "fixture", PROJECTION_MODULE, "public", projectionRange(2),
        "public func visible(helper!: HiddenHelper): Host", SemanticInfo("partial", "ast"),
        parameters: [api_model.ParameterDoc("helper", api_model.TypeRef("named", "HiddenHelper",
            SemanticType("unavailable"), navigation: Some(hidden)))],
        returnType: Some(api_model.TypeRef("named", "Host", SemanticType("unavailable"),
            navigation: Some(published))),
        documentation: Some(projectionVisibleComment()))
    let declarations = ArrayList<api_model.SymbolDoc>()
    declarations.add(visible)
    for (declaration in captured.declarations where declaration.id != PROJECTION_VISIBLE) {
        declarations.add(declaration)
    }
    return api_model.DocumentationSet(captured.generator, captured.status, captured.project,
        captured.configuration, apiCollectionState: Some(captured.apiCollectionState),
        documentationRevision: captured.documentationRevision,
        providers: captured.providers.toArray(), modules: captured.modules.toArray(),
        packages: captured.packages.toArray(), files: captured.files.toArray(),
        declarations: declarations.toArray(), assets: captured.assets.toArray(),
        orphanDocComments: captured.orphanDocComments.toArray(),
        macroInvocations: captured.macroInvocations.toArray(),
        unsupportedDeclarations: captured.unsupportedDeclarations.toArray(),
        unboundSemanticDeclarations: captured.unboundSemanticDeclarations.toArray(),
        diagnostics: captured.diagnostics.toArray(), pages: captured.pages.toArray(),
        externalDocumentation: captured.externalDocumentation.toArray())
}

private func projectionFind(documentation: api_model.DocumentationSet, id: String): ?api_model.SymbolDoc {
    for (declaration in documentation.declarations) {
        if (declaration.id == id) { return Some(declaration) }
    }
    None
}

@Test
class PublicationProjectionTest {
    @TestCase
    func externalAudiencePublishesOnlyRenderableFacts(): Unit {
        let captured = publicationProjectionFixture("external")
        let projected = publication_render.projectPublicationDocumentation(captured)
        @Expect(projected.schemaVersion, DOC_IR_SCHEMA_VERSION)
        @Expect(projected.configuration.audience, "external")
        // Strict Doc IR: the canonical codec re-validates the projection.
        let encoded = publication_render.encodeDocIr(projected)
        @Expect(publication_render.encodeDocIr(publication_render.decodeDocIr(encoded)),
            encoded)
        for (id in [PROJECTION_HELPER, PROJECTION_INTERNAL, PROJECTION_INTERNAL_MEMBER]) {
            @Expect(projectionFind(projected, id).isNone(), true)
            @Expect(encoded.contains(id), false)
        }
        for (id in [PROJECTION_HOST, PROJECTION_VISIBLE, PROJECTION_EXTEND,
            PROJECTION_EXTENSION_MEMBER]) {
            @Expect(projectionFind(projected, id).isSome(), true)
        }
        @Expect(projected.packages[0].symbolIds.size, 4)
        @Expect(projected.packages[0].symbolIds.toArray().contains(PROJECTION_HELPER), false)
        // A re-export keeps only its still-published binding.
        @Expect(projected.packages[0].reExports.size, 1)
        @Expect(projected.packages[0].reExports[0].bindings.size, 1)
        @Expect(projected.packages[0].reExports[0].bindings[0].targetSymbolIds.toArray()[0],
            PROJECTION_HOST)
        // Unbound author surfaces cannot be attributed to a proven audience.
        @Expect(projected.orphanDocComments.size, 0)
        @Expect(projected.diagnostics.size, 1)
        @Expect(projected.diagnostics[0].message, PROJECTION_OMITTED_DIAGNOSTIC)
        @Expect(projected.externalDocumentation.size, 1)
        @Expect(projected.externalDocumentation[0].symbolId, PROJECTION_HOST)
        // Only media referenced from published text survives.
        @Expect(projected.assets.size, 1)
        @Expect(projected.assets[0].id, PROJECTION_VISIBLE_ASSET)
        @Expect(encoded.contains(PROJECTION_HIDDEN_ASSET), false)
        // The existing renderer consumes the projection through its own
        // validation and visibility projection without rejecting it.
        let artifacts = publication_render.renderDocumentationFormatsWithOptions(
            projected, ["markdown"], locale: "en")
        @Expect(artifacts.size > 0, true)
    }

    @TestCase
    func hiddenReferencesLoseIdentityButKeepAuthorText(): Unit {
        let captured = publicationProjectionFixture("external")
        let projected = publication_render.projectPublicationDocumentation(captured)
        let visible = projectionFind(projected, PROJECTION_VISIBLE).getOrThrow()
        let comment = visible.documentation.getOrThrow()
        // Author prose still names the private function: text is captured, not
        // rewritten, because publishing author text is not an identity claim.
        @Expect(comment.rawText, "Public entry point.")
        @Expect(comment.localizedTexts[0].text, "Public entry point.")
        let paragraph = comment.markdown.children[0]
        @Expect(paragraph.children[0].literal.contains("hiddenHelper"), true)
        // The local reference loses its target and stops claiming resolution.
        let reference = comment.localizedTexts[1]
        @Expect(reference.kind, "see")
        @Expect(reference.targetSymbolId.isNone(), true)
        @Expect(reference.referenceState, "unavailable")
        @Expect(reference.fieldId.startsWith(PROJECTION_VISIBLE + ":doc:see:opaque:"), true)
        @Expect(reference.fieldId.contains(PROJECTION_HELPER), false)
        // The projected tag and the language variant share one opaque identity.
        @Expect(comment.tags.size, 1)
        @Expect(comment.tags[0].targetSymbolId.isNone(), true)
        @Expect(comment.tags[0].referenceState, "unavailable")
        @Expect(comment.tags[0].fieldId, reference.fieldId)
        // A semantic link keeps its author-facing target and loses its identity.
        let link = paragraph.children[1]
        let metadata = link.metadata.getOrThrow()
        @Expect(metadata.semanticTarget.getOrThrow(), "hiddenHelper")
        @Expect(metadata.semanticState.getOrThrow(), "unavailable")
        @Expect(metadata.semanticTargetSymbolId.isNone(), true)
        @Expect(metadata.semanticExternalUrl.isNone(), true)
        // A page association to an unpublished declaration keeps the page only.
        @Expect(projected.pages.size, 1)
        @Expect(projected.pages[0].targetSymbolIds.size, 1)
        @Expect(projected.pages[0].targetSymbolIds.toArray()[0], PROJECTION_HOST)
        @Expect(projected.pages[0].bindings[0].state, "resolved")
        @Expect(projected.pages[0].bindings[1].state, "unavailable")
        @Expect(projected.pages[0].bindings[1].targetSymbolId.isNone(), true)
        @Expect(projected.pages[0].bindings[1].target.isEmpty(), true)
        @Expect(publication_render.encodeDocIr(projected).contains(PROJECTION_HELPER), false)
    }

    @TestCase
    func audienceNarrowingRewritesConfigurationAndRejectsWidening(): Unit {
        let captured = publicationProjectionFixture("all")
        let full = publication_render.projectPublicationDocumentation(captured)
        @Expect(full.configuration.audience, "all")
        @Expect(full.declarations.size, 7)
        @Expect(full.orphanDocComments.size, 1)
        @Expect(full.assets.size, 2)
        let external = publication_render.projectPublicationDocumentation(captured,
            audience: "external")
        @Expect(external.configuration.audience, "external")
        @Expect(external.declarations.size, 4)
        @Expect(publication_render.encodeDocIr(external) ==
            publication_render.encodeDocIr(full), false)
        let packageAudience = publication_render.projectPublicationDocumentation(captured,
            audience: "package")
        @Expect(packageAudience.configuration.audience, "package")
        @Expect(projectionFind(packageAudience, PROJECTION_INTERNAL).isSome(), true)
        @Expect(projectionFind(packageAudience, PROJECTION_INTERNAL_MEMBER).isSome(), true)
        @Expect(projectionFind(packageAudience, PROJECTION_HELPER).isNone(), true)
        // Equal audiences are permitted; widening is not.
        @Expect(publication_render.projectPublicationDocumentation(captured,
            audience: "all").configuration.audience, "all")
        let capturedExternal = publicationProjectionFixture("external")
        @ExpectThrows[IllegalArgumentException](
            publication_render.projectPublicationDocumentation(capturedExternal,
                audience: "all"))
        @ExpectThrows[IllegalArgumentException](
            publication_render.projectPublicationDocumentation(capturedExternal,
                audience: "package"))
        @ExpectThrows[IllegalArgumentException](
            publication_render.projectPublicationDocumentation(capturedExternal,
                audience: "internal"))
    }

    @TestCase
    func navigationEvidenceForHiddenTargetsIsRetired(): Unit {
        // A captured link can name a declaration this audience cannot see; its
        // selected claim and opaque key must not survive publication.
        let projected = publication_render.projectPublicationDocumentation(
            publicationNavigationFixture())
        let symbol = projectionFind(projected, PROJECTION_VISIBLE).getOrThrow()
        // A published target keeps its captured navigation unchanged.
        let kept = symbol.returnType.getOrThrow().navigation.getOrThrow()
        @Expect(kept.state, "resolved")
        @Expect(kept.symbolKey, PROJECTION_HOST)
        @Expect(kept.url, "dependencies/fixture.html")
        // A hidden target loses the claim instead of borrowing a new one.
        let retired = symbol.parameters[0].typeRef.navigation.getOrThrow()
        @Expect(retired.state, "unavailable")
        @Expect(retired.matchLevel, "none")
        @Expect(retired.symbolKey.isEmpty(), true)
        @Expect(retired.url.isEmpty(), true)
        @Expect(publication_render.encodeDocIr(projected).contains(PROJECTION_HELPER), false)
    }

    @TestCase
    func projectionIsDetachedAndDeterministic(): Unit {
        let captured = publicationProjectionFixture("external")
        let projected = publication_render.projectPublicationDocumentation(captured)
        let encoded = publication_render.encodeDocIr(projected)
        // Projection is deterministic for one capture.
        @Expect(publication_render.encodeDocIr(
            publication_render.projectPublicationDocumentation(captured)), encoded)
        // The capture keeps its own mutable surfaces and hidden declarations.
        @Expect(captured.declarations.size, 7)
        @Expect(projectionFind(captured, PROJECTION_HELPER).isSome(), true)
        @Expect(captured.orphanDocComments.size, 1)
        // A later mutation of the caller's set cannot reach the detached result.
        captured.appendDiagnostic(api_model.Diagnostic("warning", "CJDOC3003",
            "late capture reference to " + PROJECTION_HELPER))
        @Expect(projected.diagnostics.size, 1)
        @Expect(publication_render.encodeDocIr(projected), encoded)
        @Expect(projectionFind(projected, PROJECTION_HELPER).isNone(), true)
        let reprojected = publication_render.projectPublicationDocumentation(captured)
        @Expect(reprojected.diagnostics.size, 2)
        for (diagnostic in reprojected.diagnostics) {
            @Expect(diagnostic.message.contains(PROJECTION_HELPER), false)
        }
    }
}
