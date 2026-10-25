package cjdoc

import cjdoc.model.*
import cjdoc.model as api_model
import cjdoc.render as api_render
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

// Public consumer tests: they build real captured Doc IR, query it through the
// public session surface, and assert the documented observable behaviour. No test
// names a private helper or pins a wiring detail.

private let PUBLIC_TEST_MODULE = "cjdoc:module:v1:query-public"
private let PUBLIC_TEST_SYMBOL_PREFIX = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aquery-public::fixture::"

private func chainSymbolId(kind: String, name: String, parameters: String): String {
    "${PUBLIC_TEST_SYMBOL_PREFIX}${kind}:${name}#g0(${parameters})"
}

private func catalogId(): String { chainSymbolId("class", "Catalog", "") }
private func addIntId(): String { chainSymbolId("function", "Catalog.add", "Int64") }
private func addStringId(): String { chainSymbolId("function", "Catalog.add", "String") }
private func windowId(): String { chainSymbolId("function", "Catalog.window", "Int64,Int64") }
private func opaqueId(): String { chainSymbolId("function", "opaque", "") }
private func readerId(): String { chainSymbolId("class", "Reader", "") }

private func testRange(line: Int64): SourceRange {
    SourceRange("src/catalog.cj", SourcePosition(line, 1, 0), SourcePosition(line, 60, 59))
}

private func testType(spelling: String): api_model.TypeRef {
    api_model.TypeRef("primitive", spelling, SemanticType("unavailable"))
}

private let TEST_EXAMPLE = "```cangjie\nimport fixture.*\n\nlet catalog = Catalog()\n" +
    "catalog.add(42)\n```\n\nExpected output:\n\n```text\n## Relationships\n42 汉\n```"

private func addContractTags(): Array<api_model.DocTag> {
    let tags = ArrayList<api_model.DocTag>([
        api_model.DocTag("param", "value", "value to append"),
        api_model.DocTag("param", "radix", "base used when formatting"),
        api_model.DocTag("return", "", "no return value"),
        api_model.DocTag("throws", "IllegalArgumentException", "radix other than 10 is rejected"),
        api_model.DocTag("deprecated", "", "use append instead"),
        api_model.DocTag("since", "", "0.2.0"),
        api_model.DocTag("example", "Appending", TEST_EXAMPLE),
        api_model.DocTag("precondition", "value", "the catalogue is open"),
        api_model.DocTag("postcondition", "", "the length grows by one"),
        api_model.DocTag("invariant", "entries", "entries keep insertion order"),
        api_model.DocTag("performance", "", "amortized constant time"),
        api_model.DocTag("state", "", "the catalogue must stay open"),
        api_model.DocTag("concurrency", "", "callers synchronize externally"),
        api_model.DocTag("platform", "", "every supported platform"),
        api_model.DocTag("compatibility", "", "keeps the 0.1.0 calling convention"),
        api_model.DocTag("error", "IllegalArgumentException", "radix other than 10 is rejected")
    ])
    tags.toArray()
}

private func addFunction(id: String, parameterType: String, header: String,
    ownerId: String): api_model.SymbolDoc {
    api_model.SymbolDoc(id, "function", "add", "fixture.Catalog.add", "fixture", PUBLIC_TEST_MODULE,
        "public", testRange(40), header, SemanticInfo("partial", "ast"),
        ownerId: Some(ownerId),
        parameters: [
            api_model.ParameterDoc("value", testType(parameterType)),
            api_model.ParameterDoc("radix", testType("Int64"), defaultExpression: Some("10"))
        ],
        documentation: Some(api_model.DocComment("raw", "Append a value",
            "Append a value to the catalogue.", MarkdownNode("document",
                children: [MarkdownNode("paragraph", children: [
                    MarkdownNode("text", literal: "Append a value to the catalogue.")
                ])]), tags: addContractTags())))
}

