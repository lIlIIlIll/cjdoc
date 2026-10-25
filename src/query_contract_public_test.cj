package cjdoc

import cjdoc.model.*
import cjdoc.model as api_model
import cjdoc.schema_data as query_schema
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_algorithms.*

// Consumer-visible contract tests for the query operation surface and the
// resolve_docs selection path. They run the public session, assert the machine
// status/error codes a client branches on, and validate real results against
// the published response schema rather than against source strings.

private let CONTRACT_MODULE_A = "cjdoc:module:v1:pocketkit-0.2.1"
private let CONTRACT_MODULE_B = "cjdoc:module:v1:pocket-support-0.1.0"
private let CONTRACT_SYMBOL_A = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Apocketkit-0.2.1::fixture::class:Catalog#g0()"

private func contractRange(line: Int64, path!: String = "src/api.cj"): SourceRange {
    SourceRange(path, SourcePosition(line, 1, 0), SourcePosition(line, 40, 39))
}

private func contractSymbol(id: String, name: String, moduleId: String,
    packageName: String, sourcePath!: String = "src/api.cj"): api_model.SymbolDoc {
    api_model.SymbolDoc(id, "class", name, packageName + "." + name, packageName, moduleId,
        "public", contractRange(1, path: sourcePath), "public class " + name,
        SemanticInfo("partial", "ast"))
}

private func contractDocumentation(projectName!: String = "query-contract-fixture"): api_model.DocumentationSet {
    let a = contractSymbol(CONTRACT_SYMBOL_A,
        "Catalog", CONTRACT_MODULE_A, "fixture")
    let b = contractSymbol("cjdoc:v2:cjdoc%3Amodule%3Av1%3Apocket-support-0.1.0::fixture::class:Label#g0()",
        "Label", CONTRACT_MODULE_B, "fixture", sourcePath: "dependencies/support/src/api.cj")
    // Captured evidence is padded so one candidate record is comfortably larger
    // than the smallest permitted content budget; the budget test then exercises
    // a real boundary instead of assuming a size.
    let evidence = StringBuilder()
    for (_ in 0..40) { evidence.append("captured source evidence for the selected dependency. ") }
    api_model.DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
        ProjectInfo(projectName),
        ConfigurationSnapshot(lintProfile: "off"), documentationRevision: "revision-1",
        providers: [
            ProviderInfo("ast", "builtin", CONTRACT_MODULE_A, "partial",
                api_model.SemanticCapabilities(false, false, false, false, false)),
            ProviderInfo("ast", "builtin", CONTRACT_MODULE_B, "partial",
                api_model.SemanticCapabilities(false, false, false, false, false))],
        modules: [
            api_model.ModuleDoc(CONTRACT_MODULE_A, "pocketkit", "root", "",
                packageNames: ["fixture"]),
            api_model.ModuleDoc(CONTRACT_MODULE_B, "pocket-support", "pathDependency", "",
                packageNames: ["fixture"])
        ],
        packages: [
            api_model.PackageDoc("fixture", CONTRACT_MODULE_A, sourceFiles: ["src/api.cj"],
                symbolIds: [a.id]),
            api_model.PackageDoc("fixture", CONTRACT_MODULE_B, sourceFiles: ["dependencies/support/src/api.cj"],
                symbolIds: [b.id])
        ],
        files: [FileDoc("src/api.cj", CONTRACT_MODULE_A, "fixture"),
            FileDoc("dependencies/support/src/api.cj", CONTRACT_MODULE_B, "fixture")],
        declarations: [a, b],
        dependencies: [
            DependencyInstance(CONTRACT_MODULE_A, "pocketkit", "instance-pocketkit",
                "source", "sha256:" + contractFingerprint("pocketkit-0.2.1"), "observed",
                evidence.toString(), version: "0.2.1"),
            DependencyInstance(CONTRACT_MODULE_B, "pocket-support", "instance-support",
                "source", "sha256:" + contractFingerprint("support-0.1.0"), "observed",
                evidence.toString(), version: "0.1.0")
        ])
}

private func contractSession(): DocumentationQuerySession {
    DocumentationQuerySession(contractDocumentation())
}

private func contractExecute(session: DocumentationQuerySession, request: String): JsonObject {
    queryDecodeResponse(session.execute(request))
}

private func contractStatus(result: JsonObject): String {
    queryString(result, "status")
}

private func contractErrorCode(result: JsonObject): String {
    match (result.get("error")) {
        case Some(node) => if (node.kind() == JsonKind.Object) { queryString(node.asObject(), "code") } else { "" }
        case None => ""
    }
}

