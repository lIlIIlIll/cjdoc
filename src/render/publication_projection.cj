package cjdoc.render

import cjdoc.model.*
import std.collection.*
import yjson.*

// Publication projection is one bounded, deterministic transform of captured
// Doc IR. It never introduces a second documentation schema: the result is
// strict Doc IR that the canonical codec, domain validation and renderers
// accept. The transform runs on the canonical encoded tree, which can drop
// identity-bearing facts without restating every typed constructor, and then
// decodes a detached typed value so the caller's DocumentationSet is never
// mutated (diagnostics are mutable after construction).

private let PUBLICATION_AUDIENCE_EXCLUDED = "target excluded by documentation audience"
private let PUBLICATION_AUDIENCE_SCOPE =
    "document set evidence belongs to a different documentation audience"
private let PUBLICATION_DIAGNOSTIC_OMITTED =
    "Details omitted because this diagnostic has no visible declaration binding."

private func publicationAudienceRank(audience: String): ?Int64 {
    match (audience) {
        case "external" => Some(0)
        case "package" => Some(1)
        case "all" => Some(2)
        case _ => None
    }
}

private func publicationAudienceOrFail(audience: String, what: String): String {
    match (publicationAudienceRank(audience)) {
        case Some(_) => audience
        case None => throw IllegalArgumentException(
            "${what} must be external, package, or all")
    }
}

/** Lookup shared by every published surface of one projection pass. */
private class PublicationContext {
    let audience: String
    let kept: HashSet<String>
    let hidden: HashSet<String>
    let documentSetAudiences: HashMap<String, String>

    init(audience: String, kept: HashSet<String>, hidden: HashSet<String>,
        documentSetAudiences: HashMap<String, String>) {
        this.audience = audience
        this.kept = kept
        this.hidden = hidden
        this.documentSetAudiences = documentSetAudiences
    }
}

private func publicationParse(text: String): JsonNode {
    JsonNode.parse(text, config: JsonReadOptions(
        duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
        maxDepth: DOC_IR_CODEC_MAX_NESTING_DEPTH,
        maxStringBytes: DOC_IR_MAX_JSON_STRING_BYTES,
        maxBufferedValueBytes: DOC_IR_MAX_JSON_DOCUMENT_BYTES,
        maxInputBytes: DOC_IR_MAX_JSON_DOCUMENT_BYTES))
}

private func publicationWrite(root: JsonNode): String {
    root.toJson(options: JsonWriteOptions(
        maxOutputBytes: DOC_IR_MAX_JSON_DOCUMENT_BYTES,
        maxDepth: DOC_IR_CODEC_MAX_NESTING_DEPTH))
}

private func publicationObject(node: JsonNode): ?JsonObject {
    if (node.kind() != JsonKind.Object) { return None }
    Some(node.asObject())
}

private func publicationElements(node: JsonNode, key: String): ArrayList<JsonNode> {
    let result = ArrayList<JsonNode>()
    let object = match (publicationObject(node)) {
        case Some(value) => value
        case None => return result
    }
    match (object.get(key)) {
        case Some(items) => if (items.kind() == JsonKind.Array) {
            let array = items.asArray()
            var index: Int64 = 0
            while (index < array.size()) {
                result.add(array.get(index).getOrThrow())
                index++
            }
        }
        case None => ()
    }
    result
}

private func publicationString(node: JsonNode, key: String): ?String {
    let object = match (publicationObject(node)) {
        case Some(value) => value
        case None => return None
    }
    match (object.get(key)) {
        case Some(value) => if (value.kind() == JsonKind.String) { Some(value.asString()) } else { None }
        case None => None
    }
}

private func publicationText(node: JsonNode, key: String): String {
    publicationString(node, key).getOrDefault({ => "" })
}

private func publicationReplaceArray(node: JsonNode, key: String,
    items: ArrayList<JsonNode>): Unit {
    let array = JsonNode.array()
    for (item in items) { array.add(item) }
    match (publicationObject(node)) {
        case Some(object) => let _ = object.put(key, array)
        case None => ()
    }
}

