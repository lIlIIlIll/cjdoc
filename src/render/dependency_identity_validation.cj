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

/** Lookups shared by all navigation occurrences in one validation pass. */
internal class NavigationEvidence {
    let dependencies = HashMap<String, DependencyInstance>()
    let documentSets = HashMap<String, DocumentSetIdentity>()
    let localSymbols = HashMap<String, SymbolDoc>()
    let moduleNames = HashMap<String, String>()
    let dependenciesByName = HashMap<String, ArrayList<DependencyInstance>>()

    private func dependencyFor(moduleId: String, name: String): ?DependencyInstance {
        let values = match (dependenciesByName.get(moduleId + "|" + name)) {
            case Some(records) => records
            case None => return None
        }
        var selected: ?DependencyInstance = None
        for (record in values) {
            if (let Some(previous) <- selected) {
                if (previous.instanceId != record.instanceId || previous.state != record.state) { return None }
            }
            selected = Some(record)
        }
        selected
    }

    private func localAllowed(moduleId: String, target: SymbolDoc): Bool {
        if (moduleId.isEmpty()) { return false }
        if (target.moduleId == moduleId) { return true }
        let name = match (moduleNames.get(target.moduleId)) {
            case Some(value) => value
            case None => return false
        }
        let actual = match (dependencyFor(target.moduleId, name)) {
            case Some(value) => value
            case None => return false
        }
        let selected = match (dependencyFor(moduleId, name)) {
            case Some(value) => value
            case None => return false
        }
        // Replay enforces the captured subset of DependencyNavigationBinder.localAllowed:
        // unique selected edges, equal nonempty identities and observed/verified states.
        // Source-package aliases, transitive component conflicts and cross-component
        // graph.binding proofs belong to the producer's private source-graph index,
        // which is not available here. Component IDs alone are not identity proofs.
        !selected.componentModuleId.isEmpty() && !selected.identity.isEmpty() &&
            selected.identity == actual.identity &&
            (selected.state == "observed" || selected.state == "verified") &&
            (actual.state == "observed" || actual.state == "verified")
    }

