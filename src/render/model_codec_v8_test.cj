package cjdoc.render

import cjdoc.model.*
import cjdoc.schema_data.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private let V7_CODEC_FIXTURE = """
{
  "schemaVersion": "cjdoc.doc-ir/7",
  "generator": {"name": "cjdoc", "version": "test"},
  "status": "complete",
  "project": {"name": "codec", "kind": "package"},
  "configuration": {"audience": "external", "lintProfile": "off", "cfgProfile": "default"},
  "providers": [{
    "name": "ast", "version": "builtin", "moduleId": "cjdoc:module:v1:codec",
    "state": "partial",
    "capabilities": {"sourceBinding": false, "ownership": false, "visibility": false,
      "canonicalTypes": false, "canonicalSignatures": false, "relationships": false,
      "annotations": false}
  }],
  "modules": [{"id": "cjdoc:module:v1:codec", "name": "codec", "role": "root",
    "sourcePrefix": "", "packageNames": ["codec"], "dependencyIds": []}],
  "packages": [{"name": "codec", "moduleId": "cjdoc:module:v1:codec",
    "sourceFiles": ["src/api.cj"],
    "symbolIds": ["cjdoc:v2:cjdoc%3Amodule%3Av1%3Acodec::codec::function:f#g0()"]}],
  "files": [{"path": "src/api.cj", "moduleId": "cjdoc:module:v1:codec",
    "packageName": "codec"}],
  "declarations": [{
    "id": "cjdoc:v2:cjdoc%3Amodule%3Av1%3Acodec::codec::function:f#g0()",
    "kind": "function", "name": "f", "qualifiedName": "codec.f", "packageName": "codec",
    "moduleId": "cjdoc:module:v1:codec", "ownerId": null, "visibility": "public",
    "genericParameters": [], "parameters": [], "returnType": null, "annotations": [],
    "typeRelationships": [], "symbolRelationships": [],
    "documentation": {"rawText": "pixel", "summary": "pixel", "description": "",
      "markdown": {"kind": "document", "literal": "", "source": null, "children": [
        {"kind": "paragraph", "literal": "", "source": null, "children": [
          {"kind": "image", "literal": "pixel", "source": null, "children": [
            {"kind": "text", "literal": "pixel", "source": null, "children": []}
          ]}
        ]}
      ]}, "tags": []},
    "source": {"path": "src/api.cj", "start": {"line": 1, "column": 1, "byteOffset": 0},
      "end": {"line": 1, "column": 20, "byteOffset": 19}},
    "headerSpelling": "public func f(): Unit",
    "semantic": {"state": "partial", "provider": "ast", "canonicalSignature": null},
    "origin": {"kind": "source", "macroSymbolId": null}
  }],
  "assets": [{"id": "pixel", "mediaType": "image/gif", "sourcePath": "images/pixel.gif",
    "base64": "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="}],
  "orphanDocComments": [], "macroInvocations": [], "unsupportedDeclarations": [],
  "unboundSemanticDeclarations": [], "diagnostics": []
}
"""

private let V6_EMPTY_MODULE_PROVIDER_FIXTURE = """
{
  "schemaVersion": "cjdoc.doc-ir/6",
  "generator": {"name": "cjdoc", "version": "test"},
  "status": "partial",
  "project": {"name": "empty", "kind": "package"},
  "configuration": {"audience": "external", "lintProfile": "off", "cfgProfile": "default"},
  "providers": [{"name": "ast", "version": "builtin", "state": "partial",
    "capabilities": {"sourceBinding": false, "ownership": false, "visibility": false,
      "canonicalTypes": false, "canonicalSignatures": false, "relationships": false}}],
  "modules": [], "packages": [], "files": [], "declarations": [], "assets": [],
  "orphanDocComments": [], "macroInvocations": [], "unsupportedDeclarations": [],
  "unboundSemanticDeclarations": [], "diagnostics": []
}
"""

private func codecV6ProviderMatrixJson(moduleCount: Int64, providerCount: Int64,
    sourcePrefix!: String = "src"): String {
    let out = StringBuilder()
    out.append("{\"schemaVersion\":\"cjdoc.doc-ir/6\",\"generator\":")
    out.append("{\"name\":\"cjdoc\",\"version\":\"test\"},\"status\":\"partial\",")
    out.append("\"project\":{\"name\":\"v6-matrix\",\"kind\":\"package\"},")
    out.append("\"configuration\":{\"audience\":\"external\",\"lintProfile\":\"off\",")
    out.append("\"cfgProfile\":\"default\"},\"providers\":[")
    for (index in 0..providerCount) {
        if (index > 0) { out.append(",") }
        out.append("{\"name\":\"provider-${index}\",\"version\":\"test\",\"state\":\"partial\",")
        out.append("\"capabilities\":{\"sourceBinding\":false,\"ownership\":false,")
        out.append("\"visibility\":false,\"canonicalTypes\":false,")
        out.append("\"canonicalSignatures\":false,\"relationships\":false}}")
    }
    out.append("],\"modules\":[")
    for (index in 0..moduleCount) {
        if (index > 0) { out.append(",") }
        out.append("{\"id\":\"cjdoc:module:v1:v6-${index}\",\"name\":\"v6-${index}\",")
        out.append("\"role\":\"")
        out.append(if (index == 0) { "root" } else { "workspace" })
        out.append("\",\"sourcePrefix\":\"")
        out.append(sourcePrefix)
        out.append("\",\"packageNames\":[],\"dependencyIds\":[]}")
    }
    out.append("],\"packages\":[],\"files\":[],\"declarations\":[],\"assets\":[],")
    out.append("\"orphanDocComments\":[],\"macroInvocations\":[],")
    out.append("\"unsupportedDeclarations\":[],\"unboundSemanticDeclarations\":[],")
    out.append("\"diagnostics\":[]}")
    out.toString()
}

