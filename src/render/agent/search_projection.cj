protected package cjdoc.render.agent

import cjdoc.render.search.{
    DocumentationSearchProjection, SearchContractLimits, SearchExposure, SearchProjectedEntry,
    SearchScopeModule, SearchSection, attachSearchCommentFields, attachSearchTagDictionary,
    searchContractJson, searchContractLimits}
import cjdoc.render.publication.DeclarationClassification
import cjdoc.render.reading.{isUnitType, summaryPlainText}
import cjdoc.render.routes.{docBlockAnchor, label}
import cjdoc.render.html.{RenderProjection, projectSearchPageBindings}
import cjdoc.render.foundation.{RenderTextBuffer, markdownNodeText}
import cjdoc.model.*
import cjdoc.schema_data.*
import std.collection.*
import std.sort.*
import yjson.*
private func searchPortableSymbolKey(symbol: SymbolDoc): String {
    let parameters = ArrayList<String>()
    for (parameter in symbol.parameters) { parameters.add(parameter.typeRef.spelling) }
    portableSymbolKey(symbol.packageName, symbol.qualifiedName, symbol.kind,
        symbol.genericParameters.size, parameterTypes: parameters.toArray())
}
private func searchProjectionBody(value: String, profile: String,
    limits: SearchContractLimits): (String, Bool) {
    if (profile == limits.defaultProfile) { return (value, false) }
    var count: Int64 = 0
    let out = RenderTextBuffer()
    for (rune in value.runes()) {
        if (count == limits.staticBodyTextLimit) { return (out.toString(), true) }
        out.append(rune)
        count++
    }
    (out.toString(), false)
}

/** Emit one selected tag body; localizedTexts are identity/source evidence, not another search copy. */
private func searchTagBodyText(tag: DocTag): String {
    let out = RenderTextBuffer()
    out.append(tag.name)
    if (!tag.subject.isEmpty()) { out.append(" " + tag.subject) }
    if (tag.name == "deprecated" && tag.translationState.isEmpty()) {
        // The legacy prose tree is presentation-only; keep its retrieval text.
        if (!tag.description.isEmpty()) { out.append(" " + tag.description) }
    } else if (let Some(tree) <- tag.descriptionMarkdown) {
        let text = markdownNodeText(tree)
        if (!text.isEmpty()) { out.append(" " + text) }
        else if (!tag.description.isEmpty()) { out.append(" " + tag.description) }
    } else if (!tag.description.isEmpty()) {
        out.append(" " + tag.description)
    }
    if (let Some(example) <- tag.exampleMarkdown) {
        let text = markdownNodeText(example)
        if (!text.isEmpty()) { out.append(" " + text) }
    }
    out.toString()
}

/** Full retrieval body from the captured comment AST, selected tags and captured parameter prose. */
private func searchFullBody(symbol: SymbolDoc): String {
    let comment = match (symbol.documentation) {
        case Some(value) => value
        case None => return ""
    }
    let out = RenderTextBuffer()
    out.append(markdownNodeText(comment.markdown))
    for (tag in comment.tags where tag.name != "replacement") {
        let text = searchTagBodyText(tag)
        if (!text.isEmpty()) { out.append(" " + text) }
    }
    for (parameter in symbol.parameters) {
        if (parameter.documentation.isNone()) { continue }
        var hasTag = false
        for (tag in comment.tags) {
            if (tag.name == "param" && tag.subject == parameter.name) {
                hasTag = true
                break
            }
        }
        if (!hasTag) {
            let text = parameter.documentation.getOrDefault({ => "" })
            if (!text.isEmpty()) { out.append(" " + parameter.name + " " + text) }
        }
    }
    out.toString()
}

private func searchProjectionModuleName(snapshot: DocumentationReadSnapshot,
    moduleId: String): ?String {
    snapshot.moduleFor(moduleId).map({ module: ModuleDoc => module.name })
}

private func searchOwnerSymbol(projection: RenderProjection, symbol: SymbolDoc): ?SymbolDoc {
    match (symbol.ownerId) {
        case Some(ownerId) => projection.allIndex.get(ownerId)
        case None => None
    }
}

