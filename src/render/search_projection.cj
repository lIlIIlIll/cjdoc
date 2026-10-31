package cjdoc.render

import cjdoc.model.*
import cjdoc.schema_data.*
import std.collection.*
import std.sort.*
import yjson.*
/** All profile and display budgets are read from documentationSearchContract(). */

/** Contract-backed body and display budgets for one captured projection. */
protected class SearchContractLimits {
    protected let defaultProfile: String
    protected let staticProfile: String
    protected let profiles = ArrayList<String>()
    protected let staticBodyTextLimit: Int64
    protected let summaryDisplayLimit: Int64
    protected let signatureDisplayLimit: Int64

    protected init(contractJson: String) {
        let contract = JsonNode.parse(contractJson).asObject()
        defaultProfile = contract.get("defaultProfile").getOrThrow().asString()
        let properties = contract.get("requestProperties").getOrThrow().asObject()
        let profile = properties.get("profile").getOrThrow().asObject()
        let profileValues = profile.get("enum").getOrThrow().asArray()
        var selectedStaticProfile = ""
        for (index in 0..profileValues.size()) {
            let value = profileValues[index].asString()
            profiles.add(value)
            if (value != defaultProfile) {
                if (!selectedStaticProfile.isEmpty()) {
                    throw IllegalArgumentException("search contract has multiple publication profiles")
                }
                selectedStaticProfile = value
            }
        }
        if (selectedStaticProfile.isEmpty()) {
            throw IllegalArgumentException("search contract has no publication profile")
        }
        staticProfile = selectedStaticProfile
        staticBodyTextLimit = contract.get("staticBodyTextLimit").getOrThrow().asInt64()
        summaryDisplayLimit = contract.get("summaryDisplayLimit").getOrThrow().asInt64()
        signatureDisplayLimit = contract.get("signatureDisplayLimit").getOrThrow().asInt64()
    }
}

private let DOCUMENTATION_SEARCH_CONTRACT_JSON = documentationSearchContract()
private let DOCUMENTATION_SEARCH_CONTRACT_LIMITS =
    SearchContractLimits(DOCUMENTATION_SEARCH_CONTRACT_JSON)

/** One process-static parse and authoritative serialization of the shared contract. */
protected func searchContractLimits(): SearchContractLimits {
    DOCUMENTATION_SEARCH_CONTRACT_LIMITS
}

protected func searchContractJson(): String { DOCUMENTATION_SEARCH_CONTRACT_JSON }

/** Profile the native query session projects captured Doc IR with. */
protected func searchProfileName(): String { searchContractLimits().defaultProfile }

protected func searchProfileIsKnown(profile: String): Bool {
    searchContractLimits().profiles.contains(profile)
}
/** The publisher uses the unique non-default profile from the shared contract. */
protected func searchStaticProfileName(): String {
    searchContractLimits().staticProfile
}

/** Captured publication scope of one module reference. */
protected class SearchScopeModule {
    protected let moduleId: String
    protected let moduleName: ?String
    protected let documentSet: ?DocumentSetIdentity
    protected let dependency: ?DependencyInstance
    protected let dependencyState: String

    protected init(moduleId: String, moduleName: ?String,
        documentSet: ?DocumentSetIdentity, dependency: ?DependencyInstance,
        dependencyState: String) {
        this.moduleId = moduleId
        this.moduleName = moduleName
        this.documentSet = documentSet
        this.dependency = dependency
        this.dependencyState = dependencyState
    }
}

/** One alias a declaration is exposed under by a captured re-export. */
protected class SearchExposure {
    protected let id: String
    protected let name: String
    protected let qualifiedName: String
    protected let packageName: String
    /** Index into the projection module table for the alias's own source scope. */
    protected let scope: Int64

    protected init(id: String, name: String, qualifiedName: String, packageName: String,
        scope: Int64) {
        this.id = id
        this.name = name
        this.qualifiedName = qualifiedName
        this.packageName = packageName
        this.scope = scope
    }
}

/** A documented block that renders at a stable anchor on the detail page. */
protected class SearchSection {
    /** The rendered block the section points at: parameters, return or throws. */
    protected let kind: String
    protected let anchor: String
    protected let text: String

    protected init(kind: String, anchor: String, text: String) {
        this.kind = kind
        this.anchor = anchor
        this.text = text
    }
}

/** A captured page binding with publication-specific visibility already resolved. */
protected class SearchPageBinding {
    protected let target: String
    protected let selector: String
    protected let provenance: String
    protected let version: String
    protected let sourceLine: Int64
    protected let language: String
    protected let state: String
    protected let targetSymbolId: ?String
    protected let href: ?String
    protected let navigationTitle: String
    protected let navigation: ?TypeNavigation

    protected init(target: String, selector: String, provenance: String, version: String,
        sourceLine: Int64, language: String, state: String, targetSymbolId: ?String,
        href: ?String, navigationTitle: String, navigation: ?TypeNavigation) {
        this.target = target
        this.selector = selector
        this.provenance = provenance
        this.version = version
        this.sourceLine = sourceLine
        this.language = language
        this.state = state
        this.targetSymbolId = targetSymbolId
        this.href = href
        this.navigationTitle = navigationTitle
        this.navigation = navigation
    }
}