// A declared symbol array keeps only published SymbolIds, preserving the
// captured order so deterministic publication stays stable.
private func publicationKeepSymbolIds(node: JsonNode, key: String,
    ids: HashSet<String>): ArrayList<JsonNode> {
    let result = ArrayList<JsonNode>()
    for (item in publicationElements(node, key)) {
        if (item.kind() == JsonKind.String && ids.contains(item.asString())) { result.add(item) }
    }
    result
}

private func publicationDocumentSetAudiences(root: JsonNode): HashMap<String, String> {
    let result = HashMap<String, String>()
    for (documentSet in publicationElements(root, "documentSets")) {
        let id = publicationText(documentSet, "id")
        if (!id.isEmpty()) { result[id] = publicationText(documentSet, "audience") }
    }
    result
}

private func publicationNavigationFailure(reason: String): JsonNode {
    let failure = JsonNode.array()
    failure.add(JsonNode.string("unavailable"))
    failure.add(JsonNode.string(reason))
    failure
}

// A captured navigation decision is retired to the canonical context-free
// failure when its selected evidence would disclose an unpublished declaration
// or was captured for a different documentation audience. No rejected decision
// is upgraded; it simply stops claiming a target.
private func publicationNavigationRejection(node: JsonNode,
    context: PublicationContext): ?String {
    let symbolKey = publicationText(node, "symbolKey")
    if (!symbolKey.isEmpty() && context.hidden.contains(symbolKey)) {
        return Some(PUBLICATION_AUDIENCE_EXCLUDED)
    }
    let matchLevel = publicationText(node, "matchLevel")
    if (matchLevel != "exact" && matchLevel != "compatible") { return None }
    let documentSetId = publicationText(node, "documentSetId")
    if (documentSetId.isEmpty()) { return None }
    match (context.documentSetAudiences.get(documentSetId)) {
        case Some(audience) => if (audience != context.audience) { return Some(PUBLICATION_AUDIENCE_SCOPE) }
        case None => ()
    }
    None
}

private func publicationSanitizeNavigation(node: JsonNode,
    context: PublicationContext): JsonNode {
    match (node.kind()) {
        case JsonKind.Array =>
            let array = node.asArray()
            var index: Int64 = 0
            while (index < array.size()) {
                array.set(index, publicationSanitizeNavigation(array.get(index).getOrThrow(), context))
                index++
            }
            node
        case JsonKind.Object =>
            let object = node.asObject()
            if (object.contains("matchLevel") && object.contains("reason")) {
                match (publicationNavigationRejection(node, context)) {
                    case Some(reason) => return publicationNavigationFailure(reason)
                    case None => ()
                }
            }
            var index: Int64 = 0
            while (index < object.size()) {
                let key = object.nameAt(index)
                object.put(key, publicationSanitizeNavigation(object.valueAt(index), context))
                index++
            }
            node
        case _ => node
    }
}

private func publicationSanitizeNavigationTree(root: JsonNode,
    context: PublicationContext): Unit {
    match (publicationObject(root)) {
        case Some(object) =>
            var index: Int64 = 0
            while (index < object.size()) {
                let key = object.nameAt(index)
                object.put(key, publicationSanitizeNavigation(object.valueAt(index), context))
                index++
            }
        case None => ()
    }
}

private func publicationRetireSelected(node: JsonNode): JsonNode {
    match (node.kind()) {
        case JsonKind.Array =>
            let array = node.asArray()
            var index: Int64 = 0
            while (index < array.size()) {
                array.set(index, publicationRetireSelected(array.get(index).getOrThrow()))
                index++
            }
            node
        case JsonKind.Object =>
            let object = node.asObject()
            let matchLevel = publicationText(node, "matchLevel")
            if ((matchLevel == "exact" || matchLevel == "compatible") &&
                object.contains("reason")) {
                // A selected link whose page lost its occurrence context can no
                // longer prove its module association, so it stops claiming one.
                return publicationNavigationFailure(PUBLICATION_AUDIENCE_SCOPE)
            }
            var index: Int64 = 0
            while (index < object.size()) {
                let key = object.nameAt(index)
                object.put(key, publicationRetireSelected(object.valueAt(index)))
                index++
            }
            node
        case _ => node
    }
}