private func searchParameterSectionText(symbol: SymbolDoc, comment: DocComment): String {
    let out = RenderTextBuffer()
    for (parameter in symbol.parameters) {
        var matchedTag: ?DocTag = None
        for (tag in comment.tags) {
            if (tag.name == "param" && tag.subject == parameter.name) {
                matchedTag = Some(tag)
                break
            }
        }
        let text = match (matchedTag) {
            case Some(tag) => searchTagBodyText(tag)
            case None => parameter.documentation.getOrDefault({ => "" })
        }
        if (text.isEmpty()) { continue }
        if (out.size > 0) { out.append(" ") }
        out.append(parameter.name + " " + text)
    }
    out.toString()
}

/** A section exists exactly when the reader page emits its corresponding heading. */
private func searchDeclarationSections(symbol: SymbolDoc, profile: String,
    limits: SearchContractLimits): ArrayList<SearchSection> {
    let blocks = ArrayList<SearchSection>()
    let comment = match (symbol.documentation) {
        case Some(value) => value
        case None => return blocks
    }
    let returnTags = ArrayList<DocTag>()
    let throwsTags = ArrayList<DocTag>()
    for (tag in comment.tags) {
        if (tag.name == "return" || tag.name == "returns") { returnTags.add(tag) }
        else if (tag.name == "throws") { throwsTags.add(tag) }
    }
    if (!symbol.parameters.isEmpty()) {
        blocks.add(SearchSection("parameters", docBlockAnchor(symbol, "parameters"),
            searchProjectionBody(searchParameterSectionText(symbol, comment), profile, limits)[0]))
    }
    var renderedReturnType = false
    if (let Some(value) <- symbol.returnType) { renderedReturnType = !isUnitType(value) }
    if (renderedReturnType || !returnTags.isEmpty()) {
        blocks.add(SearchSection("return", docBlockAnchor(symbol, "return"),
            searchProjectionBody(searchSectionText(returnTags), profile, limits)[0]))
    }
    if (!throwsTags.isEmpty()) {
        blocks.add(SearchSection("throws", docBlockAnchor(symbol, "throws"),
            searchProjectionBody(searchSectionText(throwsTags), profile, limits)[0]))
    }
    blocks
}

private func searchSectionText(tags: ArrayList<DocTag>): String {
    let collected = RenderTextBuffer()
    for (tag in tags) {
        let text = searchTagBodyText(tag)
        if (text.isEmpty()) { continue }
        if (collected.size > 0) { collected.append(" ") }
        collected.append(text)
    }
    collected.toString()
}


private func searchParameterTypes(symbol: SymbolDoc): ArrayList<String> {
    let result = ArrayList<String>()
    for (parameter in symbol.parameters) { result.add(parameter.typeRef.spelling) }
    result
}


/**
 * Build one immutable retrieval projection directly from the captured reader
 * snapshot. Query adapters may preserve an outer source identity; publication
 * rendering defaults that identity to the real snapshot ID.
 */
protected func buildDocumentationSearchProjection(snapshot: DocumentationReadSnapshot,
    profile: String, sourceSnapshotId!: String = ""): DocumentationSearchProjection {
    let limits = searchContractLimits()
    if (!limits.profiles.contains(profile)) {
        throw IllegalArgumentException("unknown search profile: " + profile)
    }
    let documentation = snapshot.documentation
    let projection = snapshot.projection
    let result = DocumentationSearchProjection(profile, snapshot.snapshotId,
        if (sourceSnapshotId.isEmpty()) { snapshot.snapshotId } else { sourceSnapshotId },
        snapshot.publicationRevision, snapshot.locale, documentation.configuration.audience,
        documentation.configuration.cfgProfile, documentation.apiCollectionState,
        documentation.project.name, limits, "")

    // Module scopes come from the captured Doc IR inventory, not the
    // audience-filtered declaration projection. Empty captured scopes remain
    // addressable without manufacturing search entries.
    let orderedSymbols = ArrayList<SymbolDoc>(projection.visibleSymbols.toArray())
    sort(orderedSymbols, lessThan: { left, right =>
        if (left.moduleId != right.moduleId) { left.moduleId < right.moduleId }
        else if (left.packageName != right.packageName) { left.packageName < right.packageName }
        else { left.id < right.id }
    }, stable: true)
    let orderedModules = ArrayList<ModuleDoc>()
    for (module in documentation.modules) { orderedModules.add(module) }
    sort(orderedModules, lessThan: { left, right => left.id < right.id }, stable: true)
    for (module in orderedModules) {
        let (dependency, state) = snapshot.moduleDependencyState(module.id)
        result.addModule(SearchScopeModule(module.id, Some(module.name),
            snapshot.documentSetForModule(module.id), dependency, state))
    }
    for (symbol in orderedSymbols) {
        let scope = result.modulePosition(symbol.moduleId).getOrThrow()
        result.addEntry(searchDeclarationEntry(snapshot, symbol, profile, scope, limits))
    }
    for (page in snapshot.selectedPages()) {
        result.addEntry(searchPageEntry(page, snapshot.snapshotId, profile, limits,
            projection, snapshot.locale))
    }
    searchAttachExposures(documentation, result)
    for (entry in result.entries) {
        sort(entry.exposures, lessThan: { left, right => left.id < right.id }, stable: true)
    }
    sort(result.entries, lessThan: { left, right =>
        if (left.scope != right.scope) { left.scope < right.scope }
        else if (left.canonicalId != right.canonicalId) { left.canonicalId < right.canonicalId }
        else { left.id < right.id }
    }, stable: true)
    attachSearchTagDictionary(result)
    attachSearchCommentFields(documentation, result)
    searchFinalizeContentId(result)
    result
}