/**
 * One canonical searchable entry: a declaration or a conceptual page.
 *
 * A re-export is an `exposure` of this entry, never a second entry, so counting
 * and paging cannot inflate one declaration into several results.
 */
protected class SearchProjectedEntry {
    protected let id: String
    protected let canonicalId: String
    protected let snapshotId: String
    protected let genericArity: Int64
    protected let ownerId: ?String
    protected let kind: String
    protected let name: String
    protected let qualifiedName: String
    protected let packageName: String
    protected let moduleId: String
    protected let moduleName: String
    protected let ownerName: String
    protected let ownerQualifiedName: String
    protected let parameterTypes = ArrayList<String>()
    protected let returnType: String
    protected let returnCanonical: String
    protected let symbolKey: String
    protected var summary: String
    protected var body: String
    protected var bodyTruncated: Bool
    protected let href: String
    protected let scope: Int64
    protected let concept: Bool
    protected let classification: DeclarationClassification
    protected let tagIds: Array<String>
    protected let metadataText: String
    protected var tagFacets: Array<SearchProjectionTag> = []
    protected let exposures = ArrayList<SearchExposure>()
    protected let sections = ArrayList<SearchSection>()
    protected let externalDocs = ArrayList<ExternalDocumentationReference>()
    protected let pageBindings = ArrayList<SearchPageBinding>()

    protected init(id: String, canonicalId: String, snapshotId: String,
        genericArity: Int64, ownerId: ?String, kind: String, name: String,
        qualifiedName: String, packageName: String, moduleId: String, moduleName: String,
        ownerName: String, ownerQualifiedName: String, returnType: String,
        returnCanonical: String, symbolKey: String, summary: String, body: String,
        bodyTruncated: Bool, href: String, scope: Int64, concept!: Bool = false,
        classification!: DeclarationClassification = EMPTY_DECLARATION_CLASSIFICATION) {
        this.id = id
        this.canonicalId = canonicalId
        this.snapshotId = snapshotId
        this.genericArity = genericArity
        this.ownerId = ownerId
        this.kind = kind
        this.name = name
        this.qualifiedName = qualifiedName
        this.packageName = packageName
        this.moduleId = moduleId
        this.moduleName = moduleName
        this.ownerName = ownerName
        this.ownerQualifiedName = ownerQualifiedName
        this.returnType = returnType
        this.returnCanonical = returnCanonical
        this.symbolKey = symbolKey
        this.summary = summary
        this.body = body
        this.bodyTruncated = bodyTruncated
        this.href = href
        this.scope = scope
        this.concept = concept
        this.classification = classification
        this.tagIds = if (classification.tags.isEmpty()) { [] } else {
            Array<String>(classification.tags.size, { index => classification.tags[index].id })
        }
        this.metadataText = classification.text
    }
}

/**
 * The immutable retrieval projection of one captured publication.
 *
 * Both executors read exactly this shape: the native session builds one per
 * snapshot for a requested profile, and the HTML index serialises the
 * `bounded-static` one.
 */
protected class DocumentationSearchProjection {
    protected let profile: String
    protected let fullProfileName: String
    protected let scopeSnapshotId: String
    protected let sourceSnapshotId: String
    protected let publicationRevision: String
    protected let language: String
    protected let audience: String
    protected let cfgProfile: String
    protected let apiCollectionState: String
    protected let project: String
    protected let staticBodyTextLimit: Int64
    protected let summaryDisplayLimit: Int64
    protected let signatureDisplayLimit: Int64
    protected var contentId: String
    protected let modules = ArrayList<SearchScopeModule>()
    protected let entries = ArrayList<SearchProjectedEntry>()
    protected let tagDictionary = ArrayList<SearchProjectionTag>()
    private let moduleIndex = HashMap<String, Int64>()
    private let entryIndex = HashMap<String, SearchProjectedEntry>()

    protected init(profile: String, scopeSnapshotId: String, sourceSnapshotId: String,
        publicationRevision: String, language: String, audience: String, cfgProfile: String,
        apiCollectionState: String, project: String, limits: SearchContractLimits,
        contentId: String) {
        this.profile = profile
        this.fullProfileName = limits.defaultProfile
        this.scopeSnapshotId = scopeSnapshotId
        this.sourceSnapshotId = sourceSnapshotId
        this.publicationRevision = publicationRevision
        this.language = language
        this.audience = audience
        this.cfgProfile = cfgProfile
        this.apiCollectionState = apiCollectionState
        this.project = project
        this.staticBodyTextLimit = limits.staticBodyTextLimit
        this.summaryDisplayLimit = limits.summaryDisplayLimit
        this.signatureDisplayLimit = limits.signatureDisplayLimit
        this.contentId = contentId
    }

    protected prop bodyComplete: Bool { get() { truncatedCount == 0 } }