    func validate(value: TypeNavigation, path: String, moduleId: String): Unit {
        if (!value.url.isEmpty() && navigationHref("", value.url).isNone()) {
            domainFail(path + ".url", "unsafe navigation URL")
        }
        // Contextual failures retain evidence, but do not claim a selected target.
        if (value.state != "resolved") { return }
        if (value.matchLevel == "exact") {
            // The producer also emits evidence-free exact links to captured
            // declarations. Only their actual local route has that meaning.
            if (value.documentSetId.isEmpty() && value.dependencyInstanceId.isEmpty()) {
                if (let Some(target) <- localSymbols.get(value.symbolKey)) {
                    if (value.url == symbolPagePath(target)) {
                        if (!localAllowed(moduleId, target)) {
                            domainFail(path + ".symbolKey",
                                "local exact navigation must belong to the occurrence's selected module dependency identity")
                        }
                        return
                    }
                }
            }
            if (value.symbolKey.isEmpty()) {
                domainFail(path + ".symbolKey", "external exact navigation requires a symbol key")
            }
        }
        let selectedEvidence = value.matchLevel == "exact" || value.matchLevel == "compatible"
        if (selectedEvidence) {
            if (value.documentSetId.isEmpty()) {
                domainFail(path + ".documentSetId",
                    "selected navigation requires a documentation.documentSets reference or an exact captured local target")
            }
            if (value.dependencyInstanceId.isEmpty()) {
                domainFail(path + ".dependencyInstanceId",
                    "selected navigation requires a documentation.dependencies reference")
            }
            if (value.apiIdentity.isEmpty()) {
                domainFail(path + ".apiIdentity", "selected external navigation requires an API identity")
            }
            if (value.indexIdentity.isEmpty()) {
                domainFail(path + ".indexIdentity", "selected external navigation requires an index identity")
            }
        }
        if (!value.documentSetId.isEmpty()) {
            if (let Some(documentSet) <- documentSets.get(value.documentSetId)) {
                if (value.matchLevel == "exact" && documentSet.state != "declared") {
                    domainFail(path + ".documentSetId",
                        "exact navigation requires a declared documentation.documentSets record")
                }
                if (!value.apiIdentity.isEmpty() && value.apiIdentity != documentSet.identity) {
                    domainFail(path + ".apiIdentity", "must match the referenced documentation.documentSets identity")
                }
                if ((value.matchLevel == "compatible" || !value.language.isEmpty()) && value.language != documentSet.language) {
                    domainFail(path + ".language", "must match the referenced documentation.documentSets language")
                }
                if (!value.indexIdentity.isEmpty() && value.indexIdentity != documentSet.indexIdentity) {
                    domainFail(path + ".indexIdentity", "must match the referenced documentation.documentSets indexIdentity")
                }
            } else if (value.matchLevel != "manual") {
                // Manual references are unverified and may retain a publisher
                // label without a captured document-set record.
                domainFail(path + ".documentSetId",
                    "must reference an existing documentation.documentSets record")
            }
        }
        if (!value.dependencyInstanceId.isEmpty()) {
            let dependency = match (dependencies.get(value.dependencyInstanceId)) {
                case Some(record) => record
                case None => domainFail(path + ".dependencyInstanceId",
                    "must reference an existing documentation.dependencies instanceId")
            }
            if (value.matchLevel == "exact" && dependency.state != "observed" && dependency.state != "verified") {
                domainFail(path + ".dependencyInstanceId",
                    "exact navigation requires observed or verified documentation.dependencies evidence")
            }
            // Compatible is selected only inside the producer's dependency branch,
            // but unlike exact it permits declared evidence and differing API bytes.
            if (value.matchLevel == "compatible" && (dependency.state == "unknown" ||
                dependency.state == "conflict" || dependency.identity.isEmpty())) {
                domainFail(path + ".dependencyInstanceId",
                    "compatible navigation requires a known nonconflicting documentation.dependencies identity")
            }
            // No unique page module means the producer can only emit unavailable
            // navigation, not a selected claim borrowing another module's evidence.
            if (selectedEvidence && (moduleId.isEmpty() || dependency.moduleId != moduleId)) {
                domainFail(path + ".dependencyInstanceId",
                    "selected navigation dependency must belong to the occurrence's owning module")
            }
            // Compatible mappings and unverified manual references may select a
            // document API identity different from the actual dependency bytes.
            if (value.matchLevel == "exact" && value.apiIdentity != dependency.identity) {
                domainFail(path + ".apiIdentity",
                    "exact navigation must match the referenced documentation.dependencies identity")
            }
        }
    }
}

internal func validateDependencyMetadata(documentation: DocumentationSet,
    modules: HashSet<String>): NavigationEvidence {
    let evidence = NavigationEvidence()
    for (module in documentation.modules) { evidence.moduleNames[module.id] = module.name }
    for (declaration in documentation.declarations) {
        evidence.localSymbols[declaration.id] = declaration
    }
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
            evidence.dependencies.contains(value.instanceId)) {
            domainFail("$.dependencies", "invalid graph owner or duplicate dependency instance")
        }
        evidence.dependencies[value.instanceId] = value
        let nameKey = value.moduleId + "|" + value.name
        match (evidence.dependenciesByName.get(nameKey)) {
            case Some(records) => records.add(value)
            case None => evidence.dependenciesByName[nameKey] = ArrayList<DependencyInstance>([value])
        }
        // A captured component pointer also identifies renamed dependency edges.
        if (let Some(name) <- evidence.moduleNames.get(value.componentModuleId)) {
            if (name != value.name) {
                let aliasKey = value.moduleId + "|" + name
                match (evidence.dependenciesByName.get(aliasKey)) {
                    case Some(records) => records.add(value)
                    case None => evidence.dependenciesByName[aliasKey] = ArrayList<DependencyInstance>([value])
                }
            }
        }
    }
    for (value in documentation.documentSets) {
        if (!value.moduleId.isEmpty() && !value.moduleId.startsWith("cjdoc:module:v1:")) {
            domainFail("$.documentSets", "invalid producer-scoped module identifier")
        }
        if (evidence.documentSets.contains(value.id)) { domainFail("$.documentSets", "duplicate document set identity") }
        evidence.documentSets[value.id] = value
        if (!value.baseUrl.isEmpty() && markdownLinkDestination(value.baseUrl, allowRelative: true).isNone()) {
            domainFail("$.documentSets", "unsafe document set base URL")
        }
    }
    evidence
}
