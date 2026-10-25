package cjdoc

import cjdoc.model as selection_model
import std.collection.*

// External documentation selection policy. Every input is evidence a caller
// already holds: captured dependency instances, document-set identities,
// inventory entries and catalog mappings. The policy never loads manifests or
// inventories, re-observes a source tree, derives a dependency graph or resolves
// a second time; the published-graph binding is a captured result supplied by
// the caller. Generation and a later offline query therefore rank identical
// evidence identically.
//
// Results are tuples rather than per-candidate objects because a single query
// screens every inventory entry for every candidate name.
//
// Scores keep their historical relationship: priority spans -4000..4000, the
// language bonus is 10000 and level bases are 100000 apart.

private let DEPENDENCY_DOCUMENT_LANGUAGE_BONUS: Int64 = 10000
private let DEPENDENCY_DOCUMENT_EXACT_BASE: Int64 = 300000
private let DEPENDENCY_DOCUMENT_COMPATIBLE_BASE: Int64 = 200000
private let DEPENDENCY_DOCUMENT_MANUAL_BASE: Int64 = 100000

/** Selection settings captured once from the generation request or query context. */
internal class DependencyDocumentPolicy {
    let audience: String
    let linkLanguage: String
    let linkLanguageFallback: Bool
    let linkCompatible: Bool

    init(audience: String, linkLanguage!: String = "", linkLanguageFallback!: Bool = false,
        linkCompatible!: Bool = false) {
        this.audience = audience
        this.linkLanguage = linkLanguage
        this.linkLanguageFallback = linkLanguageFallback
        this.linkCompatible = linkCompatible
    }

    init(request: GenerationRequest) {
        this.audience = request.audience
        this.linkLanguage = request.linkLanguage
        this.linkLanguageFallback = request.linkLanguageFallback
        this.linkCompatible = request.linkCompatible
    }

    func scopeMatches(dependency: selection_model.DependencyInstance,
        set: selection_model.DocumentSetIdentity): Bool {
        set.audience == audience &&
            (set.target == dependency.target || set.target == "*") &&
            (set.cfg == dependency.cfg || set.cfg == "*")
    }

    /** Whether a documented kind can satisfy a type-only query. */
    func admitsTypeKind(kind: String): Bool {
        kind == "class" || kind == "struct" || kind == "enum" ||
            kind == "interface" || kind == "typeAlias"
    }
}

/**
 * Type-only and guide-selector shape eligibility. These exclusions are silent:
 * an unrelated kind or arity is not evidence that the documented library is
 * unusable for the whole query.
 */
internal func dependencyDocumentShapeExcluded(policy: DependencyDocumentPolicy, entry: ExternalDocEntry,
    typesOnly!: Bool = false, genericArity!: Int64 = -1, sourceHeader!: String = ""): Bool {
    if (typesOnly && !policy.admitsTypeKind(entry.kind)) { return true }
    if (typesOnly && genericArity >= 0 && entry.genericArity != genericArity) { return true }
    if (!sourceHeader.isEmpty() && entry.sourceHeader != sourceHeader) { return true }
    false
}

/**
 * Dependency-identity and selection-scope eligibility, in generation order.
 * `dependency` is the captured instance for the document-set library, or `None`
 * when the set carries only a documentation-only reference. Returns the
 * recorded rejection reason, or "" when the candidate may be ranked.
 */
internal func dependencyDocumentEvidenceRejection(policy: DependencyDocumentPolicy,
    set: selection_model.DocumentSetIdentity, dependency: ?selection_model.DependencyInstance,
    authoritativeModules: HashSet<String>, packageScopeAmbiguous!: Bool = false,
    explicit!: Bool = false, typesOnly!: Bool = false): String {
    match (dependency) {
        case Some(value) =>
            if (value.state == "unknown" || value.state == "conflict" || value.identity.isEmpty()) {
                return "selected dependency identity is unknown or conflicts with build inputs"
            }
            if (!value.componentModuleId.isEmpty() && authoritativeModules.contains(value.componentModuleId)) {
                return "authoritative documented module has no visible target; external fallback is suppressed"
            }
        case None =>
            if (packageScopeAmbiguous) {
                return "multiple selected dependency components share this package scope"
            }
            if (!explicit || typesOnly) {
                return "documented library is not a selected dependency of this module"
            }
            if (set.audience != policy.audience) {
                return "documentation-only reference has a different audience"
            }
    }
    ""
}

/**
 * Explicit compatibility mappings and target/cfg/audience coverage for a
 * candidate with a captured dependency instance. `sourceContextConflicted` is
 * the captured conflict fact for that instance's component module.
 *
 * Returns `(rejection, compatible, instanceMapping, bindingRequired)`.
 * `bindingRequired` marks the only cases whose evidence includes the captured
 * published-graph comparison; callers pass that comparison to
 * [rateDependencyDocumentCandidate] as `sourceBinding`.
 */