private func publicationRetireSelectedNavigation(page: JsonNode): Unit {
    match (publicationObject(page)) {
        case Some(object) =>
            var index: Int64 = 0
            while (index < object.size()) {
                let key = object.nameAt(index)
                object.put(key, publicationRetireSelected(object.valueAt(index)))
                index++
            }
        case None => ()
    }
}

// A local reference identity embeds the hidden target SymbolId. Replace it with
// the same opaque identifier for every language variant and projected tag so
// that translation pairing survives without disclosing the hidden identity.
private func publicationRedactFieldIds(declaration: JsonNode, hidden: HashSet<String>): Unit {
    let declarationObject = match (publicationObject(declaration)) {
        case Some(value) => value
        case None => return
    }
    let comment = match (declarationObject.get("documentation")) {
        case Some(value) => value
        case None => return
    }
    if (comment.kind() != JsonKind.Object) { return }
    let declarationId = publicationText(declaration, "id")
    let fields = ArrayList<JsonNode>()
    fields.add(all: publicationElements(comment, "localizedTexts"))
    fields.add(all: publicationElements(comment, "tags"))
    let reserved = HashSet<String>()
    for (field in fields) {
        let identity = publicationText(field, "fieldId")
        if (!identity.isEmpty()) { let _ = reserved.add(identity) }
    }
    let replacements = HashMap<String, String>()
    for (field in fields) {
        // A projected tag names its kind with `name`; a localized field uses `kind`.
        let kind = match (publicationString(field, "kind")) {
            case Some(value) => value
            case None => publicationText(field, "name")
        }
        if (kind != "see" && kind != "throws") { continue }
        let identity = publicationText(field, "fieldId")
        let prefix = declarationId + ":doc:" + kind + ":"
        if (!identity.startsWith(prefix)) { continue }
        if (!hidden.contains(identity[prefix.size..])) { continue }
        if (replacements.contains(identity)) { continue }
        // Full SHA-256 over the identity string keeps the mapping opaque while
        // the scratch-padded helper avoids copying the whole input.
        let base = prefix + "opaque:" + contractFingerprint(identity)
        var candidate = base
        var suffix: Int64 = 0
        while (reserved.contains(candidate)) {
            suffix++
            candidate = base + ":" + suffix.toString()
        }
        let _ = reserved.add(candidate)
        replacements[identity] = candidate
    }
    if (replacements.isEmpty()) { return }
    for (field in fields) {
        match (replacements.get(publicationText(field, "fieldId"))) {
            case Some(candidate) => match (publicationObject(field)) {
                case Some(object) => object.put("fieldId", JsonNode.string(candidate))
                case None => ()
            }
            case None => ()
        }
    }
}

// Drop identity-bearing references to unpublished declarations. Author text,
// source attribution and selected language stay untouched: only evidence is
// removed, and no unknown state is upgraded into a resolved claim.
private func publicationSanitizeReferences(node: JsonNode, hidden: HashSet<String>,
    assets: HashSet<String>): Unit {
    match (node.kind()) {
        case JsonKind.Array =>
            let array = node.asArray()
            var index: Int64 = 0
            while (index < array.size()) {
                publicationSanitizeReferences(array.get(index).getOrThrow(), hidden, assets)
                index++
            }
        case JsonKind.Object =>
            let object = node.asObject()
            if (publicationText(node, "kind") == "image") {
                let literal = publicationText(node, "literal")
                if (!literal.isEmpty()) { let _ = assets.add(literal) }
            }
            if (let Some(macroId) <- publicationString(node, "macroSymbolId")) {
                if (hidden.contains(macroId)) { object.put("macroSymbolId", JsonNode.nullValue) }
            }
            // Semantic-link metadata encodes its local target as `targetSymbolId`
            // next to `externalUrl` and `semanticNavigation`.
            let semanticLink = object.contains("semanticNavigation") && object.contains("externalUrl")
            if (let Some(targetId) <- publicationString(node, "targetSymbolId")) {
                if (hidden.contains(targetId)) {
                    object.put("targetSymbolId", JsonNode.nullValue)
                    if (semanticLink) {
                        object.put("state", JsonNode.string("unavailable"))
                        object.put("externalUrl", JsonNode.nullValue)
                        object.put("semanticNavigation", JsonNode.nullValue)
                    } else if (object.contains("referenceState")) {
                        object.put("referenceState", JsonNode.string("unavailable"))
                    } else {
                        object.put("state", JsonNode.string("unavailable"))
                    }
                }
            }
            var index: Int64 = 0
            while (index < object.size()) {
                publicationSanitizeReferences(object.valueAt(index), hidden, assets)
                index++
            }
        case _ => ()
    }
}

