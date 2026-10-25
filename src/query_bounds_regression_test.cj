package cjdoc

import cjdoc.model.*
import cjdoc.model as bounds_model
import cjdoc.render as bounds_render
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_algorithms.*

private let BOUNDS_MODULE = "cjdoc:module:v1:root"
private let BOUNDS_QUERY_SCHEMA = JsonSchema.parse(documentationQueryOutputSchema())

private func boundsSymbolId(index: Int64): String {
    "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aroot::bounded::class:Node${index}#g0()"
}

private func boundsDocumentation(revision: String, navigation!: ?bounds_model.TypeNavigation = None,
    dependencies!: Array<bounds_model.DependencyInstance> = [],
    documentSets!: Array<bounds_model.DocumentSetIdentity> = []): bounds_model.DocumentationSet {
    let declarations = ArrayList<bounds_model.SymbolDoc>()
    let ids = ArrayList<String>()
    let summary = StringBuilder()
    for (_ in 0..1024) { summary.append("Captured contract summary 汉. ") }
    for (index in 0..6) {
        let id = boundsSymbolId(index)
        ids.add(id)
        let edges: Array<bounds_model.SymbolRelationship> = if (index < 5) {
            [bounds_model.SymbolRelationship("related", "bounded.Node${index + 1}", "resolved",
                targetSymbolId: Some(boundsSymbolId(index + 1)))]
        } else { [] }
        let comment: ?bounds_model.DocComment = if (index == 0) {
            let text = summary.toString()
            Some(bounds_model.DocComment(text, text, "", MarkdownNode("document", children: [
                MarkdownNode("paragraph", children: [MarkdownNode("text", literal: text)])]),
                tags: if (let Some(value) <- navigation) {
                    [bounds_model.DocTag("see", "bounded.Node1", "Captured related declaration",
                        navigation: Some(value))]
                } else { [] }))
        } else { None }
        declarations.add(bounds_model.SymbolDoc(id, "class", "Node${index}", "bounded.Node${index}",
            "bounded", BOUNDS_MODULE, "public", SourceRange("src/bounded.cj",
                SourcePosition(index + 1, 1, 0), SourcePosition(index + 1, 30, 29)),
            "public class Node${index}", SemanticInfo("partial", "ast"),
            symbolRelationships: edges, documentation: comment))
    }
    bounds_model.DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("bounded"),
        ConfigurationSnapshot(lintProfile: "off"), documentationRevision: revision,
        providers: [ProviderInfo("ast", "builtin", BOUNDS_MODULE, "partial",
            bounds_model.SemanticCapabilities(false, false, false, false, false, relationships: true))],
        modules: [bounds_model.ModuleDoc(BOUNDS_MODULE, "bounded", "root", "", packageNames: ["bounded"])],
        packages: [bounds_model.PackageDoc("bounded", BOUNDS_MODULE,
            sourceFiles: ["src/bounded.cj"], symbolIds: ids.toArray())],
        files: [FileDoc("src/bounded.cj", BOUNDS_MODULE, "bounded")], declarations: declarations.toArray(),
        dependencies: dependencies, documentSets: documentSets)
}

private func boundsRequest(selector: String, identity: String): JsonObject {
    let request = JsonNode.object()
    request.put("operation", JsonNode.string("get_symbol"))
    request.put(selector, JsonNode.string(identity))
    request
}

private func boundsExecute(session: DocumentationQuerySession, request: JsonObject): JsonObject {
    let text = session.execute(request.toJson())
    let response = queryDecodeResponse(text)
    let violations = BOUNDS_QUERY_SCHEMA.validate(response)
    if (!violations.isEmpty()) {
        throw IllegalArgumentException("query result violates its schema at " + violations[0].instancePath)
    }
    response
}

private func boundsPage(response: JsonObject): JsonObject {
    response.get("completeness").getOrThrow().asObject().get("query").getOrThrow().asObject()
}

private func boundsContent(response: JsonObject): JsonObject {
    response.get("completeness").getOrThrow().asObject().get("content").getOrThrow().asObject()
}

