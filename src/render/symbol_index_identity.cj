package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func appendDependencyInstance(out: RenderTextBuffer, value: DependencyInstance): Unit {
    out.append("{\"moduleId\":${escapeJsonString(value.moduleId)},\"componentModuleId\":${escapeJsonString(value.componentModuleId)},\"name\":${escapeJsonString(value.name)},\"instanceId\":${escapeJsonString(value.instanceId)},\"kind\":${escapeJsonString(value.kind)},\"identity\":${escapeJsonString(value.identity)},\"state\":${escapeJsonString(value.state)},\"evidence\":${escapeJsonString(value.evidence)},\"version\":${escapeJsonString(value.version)},\"revision\":${escapeJsonString(value.revision)},\"target\":${escapeJsonString(value.target)},\"cfg\":${escapeJsonString(value.cfg)}")
    out.append("}")
}

internal func appendDocumentSetIdentity(out: RenderTextBuffer, value: DocumentSetIdentity): Unit {
    out.append("{\"id\":${escapeJsonString(value.id)},\"moduleId\":${escapeJsonString(value.moduleId)},\"library\":${escapeJsonString(value.library)},\"identity\":${escapeJsonString(value.identity)},\"state\":${escapeJsonString(value.state)},\"source\":${escapeJsonString(value.source)},\"target\":${escapeJsonString(value.target)},\"cfg\":${escapeJsonString(value.cfg)},\"audience\":${escapeJsonString(value.audience)},\"language\":${escapeJsonString(value.language)},\"revision\":${escapeJsonString(value.revision)},\"apiVersion\":${escapeJsonString(value.apiVersion)},\"documentationRevision\":${escapeJsonString(value.documentationRevision)},\"indexIdentity\":${escapeJsonString(value.indexIdentity)},\"baseUrl\":${escapeJsonString(value.baseUrl)}")
    out.append("}")
}

internal func appendNavigationDecision(out: RenderTextBuffer, value: TypeNavigation,
    routeOverride!: ?String = None): Unit {
    if (contextFreeNavigationFailure(value) && routeOverride.getOrDefault({ => "" }).isEmpty()) {
        out.append("[${escapeJsonString(value.state)},${escapeJsonString(value.reason)}]")
        return
    }
    out.append("{\"state\":${escapeJsonString(value.state)},\"matchLevel\":${escapeJsonString(value.matchLevel)},\"reason\":${escapeJsonString(value.reason)}")
    out.append(",\"dependencyInstanceId\":${escapeJsonString(value.dependencyInstanceId)},\"documentSetId\":${escapeJsonString(value.documentSetId)}")
    out.append(",\"indexIdentity\":${escapeJsonString(value.indexIdentity)},\"symbolKey\":${escapeJsonString(value.symbolKey)}")
    out.append(",\"url\":${escapeJsonString(routeOverride.getOrDefault({ => value.url }))},\"apiIdentity\":${escapeJsonString(value.apiIdentity)},\"language\":${escapeJsonString(value.language)}}")
}

internal class SymbolInventoryIdentity {
    let sets: ArrayList<DocumentSetIdentity>
    let byModule = HashMap<String, DocumentSetIdentity>()