private func publicationProjectDeclarations(root: JsonNode, hidden: HashSet<String>,
    redact: Bool): Unit {
    let retained = ArrayList<JsonNode>()
    for (declaration in publicationElements(root, "declarations")) {
        if (hidden.contains(publicationText(declaration, "id"))) { continue }
        if (redact) { publicationRedactFieldIds(declaration, hidden) }
        retained.add(declaration)
    }
    publicationReplaceArray(root, "declarations", retained)
}

private func publicationProjectExternalDocumentation(root: JsonNode, kept: HashSet<String>): Unit {
    let object = match (publicationObject(root)) {
        case Some(value) => value
        case None => return
    }
    // Absent metadata stays absent instead of becoming an empty published array.
    if (!object.contains("externalDocumentation")) { return }
    let retained = ArrayList<JsonNode>()
    for (reference in publicationElements(root, "externalDocumentation")) {
        if (kept.contains(publicationText(reference, "symbolId"))) { retained.add(reference) }
    }
    publicationReplaceArray(root, "externalDocumentation", retained)
}

private func publicationProjectDiagnostics(root: JsonNode, kept: HashSet<String>,
    redact: Bool): Unit {
    let retained = ArrayList<JsonNode>()
    for (diagnostic in publicationElements(root, "diagnostics")) {
        match (publicationString(diagnostic, "symbolId")) {
            case Some(symbolId) => if (kept.contains(symbolId)) { retained.add(diagnostic) }
            case None =>
                // An unbound diagnostic names no declaration whose audience can
                // be proven, so its captured detail is omitted, not guessed.
                if (redact) {
                    match (publicationObject(diagnostic)) {
                        case Some(object) =>
                            object.put("message", JsonNode.string(PUBLICATION_DIAGNOSTIC_OMITTED))
                        case None => ()
                    }
                }
                retained.add(diagnostic)
        }
    }
    publicationReplaceArray(root, "diagnostics", retained)
}

private func publicationProjectPackages(root: JsonNode, kept: HashSet<String>): Unit {
    for (pkg in publicationElements(root, "packages")) {
        publicationReplaceArray(pkg, "symbolIds", publicationKeepSymbolIds(pkg, "symbolIds", kept))
        let reExports = ArrayList<JsonNode>()
        for (reExport in publicationElements(pkg, "reExports")) {
            let capturedBindings = publicationElements(reExport, "bindings")
            let bindings = ArrayList<JsonNode>()
            for (binding in capturedBindings) {
                let targets = publicationKeepSymbolIds(binding, "targetSymbolIds", kept)
                if (targets.isEmpty()) { continue }
                publicationReplaceArray(binding, "targetSymbolIds", targets)
                bindings.add(binding)
            }
            publicationReplaceArray(reExport, "bindings", bindings)
            // Losing every captured binding removes the evidence behind a
            // resolved symbol re-export; an `all` re-export never listed
            // bindings and keeps its captured state.
            if (publicationText(reExport, "kind") != "packageAlias" &&
                !capturedBindings.isEmpty() && bindings.isEmpty()) {
                match (publicationObject(reExport)) {
                    case Some(object) => object.put("state", JsonNode.string("unavailable"))
                    case None => ()
                }
            }
            reExports.add(reExport)
        }
        publicationReplaceArray(pkg, "reExports", reExports)
    }
}