private func contractSelection(result: JsonObject): JsonObject {
    result.get("selection").getOrThrow().asObject()
}

private func contractCandidateRows(result: JsonObject): JsonArray {
    contractSelection(result).get("candidates").getOrThrow().asArray()
}

private func contractSelectedRows(result: JsonObject): JsonArray {
    contractSelection(result).get("selected").getOrThrow().asArray()
}

private func contractPage(result: JsonObject): JsonObject {
    result.get("completeness").getOrThrow().asObject().get("query").getOrThrow().asObject()
}

private func contractContent(result: JsonObject): JsonObject {
    result.get("completeness").getOrThrow().asObject().get("content").getOrThrow().asObject()
}

private func contractOutputValidator(): JsonSchema {
    JsonSchema.parse(documentationQueryOutputSchema())
}

private func contractRequestValidator(): JsonSchema {
    JsonSchema.parse(query_schema.DOCUMENTATION_QUERY_REQUEST_SCHEMA)
}

private func contractIsValid(validator: JsonSchema, value: JsonNode): Bool {
    validator.validate(value).isEmpty()
}


@Test
class DocumentationQueryContractPublicTest {
    @TestCase
    func latestRequiresAnExplicitAliasEvenForOneAvailableVersion(): Unit {
        let session = contractSession()
        let unresolved = contractExecute(session,
            "{\"operation\":\"resolve_docs\",\"library\":\"pocketkit\",\"latest\":true}")
        @Expect(contractStatus(unresolved), "ambiguous")
        @Expect(contractSelectedRows(unresolved).size(), 0)
        @Expect(contractPage(unresolved).get("total").getOrThrow().asInt64(), 1)
        @Expect(contractIsValid(contractOutputValidator(), unresolved), true)
        let explicitScope = contractExecute(session,
            "{\"operation\":\"resolve_docs\",\"library\":\"pocketkit\"}")
        @Expect(contractStatus(explicitScope), "ok")
        @Expect(contractSelectedRows(explicitScope).size(), 1)
    }

    @TestCase
    func operationsRejectFieldsTheyDoNotHonour(): Unit {
        let session = contractSession()
        let cases: Array<(String, String)> = [
            ("{\"operation\":\"search\",\"query\":\"Catalog\",\"preset\":\"summary\"}",
                "field_not_applicable"),
            ("{\"operation\":\"search\",\"query\":\"Catalog\",\"maxBytes\":2048}",
                "field_not_applicable"),
            ("{\"operation\":\"search\",\"query\":\"Catalog\",\"pageId\":\"fixture:page:one\"}",
                "field_not_applicable"),
            ("{\"operation\":\"resolve_docs\",\"symbolId\":\"cjdoc:v2:x::fixture::class:Catalog#g0()\"}",
                "field_not_applicable"),
            ("{\"operation\":\"resolve_docs\",\"query\":\"pocketkit\",\"sections\":[\"signature\"]}",
                "field_not_applicable"),
            ("{\"operation\":\"get_symbol\",\"pageId\":\"fixture:page:one\",\"preset\":\"call\"}",
                "request_schema"),
            ("{\"operation\":\"get_symbol\",\"pageId\":\"fixture:page:one\",\"relations\":{\"depth\":1}}",
                "field_not_applicable"),
            ("{\"operation\":\"get_symbol\",\"pageId\":\"fixture:page:one\",\"cursor\":\"cjdoc.cursor/1:0:x\"}",
                "field_not_applicable"),
            ("{\"operation\":\"get_symbol\",\"pageId\":\"fixture:page:one\",\"sections\":[\"signature\"]}",
                "request_schema"),
            ("{\"operation\":\"get_symbol\",\"symbolId\":\"a\",\"symbolKey\":\"b\"}",
                "request_schema"),
            ("{\"operation\":\"search\",\"query\":\"Catalog\",\"unknownField\":true}",
                "unknown_field")
        ]
        for ((request, code) in cases) {
            let result = contractExecute(session, request)
            @Expect(contractStatus(result), "invalid_request")
            @Expect(contractErrorCode(result), code)
            @Expect(result.get("result").getOrThrow().asObject().get("items").getOrThrow()
                .asArray().size(), 0)
        }
        // A declared field is accepted by an operation that does honour it.
        let accepted = contractExecute(session,
            "{\"operation\":\"get_symbol\",\"symbolId\":\"${CONTRACT_SYMBOL_A}\"," +
            "\"preset\":\"summary\"}")
        @Expect(contractStatus(accepted), "ok")
        // The same request is rejected by the request schema itself, so a client
        // validating locally reaches the same conclusion.
        let invalid = JsonNode.parse("{\"operation\":\"search\",\"query\":\"Catalog\"," +
            "\"preset\":\"summary\"}")
        @Expect(contractIsValid(contractRequestValidator(), invalid), false)
    }