private func searchFingerprintField(out: StringBuilder, name: String, value: String): Unit {
    out.append(name.size.toString() + ":" + name + value.size.toString() + ":" + value)
}

private func searchFingerprintOptional(out: StringBuilder, name: String, value: ?String): Unit {
    match (value) {
        case Some(text) =>
            searchFingerprintField(out, name + ".present", "1")
            searchFingerprintField(out, name, text)
        case None => searchFingerprintField(out, name + ".present", "0")
    }
}

private func searchFingerprintNavigation(out: StringBuilder, name: String,
    value: ?TypeNavigation): Unit {
    match (value) {
        case Some(navigation) =>
            searchFingerprintField(out, name + ".present", "1")
            searchFingerprintField(out, name + ".state", navigation.state)
            searchFingerprintField(out, name + ".matchLevel", navigation.matchLevel)
            searchFingerprintField(out, name + ".reason", navigation.reason)
            searchFingerprintField(out, name + ".dependencyInstanceId", navigation.dependencyInstanceId)
            searchFingerprintField(out, name + ".documentSetId", navigation.documentSetId)
            searchFingerprintField(out, name + ".indexIdentity", navigation.indexIdentity)
            searchFingerprintField(out, name + ".symbolKey", navigation.symbolKey)
            searchFingerprintField(out, name + ".url", navigation.url)
            searchFingerprintField(out, name + ".apiIdentity", navigation.apiIdentity)
            searchFingerprintField(out, name + ".language", navigation.language)
        case None => searchFingerprintField(out, name + ".present", "0")
    }
}

private func searchFingerprintDocumentSet(out: StringBuilder, value: ?DocumentSetIdentity): Unit {
    match (value) {
        case Some(identity) =>
            searchFingerprintField(out, "documentSet.present", "1")
            searchFingerprintField(out, "documentSet.id", identity.id)
            searchFingerprintField(out, "documentSet.moduleId", identity.moduleId)
            searchFingerprintField(out, "documentSet.library", identity.library)
            searchFingerprintField(out, "documentSet.identity", identity.identity)
            searchFingerprintField(out, "documentSet.state", identity.state)
            searchFingerprintField(out, "documentSet.source", identity.source)
            searchFingerprintField(out, "documentSet.target", identity.target)
            searchFingerprintField(out, "documentSet.cfg", identity.cfg)
            searchFingerprintField(out, "documentSet.audience", identity.audience)
            searchFingerprintField(out, "documentSet.language", identity.language)
            searchFingerprintField(out, "documentSet.revision", identity.revision)
            searchFingerprintField(out, "documentSet.apiVersion", identity.apiVersion)
            searchFingerprintField(out, "documentSet.documentationRevision", identity.documentationRevision)
            searchFingerprintField(out, "documentSet.indexIdentity", identity.indexIdentity)
            searchFingerprintField(out, "documentSet.baseUrl", identity.baseUrl)
        case None => searchFingerprintField(out, "documentSet.present", "0")
    }
}

