package cjdoc.model

/** Dependency evidence is independent of semantic resolution and documentation navigation. */
public class DependencyInstance {
    public let moduleId: String
    /** Actual selected source-graph component; empty when no source edge is known. */
    public let componentModuleId: String
    public let name: String
    public let instanceId: String
    public let kind: String
    public let identity: String
    public let state: String
    public let evidence: String
    public let version: String
    public let revision: String
    public let target: String
    public let cfg: String

    public init(moduleId: String, name: String, instanceId: String, kind: String,
        identity: String, state: String, evidence: String, version!: String = "",
        revision!: String = "", target!: String = "", cfg!: String = "", componentModuleId!: String = "") {
        if (moduleId.isEmpty() || name.isEmpty() || instanceId.isEmpty()) {
            throw IllegalArgumentException("dependency instance requires module, name and instance identity")
        }
        match (kind) {
            case "source" | "binary" | "std" | "stdx" | "toolchain" => ()
            case _ => throw IllegalArgumentException("invalid dependency instance kind")
        }
        match (state) {
            case "unknown" | "declared" | "observed" | "verified" | "conflict" => ()
            case _ => throw IllegalArgumentException("invalid dependency evidence state")
        }
        this.moduleId = moduleId
        this.componentModuleId = componentModuleId
        this.name = name
        this.instanceId = instanceId
        this.kind = kind
        this.identity = identity
        this.state = state
        this.evidence = evidence
        this.version = version
        this.revision = revision
        this.target = target
        this.cfg = cfg
    }
}

/** Portable provenance for one library's documentation, not a semantic provider. */
public class DocumentSetIdentity {
    public let id: String
    /** Producer module identifier, scoped by indexIdentity rather than consumer module IDs. */
    public let moduleId: String
    public let library: String
    public let identity: String
    public let state: String
    public let source: String
    public let target: String
    public let cfg: String
    public let audience: String
    public let language: String
    public let revision: String
    /** API package version declared by the source package, not a release attestation. */
    public let apiVersion: String
    /** Documentation publication revision, independent of the API source revision above. */
    public let documentationRevision: String
    public let indexIdentity: String
    public let baseUrl: String

    public init(id: String, library: String, identity: String, state: String, source: String,
        target!: String = "", cfg!: String = "", audience!: String = "external",
        language!: String = "", revision!: String = "", indexIdentity!: String = "",
        baseUrl!: String = "", moduleId!: String = "", apiVersion!: String = "", documentationRevision!: String = "") {
        if (id.isEmpty() || library.isEmpty()) {
            throw IllegalArgumentException("document set requires id and library")
        }
        match (state) {
            case "observed" | "verified" | "declared" | "unknown" => ()
            case _ => throw IllegalArgumentException("invalid document set evidence state")
        }
        if (source.startsWith("/") || source.startsWith("file:") || source.contains("\\") ||
            (source.size > 1 && source.toArray()[1] == b':')) {
            throw IllegalArgumentException("document set source must be portable provenance, not a host path")
        }
        this.id = id
        this.moduleId = moduleId
        this.library = library
        this.identity = identity
        this.state = state
        this.source = source
        this.target = target
        this.cfg = cfg
        this.audience = audience
        this.language = language
        this.revision = revision
        this.apiVersion = apiVersion
        this.documentationRevision = documentationRevision
        this.indexIdentity = indexIdentity
        this.baseUrl = baseUrl
    }
}

/** A navigation decision never upgrades TypeRef.semantic or its provider evidence. */
public class TypeNavigation {
    public let state: String
    public let matchLevel: String
    public let reason: String
    public let dependencyInstanceId: String
    public let documentSetId: String
    public let indexIdentity: String
    public let symbolKey: String
    public let url: String
    public let apiIdentity: String
    public let language: String

    public init(state: String, matchLevel: String, reason: String,
        dependencyInstanceId!: String = "", documentSetId!: String = "",
        indexIdentity!: String = "", symbolKey!: String = "", url!: String = "",
        apiIdentity!: String = "", language!: String = "") {
        match (state) {
            case "resolved" | "unresolved" | "ambiguous" | "unavailable" => ()
            case _ => throw IllegalArgumentException("invalid type navigation state")
        }
        match (matchLevel) {
            case "exact" | "compatible" | "manual" | "none" => ()
            case _ => throw IllegalArgumentException("invalid type navigation match level")
        }
        if (reason.trimAscii().isEmpty() || (state == "resolved" && (url.isEmpty() || matchLevel == "none")) ||
            (state != "resolved" && !url.isEmpty())) {
            throw IllegalArgumentException("type navigation requires an explanation and a URL only when resolved")
        }
        this.state = state
        this.matchLevel = matchLevel
        this.reason = reason
        this.dependencyInstanceId = dependencyInstanceId
        this.documentSetId = documentSetId
        this.indexIdentity = indexIdentity
        this.symbolKey = symbolKey
        this.url = url
        this.apiIdentity = apiIdentity
        this.language = language
    }
}

/** Portable exact key: qualified path, declaration kind, generic arity and source parameter spellings. */
public func portableSymbolKey(packageName: String, qualifiedName: String, kind: String,
    genericArity: Int64, parameterTypes!: Array<String> = []): String {
    let qualified = if (packageName.isEmpty() || qualifiedName == packageName ||
        qualifiedName.startsWith(packageName + ".")) { qualifiedName }
        else { packageName + "." + qualifiedName }
    let out = StringBuilder()
    out.append(qualified)
    out.append("|${kind}|${genericArity}(")
    var first = true
    for (parameter in parameterTypes) {
        if (!first) { out.append(",") }
        first = false
        out.append(parameter)
    }
    out.append(")")
    out.toString()
}