    @TestCase
    func toolSchemasValidateActualClientArgumentBoundaries(): Unit {
        let cases: Array<(String, String, Bool)> = [
            ("resolve_docs", "{\"library\":\"pocketkit\",\"maxBytes\":2048}", true),
            ("resolve_docs", "{\"symbolId\":\"a\"}", false),
            ("search", "{\"name\":\"Catalog\",\"limit\":1}", true),
            ("search", "{\"query\":\"Catalog\",\"preset\":\"call\"}", false),
            ("get_symbol", "{\"pageId\":\"guide\",\"sections\":[\"source\"]}", true),
            ("get_symbol", "{\"pageId\":\"guide\",\"preset\":\"call\"}", false),
            ("get_symbol", "{\"symbolId\":\"a\",\"symbolKey\":\"b\"}", false),
            ("get_symbol", "{\"symbolId\":\"a\",\"preset\":\"reference\",\"relations\":{\"depth\":1}}", true)
        ]
        for ((operation, arguments, expected) in cases) {
            let validator = JsonSchema.parse(documentationQueryToolSchema(operation))
            @Expect(contractIsValid(validator, JsonNode.parse(arguments)), expected)
        }
    }

    @TestCase
    func moduleContextAloneSelectsAndUnknownContextIsExplicit(): Unit {
        let session = contractSession()
        let ambiguous = contractExecute(session, "{\"operation\":\"resolve_docs\"}")
        @Expect(contractStatus(ambiguous), "ambiguous")
        @Expect(contractSelectedRows(ambiguous).size(), 0)
        @Expect(contractPage(ambiguous).get("total").getOrThrow().asInt64(), 2)
        let scoped = contractExecute(session,
            "{\"operation\":\"resolve_docs\",\"contextModuleId\":\"${CONTRACT_MODULE_A}\"}")
        @Expect(contractStatus(scoped), "ok")
        let selected = contractSelectedRows(scoped)
        @Expect(selected.size(), 1)
        let candidate = selected[0].asObject()
        let dependency = candidate.get("dependency").getOrThrow().asObject()
        @Expect(queryString(dependency, "instanceId"), "instance-pocketkit")
        @Expect(queryString(candidate.get("documentSet").getOrThrow().asObject(), "library"),
            "pocketkit")
        @Expect(contractPage(scoped).get("reason").getOrThrow().asString(),
            "explicit_captured_context")
        // An unknown module is a scope error, never a documentation-only guess.
        let unknown = contractExecute(session,
            "{\"operation\":\"resolve_docs\",\"contextModuleId\":\"cjdoc:module:v1:absent\"}")
        @Expect(contractStatus(unknown), "scope_mismatch")
        @Expect(contractErrorCode(unknown), "context_not_captured")
        @Expect(unknown.get("selection").getOrThrow().isNull, true)
        let missingSnapshot = contractExecute(session,
            "{\"operation\":\"resolve_docs\",\"contextSnapshotId\":\"cjdoc:snapshot:v1:absent\"}")
        @Expect(contractStatus(missingSnapshot), "scope_mismatch")
        // A named library that contradicts the captured context stays unmatched.
        let wrongLibrary = contractExecute(session,
            "{\"operation\":\"resolve_docs\",\"library\":\"pocket-support\"," +
            "\"contextModuleId\":\"${CONTRACT_MODULE_A}\"}")
        @Expect(contractStatus(wrongLibrary), "not_found")
        @Expect(contractSelectedRows(wrongLibrary).size(), 0)
    }