private func searchFingerprintDependency(out: StringBuilder, value: ?DependencyInstance): Unit {
    match (value) {
        case Some(dependency) =>
            searchFingerprintField(out, "dependency.present", "1")
            searchFingerprintField(out, "dependency.moduleId", dependency.moduleId)
            searchFingerprintField(out, "dependency.componentModuleId", dependency.componentModuleId)
            searchFingerprintField(out, "dependency.name", dependency.name)
            searchFingerprintField(out, "dependency.instanceId", dependency.instanceId)
            searchFingerprintField(out, "dependency.kind", dependency.kind)
            searchFingerprintField(out, "dependency.identity", dependency.identity)
            searchFingerprintField(out, "dependency.state", dependency.state)
            searchFingerprintField(out, "dependency.evidence", dependency.evidence)
            searchFingerprintField(out, "dependency.version", dependency.version)
            searchFingerprintField(out, "dependency.revision", dependency.revision)
            searchFingerprintField(out, "dependency.target", dependency.target)
            searchFingerprintField(out, "dependency.cfg", dependency.cfg)
        case None => searchFingerprintField(out, "dependency.present", "0")
    }
}

/** Deterministic, unambiguous binding of contract, complete scope and every projected fact. */
private func searchFinalizeContentId(projection: DocumentationSearchProjection): Unit {
    let out = StringBuilder()
    searchFingerprintField(out, "format", "cjdoc.search-projection/4")
    searchFingerprintField(out, "contract", searchContractJson())
    searchFingerprintField(out, "profile", projection.profile)
    searchFingerprintField(out, "snapshotId", projection.scopeSnapshotId)
    searchFingerprintField(out, "sourceSnapshotId", projection.sourceSnapshotId)
    searchFingerprintField(out, "publicationRevision", projection.publicationRevision)
    searchFingerprintField(out, "project", projection.project)
    searchFingerprintField(out, "language", projection.language)
    searchFingerprintField(out, "audience", projection.audience)
    searchFingerprintField(out, "cfgProfile", projection.cfgProfile)
    searchFingerprintField(out, "apiCollectionState", projection.apiCollectionState)
    searchFingerprintField(out, "moduleCount", projection.modules.size.toString())
    for (module in projection.modules) {
        searchFingerprintField(out, "module.moduleId", module.moduleId)
        searchFingerprintOptional(out, "module.moduleName", module.moduleName)
        searchFingerprintField(out, "module.dependencyState", module.dependencyState)
        searchFingerprintDocumentSet(out, module.documentSet)
        searchFingerprintDependency(out, module.dependency)
    }
    searchFingerprintField(out, "tagDictionaryCount", projection.tagDictionary.size.toString())
    for (tag in projection.tagDictionary) {
        searchFingerprintField(out, "tag.scope", tag.scope.toString())
        searchFingerprintField(out, "tag.id", tag.id)
        searchFingerprintField(out, "tag.title", tag.title)
    }
    searchFingerprintField(out, "commentFieldCount",
        projection.commentFieldDictionary.size.toString())
    for (field in projection.commentFieldDictionary) {
        searchFingerprintField(out, "commentField.scope", field.scope.toString())
        searchFingerprintField(out, "commentField.id", field.id)
        searchFingerprintField(out, "commentField.title", field.title)
        searchFingerprintField(out, "commentField.repeatable", field.repeatable.toString())
    }
    searchFingerprintField(out, "entryCount", projection.entries.size.toString())
    for (entry in projection.entries) {
        searchFingerprintField(out, "entry.id", entry.id)
        searchFingerprintField(out, "entry.canonicalId", entry.canonicalId)
        searchFingerprintField(out, "entry.snapshotId", entry.snapshotId)
        searchFingerprintField(out, "entry.concept", entry.concept.toString())
        searchFingerprintField(out, "entry.scope", entry.scope.toString())
        searchFingerprintField(out, "entry.genericArity", entry.genericArity.toString())
        searchFingerprintOptional(out, "entry.ownerId", entry.ownerId)
        searchFingerprintField(out, "entry.kind", entry.kind)
        searchFingerprintField(out, "entry.name", entry.name)
        searchFingerprintField(out, "entry.qualifiedName", entry.qualifiedName)
        searchFingerprintField(out, "entry.packageName", entry.packageName)
        searchFingerprintField(out, "entry.moduleId", entry.moduleId)
        searchFingerprintField(out, "entry.moduleName", entry.moduleName)
        searchFingerprintField(out, "entry.ownerName", entry.ownerName)
        searchFingerprintField(out, "entry.ownerQualifiedName", entry.ownerQualifiedName)
        searchFingerprintField(out, "entry.symbolKey", entry.symbolKey)
        searchFingerprintField(out, "entry.returnType", entry.returnType)
        searchFingerprintField(out, "entry.returnCanonical", entry.returnCanonical)
        searchFingerprintField(out, "entry.href", entry.href)
        searchFingerprintField(out, "entry.summary", entry.summary)
        searchFingerprintField(out, "entry.body", entry.body)
        searchFingerprintField(out, "entry.bodyTruncated", entry.bodyTruncated.toString())
        for (row in entry.commentFieldRows) {
            searchFingerprintField(out, "entry.field.id", row.id)
            for (value in row.values()) {
                searchFingerprintField(out, "entry.field.value", value)
            }
        }
        searchFingerprintClassification(out, entry.classification)
        searchFingerprintField(out, "entry.parameterCount", entry.parameterTypes.size.toString())
        for (parameter in entry.parameterTypes) { searchFingerprintField(out, "entry.parameter", parameter) }
        searchFingerprintField(out, "entry.exposureCount", entry.exposures.size.toString())
        for (exposure in entry.exposures) {
            searchFingerprintField(out, "exposure.id", exposure.id)
            searchFingerprintField(out, "exposure.name", exposure.name)
            searchFingerprintField(out, "exposure.qualifiedName", exposure.qualifiedName)
            searchFingerprintField(out, "exposure.packageName", exposure.packageName)
            searchFingerprintField(out, "exposure.scope", exposure.scope.toString())
        }
        searchFingerprintField(out, "entry.sectionCount", entry.sections.size.toString())
        for (section in entry.sections) {
            searchFingerprintField(out, "section.kind", section.kind)
            searchFingerprintField(out, "section.anchor", section.anchor)
            searchFingerprintField(out, "section.text", section.text)
        }
        searchFingerprintField(out, "entry.externalDocCount", entry.externalDocs.size.toString())
        for (reference in entry.externalDocs) {
            searchFingerprintField(out, "external.name", reference.name)
            searchFingerprintField(out, "external.state", reference.state)
            searchFingerprintField(out, "external.url", reference.url)
            searchFingerprintField(out, "external.reason", reference.reason)
            searchFingerprintField(out, "external.version", reference.version)
            searchFingerprintField(out, "external.index", reference.index)
            searchFingerprintField(out, "external.format", reference.format)
            searchFingerprintField(out, "external.fingerprint", reference.fingerprint)
        }
        searchFingerprintField(out, "entry.bindingCount", entry.pageBindings.size.toString())
        for (binding in entry.pageBindings) {
            searchFingerprintField(out, "binding.target", binding.target)
            searchFingerprintField(out, "binding.selector", binding.selector)
            searchFingerprintField(out, "binding.provenance", binding.provenance)
            searchFingerprintField(out, "binding.version", binding.version)
            searchFingerprintField(out, "binding.sourceLine", binding.sourceLine.toString())
            searchFingerprintField(out, "binding.language", binding.language)
            searchFingerprintField(out, "binding.state", binding.state)
            searchFingerprintOptional(out, "binding.targetSymbolId", binding.targetSymbolId)
            searchFingerprintOptional(out, "binding.href", binding.href)
            searchFingerprintField(out, "binding.navigationTitle", binding.navigationTitle)
            searchFingerprintNavigation(out, "binding.navigation", binding.navigation)
        }
    }
    projection.contentId = contractFingerprint(out.toString())
}

