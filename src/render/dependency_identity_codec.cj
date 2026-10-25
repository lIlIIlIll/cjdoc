package cjdoc.render

import cjdoc.model.*
import std.collection.*
import yjson.*

protected func appendDependencyInstance(out: StringBuilder, value: DependencyInstance): Unit {
    out.append("{\"moduleId\":${escapeJsonString(value.moduleId)},\"componentModuleId\":${escapeJsonString(value.componentModuleId)},\"name\":${escapeJsonString(value.name)},\"instanceId\":${escapeJsonString(value.instanceId)},\"kind\":${escapeJsonString(value.kind)},\"identity\":${escapeJsonString(value.identity)},\"state\":${escapeJsonString(value.state)},\"evidence\":${escapeJsonString(value.evidence)},\"version\":${escapeJsonString(value.version)},\"revision\":${escapeJsonString(value.revision)},\"target\":${escapeJsonString(value.target)},\"cfg\":${escapeJsonString(value.cfg)}")
    out.append("}")
}

protected func appendDocumentSetIdentity(out: StringBuilder, value: DocumentSetIdentity): Unit {
    out.append("{\"id\":${escapeJsonString(value.id)},\"moduleId\":${escapeJsonString(value.moduleId)},\"library\":${escapeJsonString(value.library)},\"identity\":${escapeJsonString(value.identity)},\"state\":${escapeJsonString(value.state)},\"source\":${escapeJsonString(value.source)},\"target\":${escapeJsonString(value.target)},\"cfg\":${escapeJsonString(value.cfg)},\"audience\":${escapeJsonString(value.audience)},\"language\":${escapeJsonString(value.language)},\"revision\":${escapeJsonString(value.revision)},\"apiVersion\":${escapeJsonString(value.apiVersion)},\"documentationRevision\":${escapeJsonString(value.documentationRevision)},\"indexIdentity\":${escapeJsonString(value.indexIdentity)},\"baseUrl\":${escapeJsonString(value.baseUrl)}")
    out.append("}")
}

internal func contextFreeNavigationFailure(value: TypeNavigation): Bool {
    value.state != "resolved" && value.matchLevel == "none" &&
        value.dependencyInstanceId.isEmpty() && value.documentSetId.isEmpty() &&
        value.indexIdentity.isEmpty() && value.symbolKey.isEmpty() && value.url.isEmpty() &&
        value.apiIdentity.isEmpty() && value.language.isEmpty()
}

internal func appendNavigationDecision(out: StringBuilder, value: TypeNavigation): Unit {
    if (contextFreeNavigationFailure(value)) {
        out.append("[${escapeJsonString(value.state)},${escapeJsonString(value.reason)}]")
        return
    }
    out.append("{\"state\":${escapeJsonString(value.state)},\"matchLevel\":${escapeJsonString(value.matchLevel)},\"reason\":${escapeJsonString(value.reason)},\"dependencyInstanceId\":${escapeJsonString(value.dependencyInstanceId)},\"documentSetId\":${escapeJsonString(value.documentSetId)},\"indexIdentity\":${escapeJsonString(value.indexIdentity)},\"symbolKey\":${escapeJsonString(value.symbolKey)},\"url\":${escapeJsonString(value.url)},\"apiIdentity\":${escapeJsonString(value.apiIdentity)},\"language\":${escapeJsonString(value.language)}")
    out.append("}")
}

protected func appendTypeNavigation(out: StringBuilder, value: ?TypeNavigation): Unit {
    match (value) {
        case Some(navigation) => appendNavigationDecision(out, navigation)
        case None => out.append("null")
    }
}

internal func appendDependencyMetadata(out: StringBuilder, documentation: DocumentationSet): Unit {
    out.append("\"dependencies\":[")
    var first = true
    for (value in documentation.dependencies) {
        if (!first) { out.append(",") }; first = false
        appendDependencyInstance(out, value)
    }
    out.append("],\"documentSets\":[")
    first = true
    for (value in documentation.documentSets) {
        if (!first) { out.append(",") }; first = false
        appendDocumentSetIdentity(out, value)
    }
    out.append("],")
}