private func queryDocumentation(projectName!: String = "query-fixture"): api_model.DocumentationSet {
    let catalog = api_model.SymbolDoc(catalogId(), "class", "Catalog", "fixture.Catalog", "fixture",
        PUBLIC_TEST_MODULE, "public", testRange(1), "public class Catalog",
        SemanticInfo("partial", "ast"),
        documentation: Some(api_model.DocComment("", "A value catalogue", "",
            MarkdownNode("document", children: [
                MarkdownNode("paragraph", children: [
                    MarkdownNode("text", literal: "A value catalogue with no internal synchronization.")
                ])
            ]))))
    let addInt = addFunction(addIntId(), "Int64",
        "public func add(value: Int64, radix!: Int64 = 10): Unit", catalogId())
    let addString = addFunction(addStringId(), "String",
        "public func add(value: String): Unit", catalogId())
    let window = api_model.SymbolDoc(windowId(), "function", "window", "fixture.Catalog.window", "fixture",
        PUBLIC_TEST_MODULE, "public", testRange(195),
        "public func window(start!: Int64 = 0, limit!: Int64 = 20): Array<String>",
        SemanticInfo("partial", "ast"), ownerId: Some(catalogId()),
        returnType: Some(testType("Array<String>")),
        parameters: [
            api_model.ParameterDoc("start", testType("Int64"), defaultExpression: Some("0")),
            api_model.ParameterDoc("limit", testType("Int64"), defaultExpression: Some("20"))
        ],
        documentation: Some(api_model.DocComment("", "Read a window", "",
            MarkdownNode("document"), tags: [
                api_model.DocTag("precondition", "", "start is within 0..=size"),
                api_model.DocTag("error", "", "negative limit or start outside the range is rejected")
            ])))
    let opaque = api_model.SymbolDoc(opaqueId(), "function", "opaque", "fixture.opaque", "fixture",
        PUBLIC_TEST_MODULE, "public", testRange(70), "public func opaque(): Unit",
        SemanticInfo("partial", "ast"))
    let hidden = api_model.SymbolDoc("${PUBLIC_TEST_SYMBOL_PREFIX}function:secret#g0()",
        "function", "secret", "fixture.secret", "fixture", PUBLIC_TEST_MODULE, "private",
        testRange(300), "private func secret(): Unit", SemanticInfo("partial", "ast"))
    let reader = api_model.SymbolDoc(readerId(), "class", "Reader", "fixture.Reader", "fixture",
        PUBLIC_TEST_MODULE, "public", testRange(11), "public class Reader",
        SemanticInfo("partial", "ast"))
    let ids: Array<String> = [catalogId(), addIntId(), addStringId(), windowId(),
        opaqueId(), hidden.id, readerId()]
    api_model.DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo(projectName),
        ConfigurationSnapshot(lintProfile: "off"),
        providers: [ProviderInfo("ast", "builtin", PUBLIC_TEST_MODULE, "partial",
            api_model.SemanticCapabilities(false, false, false, false, false))],
        modules: [api_model.ModuleDoc(PUBLIC_TEST_MODULE, "query-fixture", "root", "",
            packageNames: ["fixture"])],
        packages: [api_model.PackageDoc("fixture", PUBLIC_TEST_MODULE, sourceFiles: ["src/catalog.cj"],
            symbolIds: ids)],
        files: [FileDoc("src/catalog.cj", PUBLIC_TEST_MODULE, "fixture")],
        declarations: [catalog, addInt, addString, window, opaque, hidden, reader],
        pages: [queryGuidePage()],
        diagnostics: [api_model.Diagnostic("warning", "CJDOC9001", "captured fixture warning",
            symbolId: Some(addIntId()))])
}

private func queryGuidePage(): DocumentationPage {
    let text = StringBuilder()
    for (_ in 0..80) { text.append("Guide body keeps Unicode 汉 and complete captured paragraphs. ") }
    let body = text.toString()
    DocumentationPage("query-guide", "docs/query-guide.md", "concepts/query-guide.html",
        "Budgeted guide", "guide", body,
        MarkdownNode("document", children: [MarkdownNode("paragraph",
            children: [MarkdownNode("text", literal: body)])]), language: Some("en"))
}