// Mirrors the validator's page occurrence context: captured target modules
// first, then the single root module (or the sole module). Without one, selected
// navigation evidence has no provable module association.
private func publicationPageRootModule(root: JsonNode): String {
    var rootModule = ""
    var rootCount: Int64 = 0
    var moduleCount: Int64 = 0
    var soleModule = ""
    for (module in publicationElements(root, "modules")) {
        soleModule = publicationText(module, "id")
        moduleCount++
        if (publicationText(module, "role") == "root") {
            rootModule = soleModule
            rootCount++
        }
    }
    if (rootCount == 1) { return rootModule }
    if (rootCount == 0 && moduleCount == 1) { return soleModule }
    ""
}

// Published declarations are already indexable by id; resolving a page target
// through that index avoids treating a SymbolId as a module identifier.
private func publicationModuleIndex(root: JsonNode, kept: HashSet<String>): HashMap<String, String> {
    let result = HashMap<String, String>()
    for (declaration in publicationElements(root, "declarations")) {
        let id = publicationText(declaration, "id")
        if (id.isEmpty() || !kept.contains(id)) { continue }
        result[id] = publicationText(declaration, "moduleId")
    }
    result
}

private func publicationPageModule(root: JsonNode, page: JsonNode,
    modules: HashMap<String, String>): String {
    var moduleId = ""
    var hasTarget = false
    for (id in publicationElements(page, "targetSymbolIds")) {
        if (id.kind() != JsonKind.String) { continue }
        let declarationModule = modules.get(id.asString())
        if (declarationModule.isNone()) { continue }
        let selected = declarationModule.getOrThrow()
        if (!hasTarget) {
            hasTarget = true
            moduleId = selected
        } else if (moduleId != selected) {
            return ""
        }
    }
    if (!hasTarget) { return publicationPageRootModule(root) }
    moduleId
}

private func publicationProjectPages(root: JsonNode, kept: HashSet<String>): Unit {
    let object = match (publicationObject(root)) {
        case Some(value) => value
        case None => return
    }
    // Pages are an optional additive property; an absent list stays absent.
    if (!object.contains("pages")) { return }
    let modules = publicationModuleIndex(root, kept)
    for (page in publicationElements(root, "pages")) {
        let capturedTargets = publicationElements(page, "targetSymbolIds").size
        publicationReplaceArray(page, "targetSymbolIds",
            publicationKeepSymbolIds(page, "targetSymbolIds", kept))
        let retainedTargets = publicationElements(page, "targetSymbolIds").size
        // Losing every captured target moves the page onto the fallback module
        // context, so selected evidence tied to the dropped targets can no longer
        // prove a module association.
        if ((capturedTargets > 0 && retainedTargets == 0) ||
            publicationPageModule(root, page, modules).isEmpty()) {
            publicationRetireSelectedNavigation(page)
        }
        for (binding in publicationElements(page, "bindings")) {
            let target = publicationString(binding, "targetSymbolId")
            var missingTarget = false
            if (let Some(targetId) <- target) { missingTarget = !kept.contains(targetId) }
            if (publicationText(binding, "state") != "unavailable" && !missingTarget) { continue }
            // The page keeps its captured content; the local association loses
            // the target and selector. A resolved navigation cannot describe an
            // unavailable association, so it is retired to its canonical failure
            // instead of naming a declaration that is no longer published.
            match (publicationObject(binding)) {
                case Some(object) =>
                    object.put("target", JsonNode.string(""))
                    object.put("selector", JsonNode.string(""))
                    object.put("state", JsonNode.string("unavailable"))
                    object.put("targetSymbolId", JsonNode.nullValue)
                    let navigation = object.get("navigation")
                    match (navigation) {
                        case Some(value) => if (publicationText(value, "state") == "resolved") {
                            object.put("navigation", publicationNavigationFailure(
                                PUBLICATION_AUDIENCE_EXCLUDED))
                        }
                        case None => ()
                    }
                case None => ()
            }
        }
    }
}

private func publicationProjectAssets(root: JsonNode, assets: HashSet<String>): Unit {
    let retained = ArrayList<JsonNode>()
    for (asset in publicationElements(root, "assets")) {
        if (assets.contains(publicationText(asset, "id")) ||
            assets.contains(publicationText(asset, "sourcePath"))) {
            retained.add(asset)
        }
    }
    publicationReplaceArray(root, "assets", retained)
}

