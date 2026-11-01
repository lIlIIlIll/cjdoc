package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

private func navigationOutputBoundaryFixture(occurrences: Int64, reason: String): api_model.DocumentationSet {
    let moduleId = "cjdoc:module:v1:navigation-budget"
    let symbolId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Anavigation-budget::fixture::function:api#g0()"
    let source = api_model.SourceRange("src/api.cj", api_model.SourcePosition(1, 1, 0),
        api_model.SourcePosition(1, 30, 29))
    let atom = api_model.TypeRef("source", "Unknown", api_model.SemanticType("unavailable"),
        navigation: Some(api_model.TypeNavigation("unavailable", "none", reason)))
    let result = api_model.TypeRef("source", "Repeated", api_model.SemanticType("unavailable"),
        arguments: Array<api_model.TypeRef>(occurrences, repeat: atom))
    let symbol = api_model.SymbolDoc(symbolId, "function", "api", "fixture.api", "fixture", moduleId,
        "public", source, "public func api(): Repeated", api_model.SemanticInfo("partial", "ast"),
        returnType: Some(result))
    api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"), "partial",
        api_model.ProjectInfo("navigation-output-boundary"), api_model.ConfigurationSnapshot(lintProfile: "off"),
        apiCollectionState: Some("resolved"), documentationRevision: "docs-output-boundary",
        providers: [api_model.ProviderInfo("ast", "builtin", moduleId, "partial",
            api_model.SemanticCapabilities(false, false, false, false, false))],
        modules: [api_model.ModuleDoc(moduleId, "navigation-budget", "root", "", packageNames: ["fixture"])],
        packages: [api_model.PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"], symbolIds: [symbolId])],
        files: [api_model.FileDoc("src/api.cj", moduleId, "fixture")], declarations: [symbol])
}

private func serializedObjectOccurrences(encoded: String): Int64 {
    var quoted = false
    var escaped = false
    var count: Int64 = 0
    for (rune in encoded.runes()) {
        let code = UInt32(rune)
        if (quoted) {
            if (escaped) { escaped = false }
            else if (code == 0x5Cu32) { escaped = true }
            else if (code == 0x22u32) { quoted = false }
        } else if (code == 0x22u32) { quoted = true }
        else if (code == 0x7Bu32) { count++ }
    }
    count
}

private func diagnosticObjectBoundaryFixture(occurrences: Int64): api_model.DocumentationSet {
    let range = api_model.SourceRange("src/input.cj", api_model.SourcePosition(1, 1, 0),
        api_model.SourcePosition(1, 30, 29))
    let diagnostic = api_model.Diagnostic("warning", "CJDOC3999", "边界 {text} \"quoted\"\n",
        source: Some(range))
    api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"), "partial",
        api_model.ProjectInfo("physical-object-boundary"), api_model.ConfigurationSnapshot(lintProfile: "off"),
        apiCollectionState: Some("resolved"), documentationRevision: "docs-object-boundary",
        diagnostics: Array<api_model.Diagnostic>(occurrences, repeat: diagnostic))
}

private func serializedArrayItemOccurrences(encoded: String): Int64 {
    let pending = ArrayList<JsonNode>()
    pending.add(JsonNode.parse(encoded))
    var count: Int64 = 0
    while (!pending.isEmpty()) {
        let node = pending.remove(at: pending.size - 1)
        match (node.kind()) {
            case JsonKind.Array =>
                let values = node.asArray()
                count += values.size()
                for (index in 0..values.size()) {
                    pending.add(values.get(index).getOrThrow())
                }
            case JsonKind.Object =>
                let fields = node.asObject()
                for (index in 0..fields.size()) { pending.add(fields.valueAt(index)) }
            case _ => ()
        }
    }
    count
}