private func session(): DocumentationQuerySession {
    DocumentationQuerySession(queryDocumentation())
}

private func queryResult(session: DocumentationQuerySession, request: String): JsonObject {
    JsonNode.parse(session.execute(request)).asObject()
}

@Test
class DocumentationQueryPublicTest {
    @TestCase
    func searchRanksExactIdentityAboveNameAndPreservesOverloads(): Unit {
        let query = session()
        let byName = queryResult(query, "{\"operation\":\"search\",\"name\":\"add\"}")
        @Expect(byName.get("status").getOrThrow().asString(), "ambiguous")
        let items = byName.get("result").getOrThrow().asObject().get("items").getOrThrow().asArray()
        @Expect(items.size(), 2)
        for (index in 0..items.size()) {
            let item = items[index].asObject()
            @Expect(item.get("kind").getOrThrow().asString(), "symbol")
            let relevance = item.get("match").getOrThrow().asObject()
            @Expect(relevance.get("reason").getOrThrow().asString(), "declaration_name")
            @Expect(item.get("representations").getOrThrow().asObject()
                .get("json").getOrThrow().asString().startsWith("agent/symbols/symbol-"), true)
        }
        // Exact identity is a different, unambiguous level.
        let byId = queryResult(query,
            "{\"operation\":\"search\",\"symbolId\":\"${addIntId()}\"}")
        @Expect(byId.get("status").getOrThrow().asString(), "ok")
        let exact = byId.get("result").getOrThrow().asObject().get("items").getOrThrow()
            .asArray()[0].asObject()
        @Expect(exact.get("match").getOrThrow().asObject().get("reason").getOrThrow().asString(), "symbol_id")
        @Expect(exact.get("identity").getOrThrow().asObject().get("symbolId").getOrThrow().asString(),
            addIntId())
        // An overload selector is a captured source spelling, not a type inference.
        let bySelector = queryResult(query, "{\"operation\":\"search\",\"name\":\"add\"," +
            "\"parameterTypes\":[\"Int64\",\"Int64\"],\"genericArity\":0}")
        @Expect(bySelector.get("status").getOrThrow().asString(), "ok")
    }

    @TestCase
    func searchNeverWidensTheAudienceAndSeparatesAbsenceFromIncompleteness(): Unit {
        let query = session()
        let hidden = queryResult(query, "{\"operation\":\"search\",\"name\":\"secret\"}")
        @Expect(hidden.get("status").getOrThrow().asString(), "not_found")
        @Expect(hidden.get("completeness").getOrThrow().asObject().get("query").getOrThrow()
            .asObject().get("complete").getOrThrow().asBool(), true)
        // A private declaration is not searchable even by its exact SymbolId.
        let direct = queryResult(query,
            "{\"operation\":\"search\",\"symbolId\":\"${PUBLIC_TEST_SYMBOL_PREFIX}function:secret#g0()\"}")
        @Expect(direct.get("status").getOrThrow().asString(), "not_found")
    }

    @TestCase
    func languageFallbackStillNarrowsAnAllAudienceSnapshot(): Unit {
        let encoded = JsonNode.parse(api_render.encodeDocIr(queryDocumentation())).asObject()
        encoded.get("configuration").getOrThrow().asObject().put("audience", JsonNode.string("all"))
        let query = DocumentationQuerySession(api_render.decodeDocIr(encoded.toJson()))
        let hidden = queryResult(query, "{\"operation\":\"search\",\"name\":\"secret\"," +
            "\"language\":\"fr\",\"languageFallback\":true,\"audience\":\"external\"}")
        @Expect(hidden.get("status").getOrThrow().asString(), "not_found")
        @Expect(hidden.get("result").getOrThrow().asObject().get("items").getOrThrow()
            .asArray().size(), 0)
        let scopes = hidden.get("scope").getOrThrow().asObject().get("snapshots").getOrThrow().asArray()
        @Expect(scopes[0].asObject().get("audience").getOrThrow().asString(), "external")
        @Expect(scopes[0].asObject().get("language").getOrThrow().asString(), "en")
    }