    @TestCase
    func resolveBudgetIsAHonestBoundaryWithoutFabricatedMatches(): Unit {
        let session = contractSession()
        let first = contractExecute(session,
            "{\"operation\":\"resolve_docs\",\"maxBytes\":1024}")
        @Expect(contractStatus(first), "budget_exceeded")
        @Expect(contractErrorCode(first), "candidate_exceeds_budget")
        @Expect(contractCandidateRows(first).size(), 0)
        @Expect(contractSelectedRows(first).size(), 0)
        let error = first.get("error").getOrThrow().asObject()
        let required = error.get("requiredBytes").getOrThrow().asInt64()
        @Expect(required > 1024, true)
        @Expect(error.get("maximumBytes").getOrThrow().asInt64(), 1024)
        let retry = contractContent(first).get("retry").getOrThrow().asObject()
        @Expect(retry.get("maxBytes").getOrThrow().asInt64(), required)
        @Expect(contractPage(first).get("returned").getOrThrow().asInt64(), 0)
        // The documented retry budget admits exactly one intact candidate; the
        // remaining candidates are a continuation, not an absence claim.
        let boundary = contractExecute(session,
            "{\"operation\":\"resolve_docs\",\"maxBytes\":${required}}")
        @Expect(contractStatus(boundary), "ambiguous")
        @Expect(contractCandidateRows(boundary).size(), 1)
        @Expect(contractPage(boundary).get("complete").getOrThrow().asBool(), false)
        let next = contractPage(boundary).get("next").getOrThrow().asString()
        @Expect(next.isEmpty(), false)
        let continued = contractExecute(session,
            "{\"operation\":\"resolve_docs\",\"maxBytes\":${required},\"cursor\":\"${next}\"}")
        @Expect(contractCandidateRows(continued).size(), 1)
        @Expect(contractPage(continued).get("complete").getOrThrow().asBool(), true)
        @Expect(contractPage(continued).get("next").getOrThrow().isNull, true)
        // Limit zero is a requested page size, not an absence result.
        let zero = contractExecute(session,
            "{\"operation\":\"resolve_docs\",\"limit\":0}")
        @Expect(contractCandidateRows(zero).size(), 0)
        @Expect(contractPage(zero).get("reason").getOrThrow().asString(), "zero_limit_is_not_absence")
        @Expect(contractPage(zero).get("next").getOrThrow().isNull, true)
    }

    @TestCase
    func selectedEvidenceCannotBypassTheCandidateBudget(): Unit {
        let session = contractSession()
        let blocked = contractExecute(session,
            "{\"operation\":\"resolve_docs\",\"library\":\"pocketkit\",\"maxBytes\":1024}")
        @Expect(contractStatus(blocked), "budget_exceeded")
        @Expect(contractCandidateRows(blocked).size(), 0)
        @Expect(contractSelectedRows(blocked).size(), 0)
        let required = blocked.get("error").getOrThrow().asObject()
            .get("requiredBytes").getOrThrow().asInt64()
        let retry = contractExecute(session,
            "{\"operation\":\"resolve_docs\",\"library\":\"pocketkit\",\"maxBytes\":${required}}")
        @Expect(contractStatus(retry), "ok")
        @Expect(contractSelectedRows(retry).size(), 1)
        @Expect(contractCandidateRows(retry).size(), 1)
        @Expect(queryString(contractSelectedRows(retry)[0].asObject()
            .get("documentSet").getOrThrow().asObject(), "apiVersion"), "0.2.1")
        @Expect(contractPage(retry).get("complete").getOrThrow().asBool(), true)
    }

    @TestCase
    func capturedContextNamespacesRemainDistinctAndCanBePinned(): Unit {
        let session = DocumentationQuerySession([
            contractDocumentation(projectName: "consumer-one"),
            contractDocumentation(projectName: "consumer-two")])
        let result = contractExecute(session, "{\"operation\":\"resolve_docs\"," +
            "\"library\":\"pocketkit\",\"contextModuleId\":\"${CONTRACT_MODULE_A}\"}")
        @Expect(contractStatus(result), "ambiguous")
        @Expect(result.get("error").getOrThrow().isNull, true)
        @Expect(contractSelectedRows(result).size(), 0)
        let contexts = HashSet<String>()
        let candidates = contractCandidateRows(result)
        for (index in 0..candidates.size()) {
            contexts.add(queryString(candidates[index].asObject(), "contextSnapshotId"))
        }
        @Expect(contexts.size, 2)
        let pair = candidates[0].asObject()
        let pinned = contractExecute(session, "{\"operation\":\"resolve_docs\"," +
            "\"library\":\"pocketkit\",\"contextModuleId\":\"${CONTRACT_MODULE_A}\"," +
            "\"snapshotId\":\"${queryString(pair, "snapshotId")}\"," +
            "\"contextSnapshotId\":\"${queryString(pair, "contextSnapshotId")}\"}")
        @Expect(contractStatus(pinned), "ok")
        @Expect(queryString(contractSelectedRows(pinned)[0].asObject(), "contextSnapshotId"),
            queryString(pair, "contextSnapshotId"))
        @Expect(contractIsValid(contractOutputValidator(), result), true)
    }