private func codecModuleOnlyDocument(sourcePrefix: String): DocumentationSet {
    let moduleId = "cjdoc:module:v1:prefix-validation"
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "partial", ProjectInfo("prefix-validation"),
        ConfigurationSnapshot(lintProfile: "off"), providers: [ProviderInfo("ast", "builtin",
            moduleId, "partial", SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(moduleId, "prefix-validation", "root", sourcePrefix)])
}

private func codecEmptyJson(projectName: String): String {
    let out = StringBuilder()
    out.append("{\"schemaVersion\":\"cjdoc.doc-ir/8\",\"generator\":{\"name\":\"cjdoc\",\"version\":\"test\"},")
    out.append("\"status\":\"partial\",\"project\":{\"name\":\"")
    out.append(projectName)
    out.append("\",\"kind\":\"package\"},\"configuration\":{\"audience\":\"external\",")
    out.append("\"lintProfile\":\"off\",\"cfgProfile\":\"default\"},\"providers\":[],\"modules\":[],")
    out.append("\"packages\":[],\"files\":[],\"declarations\":[],\"assets\":[],")
    out.append("\"orphanDocComments\":[],\"macroInvocations\":[],\"unsupportedDeclarations\":[],")
    out.append("\"unboundSemanticDeclarations\":[],\"diagnostics\":[]}")
    out.toString()
}

private func codecDenseDag(size: Int64): DocumentationSet {
    let modules = ArrayList<ModuleDoc>()
    let providers = ArrayList<ProviderInfo>()
    let capabilities = SemanticCapabilities(false, false, false, false, false)
    for (index in 0..size) {
        let dependencies = ArrayList<String>()
        for (dependency in (index + 1)..size) {
            dependencies.add("cjdoc:module:v1:dense-${dependency}")
        }
        let id = "cjdoc:module:v1:dense-${index}"
        modules.add(ModuleDoc(id, "dense-${index}", if (index == 0) { "root" } else { "workspace" },
            "m${index}", dependencyIds: dependencies.toArray()))
        providers.add(ProviderInfo("ast", "builtin", id, "partial", capabilities))
    }
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("dense"),
        ConfigurationSnapshot(lintProfile: "off"), providers: providers.toArray(),
        modules: modules.toArray())
}