    @TestCase
    func getSymbolKeepsMandatoryChaptersAndReportsOmisionsSeparately(): Unit {
        let query = session()
        let result = queryResult(query,
            "{\"operation\":\"get_symbol\",\"symbolId\":\"${addIntId()}\",\"preset\":\"call\"}")
        @Expect(result.get("status").getOrThrow().asString(), "ok")
        let item = result.get("result").getOrThrow().asObject().get("items").getOrThrow()
            .asArray()[0].asObject()
        let sections = item.get("sections").getOrThrow().asArray()
        let states = HashMap<String, String>()
        let contracts = HashMap<String, String>()
        for (index in 0..sections.size()) {
            let section = sections[index].asObject()
            states[section.get("name").getOrThrow().asString()] =
                section.get("state").getOrThrow().asString()
            if (section.get("name").getOrThrow().asString() == "contracts") {
                let tags = section.get("value").getOrThrow().asArray()
                for (tagIndex in 0..tags.size()) {
                    let tag = tags[tagIndex].asObject()
                    contracts[tag.get("name").getOrThrow().asString()] =
                        tag.get("description").getOrThrow().asString()
                }
            }
        }
        for (name in ["signature", "parameters", "returns", "contracts"]) {
            @Expect(states.contains(name), true)
            @Expect(states.get(name).getOrThrow() != "budget_omitted", true)
        }
        // Intact source signature and named/default parameter survive.
        let text = result.get("text").getOrThrow().asString()
        @Expect(text.contains("public func add(value: Int64, radix!: Int64 = 10): Unit"), true)
        // Every authored call condition is present, including the auxiliary tags.
        for ((name, description) in [
            ("precondition", "the catalogue is open"),
            ("postcondition", "the length grows by one"),
            ("invariant", "entries keep insertion order"),
            ("performance", "amortized constant time"),
            ("state", "the catalogue must stay open"),
            ("concurrency", "callers synchronize externally"),
            ("platform", "every supported platform"),
            ("compatibility", "keeps the 0.1.0 calling convention"),
            ("error", "radix other than 10 is rejected")]) {
            @Expect(contracts.get(name).getOrThrow(), description)
        }
        // Unselected chapters are omissions, not missing source facts.
        let content = result.get("completeness").getOrThrow().asObject().get("content")
            .getOrThrow().asObject()
        let omitted = content.get("omittedSections").getOrThrow().asArray()
        var sawNotSelected = false
        for (index in 0..omitted.size()) {
            if (omitted[index].asObject().get("reason").getOrThrow().asString() == "not_selected") {
                sawNotSelected = true
            }
        }
        @Expect(sawNotSelected, true)
    }

    @TestCase
    func budgetAndResourceLimitsNeverTruncateAContract(): Unit {
        let query = session()
        let small = queryResult(query, "{\"operation\":\"get_symbol\",\"symbolId\":\"${addIntId()}\"," +
            "\"preset\":\"call\",\"maxBytes\":1024}")
        @Expect(small.get("status").getOrThrow().asString(), "budget_exceeded")
        let error = small.get("error").getOrThrow().asObject()
        let required = error.get("requiredBytes").getOrThrow().asInt64()
        @Expect(required > 1024, true)
        @Expect(error.get("maximumBytes").getOrThrow().asInt64(), 1024)
        @Expect(small.get("result").getOrThrow().asObject().get("items").getOrThrow()
            .asArray().size(), 0)
        let retry = small.get("completeness").getOrThrow().asObject().get("content")
            .getOrThrow().asObject().get("retry").getOrThrow().asObject()
        @Expect(retry.get("maxBytes").getOrThrow().asInt64() >= required, true)
        // The documented retry budget is accepted and returns intact content.
        let retried = queryResult(query, "{\"operation\":\"get_symbol\",\"symbolId\":\"${addIntId()}\"," +
            "\"preset\":\"call\",\"maxBytes\":${required}}")
        @Expect(retried.get("status").getOrThrow().asString(), "ok")
    }