    @TestCase
    func separateCapturedConsumerSurvivesPinnedTargetSelection(): Unit {
        let session = DocumentationQuerySession([
            contractDocumentation(projectName: "separate-target"),
            contractDocumentation(projectName: "separate-consumer")])
        let discovery = contractExecute(session, "{\"operation\":\"resolve_docs\"," +
            "\"library\":\"pocketkit\",\"contextModuleId\":\"${CONTRACT_MODULE_A}\"}")
        let snapshots = discovery.get("scope").getOrThrow().asObject()
            .get("snapshots").getOrThrow().asArray()
        @Expect(snapshots.size(), 2)
        let targetId = queryString(snapshots[0].asObject(), "snapshotId")
        let consumerId = queryString(snapshots[1].asObject(), "snapshotId")
        @Expect(targetId != consumerId, true)
        let pinned = contractExecute(session, "{\"operation\":\"resolve_docs\"," +
            "\"library\":\"pocketkit\",\"contextModuleId\":\"${CONTRACT_MODULE_A}\"," +
            "\"snapshotId\":\"${targetId}\",\"contextSnapshotId\":\"${consumerId}\"}")
        @Expect(contractStatus(pinned), "ok")
        let selected = contractSelectedRows(pinned)
        @Expect(selected.size(), 1)
        @Expect(queryString(selected[0].asObject(), "snapshotId"), targetId)
        @Expect(queryString(selected[0].asObject(), "contextSnapshotId"), consumerId)
        let candidates = contractCandidateRows(pinned)
        for (index in 0..candidates.size()) {
            let candidate = candidates[index].asObject()
            @Expect(queryString(candidate, "snapshotId"), targetId)
            @Expect(queryString(candidate, "contextSnapshotId"), consumerId)
        }
        @Expect(contractIsValid(contractOutputValidator(), pinned), true)
    }

    @TestCase
    func producedResultsSatisfyThePublishedResponseSchema(): Unit {
        let session = contractSession()
        let validator = contractOutputValidator()
        let requests = [
            "{\"operation\":\"resolve_docs\"}",
            "{\"operation\":\"resolve_docs\",\"maxBytes\":1024}",
            "{\"operation\":\"resolve_docs\",\"contextModuleId\":\"${CONTRACT_MODULE_A}\"}",
            "{\"operation\":\"resolve_docs\",\"contextModuleId\":\"cjdoc:module:v1:absent\"}",
            "{\"operation\":\"search\",\"query\":\"Catalog\"}",
            "{\"operation\":\"search\",\"name\":\"Absent\"}",
            "{\"operation\":\"search\",\"query\":\"Catalog\",\"limit\":0}",
            "{\"operation\":\"get_symbol\",\"symbolId\":\"${CONTRACT_SYMBOL_A}\"}",
            "{\"operation\":\"get_symbol\",\"symbolId\":\"${CONTRACT_SYMBOL_A}\",\"maxBytes\":1024}",
            "{\"operation\":\"get_symbol\",\"symbolId\":\"cjdoc:v2:absent::fixture::class:Nope#g0()\"}",
            "{\"operation\":\"search\",\"query\":\"Catalog\",\"preset\":\"summary\"}",
            "{\"operation\":\"resolve_docs\",\"maxBytes\":1024,\"cursor\":\"cjdoc.cursor/1:0:x\"}",
            "{\"operation\":\"resolve_docs\",\"snapshotId\":\"cjdoc:snapshot:v1:absent\"}"
        ]
        for (request in requests) {
            let result = contractExecute(session, request)
            let violations = validator.validate(result)
            @Expect(violations.size, 0)
        }
    }

