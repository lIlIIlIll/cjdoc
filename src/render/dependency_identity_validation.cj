package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func consumeNavigationEncoding(value: ?TypeNavigation, path: String,
    depth: Int64, budget: DocIrEncodingBudget): Unit {
    if (let Some(navigation) <- value) {
        if (contextFreeNavigationFailure(navigation)) {
            budget.consumeCollection(2, path, depth: depth)
            budget.consumeString(navigation.state, path)
            budget.consumeString(navigation.reason, path)
            return
        }
        // Fixed keys/punctuation only; escaped strings and pretty spacing are charged separately.
        budget.consumeObject(path, depth: depth, fields: 10, compactBytes: 139)
        for (text in [navigation.state, navigation.matchLevel, navigation.reason, navigation.dependencyInstanceId, navigation.documentSetId, navigation.indexIdentity, navigation.symbolKey, navigation.url, navigation.apiIdentity, navigation.language]) {
            budget.consumeString(text, path)
        }
    } else { budget.consumeBytes(4, path) }
}

internal func consumeDependencyMetadataEncoding(documentation: DocumentationSet,
    budget: DocIrEncodingBudget): Unit {
    budget.consumeCollection(documentation.dependencies.size, "$.dependencies", depth: 1)
    for (value in documentation.dependencies) {
        budget.consumeObject("$.dependencies[]", depth: 2, fields: 12, compactBytes: 137)
        for (text in [value.moduleId, value.componentModuleId, value.name, value.instanceId, value.kind, value.identity, value.state, value.evidence, value.version, value.revision, value.target, value.cfg]) {
            budget.consumeString(text, "$.dependencies[]")
        }
    }
    budget.consumeCollection(documentation.documentSets.size, "$.documentSets", depth: 1)
    for (value in documentation.documentSets) {
        budget.consumeObject("$.documentSets[]", depth: 2, fields: 15, compactBytes: 181)
        for (text in [value.id, value.moduleId, value.library, value.identity, value.state, value.source, value.target, value.cfg, value.audience, value.language, value.revision, value.apiVersion, value.documentationRevision, value.indexIdentity, value.baseUrl]) {
            budget.consumeString(text, "$.documentSets[]")
        }
    }
}

internal func validateDependencyMetadata(documentation: DocumentationSet, modules: HashSet<String>): Unit {
    let instances = HashSet<String>()
    for (value in documentation.dependencies) {
        // Dependency graph owners need not be rendered modules. Their stable
        // built-in module IDs remain valid offline even when dependency source
        // inclusion was not requested.
        if (!value.componentModuleId.isEmpty() &&
            (!value.componentModuleId.startsWith("cjdoc:module:v1:") ||
            value.kind == "binary" || value.kind == "toolchain")) {
            domainFail("$.dependencies", "invalid selected source component identifier")
        }
        let graphOwner = value.moduleId.startsWith("cjdoc:module:v1:")
        if ((!modules.contains(value.moduleId) && !graphOwner) ||
            !instances.add(compositeKey(value.moduleId, value.instanceId))) {
            domainFail("$.dependencies", "invalid graph owner or duplicate dependency instance")
        }
    }
    let sets = HashSet<String>()
    for (value in documentation.documentSets) {
        if (!value.moduleId.isEmpty() && !value.moduleId.startsWith("cjdoc:module:v1:")) {
            domainFail("$.documentSets", "invalid producer-scoped module identifier")
        }
        if (!sets.add(value.id)) { domainFail("$.documentSets", "duplicate document set identity") }
        if (!value.baseUrl.isEmpty() && markdownLinkDestination(value.baseUrl, allowRelative: true).isNone()) {
            domainFail("$.documentSets", "unsafe document set base URL")
        }
    }
}