    @TestCase
    func structuredCallChaptersRetainCapturedTypesDefaultsAndTags(): Unit {
        let result = queryResult(session(), "{\"operation\":\"get_symbol\",\"symbolId\":\"${addIntId()}\"," +
            "\"preset\":\"call\",\"maxBytes\":65536}")
        let item = result.get("result").getOrThrow().asObject().get("items").getOrThrow()
            .asArray()[0].asObject()
        let sections = item.get("sections").getOrThrow().asArray()
        let values = HashMap<String, JsonNode>()
        for (index in 0..sections.size()) {
            let section = sections[index].asObject()
            values[section.get("name").getOrThrow().asString()] = section.get("value").getOrThrow()
        }
        let signature = values["signature"].asObject()
        @Expect(signature.get("headerSpelling").getOrThrow().asString(),
            "public func add(value: Int64, radix!: Int64 = 10): Unit")
        let parameters = values["parameters"].asObject().get("parameters").getOrThrow().asArray()
        let value = parameters[0].asObject()
        @Expect(value.get("name").getOrThrow().asString(), "value")
        @Expect(value.get("type").getOrThrow().asObject().get("spelling").getOrThrow().asString(), "Int64")
        @Expect(value.get("defaultExpression").getOrThrow().isNull, true)
        @Expect(parameters[1].asObject().get("defaultExpression").getOrThrow().asString(), "10")
        let examples = values["examples"].asArray()
        @Expect(examples[0].asObject().get("description").getOrThrow().asString(), TEST_EXAMPLE)
        let contracts = values["contracts"].asArray()
        var postcondition = ""
        for (index in 0..contracts.size()) {
            let tag = contracts[index].asObject()
            if (tag.get("name").getOrThrow().asString() == "postcondition") {
                postcondition = tag.get("description").getOrThrow().asString()
            }
        }
        @Expect(postcondition, "the length grows by one")
    }

    @TestCase
    func headingsInsideExampleOutputCannotSplitABudgetedChapter(): Unit {
        let query = session()
        for (budget in [1024, 2048, 65536]) {
            let result = queryResult(query, "{\"operation\":\"get_symbol\",\"symbolId\":\"${addIntId()}\"," +
                "\"sections\":[\"examples\",\"relations\"],\"maxBytes\":${budget}}")
            let item = result.get("result").getOrThrow().asObject().get("items").getOrThrow()
                .asArray()[0].asObject()
            let sections = item.get("sections").getOrThrow().asArray()
            var foundExample = false
            for (index in 0..sections.size()) {
                let section = sections[index].asObject()
                if (section.get("name").getOrThrow().asString() != "examples") { continue }
                foundExample = true
                if (budget == 65536) {
                    @Expect(section.get("state").getOrThrow().asString(), "available")
                }
                if (section.get("state").getOrThrow().asString() == "available") {
                    @Expect(result.get("text").getOrThrow().asString().contains(
                        "## Relationships\n42 汉\n```"), true)
                } else {
                    @Expect(section.get("state").getOrThrow().asString(), "budget_omitted")
                    @Expect(section.get("value").getOrThrow().isNull, true)
                }
            }
            @Expect(foundExample, true)
        }
    }