private func arrayBudgetSymbol(name: String, occurrences: Int64): api_model.SymbolDoc {
    let moduleId = "cjdoc:module:v1:array-budget"
    let generics = ArrayList<String>()
    let spelling = StringBuilder()
    spelling.append("public func ${name}")
    if (occurrences > 0) {
        spelling.append("<")
        for (index in 0..occurrences) {
            if (index > 0) { spelling.append(",") }
            let parameter = "T${index}"
            generics.add(parameter)
            spelling.append(parameter)
        }
        spelling.append(">")
    }
    spelling.append("()")
    let header = spelling.toString()
    let source = api_model.SourceRange("src/${name}.cj", api_model.SourcePosition(1, 1, 0),
        api_model.SourcePosition(1, header.size + 1, header.size))
    let symbolId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aarray-budget::fixture::function:${name}#g${occurrences}()"
    api_model.SymbolDoc(symbolId, "function", name, "fixture.${name}", "fixture", moduleId,
        "public", source, header, api_model.SemanticInfo("partial", "ast"),
        genericParameters: generics.toArray())
}

private func arrayItemBoundaryFixture(first: Int64, second: Int64): api_model.DocumentationSet {
    let moduleId = "cjdoc:module:v1:array-budget"
    let declarations = [arrayBudgetSymbol("first", first), arrayBudgetSymbol("second", second)]
    api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"), "partial",
        api_model.ProjectInfo("physical-array-boundary"), api_model.ConfigurationSnapshot(lintProfile: "off"),
        apiCollectionState: Some("resolved"), documentationRevision: "docs-array-boundary",
        providers: [api_model.ProviderInfo("ast", "builtin", moduleId, "partial",
            api_model.SemanticCapabilities(false, false, false, false, false))],
        modules: [api_model.ModuleDoc(moduleId, "array-budget", "root", "", packageNames: ["fixture"])],
        packages: [api_model.PackageDoc("fixture", moduleId,
            sourceFiles: ["src/first.cj", "src/second.cj"],
            symbolIds: [declarations[0].id, declarations[1].id])],
        files: [api_model.FileDoc("src/first.cj", moduleId, "fixture"),
            api_model.FileDoc("src/second.cj", moduleId, "fixture")], declarations: declarations)
}


@Test
class PublicResourceBudgetTest {
    @TestCase
    func physicalArrayItemsShareThePublishedBoundaryAcrossCollections(): Unit {
        let base = serializedArrayItemOccurrences(api_render.encodeDocIr(arrayItemBoundaryFixture(0, 0)))
        let available = api_model.DOC_IR_MAX_SCHEMA_ARRAY_ITEMS - base
        let first = available / 2
        let second = available - first
        let request = GenerationRequest("unused", lintProfile: "off")
        let accepted = boundGeneratedDocumentation(arrayItemBoundaryFixture(first, second), request)
        @Expect(accepted.apiCollectionState, "resolved")
        @Assert(accepted.declarations.size == 2)
        let encoded = api_render.encodeDocIr(accepted)
        let items = serializedArrayItemOccurrences(encoded)
        @Expect(items, api_model.DOC_IR_MAX_SCHEMA_ARRAY_ITEMS)
        @Expect(items > 100000)
        @Expect(serializedObjectOccurrences(encoded) < api_model.DOC_IR_MAX_SCHEMA_OBJECTS)
        @Expect(encoded.size < api_model.DOC_IR_MAX_JSON_DOCUMENT_BYTES)
        let replay = api_render.decodeDocIr(encoded)
        @Expect(replay.declarations[0].genericParameters.size, first)
        @Expect(replay.declarations[1].genericParameters.size, second)
        let oversized = JsonNode.parse(encoded).asObject()
        oversized.get("declarations").getOrThrow().asArray().get(1).getOrThrow().asObject()
            .get("genericParameters").getOrThrow().asArray().add(JsonNode.string("Extra"))
        @ExpectThrows[IllegalArgumentException](api_render.decodeDocIr(oversized.toJson()))
        let overflow = arrayItemBoundaryFixture(first, second + 1)
        @ExpectThrows[IllegalArgumentException](api_render.encodeDocIr(overflow))
        let fallback = boundGeneratedDocumentation(overflow, request)
        @Expect(fallback.declarations.size, 0)
        @Expect(fallback.apiCollectionState, "unavailable")
        @Expect(fallback.documentationRevision, "docs-array-boundary")
        @Expect(fallback.diagnostics[0].code, "CJDOC3027")
        @Expect(api_render.decodeDocIr(api_render.encodeDocIr(fallback)).project.name, "resource-limited")
    }

