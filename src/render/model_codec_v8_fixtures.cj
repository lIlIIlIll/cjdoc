package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal let V7_CODEC_FIXTURE = """
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

internal let V6_EMPTY_MODULE_PROVIDER_FIXTURE = """
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

internal func codecV6ProviderMatrixJson(moduleCount: Int64, providerCount: Int64,
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

internal func codecModuleOnlyDocument(sourcePrefix: String): DocumentationSet {
    let moduleId = "cjdoc:module:v1:prefix-validation"
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "partial", ProjectInfo("prefix-validation"),
        ConfigurationSnapshot(lintProfile: "off"), providers: [ProviderInfo("ast", "builtin",
            moduleId, "partial", SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(moduleId, "prefix-validation", "root", sourcePrefix)])
}

internal func codecEmptyJson(projectName: String): String {
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

internal func codecDenseDag(size: Int64): DocumentationSet {
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

internal func codecMarkdownDocument(markdown: MarkdownNode,
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

internal let CODEC_TYPE_MODULE_ID = "cjdoc:module:v1:type-validation"
internal let CODEC_TYPE_SYMBOL_ID =
    "cjdoc:v2:cjdoc%3Amodule%3Av1%3Atype-validation::fixture::function:typed#g0()"

internal func codecTypeDocument(typeRef: TypeRef,
    symbolRelationships!: Array<SymbolRelationship> = [],
    canonicalTypes!: Bool = false, relationships!: Bool = false,
    typeProviderState!: String = "partial",
    documentation!: ?DocComment = None): DocumentationSet {
    let source = SourceRange("src/typed.cj", SourcePosition(1, 1, 0), SourcePosition(1, 26, 25))
    let symbol = SymbolDoc(CODEC_TYPE_SYMBOL_ID, "function", "typed", "fixture.typed", "fixture",
        CODEC_TYPE_MODULE_ID, "public", source, "public func typed(): Unit",
        SemanticInfo("partial", "ast"), returnType: Some(typeRef),
        symbolRelationships: symbolRelationships, documentation: documentation)
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

internal let CODEC_TYPE_LINK_MODULE_ID = "cjdoc:module:v1:type-links"
internal let CODEC_TYPE_LINK_FUNCTION_ID =
    "cjdoc:v2:cjdoc%3Amodule%3Av1%3Atype-links::fixture::function:typed#g0()"

internal func codecTypeLinkDeclaration(id: String, kind: String, name: String,
    qualifiedName: String): SymbolDoc {
    let source = SourceRange("src/typed.cj", SourcePosition(1, 1, 0), SourcePosition(1, 20, 19))
    SymbolDoc(id, kind, name, qualifiedName, "fixture", CODEC_TYPE_LINK_MODULE_ID, "public",
        source, "public ${kind} ${name}", SemanticInfo("partial", "ast"))
}

internal func codecTypeLinkDocument(returnType: TypeRef,
    parameters!: Array<ParameterDoc> = [], declarations!: Array<SymbolDoc> = []): DocumentationSet {
    let source = SourceRange("src/typed.cj", SourcePosition(1, 1, 0), SourcePosition(1, 40, 39))
    let function = SymbolDoc(CODEC_TYPE_LINK_FUNCTION_ID, "function", "typed", "fixture.typed",
        "fixture", CODEC_TYPE_LINK_MODULE_ID, "public", source,
        "public func typed(): ${returnType.spelling}", SemanticInfo("partial", "ast"),
        parameters: parameters, returnType: Some(returnType))
    let allDeclarations = ArrayList<SymbolDoc>()
    allDeclarations.add(function)
    let symbolIds = ArrayList<String>()
    symbolIds.add(CODEC_TYPE_LINK_FUNCTION_ID)
    for (declaration in declarations) {
        allDeclarations.add(declaration)
        symbolIds.add(declaration.id)
    }
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("type-links"),
        ConfigurationSnapshot(lintProfile: "off"), providers: [
            ProviderInfo("ast", "builtin", CODEC_TYPE_LINK_MODULE_ID, "partial",
                SemanticCapabilities(false, false, false, false, false)),
            ProviderInfo("types", "test", CODEC_TYPE_LINK_MODULE_ID, "partial",
                SemanticCapabilities(false, false, false, true, false))
        ], modules: [ModuleDoc(CODEC_TYPE_LINK_MODULE_ID, "type-links", "root", "",
            packageNames: ["fixture"])], packages: [PackageDoc("fixture", CODEC_TYPE_LINK_MODULE_ID,
            sourceFiles: ["src/typed.cj"], symbolIds: symbolIds.toArray())],
        files: [FileDoc("src/typed.cj", CODEC_TYPE_LINK_MODULE_ID, "fixture")],
        declarations: allDeclarations.toArray())
}

internal func codecNestedType(depth: Int64): TypeRef {
    var value = TypeRef("source", "Leaf", SemanticType("partial", provider: Some("types")))
    var current: Int64 = 0
    while (current < depth) {
        value = TypeRef("source", "Layer", SemanticType("partial", provider: Some("types")),
            arguments: [value])
        current++
    }
    value
}

internal func codecMarkdownAtDepth(depth: Int64): MarkdownNode {
    var inline = MarkdownNode("text", literal: "leaf")
    var current: Int64 = 2 // document(0) -> paragraph(1) -> inline(2)
    while (current < depth) {
        inline = MarkdownNode("emphasis", children: [inline])
        current++
    }
    MarkdownNode("document", children: [MarkdownNode("paragraph", children: [inline])])
}

internal func codecSharedType(levels: Int64): TypeRef {
    var shared = TypeRef("source", "Leaf", SemanticType("partial", provider: Some("types")))
    var current: Int64 = 0
    while (current < levels) {
        shared = TypeRef("source", "Pair", SemanticType("partial", provider: Some("types")),
            arguments: [shared, shared])
        current++
    }
    shared
}

internal func codecSharedMarkdown(levels: Int64): MarkdownNode {
    var shared = MarkdownNode("text", literal: "leaf")
    var current: Int64 = 0
    while (current < levels) {
        shared = MarkdownNode("emphasis", children: [shared, shared])
        current++
    }
    MarkdownNode("document", children: [MarkdownNode("paragraph", children: [shared])])
}

internal func codecProviderDocument(name: String, version: String,
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

internal func codecAsset(base64: String, sourcePath: String): AssetDoc {
    let decoded = decodeAssetBase64(base64)
    AssetDoc("sha256-${docIrSha256Bytes(decoded)}", "image/gif", sourcePath, base64)
}

internal func codecRendererFixture(): DocumentationSet {
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

internal func codecRenderedText(artifacts: Array<RenderArtifact>): String {
    let out = StringBuilder()
    for (artifact in artifacts) { if (!artifact.isBinary) { out.append(artifact.content) } }
    out.toString()
}