    @TestCase
    func longValidRequestsProduceUsableBoundContinuation(): Unit {
        let term = StringBuilder()
        for (_ in 0..600) { term.append(" ") }
        term.append("catalogue")
        for (_ in 0..600) { term.append(" ") }
        let request = JsonNode.object()
        request.put("operation", JsonNode.string("search"))
        request.put("query", JsonNode.string(term.toString()))
        request.put("limit", JsonNode.int64(1))
        let query = session()
        let first = queryResult(query, request.toJson())
        let next = first.get("completeness").getOrThrow().asObject().get("query").getOrThrow()
            .asObject().get("next").getOrThrow().asString()
        @Expect(next.size <= 1024, true)
        request.put("cursor", JsonNode.string(next))
        let second = queryResult(query, request.toJson())
        @Expect(second.get("status").getOrThrow().asString(),
            first.get("status").getOrThrow().asString())
        let firstItem = first.get("result").getOrThrow().asObject().get("items").getOrThrow()
            .asArray()[0].asObject()
        let secondItem = second.get("result").getOrThrow().asObject().get("items").getOrThrow()
            .asArray()[0].asObject()
        @Expect(firstItem.get("identity").getOrThrow().toJson() !=
            secondItem.get("identity").getOrThrow().toJson(), true)
    }

    @TestCase
    func malformedRequestsAndStaleCursorsAreMachineReadable(): Unit {
        let query = session()
        let invalid = queryResult(query, "{\"operation\":\"search\",\"unknownField\":true}")
        @Expect(invalid.get("status").getOrThrow().asString(), "invalid_request")
        @Expect(invalid.get("error").getOrThrow().asObject().get("code").getOrThrow().asString(),
            "unknown_field")
        @Expect(documentationQueryExitCode(invalid.toJson()), 2)
        @Expect(documentationQueryExitCode(
            "{\"schemaVersion\":\"cjdoc.query-result/1\",\"status\":\"ambiguous\"}"), 0)
        let broken = queryResult(query, "{not json")
        @Expect(broken.get("status").getOrThrow().asString(), "invalid_request")
        // Continuation is bound to the exact request and the frozen content.
        let first = queryResult(query, "{\"operation\":\"search\",\"query\":\"catalogue\",\"limit\":1}")
        let items = first.get("result").getOrThrow().asObject().get("items").getOrThrow().asArray()
        @Expect(items.size(), 1)
        let next = first.get("completeness").getOrThrow().asObject().get("query").getOrThrow()
            .asObject().get("next").getOrThrow().asString()
        let second = queryResult(query, "{\"operation\":\"search\",\"query\":\"catalogue\"," +
            "\"limit\":1,\"cursor\":\"${next}\"}")
        @Expect(second.get("status").getOrThrow().asString(),
            first.get("status").getOrThrow().asString())
        let firstKey = items[0].asObject().get("identity").getOrThrow().asObject()
            .get("symbolKey").getOrThrow().asString()
        let secondItems = second.get("result").getOrThrow().asObject().get("items").getOrThrow()
            .asArray()
        @Expect(secondItems.size(), 1)
        let secondKey = secondItems[0].asObject().get("identity").getOrThrow().asObject()
            .get("symbolKey").getOrThrow().asString()
        @Expect(firstKey != secondKey, true)
        // A changed filter invalidates the old continuation explicitly.
        let widened = queryResult(query, "{\"operation\":\"search\",\"query\":\"catalogue\"," +
            "\"limit\":2,\"cursor\":\"${next}\"}")
        @Expect(widened.get("status").getOrThrow().asString(), "stale_cursor")
        // A changed snapshot identity invalidates it as well.
        let otherSnapshot = queryResult(query,
            "{\"operation\":\"search\",\"query\":\"catalogue\",\"limit\":1," +
            "\"snapshotId\":\"cjdoc:snapshot:v1:other\",\"cursor\":\"${next}\"}")
        @Expect(otherSnapshot.get("status").getOrThrow().asString(), "scope_mismatch")
        // Zero is a requested page size, not an absence result.
        let zero = queryResult(query, "{\"operation\":\"search\",\"query\":\"catalogue\",\"limit\":0}")
        @Expect(zero.get("result").getOrThrow().asObject().get("items").getOrThrow()
            .asArray().size(), 0)
        @Expect(zero.get("completeness").getOrThrow().asObject().get("query").getOrThrow()
            .asObject().get("next").getOrThrow().isNull, true)
    }

