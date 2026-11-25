protected package cjdoc.render.search

import cjdoc.model.*
import cjdoc.schema_data.documentationSearchContract
import cjdoc.render.publication.{DeclarationClassification, EMPTY_DECLARATION_CLASSIFICATION}
import std.collection.*
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
    // Published comment field values of this declaration. Kept out of `body` so a
    // custom value is never truncated by the body budget or ranked as a name.
    protected var commentFieldRows: Array<SearchCommentFieldUse> = []
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

/** One published comment field namespace, shared by every member using it. */
protected class SearchProjectionCommentField {
    protected let scope: Int64
    protected let id: String
    protected let title: String
    protected let repeatable: Bool

    protected init(scope: Int64, id: String, title: String, repeatable: Bool) {
        this.scope = scope
        this.id = id
        this.title = title
        this.repeatable = repeatable
    }
}

/** One declaration's values for one field, in author order. */
protected class SearchCommentFieldUse {
    protected let id: String
    private let valuesStorage: ArrayList<String>

    protected init(id: String, values: Array<String>) {
        this.id = id
        this.valuesStorage = ArrayList<String>(values)
    }

    protected func values(): ArrayList<String> { valuesStorage }
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
    protected let commentFieldDictionary = ArrayList<SearchProjectionCommentField>()
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