@Test
class DocumentationQueryBoundsRegressionTest {
    @TestCase
    func relationContinuationNeverEmitsBeyondTheRequestedDepth(): Unit {
        let session = DocumentationQuerySession(boundsDocumentation("first"))
        for (depth in [1, 4]) {
            let request = boundsRequest("symbolId", boundsSymbolId(0))
            let sections = JsonNode.array()
            sections.add(JsonNode.string("relations"))
            request.put("sections", sections)
            let relations = JsonNode.object()
            relations.put("direction", JsonNode.string("outgoing"))
            relations.put("depth", JsonNode.int64(depth))
            relations.put("limit", JsonNode.int64(1))
            request.put("relations", relations)
            var observed: Int64 = 0
            while (observed < depth) {
                let response = boundsExecute(session, request)
                @Expect(queryString(response, "status"), "ok")
                let rows = response.get("result").getOrThrow().asObject().get("relations").getOrThrow().asArray()
                @Expect(rows.size(), 1)
                observed++
                @Expect(rows[0].asObject().get("depth").getOrThrow().asInt64(), observed)
                let page = boundsPage(response)
                if (observed < depth) {
                    @Expect(page.get("complete").getOrThrow().asBool(), false)
                    request.put("cursor", page.get("next").getOrThrow())
                } else {
                    @Expect(page.get("complete").getOrThrow().asBool(), true)
                    @Expect(page.get("next").getOrThrow().isNull, true)
                    @Expect(boundsContent(response).get("complete").getOrThrow().asBool(), false)
                    let omitted = boundsContent(response).get("omittedSections").getOrThrow().asArray()
                    var depthOmissions: Int64 = 0
                    for (index in 0..omitted.size()) {
                        let reason = queryString(omitted[index].asObject(), "reason")
                        if (reason == if (depth == 1) { "relation_depth" } else { "resource_limit" }) {
                            depthOmissions++
                        }
                    }
                    @Expect(depthOmissions, 1)
                }
            }
        }
    }

    @TestCase
    func ambiguousIdentitiesUseIntactBudgetedCandidatePages(): Unit {
        let session = DocumentationQuerySession([boundsDocumentation("first"), boundsDocumentation("other")])
        for ((selector, identity) in [("symbolId", boundsSymbolId(0)),
            ("symbolKey", portableSymbolKey("bounded", "bounded.Node0", "class", 0))]) {
            let request = boundsRequest(selector, identity)
            request.put("maxBytes", JsonNode.int64(1024))
            let rejected = boundsExecute(session, request)
            @Expect(queryString(rejected, "status"), "budget_exceeded")
            @Expect(boundsPage(rejected).get("returned").getOrThrow().asInt64(), 0)
            let required = rejected.get("error").getOrThrow().asObject().get("requiredBytes").getOrThrow().asInt64()
            @Expect(required > 1024, true)
            @Expect(boundsContent(rejected).get("retry").getOrThrow().asObject()
                .get("maxBytes").getOrThrow().asInt64(), required)
            request.put("maxBytes", JsonNode.int64(required))
            let seen = HashSet<String>()
            for (pageIndex in 0..2) {
                let response = boundsExecute(session, request)
                @Expect(queryString(response, "status"), "ambiguous")
                let rows = response.get("result").getOrThrow().asObject().get("items").getOrThrow().asArray()
                @Expect(rows.size(), 1)
                let item = rows[0].asObject()
                @Expect(queryString(item, "signature"), "public class Node0")
                let snapshot = queryString(item.get("identity").getOrThrow().asObject(), "snapshotId")
                @Expect(seen.add(snapshot), true)
                let page = boundsPage(response)
                @Expect(page.get("complete").getOrThrow().asBool(), pageIndex == 1)
                if (pageIndex == 0) { request.put("cursor", page.get("next").getOrThrow()) }
                else { @Expect(page.get("next").getOrThrow().isNull, true) }
            }
        }
    }

    @TestCase
    func publicationWhitespaceNeverChangesQuotedSourceContracts(): Unit {
        let original = "汉 \\\"quoted\\\" \\\\ tail\n"
        let token = JsonNode.string(original).toJson()
        let compact = "{\"contract\":" + token + "}"
        let formatted = "{\r\n\t\"contract\"\t: " + token + "\r\n}\n"
        @Expect(queryEncodedProjectionMatches(formatted, compact), true)
        @Expect(queryEncodedProjectionMatches(compact, formatted), true)
        @Expect(queryEncodedProjectionMatches(formatted,
            compact.replace("quoted", "quote d")), false)
        let changedEscapes = "{\"contract\":" +
            JsonNode.string("汉 \"quoted\" \\\\ tail\n").toJson() + "}"
        @Expect(queryEncodedProjectionMatches(formatted, changedEscapes), false)
    }
}

private let RELATION_CONTEXT_API = "sha256:1111111111111111111111111111111111111111111111111111111111111111"
private let RELATION_CONTEXT_INDEX = "2222222222222222222222222222222222222222222222222222222222222222"

