package cjdoc

import cjdoc.model as query_model
import cjdoc.render as query_render
import std.collection.*
import yjson.*

// A hash-valid package must also describe exactly the captured publication's
// representation graph. Arbitrary or missing routes cannot become citations.
internal func validateQueryRepresentationGraph(manifest: JsonObject,
    snapshot: query_render.DocumentationReadSnapshot, resources: HashSet<String>): Unit {
    let expected = JsonNode.parse(query_render.agentRepresentationMappings(snapshot)).asArray()
    let actual = manifest.get("representations").getOrThrow()
    if (queryCanonical(expected) != queryCanonical(actual)) {
        throw DocumentationQueryException("unavailable", "representation_projection_mismatch",
            "The representation mapping is not the complete projection of the captured Doc IR.")
    }
    let scope = StringBuilder()
    query_render.appendAgentReadingScope(scope, snapshot, Option<String>.None)
    if (queryCanonical(JsonNode.parse(scope.toString())) !=
        queryCanonical(manifest.get("scope").getOrThrow())) {
        throw DocumentationQueryException("unavailable", "scope_projection_mismatch",
            "The package scope contradicts the captured reading projection.")
    }
    let sets = JsonNode.array()
    for (module in snapshot.documentation.modules) {
        if (let Some(identity) <- snapshot.documentSetForModule(module.id)) {
            sets.add(queryDocumentSetNode(identity))
        }
    }
    if (queryCanonical(sets) != queryCanonical(manifest.get("documentSets").getOrThrow())) {
        throw DocumentationQueryException("unavailable", "document_sets_projection_mismatch",
            "The package document sets contradict their captured module identities.")
    }
    let expectedPaths = HashSet<String>()
    expectedPaths.add(queryString(manifest.get("docIr").getOrThrow().asObject(), "path"))
    expectedPaths.add(queryString(manifest.get("symbolIndex").getOrThrow().asObject(), "path"))
    for (index in 0..expected.size()) {
        let entry = expected[index].asObject()
        for (kind in ["markdown", "json"]) {
            let path = queryString(entry, kind)
            if (!expectedPaths.add(path)) {
                throw DocumentationQueryException("unavailable", "duplicate_representation_path",
                    "Independent readable representations cannot share one resource path.")
            }
        }
    }
    let reports = manifest.get("reports").getOrThrow().asArray()
    for (index in 0..reports.size()) {
        if (!expectedPaths.add(queryString(reports[index].asObject(), "path"))) {
            throw DocumentationQueryException("unavailable", "duplicate_report_path",
                "A report cannot replace another packaged resource.")
        }
    }
    if (expectedPaths.size != resources.size) {
        throw DocumentationQueryException("unavailable", "resource_graph_mismatch",
            "The immutable resource inventory is not the complete representation graph.")
    }
    for (path in expectedPaths) {
        if (!resources.contains(path)) {
            throw DocumentationQueryException("unavailable", "representation_resource_missing",
                "A declared readable representation is absent from the resource inventory.")
        }
    }
}