private func searchFingerprintClassification(out: StringBuilder,
    classification: DeclarationClassification): Unit {
    searchFingerprintField(out, "classification.group", classification.group.isSome().toString())
    if (let Some(group) <- classification.group) {
        searchFingerprintField(out, "group.id", group.id)
        searchFingerprintField(out, "group.packageName", group.packageName)
        searchFingerprintOptional(out, "group.ownerId", group.ownerId)
        searchFingerprintField(out, "group.title", group.title)
        searchFingerprintOptional(out, "group.order",
            group.order.map({ value: Int64 => value.toString() }))
    }
    searchFingerprintField(out, "classification.tagCount", classification.tags.size.toString())
    for (tag in classification.tags) {
        searchFingerprintField(out, "classification.tag.id", tag.id)
        searchFingerprintField(out, "classification.tag.title", tag.title)
    }
}

private func searchDeclarationEntry(snapshot: DocumentationReadSnapshot, symbol: SymbolDoc,
    profile: String, scope: Int64, limits: SearchContractLimits): SearchProjectedEntry {
    let owner = searchOwnerSymbol(snapshot.projection, symbol)
    let (body, truncated) = searchProjectionBody(searchFullBody(symbol), profile, limits)
    let entry = SearchProjectedEntry(symbol.id, symbol.id, snapshot.snapshotId,
        symbol.genericParameters.size, symbol.ownerId, symbol.kind, symbol.name,
        symbol.qualifiedName, symbol.packageName, symbol.moduleId,
        searchProjectionModuleName(snapshot, symbol.moduleId).getOrDefault({ => "" }),
        owner.map({ value: SymbolDoc => value.name }).getOrDefault({ => "" }),
        owner.map({ value: SymbolDoc => value.qualifiedName }).getOrDefault({ => "" }),
        symbol.returnType.map({ value: TypeRef => value.spelling }).getOrDefault({ => "" }),
        symbol.returnType.map({ value: TypeRef =>
            value.semantic.canonical.getOrDefault({ => "" }) }).getOrDefault({ => "" }),
        searchPortableSymbolKey(symbol), "", body, truncated,
        snapshot.symbolHtmlPath(symbol.id).getOrThrow(), scope,
        classification: snapshot.projection.catalog.classificationFor(symbol))
    entry.parameterTypes.add(all: searchParameterTypes(symbol))
    entry.summary = match (symbol.documentation) {
        case Some(comment) => summaryPlainText(comment)
        case None => ""
    }
    entry.sections.add(all: searchDeclarationSections(symbol, profile, limits))
    for (reference in snapshot.documentation.externalDocumentation where reference.symbolId == symbol.id) {
        entry.externalDocs.add(reference)
    }
    entry
}