    @TestCase
    func getSymbolReportsMissingDocumentationWithoutInventingIt(): Unit {
        let query = session()
        let result = queryResult(query,
            "{\"operation\":\"get_symbol\",\"symbolId\":\"${opaqueId()}\",\"preset\":\"summary\"}")
        @Expect(result.get("status").getOrThrow().asString(), "ok")
        let content = result.get("completeness").getOrThrow().asObject().get("content")
            .getOrThrow().asObject()
        let missing = content.get("missingSections").getOrThrow().asArray()
        var sawDescriptionMissing = false
        for (index in 0..missing.size()) {
            if (missing[index].asString() == "description") { sawDescriptionMissing = true }
        }
        @Expect(sawDescriptionMissing, true)
        let text = result.get("text").getOrThrow().asString()
        @Expect(text.contains("## Signature"), true)
        @Expect(text.contains("public func opaque(): Unit"), true)
    }

    @TestCase
    func ambiguousIdentityAcrossScopesIsARegularResult(): Unit {
        let first = queryDocumentation()
        let second = queryDocumentation(projectName: "query-fixture-second")
        // Distinct captured content produces a distinct snapshot identity.
        let query = DocumentationQuerySession([first, second])
        let result = queryResult(query, "{\"operation\":\"get_symbol\",\"symbolId\":\"${addIntId()}\"}")
        @Expect(result.get("status").getOrThrow().asString(), "ambiguous")
        let items = result.get("result").getOrThrow().asObject().get("items").getOrThrow().asArray()
        @Expect(items.size(), 2)
        let snapshots = HashSet<String>()
        for (index in 0..items.size()) {
            let identity = items[index].asObject().get("identity").getOrThrow().asObject()
            let _ = snapshots.add(identity.get("snapshotId").getOrThrow().asString())
        }
        @Expect(snapshots.size, 2)
        // Naming one snapshot resolves it exactly.
        let only = queryResult(query, "{\"operation\":\"get_symbol\",\"symbolId\":\"${addIntId()}\"," +
            "\"snapshotId\":\"${api_render.documentationSnapshotId(first)}\"}")
        @Expect(only.get("status").getOrThrow().asString(), "ok")
        let unknown = queryResult(query, "{\"operation\":\"get_symbol\",\"symbolId\":\"${addIntId()}\"," +
            "\"snapshotId\":\"cjdoc:snapshot:v1:not-loaded\"}")
        @Expect(unknown.get("status").getOrThrow().asString(), "scope_mismatch")
    }

    @TestCase
    func conceptsCarryPageIdentityOnlyAndRelationsStayBounded(): Unit {
        let query = session()
        let missingPage = queryResult(query,
            "{\"operation\":\"get_symbol\",\"pageId\":\"fixture:page:absent\"}")
        @Expect(missingPage.get("status").getOrThrow().asString(), "not_found")
        let relations = queryResult(query, "{\"operation\":\"get_symbol\",\"symbolId\":\"${addIntId()}\"," +
            "\"sections\":[\"signature\",\"relations\"]," +
            "\"relations\":{\"depth\":1,\"limit\":2,\"direction\":\"both\"}}")
        @Expect(relations.get("status").getOrThrow().asString(), "ok")
        let owned = relations.get("result").getOrThrow().asObject().get("relations").getOrThrow()
            .asArray()
        @Expect(owned.size() <= 2, true)
        if (owned.size() > 0) {
            let edge = owned[0].asObject()
            @Expect(edge.get("kind").getOrThrow().asString(), "owner")
            let target = edge.get("to").getOrThrow().asObject()
            @Expect(target.get("symbolId").getOrThrow().asString(), catalogId())
            @Expect(target.get("pageId").getOrThrow().isNull, true)
        }
        // Depth 0 is an explicit omission with a real retry, not an empty success.
        let noDepth = queryResult(query, "{\"operation\":\"get_symbol\",\"symbolId\":\"${addIntId()}\"," +
            "\"sections\":[\"signature\",\"relations\"],\"relations\":{\"depth\":0}}")
        let omitted = noDepth.get("completeness").getOrThrow().asObject().get("content")
            .getOrThrow().asObject().get("omittedSections").getOrThrow().asArray()
        var sawDepth = false
        for (index in 0..omitted.size()) {
            let value = omitted[index].asObject()
            if (value.get("reason").getOrThrow().asString() == "relation_depth") { sawDepth = true }
            @Expect(value.get("next").getOrThrow().isNull, false)
        }
        @Expect(sawDepth, true)
    }

