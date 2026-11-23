protected package cjdoc.render.html

import cjdoc.render.routes.{navigationHref, isCapturedLocalApiLink}
import cjdoc.render.codec.{NavigationEvidence, validateDependencyMetadata}
import cjdoc.model.*
import std.collection.*

internal class DeprecationAction {
    let name: String
    let href: String
    let navigation: ?TypeNavigation

    init(name: String, href: String, navigation!: ?TypeNavigation = None) {
        this.name = name
        this.href = href
        this.navigation = navigation
    }

    prop kind: String { get() { navigation.map({ value => value.matchLevel }).getOrDefault({ => "api" }) } }
}

private func selectedReplacementTag(comment: DocComment): ?DocTag {
    var selected: ?DocTag = None
    for (tag in comment.tags where tag.name == "replacement") {
        if (selected.isSome() || !sharedReplacementTag(tag)) { return None }
        selected = Some(tag)
    }
    for (text in comment.localizedTexts where text.kind == "replacement") { return None }
    selected
}

private func replacementSignatureMatches(symbol: SymbolDoc, reference: ParsedDocReference): Bool {
    if (!reference.hasSignature) { return true }
    if (!referenceKindTakesSignature(symbol.kind) || symbol.parameters.size != reference.parameterTypes.size) {
        return false
    }
    for (i in 0..symbol.parameters.size) {
        let typeRef = symbol.parameters[i].typeRef
        let expected = reference.parameterTypes[i]
        if (normalizeTypeSpelling(typeRef.spelling) == expected) { continue }
        if (typeRef.semantic.state == "resolved") {
            if (let Some(canonical) <- typeRef.semantic.canonical) {
                if (normalizeTypeSpelling(canonical) == expected) { continue }
            }
        }
        return false
    }
    true
}

private func addReplacementSelector(index: HashMap<String, ArrayList<SymbolDoc>>, name: String,
    symbol: SymbolDoc): Unit {
    if (let Some(candidates) <- index.get(name)) { candidates.add(symbol) }
}

// Index only names an author actually used, but include hidden candidates:
// publication visibility cannot turn an ambiguous authored name into a proof.
private class ReplacementSelectors {
    private let qualified = HashMap<String, ArrayList<SymbolDoc>>()
    private let simple = HashMap<String, ArrayList<SymbolDoc>>()
    private let parsed = HashMap<String, ParsedDocReference>()
    private let all: HashMap<String, SymbolDoc>

    init(tags: ArrayList<(SymbolDoc, DocTag)>, all: HashMap<String, SymbolDoc>) {
        this.all = all
        for ((_, tag) in tags where !parsed.contains(tag.subject) && !all.contains(tag.subject)) {
            let reference = parseDocReference(tag.subject)
            parsed[tag.subject] = reference
            if (!qualified.contains(reference.name)) {
                qualified[reference.name] = ArrayList<SymbolDoc>()
                simple[reference.name] = ArrayList<SymbolDoc>()
            }
        }
        if (parsed.isEmpty()) { return }
        for ((_, symbol) in all) {
            addReplacementSelector(qualified, symbol.qualifiedName, symbol)
            addReplacementSelector(simple, symbol.name, symbol)
        }
    }

    // An empty ID with a true match means the source selector is ambiguous.
    func matchTarget(subject: String): (Bool, String) {
        if (all.contains(subject)) { return (true, subject) }
        let reference = parsed[subject]
        let named = qualified[reference.name]
        let candidates = if (named.isEmpty()) { simple[reference.name] } else { named }
        var id = ""
        for (candidate in candidates where replacementSignatureMatches(candidate, reference)) {
            if (!id.isEmpty()) { return (true, "") }
            id = candidate.id
        }
        (!id.isEmpty(), id)
    }
}

internal class DeprecationProjection {
    let entries = HashMap<String, ?DeprecationAction>()
    private var proof: ?NavigationEvidence = None

