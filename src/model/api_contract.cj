package cjdoc.model

import std.collection.*

public let API_SURFACE_SCHEMA_VERSION = "cjdoc.api-surface/2"
public let API_SURFACE_LEGACY_SCHEMA_VERSION = "cjdoc.api-surface/1"
public let API_DIFF_SCHEMA_VERSION = "cjdoc.api-diff/1"

public func isApiContractState(value: String): Bool {
    value == "resolved" || value == "partial" || value == "unavailable" || value == "ambiguous"
}
public func isApiMatchState(value: String): Bool {
    value == "exact" || value == "fallback" || value == "ambiguous" ||
        value == "added" || value == "removed"
}

public func isApiClassification(value: String): Bool {
    value == "breaking" || value == "potentially-breaking" || value == "additive" ||
        value == "documentation-only" || value == "metadata-only" || value == "unchanged"
}

public class ApiContractParameter {
    public let name: String
    public let typeState: String
    public let `type`: ?String
    public let defaultState: String
    public let defaultValue: ?String

    public init(name: String, typeState!: String = "unavailable", `type`!: ?String = None,
        defaultState!: String = "unavailable", defaultValue!: ?String = None) {
        if (name.isEmpty() || !isApiContractState(typeState) || !isApiContractState(defaultState)) {
            throw IllegalArgumentException("invalid API contract parameter")
        }
        if ((typeState == "resolved" && `type`.isNone()) ||
            (typeState != "resolved" && `type`.isSome())) {
            throw IllegalArgumentException("API parameter type state/value mismatch")
        }
        if ((defaultState == "resolved" && defaultValue.isNone()) ||
            (defaultState != "resolved" && defaultValue.isSome())) {
            throw IllegalArgumentException("API parameter default state/value mismatch")
        }
        this.name = name
        this.typeState = typeState
        this.`type` = `type`
        this.defaultState = defaultState
        this.defaultValue = defaultValue
    }
}

public class ApiContractDeclaration {
    public let id: String
    public let moduleId: String
    public let packageName: String
    public let ownerId: ?String
    public let kind: String
    public let name: String
    public let qualifiedName: String
    public let visibility: String
    public let sourceApiSignatureState: String
    private let sourceApiSignatureStorage: ArrayList<String>
    private let genericParametersStorage: ArrayList<String>
    private let parametersStorage: ArrayList<ApiContractParameter>
    public let returnState: String
    public let returnType: ?String
    private let relationshipStorage: ArrayList<String>
    public let enumNonExhaustive: ?Bool
    public let documentationFingerprint: String
    public let sourceFingerprint: String
    public let metadataFingerprint: String
    public let collectionState: String

    public init(id: String, moduleId: String, packageName: String, kind: String, name: String,
        qualifiedName: String, visibility: String, sourceApiSignatureState: String,
        sourceApiSignature!: Array<String> = [], ownerId!: ?String = None,
        genericParameters!: Array<String> = [], parameters!: Array<ApiContractParameter> = [],
        returnState!: String = "unavailable", returnType!: ?String = None,
        relationships!: Array<String> = [], enumNonExhaustive!: ?Bool = None,
        documentationFingerprint!: String = "", sourceFingerprint!: String = "",
        metadataFingerprint!: String = "", collectionState!: String = "resolved") {
        if (id.isEmpty() || moduleId.isEmpty() || packageName.isEmpty() || kind.isEmpty() ||
            name.isEmpty() || !isApiContractState(collectionState) ||
            !isApiContractState(returnState) || !isApiContractState(sourceApiSignatureState)) {
            throw IllegalArgumentException("invalid API contract declaration")
        }
        if ((sourceApiSignatureState == "resolved" && sourceApiSignature.isEmpty()) ||
            (sourceApiSignatureState != "resolved" && !sourceApiSignature.isEmpty())) {
            throw IllegalArgumentException("API source signature state/value mismatch")
        }
        if ((returnState == "resolved" && returnType.isNone()) ||
            (returnState != "resolved" && returnType.isSome())) {
            throw IllegalArgumentException("API return state/value mismatch")
        }
        this.id = id
        this.moduleId = moduleId
        this.packageName = packageName
        this.ownerId = ownerId
        this.kind = kind
        this.name = name
        this.qualifiedName = qualifiedName
        this.visibility = visibility
        this.sourceApiSignatureState = sourceApiSignatureState
        this.sourceApiSignatureStorage = ArrayList<String>(sourceApiSignature)
        this.genericParametersStorage = ArrayList<String>(genericParameters)
        this.parametersStorage = ArrayList<ApiContractParameter>(parameters)
        this.returnState = returnState
        this.returnType = returnType
        this.relationshipStorage = ArrayList<String>(relationships)
        this.enumNonExhaustive = enumNonExhaustive
        this.documentationFingerprint = documentationFingerprint
        this.sourceFingerprint = sourceFingerprint
        this.metadataFingerprint = metadataFingerprint
        this.collectionState = collectionState
    }

    public prop sourceApiSignature: ReadOnlyList<String> { get() { sourceApiSignatureStorage } }
    public prop genericParameters: ReadOnlyList<String> { get() { genericParametersStorage } }
    public prop parameters: ReadOnlyList<ApiContractParameter> { get() { parametersStorage } }
    public prop relationships: ReadOnlyList<String> { get() { relationshipStorage } }
}

public class ApiContractExposure {
    public let id: String
    public let moduleId: String
    public let packageName: String
    public let exposedName: String
    private let targetIdsStorage: ArrayList<String>
    public let state: String

