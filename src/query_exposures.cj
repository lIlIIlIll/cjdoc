package cjdoc

import cjdoc.model as query_model
import cjdoc.render as query_render
import std.collection.*
import yjson.*

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
            // The complete captured record includes unresolved/ambiguous imports.
            // This context does not assert a binding to any particular symbol.
            context.put("reExport", imports[position])
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