internal func assessDependencyDocumentCompatibility(policy: DependencyDocumentPolicy,
    set: selection_model.DocumentSetIdentity, dependency: selection_model.DependencyInstance,
    compatibilityMappings: HashMap<String, String>,
    sourceContextConflicted!: Bool = false): (String, Bool, Bool, Bool) {
    if (sourceContextConflicted) {
        return ("selected source dependency graph contains conflicting build inputs", false, false, false)
    }
    let instanceMapping = policy.linkCompatible && compatibilityMappings.get(
        dependencyCompatibilityKey(dependency.instanceId, dependency.target, dependency.cfg)) == Some(set.identity)
    var compatible = false
    if (dependency.identity != set.identity) {
        compatible = instanceMapping || (policy.linkCompatible &&
            compatibilityMappings.get(dependencyCompatibilityKey(dependency.identity, dependency.target, dependency.cfg)) == Some(set.identity))
        if (!compatible) {
            return ("API identity mismatch; no latest or neighbouring-version fallback", false, instanceMapping, false)
        }
    }
    if (set.audience != policy.audience || (!policy.scopeMatches(dependency, set) && !compatible)) {
        return ("document coverage does not match target, cfg or audience", compatible, instanceMapping, false)
    }
    ("", compatible, instanceMapping, dependency.identity == set.identity)
}

/**
 * Binding evidence, pin state, match level, priority and language ranking.
 * `sourceBinding` is the captured published-graph comparison and is ignored
 * unless the document set identity equals the selected dependency identity.
 *
 * Returns `(rejection, level, score)`; level and score are meaningful only when
 * the rejection is empty.
 */
internal func rateDependencyDocumentCandidate(policy: DependencyDocumentPolicy,
    set: selection_model.DocumentSetIdentity, dependency: ?selection_model.DependencyInstance,
    compatible!: Bool = false, instanceMapping!: Bool = false, sourceBinding!: String = "unavailable",
    inventoryPinned!: Bool = false, priority!: Int64 = 0): (String, String, Int64) {
    var level = "manual"
    var accepted = compatible
    if (let Some(value) <- dependency) {
        let sameIdentity = value.identity == set.identity
        if (sameIdentity) {
            if (sourceBinding == "conflict") {
                return ("published or selected dependency graph contains conflicting build inputs", "", 0)
            }
            if (sourceBinding == "mismatch") {
                if (!instanceMapping) {
                    return ("source bytes match but selected transitive dependency/build context differs", "", 0)
                }
                accepted = true
            }
        }
        level = if (accepted) {
            "compatible"
        } else if (sameIdentity && inventoryPinned && sourceBinding == "matched" &&
            (value.state == "observed" || value.state == "verified") && set.state == "declared") {
            "exact"
        } else {
            "manual"
        }
    }
    let base: Int64 = match (level) {
        case "exact" => DEPENDENCY_DOCUMENT_EXACT_BASE
        case "compatible" => DEPENDENCY_DOCUMENT_COMPATIBLE_BASE
        case _ => DEPENDENCY_DOCUMENT_MANUAL_BASE
    }
    var score = priority * 4 + base
    if (!policy.linkLanguage.isEmpty()) {
        // 10000 exceeds the full priority span (8000); together they stay below
        // the smallest level gap (100000).
        if (set.language == policy.linkLanguage) {
            score += DEPENDENCY_DOCUMENT_LANGUAGE_BONUS
        } else if (!policy.linkLanguageFallback) {
            return ("selected API identity has no requested language", "", 0)
        }
    }
    ("", level, score)
}

/**
 * Running best candidate together with the evidence it was chosen from.
 * `ambiguous` is sticky: once an equal-scoring candidate names a different
 * target, no later candidate may be presented as the single answer.
 */
internal class DependencyDocumentChoice {
    let resolver: ExternalDocResolver
    let entry: ExternalDocEntry
    let dependencyInstanceId: String
    /** True when a captured dependency instance backed this match, false for a documentation-only reference. */
    let dependencyBacked: Bool
    let level: String
    let score: Int64
    var ambiguous: Bool = false

    init(resolver: ExternalDocResolver, entry: ExternalDocEntry, dependencyInstanceId: String,
        dependencyBacked: Bool, level: String, score: Int64) {
        this.resolver = resolver; this.entry = entry
        this.dependencyInstanceId = dependencyInstanceId; this.dependencyBacked = dependencyBacked
        this.level = level; this.score = score
    }
}

/** Equal-score identity rule: shared publication routes do not make distinct declarations,
 * document sets or dependency instances the same target. */
internal func dependencyDocumentSameTarget(left: ExternalDocEntry, leftInstanceId: String,
    right: ExternalDocEntry, rightInstanceId: String): Bool {
    left.symbolKey == right.symbolKey && left.documentSet.id == right.documentSet.id &&
        left.url == right.url && left.documentSet.identity == right.documentSet.identity &&
        leftInstanceId == rightInstanceId
}

/**
 * Folds one accepted candidate into the running choice with the historical
 * ordering: a strictly higher score replaces the winner, a lower score is
 * ignored, and an equal score keeps the earlier winner but marks ambiguity when
 * the targets differ. Only a new winner allocates.
 */
internal func chooseDependencyDocumentCandidate(previous: ?DependencyDocumentChoice,
    resolver: ExternalDocResolver, entry: ExternalDocEntry, dependencyInstanceId: String,
    dependencyBacked: Bool, level: String, score: Int64): DependencyDocumentChoice {
    match (previous) {
        case None => DependencyDocumentChoice(resolver, entry, dependencyInstanceId, dependencyBacked, level, score)
        case Some(current) =>
            if (score > current.score) {
                DependencyDocumentChoice(resolver, entry, dependencyInstanceId, dependencyBacked, level, score)
            } else {
                if (score == current.score &&
                    !dependencyDocumentSameTarget(current.entry, current.dependencyInstanceId,
                        entry, dependencyInstanceId)) {
                    current.ambiguous = true
                }
                current
            }
    }
}