    @TestCase
    func physicalObjectOccurrencesRespectThePublishedBoundaryAndFallback(): Unit {
        let one = serializedObjectOccurrences(api_render.encodeDocIr(diagnosticObjectBoundaryFixture(1)))
        let two = serializedObjectOccurrences(api_render.encodeDocIr(diagnosticObjectBoundaryFixture(2)))
        let perOccurrence = two - one
        @Assert(perOccurrence > 0)
        let base = one - perOccurrence
        let acceptedOccurrences = (api_model.DOC_IR_MAX_SCHEMA_OBJECTS - base) / perOccurrence
        let request = GenerationRequest("unused", lintProfile: "off")
        let accepted = boundGeneratedDocumentation(diagnosticObjectBoundaryFixture(acceptedOccurrences), request)
        @Expect(accepted.apiCollectionState, "resolved")
        @Expect(accepted.diagnostics.size, acceptedOccurrences)
        let encoded = api_render.encodeDocIr(accepted)
        let objects = serializedObjectOccurrences(encoded)
        @Expect(api_model.DOC_IR_MAX_SCHEMA_OBJECTS, 131072)
        @Expect(objects > 65536)
        @Expect(objects <= api_model.DOC_IR_MAX_SCHEMA_OBJECTS)
        @Expect(api_model.DOC_IR_MAX_SCHEMA_OBJECTS - objects < perOccurrence)
        @Expect(api_render.decodeDocIr(encoded).diagnostics.size, acceptedOccurrences)
        // Keep the schema valid so only the aggregate occurrence boundary rejects it.
        let oversized = JsonNode.parse(encoded).asObject()
        let diagnostics = oversized.get("diagnostics").getOrThrow().asArray()
        diagnostics.add(JsonNode.parse(diagnostics.get(0).getOrThrow().toJson()))
        @ExpectThrows[IllegalArgumentException](api_render.decodeDocIr(oversized.toJson()))
        let overflow = diagnosticObjectBoundaryFixture(acceptedOccurrences + 1)
        @ExpectThrows[IllegalArgumentException](api_render.encodeDocIr(overflow))
        let fallback = boundGeneratedDocumentation(overflow, request)
        @Expect(fallback.project.name, "resource-limited")
        @Expect(fallback.apiCollectionState, "unavailable")
        @Expect(fallback.documentationRevision, "docs-object-boundary")
        @Expect(fallback.diagnostics[0].code, "CJDOC3027")
        @Expect(api_render.decodeDocIr(api_render.encodeDocIr(fallback)).diagnostics.size, 1)
    }

    @TestCase
    func escapedNavigationReasonsRespectThePublishedDocumentBoundaryAndFallback(): Unit {
        // The shared 1 MiB value expands to 2 MiB at each JSON occurrence.
        // Thirty-one fit within 64 MiB; thirty-two plus the surrounding model do not.
        let reason = String.fromUtf8(Array<Byte>(1024 * 1024, repeat: b'"')) + "\n中文"
        let request = GenerationRequest("unused", lintProfile: "off")
        let accepted = boundGeneratedDocumentation(navigationOutputBoundaryFixture(31, reason), request)
        @Expect(accepted.declarations.size, 1)
        @Expect(accepted.apiCollectionState, "resolved")
        api_render.validateDocumentationSet(accepted)
        // Keep the full boundary in validation; round-trip a value above the old
        // 32 MiB cap without retaining a second near-64 MiB encoding in the suite.
        let roundTrip = navigationOutputBoundaryFixture(17, reason)
        let encoded = api_render.encodeDocIr(roundTrip)
        @Expect(encoded.size > 32 * 1024 * 1024)
        @Expect(encoded.size < api_model.DOC_IR_MAX_JSON_DOCUMENT_BYTES)
        let replay = api_render.decodeDocIr(encoded)
        @Expect(replay.declarations.size, 1)
        let arguments = replay.declarations[0].returnType.getOrThrow().arguments
        @Expect(arguments.size, 17)
        @Expect(arguments[0].navigation.getOrThrow().reason, reason)
        let rejected = navigationOutputBoundaryFixture(32, reason)
        @ExpectThrows[IllegalArgumentException](api_render.encodeDocIr(rejected))
        let fallback = boundGeneratedDocumentation(rejected, request)
        @Expect(fallback.declarations.size, 0)
        @Expect(fallback.apiCollectionState, "unavailable")
        @Expect(fallback.documentationRevision, "docs-output-boundary")
        @Expect(fallback.diagnostics[0].code, "CJDOC3027")
        @Expect(api_render.decodeDocIr(api_render.encodeDocIr(fallback)).project.name, "resource-limited")
    }