private func searchPageEntry(page: DocumentationPage, snapshotId: String, profile: String,
    limits: SearchContractLimits, projection: RenderProjection,
    locale: String): SearchProjectedEntry {
    let (body, truncated) = searchProjectionBody(
        page.title + "\n" + markdownNodeText(page.markdown), profile, limits)
    let entry = SearchProjectedEntry(page.id, page.id, snapshotId, 0, None, "concept",
        page.title, "", "", "", "", "", "", "", "", "", "", body, truncated,
        page.route, -1, concept: true)
    entry.pageBindings.add(all: projectSearchPageBindings(page, projection, locale))
    entry
}

/**
 * Attach each captured re-export alias to the canonical entry it exposes.
 *
 * The alias keeps its own name and package so an exposure-only match stays
 * reachable, but it never becomes a second result identity.
 */
private func searchAttachExposures(documentation: DocumentationSet,
    result: DocumentationSearchProjection): Unit {
    let byCanonical = HashMap<String, SearchProjectedEntry>()
    for (entry in result.entries where !entry.concept) { byCanonical[entry.id] = entry }
    for (pkg in documentation.packages) {
        for (reExport in pkg.reExports) {
            for (binding in reExport.bindings) {
                for (targetId in binding.targetSymbolIds) {
                    let entry = match (byCanonical.get(targetId)) {
                        case Some(value) => value
                        case None => continue
                    }
                    let scope = result.modulePosition(pkg.moduleId).getOrThrow()
                    let exposure = SearchExposure(
                        "${reExport.id}:${binding.exposedName}:${targetId}", binding.exposedName,
                        pkg.name + "." + binding.exposedName, pkg.name, scope)
                    var present = false
                    for (existing in entry.exposures) {
                        if (existing.id == exposure.id) { present = true; break }
                    }
                    if (!present) { entry.exposures.add(exposure) }
                }
            }
        }
    }
}
