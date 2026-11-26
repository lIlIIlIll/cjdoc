protected package cjdoc.query

import cjdoc.model as query_model
import cjdoc.render as query_render
import std.collection.*
import yjson.*
private func queryCapturedSourceRange(node: JsonNode): query_model.SourceRange {
    let object = node.asObject()
    let start = object.get("start").getOrThrow().asObject()
    let end = object.get("end").getOrThrow().asObject()
    query_model.SourceRange(queryString(object, "path"),
        query_model.SourcePosition(queryInt(start, "line"), queryInt(start, "column"),
            queryInt(start, "byteOffset")),
        query_model.SourcePosition(queryInt(end, "line"), queryInt(end, "column"),
            queryInt(end, "byteOffset")))
}

// Query results expose the visible name and targets. The imported spelling is
// evidence for replaying Doc IR, not part of query-result/5's binding shape.
private func queryReExportProjection(captured: JsonObject): JsonObject {
    let result = JsonNode.object()
    for (index in 0..captured.size()) {
        let key = captured.nameAt(index)
        if (key != "bindings") {
            result.put(key, captured.valueAt(index))
            continue
        }
        let bindings = captured.valueAt(index).asArray()
        let projected = JsonNode.array()
        for (position in 0..bindings.size()) {
            let binding = bindings[position].asObject()
            let row = JsonNode.object()
            row.put("exposedName", binding.get("exposedName").getOrThrow())
            row.put("targetSymbolIds", binding.get("targetSymbolIds").getOrThrow())
            projected.add(row)
        }
        result.put(key, projected)
    }
    result
}


internal func queryCapturedImportContexts(raw: JsonObject,
    snapshot: query_render.DocumentationReadSnapshot): JsonArray {
    let contexts = JsonNode.array()
    let packages = raw.get("packages").getOrThrow().asArray()
    for (index in 0..packages.size()) {
        let packageNode = packages[index].asObject()
        let moduleId = queryString(packageNode, "moduleId")
        let imports = packageNode.get("reExports").getOrThrow().asArray()
        for (position in 0..imports.size()) {
            let context = JsonNode.object()
            context.put("moduleId", JsonNode.string(moduleId))
            context.put("packageName", packageNode.get("name").getOrThrow())
            context.put("documentSet", match (snapshot.documentSetForModule(moduleId)) {
                case Some(value) => queryDocumentSetNode(value)
                case None => JsonNode.nullValue
            })
            // Keep unresolved and ambiguous records without claiming a target.
            let reExport = imports[position].asObject()
            context.put("reExport", queryReExportProjection(reExport))
            let sourceRange = queryCapturedSourceRange(
                reExport.get("source").getOrThrow())
            context.put("source", JsonNode.parse(query_render.sourceReferenceJson(
                snapshot.sourceReference(moduleId, sourceRange))))
            contexts.add(context)
        }
    }
    contexts
}

internal func queryBuildExposureIndex(document: QueryDocument): Unit {
    let contexts = document.input.importContexts
    for (index in 0..contexts.size()) {
        let context = contexts[index].asObject()
        let reExport = context.get("reExport").getOrThrow().asObject()
        if (queryString(reExport, "state") != "resolved") { continue }
        let bindings = reExport.get("bindings").getOrThrow().asArray()
        for (position in 0..bindings.size()) {
            let binding = bindings[position].asObject()
            let name = queryString(binding, "exposedName")
            let targets = document.aliases.get(name).getOrDefault({ => ArrayList<String>() })
            let ids = binding.get("targetSymbolIds").getOrThrow().asArray()
            for (target in 0..ids.size()) {
                let id = ids[target].asString()
                if (!document.visibleIds.contains(id)) { continue }
                if (!targets.contains(id)) { targets.add(id) }
                let exposure = JsonNode.object()
                exposure.put("kind", JsonNode.string("reexport"))
                exposure.put("alias", JsonNode.string(name))
                exposure.put("exposedName", JsonNode.string(name))
                exposure.put("symbolId", JsonNode.string(id))
                exposure.put("snapshotId", JsonNode.string(document.input.snapshot.snapshotId))
                exposure.put("state", JsonNode.string("resolved"))
                exposure.put("declaringModuleId", context.get("moduleId").getOrThrow())
                exposure.put("declaringPackage", context.get("packageName").getOrThrow())
                exposure.put("documentSet", context.get("documentSet").getOrThrow())
                exposure.put("reExport", reExport)
                exposure.put("source", context.get("source").getOrThrow())
                let values = document.exposures.get(id).getOrDefault({ => JsonNode.array() })
                values.add(exposure)
                document.exposures[id] = values
            }
            if (!targets.isEmpty()) { document.aliases[name] = targets }
        }
    }
}

internal func queryCapturedRelations(input: QuerySnapshotInput,
    symbol: query_model.SymbolDoc): JsonObject {
    let captured = input.symbolNodes[symbol.id]
    let value = JsonNode.object()
    value.put("ownerId", queryNullable(symbol.ownerId))
    value.put("typeRelationships", captured.get("typeRelationships").getOrThrow())
    value.put("symbolRelationships", captured.get("symbolRelationships").getOrThrow())
    value.put("packageImportContext", input.importContexts)
    value
}