    @TestCase
    func responseSchemaRejectsMalformedResultVariants(): Unit {
        let session = contractSession()
        let validator = contractOutputValidator()
        let ok = contractExecute(session,
            "{\"operation\":\"get_symbol\",\"symbolId\":\"${CONTRACT_SYMBOL_A}\"}")
        @Expect(contractStatus(ok), "ok")
        @Expect(contractIsValid(validator, ok), true)
        let ambiguous = contractExecute(session, "{\"operation\":\"search\",\"query\":\"fixture\"}")
        @Expect(contractStatus(ambiguous), "ambiguous")
        @Expect(contractIsValid(validator, ambiguous), true)
        let missing = contractExecute(session, "{\"operation\":\"search\",\"name\":\"Absent\"}")
        @Expect(contractStatus(missing), "not_found")
        let budget = contractExecute(session,
            "{\"operation\":\"resolve_docs\",\"maxBytes\":1024}")
        @Expect(contractStatus(budget), "budget_exceeded")
        let failure = contractExecute(session, "{\"operation\":\"resolve_docs\"," +
            "\"contextModuleId\":\"cjdoc:module:v1:absent\"}")
        @Expect(contractStatus(failure), "scope_mismatch")

        // A required member is never optional.
        let dropped = queryDecodeResponse(ok.toJson())
        let _ = dropped.remove("text")
        @Expect(contractIsValid(validator, dropped), false)
        // An undeclared member is never tolerated.
        let extra = queryDecodeResponse(ok.toJson())
        extra.put("fabricated", JsonNode.boolean(true))
        @Expect(contractIsValid(validator, extra), false)

        // A documented outcome cannot carry an error object.
        let successWithError = queryDecodeResponse(ok.toJson())
        successWithError.put("error", queryErrorNode("fabricated", "not a real failure",
            Option<Int64>.None, Option<Int64>.None))
        @Expect(contractIsValid(validator, successWithError), false)
        // A failure always carries its machine-readable error.
        let failureWithoutError = queryDecodeResponse(failure.toJson())
        failureWithoutError.put("error", JsonNode.nullValue)
        @Expect(contractIsValid(validator, failureWithoutError), false)
        // Detail chapters cannot be replaced by discovery strings.
        let stringDetail = queryDecodeResponse(ok.toJson())
        let detailSections = stringDetail.get("result").getOrThrow().asObject()
            .get("items").getOrThrow().asArray()[0].asObject()
            .get("sections").getOrThrow().asArray()
        for (index in 0..detailSections.size()) {
            let section = detailSections[index].asObject()
            if (queryString(section, "name") == "signature") {
                section.put("value", JsonNode.string("public class Catalog"))
            }
        }
        @Expect(contractIsValid(validator, stringDetail), false)
        let noPrimaryItem = queryDecodeResponse(ok.toJson())
        noPrimaryItem.get("result").getOrThrow().asObject().put("items", JsonArray())
        @Expect(contractIsValid(validator, noPrimaryItem), false)
        // An absence claim cannot smuggle a fabricated item.
        if (ambiguous.get("result").getOrThrow().asObject().get("items").getOrThrow().asArray().size() > 0) {
            let absenceWithItem = queryDecodeResponse(ambiguous.toJson())
            absenceWithItem.put("status", JsonNode.string("not_found"))
            @Expect(contractIsValid(validator, absenceWithItem), false)
        }
        // A complete page cannot still advertise a continuation.
        let pageWithNext = queryDecodeResponse(ambiguous.toJson())
        pageWithNext.put("status", JsonNode.string("ok"))
        pageWithNext.put("error", JsonNode.nullValue)
        let queryPage = contractPage(pageWithNext)
        queryPage.put("complete", JsonNode.boolean(true))
        queryPage.put("next", JsonNode.string("cjdoc.cursor/1:1:deadbeef"))
        @Expect(contractIsValid(validator, pageWithNext), false)
        // A budget rejection must name a reachable retry budget.
        let budgetWithoutRetry = queryDecodeResponse(budget.toJson())
        contractContent(budgetWithoutRetry).put("retry", JsonNode.nullValue)
        @Expect(contractIsValid(validator, budgetWithoutRetry), false)
        // Only the declared resource omission reason is expressible.
        let badOmission = queryDecodeResponse(missing.toJson())
        let omitted = JsonNode.object()
        omitted.put("section", JsonNode.string("description"))
        omitted.put("reason", JsonNode.string("invented"))
        omitted.put("next", JsonNode.nullValue)
        contractContent(badOmission).get("omittedSections").getOrThrow().asArray().add(omitted)
        @Expect(contractIsValid(validator, badOmission), false)
        // A declared enumeration still accepts the documented resource omission.
        let goodOmission = queryDecodeResponse(missing.toJson())
        let allowedOmission = JsonNode.object()
        allowedOmission.put("section", JsonNode.string("description"))
        allowedOmission.put("reason", JsonNode.string("resource_limit"))
        allowedOmission.put("next", JsonNode.nullValue)
        contractContent(goodOmission).get("omittedSections").getOrThrow().asArray().add(allowedOmission)
        @Expect(contractIsValid(validator, goodOmission), true)
    }
}