private func publicationProjectTree(root: JsonNode, context: PublicationContext,
    redact: Bool): String {
    let hidden = context.hidden
    if (redact) {
        // Unbound author surfaces have no declaration whose audience is proven.
        for (key in ["orphanDocComments", "unsupportedDeclarations", "macroInvocations",
            "unboundSemanticDeclarations"]) {
            publicationReplaceArray(root, key, ArrayList<JsonNode>())
        }
    }
    publicationProjectDeclarations(root, hidden, redact)
    publicationProjectExternalDocumentation(root, context.kept)
    publicationProjectDiagnostics(root, context.kept, redact)
    publicationProjectPackages(root, context.kept)
    publicationProjectPages(root, context.kept)
    let assets = HashSet<String>()
    publicationSanitizeReferences(root, hidden, assets)
    publicationProjectAssets(root, assets)
    publicationSanitizeNavigationTree(root, context)
    publicationWrite(root)
}

/**
 * Project captured documentation into an audience-safe detached publication.
 *
 * The caller's documentation set is never mutated: selection runs on its
 * canonical encoding and a freshly decoded value is returned, so a later
 * change to the caller's own set cannot alter a projection. Renderability and
 * extension-container visibility come from the renderer's own projection, so
 * publication and rendering cannot disagree. Hidden declarations, their package
 * listings, re-export targets, page associations, macro provenance and
 * reference identities are removed or left unsatisfied; visible declarations
 * keep their captured documentation, source attribution, selected language,
 * semantic states and navigation facts. Author-visible prose is preserved
 * exactly as captured, even when the author named a non-public declaration,
 * because publishing author text is not an identity claim.
 *
 * @param documentation Captured documentation to project.
 * @param audience Optional equal or narrower audience. Widening the captured
 * audience is rejected; absent keeps the captured configuration.
 * @return Strict, detached Doc IR valid for the existing codec and renderer.
 */
public func projectPublicationDocumentation(documentation: DocumentationSet,
    audience!: ?String = None): DocumentationSet {
    let configured = publicationAudienceOrFail(documentation.configuration.audience,
        "documentation audience")
    let selected = match (audience) {
        case Some(requested) =>
            let requestedRank = match (publicationAudienceRank(requested)) {
                case Some(rank) => rank
                case None => throw IllegalArgumentException(
                    "publication audience must be external, package, or all")
            }
            if (requestedRank > publicationAudienceRank(configured).getOrThrow()) {
                throw IllegalArgumentException(
                    "publication projection cannot widen the captured audience '${configured}'")
            }
            requested
        case None => configured
    }
    let root = publicationParse(encodeDocIr(documentation))
    let documentSetAudiences = publicationDocumentSetAudiences(root)
    let redact = publicationAudienceRank(selected).getOrThrow() < 2
    // Selection must observe the requested audience, so a narrowed projection
    // first rewrites the detached configuration and retires evidence captured
    // for the wider audience. An unchanged audience reuses the caller's model
    // read-only, which avoids a second whole-document decode.
    let requested = if (selected == configured) {
        documentation
    } else {
        match (publicationObject(root)) {
            case Some(object) => match (object.get("configuration")) {
                case Some(configuration) => if (configuration.kind() == JsonKind.Object) {
                    configuration.asObject().put("audience", JsonNode.string(selected))
                }
                case None => ()
            }
            case None => ()
        }
        let staging = PublicationContext(selected, HashSet<String>(), HashSet<String>(),
            documentSetAudiences)
        publicationSanitizeNavigationTree(root, staging)
        decodeDocIr(publicationWrite(root))
    }
    // Select exactly what the renderer would publish for the requested audience.
    let projection = RenderProjection(requested)
    let kept = HashSet<String>()
    for ((id, _) in projection.visibleIndex) { let _ = kept.add(id) }
    let hidden = HashSet<String>()
    for (declaration in requested.declarations) {
        if (!kept.contains(declaration.id)) { let _ = hidden.add(declaration.id) }
    }
    let context = PublicationContext(selected, kept, hidden, documentSetAudiences)
    decodeDocIr(publicationProjectTree(root, context, redact))
}