    init(documentation: DocumentationSet, publicationRevision!: ?String = None) {
        let revision = publicationRevision.getOrDefault({ => documentation.documentationRevision })
        let publicationIdentity = contractFingerprint(revision + "\n" + documentation.readingLanguage.getOrDefault({ => "" }))
        this.sets = ArrayList<DocumentSetIdentity>(documentation.documentSets.toArray())
        for (module in documentation.modules) {
            let organization = module.organization.getOrDefault({ => "" })
            let library = if (organization.isEmpty() || module.name.contains("::")) { module.name }
                else { organization + "::" + module.name }
            for (dependency in documentation.dependencies) {
                if (dependency.moduleId != module.id || dependency.name != module.name || dependency.identity.isEmpty()) { continue }
                var found: ?DocumentSetIdentity = None
                for (entry in sets) {
                    if (entry.moduleId == module.id && entry.library == library && entry.identity == dependency.identity &&
                        entry.target == dependency.target && entry.cfg == dependency.cfg &&
                        entry.revision == dependency.revision && entry.apiVersion == dependency.version &&
                        entry.documentationRevision == revision &&
                        entry.baseUrl.isEmpty() && entry.indexIdentity.isEmpty() &&
                        (entry.language.isEmpty() || entry.language == documentation.readingLanguage.getOrDefault({ => "" }))) {
                        found = Some(entry)
                        break
                    }
                }
                let entry = found.getOrDefault({ =>
                    let state = if (dependency.state == "conflict") { "unknown" } else { dependency.state }
                    let generated = DocumentSetIdentity("cjdoc:document-set:v1:" + dependency.instanceId + "-" + publicationIdentity,
                        library, dependency.identity, state, "source-snapshot",
                        target: dependency.target, cfg: dependency.cfg, audience: documentation.configuration.audience,
                        language: documentation.readingLanguage.getOrDefault({ => "" }), revision: dependency.revision,
                        moduleId: module.id, apiVersion: dependency.version,
                        documentationRevision: revision)
                    sets.add(generated)
                    generated
                })
                byModule[module.id] = entry
                break
            }
            if (!byModule.contains(module.id)) {
                let unknown = DocumentSetIdentity("cjdoc:document-set:v1:unknown-" + contractFingerprint(module.id + "\n" + publicationIdentity),
                    library, "", "unknown", "legacy-or-unobserved-doc-ir", moduleId: module.id,
                    audience: documentation.configuration.audience,
                    language: documentation.readingLanguage.getOrDefault({ => "" }), documentationRevision: revision)
                sets.add(unknown)
                byModule[module.id] = unknown
            }
        }
    }
}

internal func appendInventoryMetadata(out: RenderTextBuffer, documentation: DocumentationSet,
    identity: SymbolInventoryIdentity): Unit {
    out.append(",\n  \"dependencies\": [")
    var first = true
    for (entry in documentation.dependencies) {
        if (!first) { out.append(",") }; first = false
        appendDependencyInstance(out, entry)
    }
    out.append("],\n  \"documentSets\": [")
    first = true
    for (entry in identity.sets) {
        if (!first) { out.append(",") }; first = false
        appendDocumentSetIdentity(out, entry)
    }
    out.append("]")
}

internal func symbolInventoryKey(symbol: SymbolDoc): String {
    let parameters = ArrayList<String>()
    for (parameter in symbol.parameters) { parameters.add(parameter.typeRef.spelling) }
    portableSymbolKey(symbol.packageName, symbol.qualifiedName, symbol.kind,
        symbol.genericParameters.size, parameterTypes: parameters.toArray())
}

private func appendInventoryTypeNavigation(out: RenderTextBuffer, value: TypeRef, first: Bool, hrefPrefix: String): Bool {
    var nextFirst = first
    if (value.navigation.isSome()) {
        if (!nextFirst) { out.append(",") }; nextFirst = false
        out.append("{\"spelling\":${escapeJsonString(value.spelling)},\"navigation\":")
        appendInventoryNavigation(out, value.navigation, hrefPrefix)
        out.append("}")
    }
    for (argument in value.arguments) { nextFirst = appendInventoryTypeNavigation(out, argument, nextFirst, hrefPrefix) }
    nextFirst
}

internal func appendInventoryTypeNavigations(out: RenderTextBuffer, symbol: SymbolDoc, hrefPrefix: String): Unit {
    out.append(",\"typeNavigations\":[")
    var first = true
    for (parameter in symbol.parameters) { first = appendInventoryTypeNavigation(out, parameter.typeRef, first, hrefPrefix) }
    if (let Some(value) <- symbol.returnType) { first = appendInventoryTypeNavigation(out, value, first, hrefPrefix) }
    for (relation in symbol.typeRelationships) { first = appendInventoryTypeNavigation(out, relation.target, first, hrefPrefix) }
    out.append("]")
}

internal func appendInventoryNavigation(out: RenderTextBuffer, navigation: ?TypeNavigation, hrefPrefix: String): Unit {
    match (navigation) {
        case Some(value) =>
            let url = if (value.url.isEmpty() || value.url.startsWith("http://") || value.url.startsWith("https://")) {
                value.url
            } else { hrefPrefix + value.url.removePrefix("./") }
            appendNavigationDecision(out, value, routeOverride: Some(url))
        case None => out.append("null")
    }
}