    init(documentation: DocumentationSet, projection: RenderProjection) {
        let candidates = ArrayList<(SymbolDoc, DocTag)>()
        for (symbol in projection.visibleSymbols where declarationIsDeprecated(symbol)) {
            entries[symbol.id] = None
            if (let Some(comment) <- symbol.documentation) {
                if (let Some(tag) <- selectedReplacementTag(comment)) {
                    if (let Some(navigation) <- tag.navigation) {
                        if (navigation.state == "resolved") { candidates.add((symbol, tag)) }
                    }
                }
            }
        }
        if (candidates.isEmpty()) { return }
        let selectors = ReplacementSelectors(candidates, projection.allIndex)
        for ((symbol, tag) in candidates) {
            if (scopedGenericReference(symbol, tag.subject, projection.allIndex)) { continue }
            let (localMatch, localId) = selectors.matchTarget(tag.subject)
            let navigation = tag.navigation.getOrThrow()
            let action = if (localMatch) {
                localAction(symbol, tag, localId, documentation, projection)
            } else { externalAction(symbol, tag, navigation, documentation) }
            if (action.isSome()) { entries[symbol.id] = action }
        }
    }

    private func evidence(documentation: DocumentationSet): NavigationEvidence {
        if (let Some(value) <- proof) { return value }
        let modules = HashSet<String>()
        for (module in documentation.modules) { let _ = modules.add(module.id) }
        let value = validateDependencyMetadata(documentation, modules)
        proof = Some(value)
        value
    }

    private func validNavigation(value: TypeNavigation, moduleId: String, documentation: DocumentationSet): Bool {
        try {
            evidence(documentation).validate(value, "@replacement", moduleId)
            true
        } catch (_: Exception) { false }
    }

    private func localAction(owner: SymbolDoc, tag: DocTag, id: String, documentation: DocumentationSet,
        projection: RenderProjection): ?DeprecationAction {
        let navigation = tag.navigation.getOrThrow()
        if (id.isEmpty() || id == owner.id || tag.referenceState != "resolved" || tag.targetSymbolId != Some(id) ||
            !isCapturedLocalApiLink(navigation) || navigation.symbolKey != id || !navigation.indexIdentity.isEmpty() ||
            !navigation.apiIdentity.isEmpty() || !navigation.language.isEmpty()) { return None }
        let target = match (projection.visibleIndex.get(id)) { case Some(value) => value; case None => return None }
        if (target.moduleId != owner.moduleId && !validNavigation(navigation, owner.moduleId, documentation)) {
            return None
        }
        let routes = match (projection.apiRoutes) { case Some(value) => value; case None => return None }
        if (routes.filePath(id).isNone()) { return None }
        let name = htmlContextLabel(target)
        return Some(DeprecationAction(target.ownerId.flatMap({ key => projection.visibleIndex.get(key) })
            .map({ parent => parent.name + "." + name }).getOrDefault({ => name }), routes.fileHref(id)))
    }

    private func externalAction(owner: SymbolDoc, tag: DocTag, navigation: TypeNavigation,
        documentation: DocumentationSet): ?DeprecationAction {
        if (tag.targetSymbolId.isSome() || tag.referenceState != "unavailable" ||
            (navigation.matchLevel != "exact" && navigation.matchLevel != "compatible") ||
            navigation.documentSetId.isEmpty() || !replacementMatchesExternalKey(tag.subject, navigation.symbolKey) ||
            navigation.reason != externalReplacementSelection(owner, tag.subject, navigation) ||
            !validNavigation(navigation, owner.moduleId, documentation)) { return None }
        let proof = evidence(documentation)
        let set = proof.documentSets[navigation.documentSetId]
        if (!replacementUrlWithinDocumentSet(navigation.url, set) ||
            proof.dependencyFor(owner.moduleId, set.library).map({ value => value.instanceId }) !=
                Some(navigation.dependencyInstanceId)) { return None }
        navigationHref("", navigation.url).map({ href => DeprecationAction(tag.subject, href, navigation: Some(navigation)) })
    }

    func contains(id: String): Bool { entries.contains(id) }
    func action(id: String): ?DeprecationAction { entries.get(id).getOrDefault({ => None<DeprecationAction> }) }
}