    @TestCase
    func projectionFallbackUsesTheExistingDecoderDocumentLimit(): Unit {
        let chunk = String.fromUtf8(Array<Byte>(1024 * 1024, repeat: b'y'))
        let diagnostics = ArrayList<api_model.Diagnostic>()
        for (_ in 0..35) { diagnostics.add(api_model.Diagnostic("warning", "CJDOC3999", chunk)) }
        let documentation = api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"), "partial",
            api_model.ProjectInfo("decoder-budget"), api_model.ConfigurationSnapshot(lintProfile: "off"),
            diagnostics: diagnostics.toArray())
        @Expect(boundGeneratedDocumentation(documentation, GenerationRequest("unused", lintProfile: "off", maxDocIrMiB: 32)).project.name,
            "resource-limited")
        @Expect(boundGeneratedDocumentation(documentation, GenerationRequest("unused", lintProfile: "off")).project.name,
            "decoder-budget")
    }
    @TestCase
    func projectionReplacesOversizedFieldsAndAggregateOutput(): Unit {
        let request = GenerationRequest("unused", lintProfile: "off")
        let oversizedField = String.fromUtf8(Array<Byte>(
            api_model.DOC_IR_MAX_JSON_STRING_BYTES + 1, repeat: b'x'))
        let singleField = api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"),
            "partial", api_model.ProjectInfo(oversizedField),
            api_model.ConfigurationSnapshot(lintProfile: "off"), documentationRevision: "docs-limit")
        let singleFallback = boundGeneratedDocumentation(singleField, request)
        @Expect(singleFallback.apiCollectionState, "unavailable")
        @Expect(singleFallback.documentationRevision, "docs-limit")
        @Expect(singleFallback.status, "partial")
        @Expect(singleFallback.project.name, "resource-limited")
        @Expect(singleFallback.generator.version, "0.7.7")
        @Expect(singleFallback.diagnostics.size, 1)
        @Expect(singleFallback.diagnostics[0].code, "CJDOC3027")

        let escapedRevision = String.fromUtf8(Array<Byte>(
            api_model.DOC_IR_MAX_JSON_DOCUMENT_BYTES / 6 + 1, repeat: 0))
        for (revision in [oversizedField, escapedRevision]) {
            let revisionField = api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"),
                "partial", api_model.ProjectInfo("oversized-publication"),
                api_model.ConfigurationSnapshot(lintProfile: "off"), documentationRevision: revision)
            let revisionFallback = boundGeneratedDocumentation(revisionField, request)
            @Assert(revisionFallback.documentationRevision.isEmpty())
            @Expect(revisionFallback.apiCollectionState, "unavailable")
            @Expect(revisionFallback.diagnostics[0].code, "CJDOC3027")
            @Expect(api_render.decodeDocIr(api_render.encodeDocIr(revisionFallback)).project.name, "resource-limited")
        }

        // One shared 1 MiB allocation expands to more than the 64 MiB output
        // artifact limit when encoded at each diagnostic occurrence.
        let chunk = String.fromUtf8(Array<Byte>(1024 * 1024, repeat: b'y'))
        let diagnostics = ArrayList<api_model.Diagnostic>()
        for (_ in 0..70) {
            diagnostics.add(api_model.Diagnostic("warning", "CJDOC3999", chunk))
        }
        let aggregate = api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"),
            "partial", api_model.ProjectInfo("aggregate-budget"),
            api_model.ConfigurationSnapshot(lintProfile: "off"),
            diagnostics: diagnostics.toArray())
        let aggregateFallback = boundGeneratedDocumentation(aggregate, request)
        @Expect(aggregateFallback.status, "partial")
        @Expect(aggregateFallback.project.name, "resource-limited")
        @Expect(aggregateFallback.diagnostics.size, 1)
        @Expect(aggregateFallback.diagnostics[0].code, "CJDOC3027")

        let small = api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"),
            "partial", api_model.ProjectInfo("small"),
            api_model.ConfigurationSnapshot(lintProfile: "off"))
        @Expect(boundGeneratedDocumentation(small, request).project.name, "small")
    }
}