    @TestCase
    func conceptualPageBudgetRetriesTheIntactCapturedPage(): Unit {
        let query = session()
        let small = queryResult(query, "{\"operation\":\"get_symbol\",\"pageId\":\"query-guide\"," +
            "\"sections\":[\"description\"],\"maxBytes\":1024}")
        @Expect(small.get("status").getOrThrow().asString(), "budget_exceeded")
        let required = small.get("error").getOrThrow().asObject().get("requiredBytes").getOrThrow().asInt64()
        let retried = queryResult(query, "{\"operation\":\"get_symbol\",\"pageId\":\"query-guide\"," +
            "\"sections\":[\"description\"],\"maxBytes\":${required}}")
        @Expect(retried.get("status").getOrThrow().asString(), "ok")
        let item = retried.get("result").getOrThrow().asObject().get("items").getOrThrow().asArray()[0].asObject()
        let identity = item.get("identity").getOrThrow().asObject()
        @Expect(identity.get("symbolId").getOrThrow().isNull, true)
        @Expect(identity.get("pageId").getOrThrow().asString(), "query-guide")
        let page = item.get("sections").getOrThrow().asArray()[0].asObject().get("value").getOrThrow().asObject()
        @Expect(page.get("text").getOrThrow().asString(), queryGuidePage().text)
        @Expect(page.get("markdown").getOrThrow().asObject().get("kind").getOrThrow().asString(), "document")
        let sourceOnly = queryResult(query, "{\"operation\":\"get_symbol\",\"pageId\":\"query-guide\"," +
            "\"sections\":[\"source\"],\"maxBytes\":1024}")
        @Expect(sourceOnly.get("text").getOrThrow().asString().contains("Guide body keeps Unicode"), false)
        let sourceItem = sourceOnly.get("result").getOrThrow().asObject().get("items").getOrThrow().asArray()[0].asObject()
        @Expect(sourceItem.get("source").getOrThrow().asObject().get("url").getOrThrow().isNull, true)
        let invalid = queryResult(query, "{\"operation\":\"get_symbol\",\"pageId\":\"query-guide\"," +
            "\"sections\":[\"parameters\"]}")
        @Expect(invalid.get("status").getOrThrow().asString(), "invalid_request")
    }

    @TestCase
    func exitCodeAcceptsResultsAboveTheGenericJsonBufferDefault(): Unit {
        let payload = String.fromUtf8(Array<Byte>(9 * 1024 * 1024, repeat: b'x'))
        let result = JsonNode.object()
        result.put("schemaVersion", JsonNode.string("cjdoc.query-result/1"))
        result.put("status", JsonNode.string("ok"))
        result.put("text", JsonNode.string(payload))
        @Expect(documentationQueryExitCode(result.toJson()), 0)
    }

    @TestCase
    func sameInputProducesTheSameResultAndReportsItsCatalog(): Unit {
        let query = session()
        let request = "{\"operation\":\"search\",\"name\":\"add\"}"
        let first = query.execute(request)
        let second = query.execute(request)
        @Expect(first, second)
        let result = JsonNode.parse(first).asObject()
        let scope = result.get("scope").getOrThrow().asObject()
        @Expect(scope.get("catalogId").getOrThrow().asString().startsWith("cjdoc:catalog:v1:"), true)
        let snapshots = scope.get("snapshots").getOrThrow().asArray()
        @Expect(snapshots.size(), 1)
        @Expect(snapshots[0].asObject().get("sourceKind").getOrThrow().asString(), "public-model")
        @Expect(result.get("schemaVersion").getOrThrow().asString(), "cjdoc.query-result/1")
    }
}
