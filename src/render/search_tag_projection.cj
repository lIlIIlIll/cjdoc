package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.sort.*

/** One published module/tag namespace, shared by every canonical member using it. */
protected class SearchProjectionTag {
    protected let key: String
    protected let snapshotId: String
    protected let sourceSnapshotId: String
    protected let scope: Int64
    protected let module: SearchScopeModule
    protected let id: String
    protected let title: String

    protected init(projection: DocumentationSearchProjection, scope: Int64,
        label: DeclarationTagClassification, key: String) {
        this.key = key
        this.snapshotId = projection.scopeSnapshotId
        this.sourceSnapshotId = projection.sourceSnapshotId
        this.scope = scope
        this.module = projection.modules[scope]
        this.id = label.id
        this.title = label.title
    }
}

private func searchProjectionTagKey(projection: DocumentationSearchProjection,
    moduleId: String, id: String): String {
    "${projection.scopeSnapshotId.size}:${projection.scopeSnapshotId}" +
        documentationMetadataTagKey(moduleId, id)
}

internal func attachSearchTagDictionary(projection: DocumentationSearchProjection): Unit {
    let byKey = HashMap<String, SearchProjectionTag>()
    for (entry in projection.entries where !entry.classification.tags.isEmpty()) {
        let module = projection.modules[entry.scope]
        entry.tagFacets = Array<SearchProjectionTag>(entry.classification.tags.size, { index =>
            let label = entry.classification.tags[index]
            let key = searchProjectionTagKey(projection, module.moduleId, label.id)
            match (byKey.get(key)) {
                case Some(value) => value
                case None =>
                    let value = SearchProjectionTag(projection, entry.scope, label, key)
                    byKey[key] = value
                    projection.tagDictionary.add(value)
                    value
            }
        })
    }
    sort(projection.tagDictionary, lessThan: { left, right =>
        if (left.scope != right.scope) { left.scope < right.scope } else { left.id < right.id }
    }, stable: true)
}

/** Expand only captured identity evidence, never a name-derived dependency identity. */
protected func appendSearchTagFacetJson(out: StringBuilder, tag: SearchProjectionTag,
    count: Int64): Unit {
    out.append("{\"scope\":{\"snapshotId\":" + escapeJsonString(tag.snapshotId) +
        ",\"sourceSnapshotId\":" + escapeJsonString(tag.sourceSnapshotId) +
        ",\"moduleId\":" + escapeJsonString(tag.module.moduleId) + ",\"documentSet\":")
    match (tag.module.documentSet) {
        case Some(identity) => appendDocumentSetIdentity(out, identity)
        case None => out.append("null")
    }
    out.append(",\"dependencyInstance\":")
    match (tag.module.dependency) {
        case Some(dependency) => appendDependencyInstance(out, dependency)
        case None => out.append("null")
    }
    out.append(",\"dependencyInstanceState\":" + escapeJsonString(tag.module.dependencyState) +
        "},\"id\":" + escapeJsonString(tag.id) + ",\"title\":" + escapeJsonString(tag.title) +
        ",\"count\":" + count.toString() + "}")
}