    protected prop bodyTextLimit: ?Int64 {
        get() {
            if (profile == fullProfileName) { None } else { Some(staticBodyTextLimit) }
        }
    }

    protected prop truncatedCount: Int64 {
        get() {
            var count: Int64 = 0
            for (entry in entries where entry.bodyTruncated) { count++ }
            count
        }
    }

    /** Full stored body text of one canonical entry, found without a scan. */
    protected func bodyOf(canonicalId: String): String {
        entryIndex.get(searchEntryKey(scopeSnapshotId, canonicalId)).
            map({ entry: SearchProjectedEntry => entry.body }).getOrDefault({ => "" })
    }

    protected func addModule(module: SearchScopeModule): Int64 {
        let position = modules.size
        modules.add(module)
        moduleIndex[module.moduleId] = position
        position
    }

    protected func modulePosition(moduleId: String): ?Int64 {
        moduleIndex.get(moduleId)
    }

    protected func addEntry(entry: SearchProjectedEntry): Unit {
        entries.add(entry)
        entryIndex[searchEntryKey(entry.snapshotId, entry.canonicalId)] = entry
    }

    protected func scopeOf(entry: SearchProjectedEntry): ?SearchScopeModule {
        if (entry.scope < 0 || entry.scope >= modules.size) { return None }
        Some(modules[entry.scope])
    }
}

private func searchEntryKey(snapshotId: String, canonicalId: String): String {
    snapshotId + "\u{0}" + canonicalId
}


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

/** Emit every author tag's identity and parsed descriptive prose as body text. */
private func searchTagBodyText(tag: DocTag): String {
    let out = RenderTextBuffer()
    out.append(tag.name)
    if (!tag.subject.isEmpty()) { out.append(" " + tag.subject) }
    if (let Some(tree) <- tag.descriptionMarkdown) {
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

/** Full retrieval body from the comment AST, tags and captured parameter prose. */
private func searchFullBody(symbol: SymbolDoc): String {
    let comment = match (symbol.documentation) {
        case Some(value) => value
        case None => return ""
    }
    let out = RenderTextBuffer()
    out.append(markdownNodeText(comment.markdown))
    for (tag in comment.tags) {
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


private func searchPackageHasVisibleExposure(value: PackageDoc,
    visible: HashMap<String, SymbolDoc>): Bool {
    for (reExport in value.reExports) {
        for (binding in reExport.bindings) {
            for (targetId in binding.targetSymbolIds) {
                if (visible.contains(targetId)) { return true }
            }
        }
    }
    false
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

    // Sort all canonical and exposure scopes before assigning their shared
    // table positions. The table then captures each full module identity once.
    // Keep one full module identity per module and let entries/exposures retain
    // their package context separately.
    let moduleIds = ArrayList<String>()
    let seenModuleIds = HashSet<String>()
    let orderedSymbols = ArrayList<SymbolDoc>(projection.visibleSymbols.toArray())
    sort(orderedSymbols, lessThan: { left, right =>
        if (left.moduleId != right.moduleId) { left.moduleId < right.moduleId }
        else if (left.packageName != right.packageName) { left.packageName < right.packageName }
        else { left.id < right.id }
    }, stable: true)
    for (symbol in orderedSymbols) {
        if (seenModuleIds.add(symbol.moduleId)) { moduleIds.add(symbol.moduleId) }
    }
    for (pkg in documentation.packages) {
        if (!searchPackageHasVisibleExposure(pkg, projection.visibleIndex)) { continue }
        if (seenModuleIds.add(pkg.moduleId)) { moduleIds.add(pkg.moduleId) }
    }
    sort(moduleIds)
    for (moduleId in moduleIds) {
        let (dependency, state) = snapshot.moduleDependencyState(moduleId)
        result.addModule(SearchScopeModule(moduleId,
            searchProjectionModuleName(snapshot, moduleId),
            snapshot.documentSetForModule(moduleId), dependency, state))
    }
    for (symbol in orderedSymbols) {
        let scope = result.modulePosition(symbol.moduleId).getOrThrow()
        result.addEntry(searchDeclarationEntry(snapshot, symbol, profile, scope, limits))
    }
    for (page in snapshot.selectedPages()) {
        result.addEntry(searchPageEntry(page, snapshot.snapshotId, profile, limits,
            projection.visibleIndex, snapshot.locale))
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
    searchFingerprintField(out, "format", "cjdoc.search-projection/3")
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
        symbolUrl(snapshot.projection.visibleIndex, symbol), scope,
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
    limits: SearchContractLimits, visible: HashMap<String, SymbolDoc>,
    locale: String): SearchProjectedEntry {
    let (body, truncated) = searchProjectionBody(
        page.title + "\n" + markdownNodeText(page.markdown), profile, limits)
    let entry = SearchProjectedEntry(page.id, page.id, snapshotId, 0, None, "concept",
        page.title, "", "", "", "", "", "", "", "", "", "", body, truncated,
        page.route, -1, concept: true)
    entry.pageBindings.add(all: projectSearchPageBindings(page, visible, locale))
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