private func boundsContextDependencies(target: String, cfg: String,
    standardIdentity!: String = "", complete!: Bool = true): Array<bounds_model.DependencyInstance> {
    let rows = ArrayList<bounds_model.DependencyInstance>([
        bounds_model.DependencyInstance(BOUNDS_MODULE, "bounded", "relation-self", "source",
            RELATION_CONTEXT_API, "observed", "controlled source context", version: "1.0",
            target: target, cfg: cfg, componentModuleId: BOUNDS_MODULE)
    ])
    for (kind in ["std", "stdx", "toolchain"]) {
        if (!complete && kind == "stdx") { continue }
        let identity = if (kind == "std") { standardIdentity } else { "" }
        rows.add(bounds_model.DependencyInstance(BOUNDS_MODULE, kind, "relation-" + kind, kind,
            identity, if (identity.isEmpty()) { "unknown" } else { "observed" },
            "controlled captured build input", target: target, cfg: cfg))
    }
    rows.toArray()
}

private func boundsRelatedContextEdge(target: String, cfg: String,
    standardIdentity: String, complete: Bool, matchLevel: String): JsonObject {
    let captured = bounds_model.DocumentSetIdentity("captured-relation-docs", "bounded",
        RELATION_CONTEXT_API, "declared", "source-snapshot", target: "target-a", cfg: "cfg-a",
        language: "en", indexIdentity: RELATION_CONTEXT_INDEX, moduleId: BOUNDS_MODULE,
        apiVersion: "1.0", documentationRevision: "captured")
    let navigation = bounds_model.TypeNavigation("resolved", matchLevel, "captured navigation",
        dependencyInstanceId: "relation-self", documentSetId: captured.id,
        indexIdentity: captured.indexIdentity, symbolKey: portableSymbolKey("bounded", "bounded.Node1", "class", 0),
        url: "symbols/related.html", apiIdentity: RELATION_CONTEXT_API, language: "en")
    let consumer = boundsDocumentation("consumer", navigation: Some(navigation), documentSets: [captured],
        dependencies: boundsContextDependencies("target-a", "cfg-a"))
    let related = boundsDocumentation("related", dependencies: boundsContextDependencies(target, cfg,
        standardIdentity: standardIdentity, complete: complete))
    let session = DocumentationQuerySession([consumer, related])
    let request = boundsRequest("symbolId", boundsSymbolId(0))
    request.put("snapshotId", JsonNode.string(bounds_render.DocumentationReadSnapshot(consumer).snapshotId))
    let snapshots = JsonNode.array()
    snapshots.add(JsonNode.string(bounds_render.DocumentationReadSnapshot(related).snapshotId))
    request.put("relatedSnapshotIds", snapshots)
    let sections = JsonNode.array()
    sections.add(JsonNode.string("relations"))
    request.put("sections", sections)
    let relations = JsonNode.object()
    relations.put("direction", JsonNode.string("outgoing"))
    relations.put("depth", JsonNode.int64(1))
    relations.put("limit", JsonNode.int64(100))
    request.put("relations", relations)
    let response = boundsExecute(session, request)
    if (queryString(response, "status") != "ok") {
        throw IllegalStateException("relation fixture query failed: " + response.toJson())
    }
    let rows = response.get("result").getOrThrow().asObject().get("relations").getOrThrow().asArray()
    let capturedEdges = ArrayList<JsonObject>()
    for (index in 0..rows.size()) {
        let row = rows[index].asObject()
        if (queryString(row, "kind") == "see") { capturedEdges.add(row) }
    }
    if (capturedEdges.size != 1) { throw IllegalStateException("captured relation was lost or duplicated") }
    capturedEdges[0]
}

@Test
class DocumentationQueryRelationContextTest {
    @TestCase
    func matchingRelatedContextPreservesTheCapturedNavigationGrade(): Unit {
        for (grade in ["exact", "compatible", "manual"]) {
            let edge = boundsRelatedContextEdge("target-a", "cfg-a", "", true, grade)
            @Expect(queryString(edge, "state"), "resolved")
            @Expect(!edge.get("to").getOrThrow().isNull, true)
            @Expect(queryString(edge.get("navigation").getOrThrow().asObject(), "matchLevel"), grade)
        }
    }

    @TestCase
    func differentOrIncompleteRelatedContextsNeverInheritNavigationEvidence(): Unit {
        for ((target, cfg, standard, complete) in [
            ("target-b", "cfg-a", "", true),
            ("target-a", "cfg-b", "", true),
            ("target-a", "cfg-a", "different-std-build", true),
            ("target-a", "cfg-a", "", false)
        ]) {
            for (grade in ["exact", "compatible", "manual"]) {
                let edge = boundsRelatedContextEdge(target, cfg, standard, complete, grade)
                @Expect(queryString(edge, "state"), "unavailable")
                @Expect(edge.get("to").getOrThrow().isNull, true)
                @Expect(queryString(edge.get("navigation").getOrThrow().asObject(), "matchLevel"), grade)
            }
        }
    }
}