private func codecMarkdownDocument(markdown: MarkdownNode,
    assets!: Array<AssetDoc> = []): DocumentationSet {
    let moduleId = "cjdoc:module:v1:markdown-validation"
    let symbolId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Amarkdown-validation::fixture::function:api#g0()"
    let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 24, 23))
    let symbol = SymbolDoc(symbolId, "function", "api", "fixture.api", "fixture", moduleId,
        "public", source, "public func api(): Unit", SemanticInfo("partial", "ast"),
        documentation: Some(DocComment("raw", "summary", "", markdown)))
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("markdown-validation"),
        ConfigurationSnapshot(lintProfile: "off"), providers: [ProviderInfo("ast", "builtin",
            moduleId, "partial", SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(moduleId, "markdown-validation", "root", "", packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"], symbolIds: [symbolId])],
        files: [FileDoc("src/api.cj", moduleId, "fixture")], declarations: [symbol], assets: assets)
}

private let CODEC_TYPE_MODULE_ID = "cjdoc:module:v1:type-validation"
private let CODEC_TYPE_SYMBOL_ID =
    "cjdoc:v2:cjdoc%3Amodule%3Av1%3Atype-validation::fixture::function:typed#g0()"

private func codecTypeDocument(typeRef: TypeRef,
    symbolRelationships!: Array<SymbolRelationship> = [],
    canonicalTypes!: Bool = false, relationships!: Bool = false,
    typeProviderState!: String = "partial"): DocumentationSet {
    let source = SourceRange("src/typed.cj", SourcePosition(1, 1, 0), SourcePosition(1, 26, 25))
    let symbol = SymbolDoc(CODEC_TYPE_SYMBOL_ID, "function", "typed", "fixture.typed", "fixture",
        CODEC_TYPE_MODULE_ID, "public", source, "public func typed(): Unit",
        SemanticInfo("partial", "ast"), returnType: Some(typeRef),
        symbolRelationships: symbolRelationships)
    DocumentationSet(GeneratorInfo("cjdoc", "test"),
        if (typeProviderState == "unavailable" || typeProviderState == "ambiguous") { "partial" }
        else { "complete" }, ProjectInfo("type-validation"),
        ConfigurationSnapshot(lintProfile: "off"), providers: [
            ProviderInfo("ast", "builtin", CODEC_TYPE_MODULE_ID, "partial",
                SemanticCapabilities(false, false, false, false, false,
                    relationships: relationships)),
            ProviderInfo("types", "test", CODEC_TYPE_MODULE_ID, typeProviderState,
                SemanticCapabilities(false, false, false, canonicalTypes, false))
        ], modules: [ModuleDoc(CODEC_TYPE_MODULE_ID, "type-validation", "root", "",
            packageNames: ["fixture"])], packages: [PackageDoc("fixture", CODEC_TYPE_MODULE_ID,
            sourceFiles: ["src/typed.cj"], symbolIds: [CODEC_TYPE_SYMBOL_ID])],
        files: [FileDoc("src/typed.cj", CODEC_TYPE_MODULE_ID, "fixture")], declarations: [symbol])
}

private func codecNestedType(depth: Int64): TypeRef {
    var value = TypeRef("source", "Leaf", SemanticType("partial", provider: Some("types")))
    var current: Int64 = 0
    while (current < depth) {
        value = TypeRef("source", "Layer", SemanticType("partial", provider: Some("types")),
            arguments: [value])
        current++
    }
    value
}

private func codecMarkdownAtDepth(depth: Int64): MarkdownNode {
    var inline = MarkdownNode("text", literal: "leaf")
    var current: Int64 = 2 // document(0) -> paragraph(1) -> inline(2)
    while (current < depth) {
        inline = MarkdownNode("emphasis", children: [inline])
        current++
    }
    MarkdownNode("document", children: [MarkdownNode("paragraph", children: [inline])])
}

private func codecSharedType(levels: Int64): TypeRef {
    var shared = TypeRef("source", "Leaf", SemanticType("partial", provider: Some("types")))
    var current: Int64 = 0
    while (current < levels) {
        shared = TypeRef("source", "Pair", SemanticType("partial", provider: Some("types")),
            arguments: [shared, shared])
        current++
    }
    shared
}

private func codecSharedMarkdown(levels: Int64): MarkdownNode {
    var shared = MarkdownNode("text", literal: "leaf")
    var current: Int64 = 0
    while (current < levels) {
        shared = MarkdownNode("emphasis", children: [shared, shared])
        current++
    }
    MarkdownNode("document", children: [MarkdownNode("paragraph", children: [shared])])
}

private func codecProviderDocument(name: String, version: String,
    canonicalSignature!: ?String = None, path!: String = "src/provider.cj",
    providerState!: String = "partial", declarationState!: String = "partial"): DocumentationSet {
    let moduleId = "cjdoc:module:v1:provider-validation"
    let symbolId =
        "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aprovider-validation::fixture::function:api#g0()"
    let source = SourceRange(path, SourcePosition(1, 1, 0),
        SourcePosition(1, 24, 23))
    let symbol = SymbolDoc(symbolId, "function", "api", "fixture.api", "fixture", moduleId,
        "public", source, "public func api(): Unit", SemanticInfo(declarationState, name,
            canonicalSignature: canonicalSignature))
    DocumentationSet(GeneratorInfo("cjdoc", "test"),
        if (providerState == "unavailable" || providerState == "ambiguous") { "partial" }
        else { "complete" }, ProjectInfo("provider-validation"),
        ConfigurationSnapshot(lintProfile: "off"), providers: [ProviderInfo(name, version,
            moduleId, providerState, SemanticCapabilities(false, false, false, false,
                canonicalSignature.isSome()))],
        modules: [ModuleDoc(moduleId, "provider-validation", "root", "",
            packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", moduleId, sourceFiles: [path],
            symbolIds: [symbolId])], files: [FileDoc(path, moduleId, "fixture")],
        declarations: [symbol])
}

private func codecAsset(base64: String, sourcePath: String): AssetDoc {
    let decoded = decodeAssetBase64(base64)
    AssetDoc("sha256-${docIrSha256Bytes(decoded)}", "image/gif", sourcePath, base64)
}

private func codecRendererFixture(): DocumentationSet {
    let moduleId = "cjdoc:module:v1:render-v8"
    let symbolId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Arender-v8::fixture::function:api#g0()"
    let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 24, 23))
    let heading = MarkdownNode("heading", MarkdownNodeMetadata.forHeading(2),
        children: [MarkdownNode("text", literal: "Topic")])
    let link = MarkdownNode("paragraph", children: [MarkdownNode("link", literal: "#topic",
        children: [MarkdownNode("text", literal: "Jump")])])
    let firstItem = MarkdownNode("list_item", MarkdownNodeMetadata.forListItem("checked"),
        children: [MarkdownNode("paragraph", children: [MarkdownNode("text", literal: "First")])])
    let secondItem = MarkdownNode("list_item", MarkdownNodeMetadata.forListItem("notTask"),
        children: [MarkdownNode("paragraph", children: [MarkdownNode("text", literal: "Second")])])
    let list = MarkdownNode("list", MarkdownNodeMetadata.forList("ordered", 3, "parenthesis", false),
        children: [firstItem, secondItem])
    let headerCell = MarkdownNode("table_cell", MarkdownNodeMetadata.forTableCell("center"),
        children: [MarkdownNode("text", literal: "Name")])
    let header = MarkdownNode("table_row", MarkdownNodeMetadata.forTableRow(true),
        children: [headerCell])
    let table = MarkdownNode("table", MarkdownNodeMetadata.forTable(["center"]),
        children: [header])
    let code = MarkdownNode("code_block", MarkdownNodeMetadata.forCodeBlock("fenced", Some("~"),
        4, "cj {.numberLines}", "cj", "{.numberLines}"), literal: "main()")
    let markdown = MarkdownNode("document", children: [heading, link, list, table, code])
    let returnType = TypeRef("primitive", "Unit", SemanticType("resolved",
        canonical: Some("std.core.Unit"), provider: Some("ast")))
    let symbol = SymbolDoc(symbolId, "function", "api", "fixture.api", "fixture", moduleId,
        "public", source, "public func api(): Unit", SemanticInfo("partial", "ast"),
        returnType: Some(returnType), documentation: Some(DocComment("raw", "summary", "",
            markdown, tags: [DocTag("return", "", "MUST-NOT-RENDER")])))
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("renderer"),
        ConfigurationSnapshot(lintProfile: "off"), providers: [ProviderInfo("ast", "builtin",
            moduleId, "partial", SemanticCapabilities(false, false, false, true, false))],
        modules: [ModuleDoc(moduleId, "renderer", "root", "", packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"], symbolIds: [symbolId])],
        files: [FileDoc("src/api.cj", moduleId, "fixture")], declarations: [symbol])
}

private func codecRenderedText(artifacts: Array<RenderArtifact>): String {
    let out = StringBuilder()
    for (artifact in artifacts) { if (!artifact.isBinary) { out.append(artifact.content) } }
    out.toString()
}