    public init(id: String, moduleId: String, packageName: String, exposedName: String,
        targetIds: Array<String>, state!: String = "resolved") {
        if (id.isEmpty() || moduleId.isEmpty() || packageName.isEmpty() || exposedName.isEmpty() ||
            targetIds.isEmpty() || !isApiContractState(state)) {
            throw IllegalArgumentException("invalid API exposure")
        }
        this.id = id
        this.moduleId = moduleId
        this.packageName = packageName
        this.exposedName = exposedName
        this.targetIdsStorage = ArrayList<String>(targetIds)
        this.state = state
    }

    public prop targetIds: ReadOnlyList<String> { get() { targetIdsStorage } }
}

public class ApiContractSnapshot {
    public let schemaVersion: String
    public let project: String
    public let audience: String
    public let cfgProfile: String
    public let collectionState: String
    private let declarationsStorage: ArrayList<ApiContractDeclaration>
    private let exposuresStorage: ArrayList<ApiContractExposure>

    public init(project: String, audience: String, cfgProfile: String,
        collectionState!: String = "resolved", declarations!: Array<ApiContractDeclaration> = [],
        exposures!: Array<ApiContractExposure> = [], schemaVersion!: String = API_SURFACE_SCHEMA_VERSION) {
        if (project.isEmpty() || audience.isEmpty() || cfgProfile.isEmpty() ||
            !isApiContractState(collectionState) ||
            (schemaVersion != API_SURFACE_SCHEMA_VERSION && schemaVersion != API_SURFACE_LEGACY_SCHEMA_VERSION)) {
            throw IllegalArgumentException("invalid API contract snapshot")
        }
        this.schemaVersion = schemaVersion
        this.project = project
        this.audience = audience
        this.cfgProfile = cfgProfile
        this.collectionState = collectionState
        this.declarationsStorage = ArrayList<ApiContractDeclaration>(declarations)
        this.exposuresStorage = ArrayList<ApiContractExposure>(exposures)
    }

    public prop declarations: ReadOnlyList<ApiContractDeclaration> { get() { declarationsStorage } }
    public prop exposures: ReadOnlyList<ApiContractExposure> { get() { exposuresStorage } }
}

public class ApiDiffEvidence {
    public let field: String
    public let before: ?String
    public let after: ?String
    public let state: String

    public init(field: String, before!: ?String = None, after!: ?String = None,
        state!: String = "resolved") {
        if (field.isEmpty() || !isApiContractState(state)) {
            throw IllegalArgumentException("invalid API diff evidence")
        }
        this.field = field
        this.before = before
        this.after = after
        this.state = state
    }
}

public class ApiDiffEntry {
    public let oldId: ?String
    public let newId: ?String
    public let kind: String
    public let classification: String
    public let matchState: String
    private let reasonsStorage: ArrayList<String>
    private let evidenceStorage: ArrayList<ApiDiffEvidence>

    public init(kind: String, classification: String, matchState: String,
        oldId!: ?String = None, newId!: ?String = None, reasons!: Array<String> = [],
        evidence!: Array<ApiDiffEvidence> = []) {
        if (kind.isEmpty() || !isApiClassification(classification) || !isApiMatchState(matchState)) {
            throw IllegalArgumentException("invalid API diff entry")
        }
        this.oldId = oldId
        this.newId = newId
        this.kind = kind
        this.classification = classification
        this.matchState = matchState
        this.reasonsStorage = ArrayList<String>(reasons)
        this.evidenceStorage = ArrayList<ApiDiffEvidence>(evidence)
    }

    public prop reasons: ReadOnlyList<String> { get() { reasonsStorage } }
    public prop evidence: ReadOnlyList<ApiDiffEvidence> { get() { evidenceStorage } }
}

public class ApiDiffSummary {
    public let breaking: Int64
    public let potentiallyBreaking: Int64
    public let additive: Int64
    public let documentationOnly: Int64
    public let metadataOnly: Int64
    public let unchanged: Int64

    public init(breaking!: Int64 = 0, potentiallyBreaking!: Int64 = 0, additive!: Int64 = 0,
        documentationOnly!: Int64 = 0, metadataOnly!: Int64 = 0, unchanged!: Int64 = 0) {
        this.breaking = breaking
        this.potentiallyBreaking = potentiallyBreaking
        this.additive = additive
        this.documentationOnly = documentationOnly
        this.metadataOnly = metadataOnly
        this.unchanged = unchanged
    }
}

public class ApiDiffReport {
    public let schemaVersion: String
    public let baseline: ApiContractSnapshot
    public let current: ApiContractSnapshot
    public let comparisonState: String
    public let summary: ApiDiffSummary
    private let entriesStorage: ArrayList<ApiDiffEntry>

    public init(baseline: ApiContractSnapshot, current: ApiContractSnapshot,
        comparisonState!: String = "resolved", summary!: ApiDiffSummary = ApiDiffSummary(),
        entries!: Array<ApiDiffEntry> = []) {
        if (!isApiContractState(comparisonState)) {
            throw IllegalArgumentException("invalid API diff comparison state")
        }
        this.schemaVersion = API_DIFF_SCHEMA_VERSION
        this.baseline = baseline
        this.current = current
        this.comparisonState = comparisonState
        this.summary = summary
        this.entriesStorage = ArrayList<ApiDiffEntry>(entries)
    }

    public prop entries: ReadOnlyList<ApiDiffEntry> { get() { entriesStorage } }
}