internal func decodeDependencyInstance(node: JsonNode, path: String): DependencyInstance {
    let value = strictObject(node, path, ["moduleId", "componentModuleId", "name", "instanceId", "kind", "identity", "state", "evidence", "version", "revision", "target", "cfg"])
    DependencyInstance(stringAt(value, "moduleId", path),
        stringAt(value, "name", path),
        stringAt(value, "instanceId", path),
        stringAt(value, "kind", path),
        stringAt(value, "identity", path),
        stringAt(value, "state", path),
        stringAt(value, "evidence", path),
        version: stringAt(value, "version", path),
        revision: stringAt(value, "revision", path),
        target: stringAt(value, "target", path),
        cfg: stringAt(value, "cfg", path),
        componentModuleId: stringAt(value, "componentModuleId", path))
}

internal func decodeDocumentSetIdentity(node: JsonNode, path: String): DocumentSetIdentity {
    let value = strictObject(node, path, ["id", "moduleId", "library", "identity", "state", "source", "target", "cfg", "audience", "language", "revision", "apiVersion", "documentationRevision", "indexIdentity", "baseUrl"])
    DocumentSetIdentity(stringAt(value, "id", path),
        stringAt(value, "library", path),
        stringAt(value, "identity", path),
        stringAt(value, "state", path),
        stringAt(value, "source", path),
        target: stringAt(value, "target", path),
        cfg: stringAt(value, "cfg", path),
        audience: stringAt(value, "audience", path),
        language: stringAt(value, "language", path),
        revision: stringAt(value, "revision", path),
        indexIdentity: stringAt(value, "indexIdentity", path),
        baseUrl: stringAt(value, "baseUrl", path),
        moduleId: stringAt(value, "moduleId", path),
        apiVersion: stringAt(value, "apiVersion", path),
        documentationRevision: stringAt(value, "documentationRevision", path))
}

protected func decodeNavigationDecision(node: JsonNode, path: String): TypeNavigation {
    if (node.kind() == JsonKind.Array) {
        let values = node.asArray()
        if (values.size() != 2 || values.get(0).getOrThrow().kind() != JsonKind.String ||
            values.get(1).getOrThrow().kind() != JsonKind.String) {
            domainFail(path, "navigation failure tuple requires exactly two strings")
        }
        let state = values.get(0).getOrThrow().asString()
        if (state == "resolved") { domainFail(path, "resolved navigation requires its complete context object") }
        return TypeNavigation(state, "none", values.get(1).getOrThrow().asString())
    }
    let value = strictObject(node, path, ["state", "matchLevel", "reason", "dependencyInstanceId", "documentSetId", "indexIdentity", "symbolKey", "url", "apiIdentity", "language"])
    let decision = TypeNavigation(stringAt(value, "state", path),
        stringAt(value, "matchLevel", path),
        stringAt(value, "reason", path),
        dependencyInstanceId: stringAt(value, "dependencyInstanceId", path),
        documentSetId: stringAt(value, "documentSetId", path),
        indexIdentity: stringAt(value, "indexIdentity", path),
        symbolKey: stringAt(value, "symbolKey", path),
        url: stringAt(value, "url", path),
        apiIdentity: stringAt(value, "apiIdentity", path),
        language: stringAt(value, "language", path))
    if (contextFreeNavigationFailure(decision)) {
        domainFail(path, "context-free navigation failure requires its canonical two-string tuple")
    }
    decision
}

internal func decodeTypeNavigation(node: ?JsonNode, path: String): ?TypeNavigation {
    match (node) {
        case None => None
        case Some(value) => if (value.isNull) { None } else { Some(decodeNavigationDecision(value, path)) }
    }
}

internal func decodeDependencyInstances(node: ?JsonNode): Array<DependencyInstance> {
    let result = ArrayList<DependencyInstance>()
    if (let Some(value) <- node) {
        var index: Int64 = 0
        for (item in jsonArrayValues(value.asArray())) {
            result.add(decodeDependencyInstance(item, "$.dependencies[${index}]"))
            index++
        }
    }
    result.toArray()
}

internal func decodeDocumentSetIdentities(node: ?JsonNode): Array<DocumentSetIdentity> {
    let result = ArrayList<DocumentSetIdentity>()
    if (let Some(value) <- node) {
        var index: Int64 = 0
        for (item in jsonArrayValues(value.asArray())) {
            result.add(decodeDocumentSetIdentity(item, "$.documentSets[${index}]"))
            index++
        }
    }
    result.toArray()
}