@Test
class ModelCodecV8Test {
    @TestCase
    func sha256MatchesPublishedVectors(): Unit {
        @Expect(docIrSha256Bytes([]),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        @Expect(docIrSha256Bytes("abc".toArray()),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @TestCase
    func v7MigrationRekeysAssetsAndAddsV8Fields(): Unit {
        let migrated = decodeDocIr(V7_CODEC_FIXTURE)
        let assetId = "sha256-1e85ec81b9800b4c443d39caca0d0926089a3ac201120db1ceb45b93789480b8"
        @Expect(migrated.schemaVersion, DOC_IR_SCHEMA_VERSION)
        @Expect(migrated.assets[0].id, assetId)
        let comment = migrated.declarations[0].documentation.getOrThrow()
        @Expect(comment.markdown.children[0].children[0].literal, assetId)
        @Expect(comment.markdown.children[0].metadata.isNone())
        @Expect(migrated.declarations[0].enumNonExhaustive.isNone())
        let encoded = encodeDocIr(migrated)
        @Expect(encoded.contains("\"schemaVersion\": \"cjdoc.doc-ir/8\""))
        @Expect(encoded.contains("\"metadata\": null"))
        @Expect(encoded.contains("\"enumNonExhaustive\": null"))
        @Expect(encodeDocIr(decodeDocIr(encoded)), encoded)
        let dangling = encoded.replace("\"macroSymbolId\": null",
            "\"macroSymbolId\": \"cjdoc:v2:missing\"")
        @Expect(dangling != encoded)
        @ExpectThrows[IllegalArgumentException](decodeDocIr(dangling))
    }

    @TestCase
    func denseDagIsLinearAndCyclesStillFail(): Unit {
        // Complete DAG: 64 vertices and 64*63/2 = 2016 edges. The old path-recursive
        // validator expands roughly 2^62 paths from vertex zero; tri-color visits each edge once.
        let dense = codecDenseDag(64)
        validateDocumentationSet(dense)
        @Expect(dense.modules.size, 64)

        let capabilities = SemanticCapabilities(false, false, false, false, false)
        let firstId = "cjdoc:module:v1:cycle-a"
        let secondId = "cjdoc:module:v1:cycle-b"
        let cyclic = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
            ProjectInfo("cycle"), ConfigurationSnapshot(lintProfile: "off"), providers: [
                ProviderInfo("ast", "builtin", firstId, "partial", capabilities),
                ProviderInfo("ast", "builtin", secondId, "partial", capabilities)
            ], modules: [
                ModuleDoc(firstId, "a", "root", "", dependencyIds: [secondId]),
                ModuleDoc(secondId, "b", "workspace", "", dependencyIds: [firstId])
            ])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(cyclic))
    }

    @TestCase
    func strictJsonStringLimitCoversSixteenMiBAssetEncoding(): Unit {
        // Base64 for a 16 MiB asset is 22,369,624 bytes; exercise the exact 24 MiB parser limit.
        let payload = String.fromUtf8(Array<Byte>(24 * 1024 * 1024, repeat: b'a'))
        let decoded = decodeDocIr(codecEmptyJson(payload))
        @Expect(decoded.project.name.size, 24 * 1024 * 1024)
    }

    @TestCase
    func strictJsonStringLimitRejectsOneByteOverBoundary(): Unit {
        let payload = String.fromUtf8(Array<Byte>(24 * 1024 * 1024 + 1, repeat: b'a'))
        @ExpectThrows(decodeDocIr(codecEmptyJson(payload)))
    }

    @TestCase
    func largeDefaultHeapCodeBlockShapeRoundTripsAndOverBudgetShapeRejects(): Unit {
        let codeBlock = MarkdownNode("code_block",
            MarkdownNodeMetadata.forCodeBlock("indented", None<String>, 0, "", "", ""),
            literal: "code")
        let children = ArrayList<MarkdownNode>()
        // Each block contributes both a Markdown and metadata object. This
        // stays close to the 32 MiB conservative encoding census while leaving
        // room for the fixed document envelope.
        for (_ in 0..23000) { children.add(codeBlock) }
        let encoded = encodeDocIr(codecMarkdownDocument(
            MarkdownNode("document", children: children.toArray())))
        @Expect(encoded.size < DOC_IR_MAX_JSON_DOCUMENT_BYTES)

        let decoded = decodeDocIr(encoded)
        @Expect(decoded.declarations[0].documentation.getOrThrow()
            .markdown.children.size, 23000)

        for (_ in 23000..24000) { children.add(codeBlock) }
        @ExpectThrows[IllegalArgumentException](encodeDocIr(codecMarkdownDocument(
            MarkdownNode("document", children: children.toArray()))))
    }

    @TestCase
    func semanticTypeCorrelationIsClosedInDomainAndSchema(): Unit {
        let unavailable = TypeRef("source", "Unknown", SemanticType("unavailable"))
        let unavailableJson = encodeDocIr(codecTypeDocument(unavailable))
        @Expect(decodeDocIr(unavailableJson).declarations.size, 1)

        let resolved = TypeRef("semantic", "Known", SemanticType("resolved",
            canonical: Some("fixture.Known"), provider: Some("types")))
        let resolvedJson = encodeDocIr(codecTypeDocument(resolved, canonicalTypes: true))
        @Expect(decodeDocIr(resolvedJson).declarations.size, 1)

        let missingProvider = TypeRef("source", "Partial", SemanticType("partial"))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecTypeDocument(missingProvider)))
        let unavailableProvider = TypeRef("source", "Unknown", SemanticType("unavailable",
            provider: Some("types")))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecTypeDocument(unavailableProvider)))
        let unavailableCanonical = TypeRef("source", "Unknown", SemanticType("unavailable",
            canonical: Some("fixture.Unknown"), provider: Some("types")))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecTypeDocument(unavailableCanonical, canonicalTypes: true)))
        let emptyCanonical = TypeRef("semantic", "Known", SemanticType("partial",
            canonical: Some(""), provider: Some("types")))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecTypeDocument(emptyCanonical, canonicalTypes: true)))
        let blankCanonical = TypeRef("semantic", "Known", SemanticType("partial",
            canonical: Some(" \t"), provider: Some("types")))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecTypeDocument(blankCanonical, canonicalTypes: true)))

        let emptyCanonicalJson = resolvedJson.replace(
            "\"canonical\": \"fixture.Known\"", "\"canonical\": \"\"")
        @Expect(emptyCanonicalJson != resolvedJson)
        let canonicalError = @AssertThrows[IllegalArgumentException](decodeDocIr(emptyCanonicalJson))
        @Expect(canonicalError.message.contains("invalid Doc IR schema"))
        let blankCanonicalJson = resolvedJson.replace(
            "\"canonical\": \"fixture.Known\"", "\"canonical\": \"   \"")
        @Expect(blankCanonicalJson != resolvedJson)
        let blankCanonicalError = @AssertThrows[IllegalArgumentException](
            decodeDocIr(blankCanonicalJson))
        @Expect(blankCanonicalError.message.contains("invalid Doc IR schema"))

        let partial = TypeRef("source", "Partial", SemanticType("partial", provider: Some("types")))
        let partialJson = encodeDocIr(codecTypeDocument(partial))
        let missingProviderJson = partialJson.replace(
            "\"provider\": \"types\"", "\"provider\": null")
        @Expect(missingProviderJson != partialJson)
        let providerError = @AssertThrows[IllegalArgumentException](decodeDocIr(missingProviderJson))
        @Expect(providerError.message.contains("invalid Doc IR schema"))

        let unavailableCanonicalJson = unavailableJson.replace(
            "\"canonical\": null", "\"canonical\": \"fixture.Unknown\"")
        @Expect(unavailableCanonicalJson != unavailableJson)
        let unavailableError = @AssertThrows[IllegalArgumentException](
            decodeDocIr(unavailableCanonicalJson))
        @Expect(unavailableError.message.contains("invalid Doc IR schema"))
        let unavailableProviderJson = unavailableJson.replace(
            "\"provider\": null", "\"provider\": \"types\"")
        @Expect(unavailableProviderJson != unavailableJson)
        let unavailableProviderError = @AssertThrows[IllegalArgumentException](
            decodeDocIr(unavailableProviderJson))
        @Expect(unavailableProviderError.message.contains("invalid Doc IR schema"))
    }

    @TestCase
    func unavailableProviderCannotBackUsableDeclarationOrTypeSemantics(): Unit {
        let unavailableDeclaration = codecProviderDocument("provider", "version",
            providerState: "unavailable", declarationState: "unavailable")
        let encoded = encodeDocIr(unavailableDeclaration)
        @Expect(decodeDocIr(encoded).declarations[0].semantic.state, "unavailable")

        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecProviderDocument("provider", "version", providerState: "unavailable",
                declarationState: "resolved")))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecProviderDocument("provider", "version", canonicalSignature: Some("api(): Unit"),
                providerState: "unavailable", declarationState: "unavailable")))

        let resolvedType = TypeRef("semantic", "Known", SemanticType("resolved",
            canonical: Some("fixture.Known"), provider: Some("types")))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecTypeDocument(
            resolvedType, canonicalTypes: true, typeProviderState: "unavailable")))

        // Ambiguous is intentionally not unavailable: it can retain a
        // non-authoritative spelling, but that spelling is never resolved.
        let ambiguousType = TypeRef("source", "Maybe", SemanticType("ambiguous",
            canonical: Some("fixture.Maybe"), provider: Some("types")))
        validateDocumentationSet(codecTypeDocument(ambiguousType, canonicalTypes: true,
            typeProviderState: "ambiguous"))
    }

    @TestCase
    func symbolRelationshipsRequireCapabilityExceptSourceFallback(): Unit {
        let typeRef = TypeRef("source", "Partial", SemanticType("partial", provider: Some("types")))
        let sourceFallback = SymbolRelationship("references", "missing", "unavailable")
        validateDocumentationSet(codecTypeDocument(typeRef,
            symbolRelationships: [sourceFallback]))

        let unavailableTarget = SymbolRelationship("references", "typed", "unavailable",
            targetSymbolId: Some(CODEC_TYPE_SYMBOL_ID))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecTypeDocument(typeRef,
            symbolRelationships: [unavailableTarget])))

        let providerRelationship = SymbolRelationship("references", "candidate", "partial")
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecTypeDocument(typeRef,
            symbolRelationships: [providerRelationship])))
        validateDocumentationSet(codecTypeDocument(typeRef,
            symbolRelationships: [providerRelationship], relationships: true))
    }

    @TestCase
    func recursiveDomainDepthIsExactAndCodecHasHeadroom(): Unit {
        let exactType = codecTypeDocument(codecNestedType(DOC_IR_MAX_TYPE_DEPTH))
        let typeJson = encodeDocIr(exactType)
        @Expect(decodeDocIr(typeJson).declarations.size, 1)
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecTypeDocument(codecNestedType(DOC_IR_MAX_TYPE_DEPTH + 1))))

        let exactMarkdown = codecMarkdownDocument(
            codecMarkdownAtDepth(DOC_IR_MAX_MARKDOWN_DEPTH))
        let markdownJson = encodeDocIr(exactMarkdown)
        @Expect(decodeDocIr(markdownJson).declarations.size, 1)
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            codecMarkdownAtDepth(DOC_IR_MAX_MARKDOWN_DEPTH + 1))))
    }

    @TestCase
    func sharedReferencesConsumeEncodedOccurrenceBudgets(): Unit {
        // Only 18 TypeRef objects are allocated, but binary sharing at 17
        // levels would serialize 262143 occurrences. Validation charges the
        // expansion that JSON will emit rather than unique object identity.
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecTypeDocument(codecSharedType(17))))

        // The same attack surface exists for MarkdownNode: 20 allocated nodes
        // (including document/paragraph) expand past the document-wide node and
        // edge limits and must fail before encoding.
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecMarkdownDocument(codecSharedMarkdown(17))))
    }

    @TestCase
    func encodedFieldAndOutputArtifactBudgetsAreClosed(): Unit {
        let oversizedField = String.fromUtf8(Array<Byte>(
            DOC_IR_MAX_JSON_STRING_BYTES + 1, repeat: b'x'))
        let singleField = DocumentationSet(GeneratorInfo("cjdoc", "test"), "partial",
            ProjectInfo(oversizedField), ConfigurationSnapshot(lintProfile: "off"))
        @Expect(!docIrFitsEncodedBudget(singleField, DOC_IR_MAX_OUTPUT_ARTIFACT_BYTES))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(singleField))

        let chunk = String.fromUtf8(Array<Byte>(1024 * 1024, repeat: b'y'))
        let diagnostics = ArrayList<Diagnostic>()
        for (_ in 0..24) {
            diagnostics.add(Diagnostic("warning", "CJDOC3999", chunk))
        }
        let aggregate = DocumentationSet(GeneratorInfo("cjdoc", "test"), "partial",
            ProjectInfo("aggregate-budget"), ConfigurationSnapshot(lintProfile: "off"),
            diagnostics: diagnostics.toArray())
        validateDocumentationSet(aggregate)
        @Expect(docIrFitsEncodedBudget(aggregate, DOC_IR_MAX_OUTPUT_ARTIFACT_BYTES))

        for (_ in 24..40) {
            diagnostics.add(Diagnostic("warning", "CJDOC3999", chunk))
        }
        let overDocumentBudget = DocumentationSet(GeneratorInfo("cjdoc", "test"), "partial",
            ProjectInfo("aggregate-budget"), ConfigurationSnapshot(lintProfile: "off"),
            diagnostics: diagnostics.toArray())
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(overDocumentBudget))
    }

    @TestCase
    func frozenLegacySchemaIdsAndEmptyModuleProviderPolicy(): Unit {
        let frozenId = "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir.schema.json"
        @Expect(DOC_IR_V6_SCHEMA.contains(frozenId))
        @Expect(DOC_IR_V7_SCHEMA.contains(frozenId))
        @ExpectThrows[IllegalArgumentException](decodeDocIr(V6_EMPTY_MODULE_PROVIDER_FIXTURE))
    }

    @TestCase
    func v6GlobalProviderMigrationPreflightsCartesianExpansion(): Unit {
        let migrated = decodeDocIr(codecV6ProviderMatrixJson(2, 1))
        @Expect(migrated.modules.size, 2)
        @Expect(migrated.providers.size, 2)
        @Expect(migrated.providers[0].moduleId != migrated.providers[1].moduleId)

        let error = @AssertThrows[IllegalArgumentException](
            decodeDocIr(codecV6ProviderMatrixJson(4096, 4096)))
        @Expect(error.message.contains("migration exceeds Doc IR occurrence/encoding budget"))
    }

    @TestCase
    func moduleSourcePrefixIsEmptyOrPortableRelativeAcrossDomainAndMigration(): Unit {
        validateDocumentationSet(codecModuleOnlyDocument(""))
        let encoded = encodeDocIr(codecModuleOnlyDocument("workspace/src"))
        @Expect(decodeDocIr(encoded).modules[0].sourcePrefix, "workspace/src")

        for (invalid in ["/absolute", "C:drive", "..", "../escape", "src/../escape",
            "src\\windows", "src//nested", "src/"]) {
            @ExpectThrows[IllegalArgumentException](ModuleDoc(
                "cjdoc:module:v1:invalid-prefix", "invalid-prefix", "root", invalid))
        }

        let invalidV8 = encoded.replace(
            "\"sourcePrefix\": \"workspace/src\"", "\"sourcePrefix\": \"../escape\"")
        @Expect(invalidV8 != encoded)
        let schemaError = @AssertThrows[IllegalArgumentException](decodeDocIr(invalidV8))
        @Expect(schemaError.message.contains("invalid Doc IR schema"))

        // Frozen v6 schema accepts this legacy spelling; migration must still
        // close it under the v8 typed domain before returning a document.
        @ExpectThrows[IllegalArgumentException](
            decodeDocIr(codecV6ProviderMatrixJson(1, 1, sourcePrefix: "../escape")))
    }

    @TestCase
    func fencedCodeAndOrderedListBoundsFailClosed(): Unit {
        let boundedFence = MarkdownNode("code_block", MarkdownNodeMetadata.forCodeBlock("fenced",
            Some("~"), DOC_IR_MAX_FENCE_LENGTH, "cj", "cj", ""), literal: "main()")
        validateDocumentationSet(codecMarkdownDocument(MarkdownNode("document",
            children: [boundedFence])))

        let oversizedFence = MarkdownNode("code_block", MarkdownNodeMetadata.forCodeBlock("fenced",
            Some("~"), DOC_IR_MAX_FENCE_LENGTH + 1, "", "", ""), literal: "main()")
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [oversizedFence]))))

        let collidingFence = MarkdownNode("code_block", MarkdownNodeMetadata.forCodeBlock("fenced",
            Some("`"), 3, "", "", ""), literal: "```")
        let collidingDocument = codecMarkdownDocument(
            MarkdownNode("document", children: [collidingFence]))
        let collidingJson = encodeDocIr(collidingDocument)
        @Expect(decodeDocIr(collidingJson).declarations.size, 1)

        let invalidBacktickInfo = MarkdownNode("code_block",
            MarkdownNodeMetadata.forCodeBlock("fenced", Some("`"), 3,
                "cj`unsafe", "cj", ""), literal: "main()")
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [invalidBacktickInfo]))))

        let tildeWithBacktickInfo = MarkdownNode("code_block",
            MarkdownNodeMetadata.forCodeBlock("fenced", Some("~"), 3,
                "cj`safe", "cj", ""), literal: "main()")
        let tildeJson = encodeDocIr(codecMarkdownDocument(
            MarkdownNode("document", children: [tildeWithBacktickInfo])))
        @Expect(decodeDocIr(tildeJson).declarations.size, 1)
        let invalidBacktickJson = tildeJson.replace(
            "\"fenceCharacter\": \"~\"", "\"fenceCharacter\": \"`\"")
        @Expect(invalidBacktickJson != tildeJson)
        let infoError = @AssertThrows[IllegalArgumentException](decodeDocIr(invalidBacktickJson))
        @Expect(infoError.message.contains("invalid Doc IR schema"))

        let multilineInfo = MarkdownNode("code_block", MarkdownNodeMetadata.forCodeBlock("fenced",
            Some("~"), 3, "cj\nunsafe", "cj", ""), literal: "main()")
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [multilineInfo]))))

        let item = MarkdownNode("list_item", MarkdownNodeMetadata.forListItem("notTask"),
            children: [MarkdownNode("paragraph", children: [MarkdownNode("text", literal: "item")])])
        let overflowingList = MarkdownNode("list", MarkdownNodeMetadata.forList("ordered",
            9223372036854775807, "period", true), children: [item, item])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [overflowingList]))))

        let lastNineDigitItem = MarkdownNode("list", MarkdownNodeMetadata.forList("ordered",
            DOC_IR_MAX_ORDERED_LIST_NUMBER, "period", true), children: [item])
        validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [lastNineDigitItem])))
        let sequenceBecomesTenDigits = MarkdownNode("list", MarkdownNodeMetadata.forList("ordered",
            DOC_IR_MAX_ORDERED_LIST_NUMBER, "period", true), children: [item, item])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [sequenceBecomesTenDigits]))))
        let tenDigitStart = MarkdownNode("list", MarkdownNodeMetadata.forList("ordered",
            DOC_IR_MAX_ORDERED_LIST_NUMBER + 1, "period", true), children: [item])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [tenDigitStart]))))
        let zeroOrdered = MarkdownNode("list", MarkdownNodeMetadata.forList("ordered",
            0, "period", true), children: [item])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [zeroOrdered]))))
        let nonzeroBullet = MarkdownNode("list", MarkdownNodeMetadata.forList("bullet",
            1, "none", true), children: [item])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [nonzeroBullet]))))

        let orderedJson = encodeDocIr(codecMarkdownDocument(MarkdownNode("document",
            children: [MarkdownNode("list", MarkdownNodeMetadata.forList("ordered", 3,
                "period", true), children: [item])])))
        let zeroOrderedJson = orderedJson.replace("\"start\": 3", "\"start\": 0")
        @Expect(zeroOrderedJson != orderedJson)
        let orderedSchemaError = @AssertThrows[IllegalArgumentException](decodeDocIr(zeroOrderedJson))
        @Expect(orderedSchemaError.message.contains("invalid Doc IR schema"))
    }

    @TestCase
    func markdownGrammarAndTableMetadataAreClosed(): Unit {
        let paragraph = MarkdownNode("paragraph", children: [MarkdownNode("text", literal: "cell")])
        let invalidList = MarkdownNode("list", MarkdownNodeMetadata.forList("bullet", 0, "none", true),
            children: [paragraph])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [invalidList]))))

        let invalidParagraph = MarkdownNode("paragraph", children: [MarkdownNode("code_block",
            MarkdownNodeMetadata.forCodeBlock("indented", None<String>, 0, "", "", ""), literal: "code")])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [invalidParagraph]))))

        let headerCell = MarkdownNode("table_cell", MarkdownNodeMetadata.forTableCell("left"),
            children: [MarkdownNode("text", literal: "name")])
        let bodyCell = MarkdownNode("table_cell", MarkdownNodeMetadata.forTableCell("left"),
            children: [MarkdownNode("text", literal: "value")])
        let header = MarkdownNode("table_row", MarkdownNodeMetadata.forTableRow(true),
            children: [headerCell])
        let body = MarkdownNode("table_row", MarkdownNodeMetadata.forTableRow(false),
            children: [bodyCell])
        let validTable = MarkdownNode("table", MarkdownNodeMetadata.forTable(["left"]),
            children: [header, body])
        validateDocumentationSet(codecMarkdownDocument(MarkdownNode("document", children: [validTable])))

        let wrongHeader = MarkdownNode("table", MarkdownNodeMetadata.forTable(["left"]),
            children: [MarkdownNode("table_row", MarkdownNodeMetadata.forTableRow(false),
                children: [headerCell])])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [wrongHeader]))))

        let wrongAlignment = MarkdownNode("table", MarkdownNodeMetadata.forTable(["right"]),
            children: [header])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document", children: [wrongAlignment]))))

        let legacyTable = MarkdownNode("table", children: [MarkdownNode("table_row",
            children: [MarkdownNode("table_cell", children: [MarkdownNode("text", literal: "legacy")])])])
        validateDocumentationSet(codecMarkdownDocument(MarkdownNode("document", children: [legacyTable])))
    }

    @TestCase
    func contentAddressedImagesMustResolveButRelativeReferencesMayRemainMissing(): Unit {
        let relative = MarkdownNode("document", children: [MarkdownNode("paragraph", children: [
            MarkdownNode("image", literal: "images/missing.png",
                children: [MarkdownNode("text", literal: "missing")])
        ])])
        validateDocumentationSet(codecMarkdownDocument(relative))

        let dangling = MarkdownNode("document", children: [MarkdownNode("paragraph", children: [
            MarkdownNode("image", literal: "sha256-0000000000000000000000000000000000000000000000000000000000000000",
                children: [MarkdownNode("text", literal: "missing")])
        ])])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(dangling)))
    }

    @TestCase
    func imageAssetsRequireCompleteRasterStructureAndTotalPixelBudget(): Unit {
        let truncated = codecAsset("R0lGODlh", "images/truncated.gif")
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecMarkdownDocument(MarkdownNode("document"), assets: [truncated])))
        @ExpectThrows[IllegalArgumentException](decodeDocIr(V7_CODEC_FIXTURE.replace(
            "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==", "R0lGODlh")))

        // Each image declares an 8192x8192 logical canvas (67,108,864
        // pixels) and passes the per-image limit. Three distinct payloads
        // exceed the 200,000,000-pixel document budget.
        let largeAssets = [
            codecAsset("R0lGODlhACAAIIAAAAAAAP///ywAAAAAAQAgACACAUwAOw==", "images/large-0.gif"),
            codecAsset("R0lGODlhACAAIIAAAAAAAP///ywAAAAAAQAgACACAU0AOw==", "images/large-1.gif"),
            codecAsset("R0lGODlhACAAIIAAAAAAAP///ywAAAAAAQAgACACAU4AOw==", "images/large-2.gif")
        ]
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            MarkdownNode("document"), assets: largeAssets)))
    }

    @TestCase
    func providerIdentityCanonicalSignatureAndPortablePathAreClosed(): Unit {
        validateDocumentationSet(codecProviderDocument("provider", "version",
            canonicalSignature: Some("fixture.api(): Unit")))
        let exactIdentity = String.fromUtf8(Array<Byte>(
            DOC_IR_MAX_PROVIDER_IDENTITY_BYTES, repeat: b'p'))
        let exactIdentityRoundTrip = decodeDocIr(encodeDocIr(
            codecProviderDocument(exactIdentity, exactIdentity)))
        @Expect(exactIdentityRoundTrip.providers[0].name.size,
            DOC_IR_MAX_PROVIDER_IDENTITY_BYTES)
        @Expect(exactIdentityRoundTrip.providers[0].version.size,
            DOC_IR_MAX_PROVIDER_IDENTITY_BYTES)
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecProviderDocument(" \t", "version")))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecProviderDocument("provider", " \n")))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecProviderDocument(String.fromUtf8(Array<Byte>(
                DOC_IR_MAX_PROVIDER_IDENTITY_BYTES + 1, repeat: b'p')), "version")))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecProviderDocument("provider", String.fromUtf8(Array<Byte>(
                DOC_IR_MAX_PROVIDER_IDENTITY_BYTES + 1, repeat: b'v')))))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecProviderDocument("provider", "version", canonicalSignature: Some("  \t"))))

        let providerJson = encodeDocIr(codecProviderDocument("provider", "version",
            canonicalSignature: Some("fixture.api(): Unit")))
        let blankSignature = providerJson.replace("fixture.api(): Unit", "   ")
        let signatureError = @AssertThrows[IllegalArgumentException](decodeDocIr(blankSignature))
        @Expect(signatureError.message.contains("invalid Doc IR schema"))
        let blankVersion = providerJson.replace("\"version\": \"version\"",
            "\"version\": \"   \"")
        let versionError = @AssertThrows[IllegalArgumentException](decodeDocIr(blankVersion))
        @Expect(versionError.message.contains("invalid Doc IR schema"))

        let invalidSegment = providerJson.replace("src/provider.cj", "src/../provider.cj")
        let pathError = @AssertThrows[IllegalArgumentException](decodeDocIr(invalidSegment))
        @Expect(pathError.message.contains("invalid Doc IR schema"))
        let emptySegment = providerJson.replace("src/provider.cj", "src//provider.cj")
        let emptySegmentError = @AssertThrows[IllegalArgumentException](decodeDocIr(emptySegment))
        @Expect(emptySegmentError.message.contains("invalid Doc IR schema"))
        let hiddenSegment = providerJson.replace("src/provider.cj", "src/.hidden/provider.cj")
        @Expect(decodeDocIr(hiddenSegment).files[0].path, "src/.hidden/provider.cj")
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecProviderDocument("provider", "version", path: "C:provider.cj")))
        let drivePrefix = providerJson.replace("src/provider.cj", "C:provider.cj")
        let drivePrefixError = @AssertThrows[IllegalArgumentException](decodeDocIr(drivePrefix))
        @Expect(drivePrefixError.message.contains("invalid Doc IR schema"))
        validateDocumentationSet(codecProviderDocument(
            "provider", "version", path: "1:provider.cj"))
        @Expect(decodeDocIr(providerJson.replace("src/provider.cj", "1:provider.cj"))
            .files[0].path, "1:provider.cj")

        // Frozen v7 accepts the historical loose shape declaratively, but the
        // v8 migration must still fail closed in the final domain validator.
        let legacyBlankProvider = V7_CODEC_FIXTURE.replace(
            "\"name\": \"ast\"", "\"name\": \"   \"")
        @ExpectThrows[IllegalArgumentException](decodeDocIr(legacyBlankProvider))
    }

    @TestCase
    func schemaAssociatesMetadataWithMarkdownKind(): Unit {
        let heading = MarkdownNode("document", children: [MarkdownNode("heading",
            MarkdownNodeMetadata.forHeading(2), children: [MarkdownNode("text", literal: "topic")])])
        let encoded = encodeDocIr(codecMarkdownDocument(heading))
        let wrongMetadata = encoded.replace("\"level\": 2",
            "\"listKind\": \"bullet\", \"start\": 0, \"delimiter\": \"none\", \"tight\": true")
        @Expect(wrongMetadata != encoded)
        let error = @AssertThrows[IllegalArgumentException](decodeDocIr(wrongMetadata))
        @Expect(error.message.contains("invalid Doc IR schema"))
    }

    @TestCase
    func renderersPreserveClosedMarkdownMetadataAndSuppressUnitReturns(): Unit {
        let documentation = codecRendererFixture()
        let markdown = codecRenderedText(MarkdownDocumentationRenderer().render(documentation))
        let html = codecRenderedText(HtmlDocumentationRenderer().render(documentation))
        @Expect(markdown.contains("##### Topic"))
        @Expect(markdown.contains("3) [x] First\n\n4) Second"))
        @Expect(markdown.contains("| :---: |"))
        @Expect(markdown.contains("~~~~cj {.numberLines}"))
        @Expect(html.contains("--doc-topic"))
        @Expect(html.contains("<ol start=\"3\">"))
        @Expect(html.contains("type=\"checkbox\" disabled checked"))
        @Expect(html.contains("<th class=\"align-center\">"))
        @Expect(html.contains("data-language=\"cj\""))
        @Expect(html.contains("data-cjdoc-attributes=\"{.numberLines}\""))
        @Expect(!html.contains("<h3>Returns</h3>"))
        @Expect(!html.contains("MUST-NOT-RENDER"))
    }
}
