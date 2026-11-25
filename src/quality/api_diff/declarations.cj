protected package cjdoc.quality.api_diff

import cjdoc.model.*
import std.collection.*

protected func apiDiffOptionText(value: ?String, fallback: String): String {
    match (value) { case Some(text) => text case None => fallback }
}

private func declarationBucketKey(value: ApiContractDeclaration): String {
    value.moduleId + "\n" + value.packageName + "\n" + apiDiffOptionText(value.ownerId, "") +
        "\n" + value.kind + "\n" + value.name
}

private func declarationSignatureKey(value: ApiContractDeclaration): String {
    declarationBucketKey(value) + "\n" + joinedStrings(value.sourceApiSignature)
}


private func visibilityRank(value: String): Int64 {
    match (value) {
        case "private" => 0
        case "internal" => 1
        case "protected" => 2
        case "public" => 3
        case _ => -1
    }
}

private func optionalEqual(left: ?String, right: ?String): Bool {
    match ((left, right)) {
        case (None, None) => true
        case (Some(a), Some(b)) => a == b
        case _ => false
    }
}

private func optionalBoolEqual(left: ?Bool, right: ?Bool): Bool {
    match ((left, right)) {
        case (None, None) => true
        case (Some(a), Some(b)) => a == b
        case _ => false
    }
}

private func fingerprintChanged(left: String, right: String): Bool {
    left != "" && right != "" && left != right
}

func joinedStrings(values: ReadOnlyList<String>): String {
    let out = StringBuilder()
    var first = true
    for (value in values) {
        if (!first) { out.append("|") }
        first = false
        out.append(value)
    }
    out.toString()
}

private func parameterValue(value: ApiContractParameter): String {
    let typeValueText = match (value.`type`) { case Some(text) => text case None => "<unknown>" }
    let defaultValue = match (value.defaultValue) { case Some(text) => text case None => "<none>" }
    value.name + ":" + value.typeState + ":" + typeValueText + ":" + value.defaultState + ":" + defaultValue
}

private func parametersValue(values: ReadOnlyList<ApiContractParameter>): String {
    let out = StringBuilder()
    var first = true
    for (value in values) {
        if (!first) { out.append("|") }
        first = false
        out.append(parameterValue(value))
    }
    out.toString()
}

func addReason(reasons: ArrayList<String>, evidence: ArrayList<ApiDiffEvidence>,
    field: String, reason: String, before!: ?String = None, after!: ?String = None,
    state!: String = "resolved"): Unit {
    reasons.add(reason)
    evidence.add(ApiDiffEvidence(field, before: before, after: after, state: state))
}

private func relationshipIsResolved(value: String): Bool {
    let parts = value.split(":")
    if (parts.size < 3) { return true }
    parts[1] == "resolved"
}

private func removedResolvedRelationship(old: ApiContractDeclaration,
    current: ApiContractDeclaration): Bool {
    if (old.collectionState != "resolved" || current.collectionState != "resolved") {
        return false
    }
    for (relationship in old.relationships) {
        if (!containsRelationship(current.relationships, relationship) && relationshipIsResolved(relationship)) {
            return true
        }
    }
    false
}

private func containsRelationship(values: ReadOnlyList<String>, target: String): Bool {
    for (value in values) {
        if (value == target) { return true }
    }
    false
}

private func sourceSignatureOnlyVisibilityChange(old: ApiContractDeclaration,
    current: ApiContractDeclaration): Bool {
    if (old.sourceApiSignature.size != current.sourceApiSignature.size) { return false }
    var changed = false
    var index: Int64 = 0
    while (index < old.sourceApiSignature.size) {
        if (old.sourceApiSignature[index] != current.sourceApiSignature[index]) {
            if (old.sourceApiSignature[index] != old.visibility ||
                current.sourceApiSignature[index] != current.visibility) {
                return false
            }
            changed = true
        }
        index++
    }
    changed
}

private func appendedParametersAreDefaulted(old: ApiContractDeclaration,
    current: ApiContractDeclaration): Bool {
    if (current.parameters.size <= old.parameters.size) { return false }
    var index = old.parameters.size
    while (index < current.parameters.size) {
        if (current.parameters[index].defaultState != "resolved") { return false }
        index++
    }
    true
}

private func parameterListEnd(declaration: ApiContractDeclaration): Int64 {
    let signature = declaration.sourceApiSignature
    let introducer = match (declaration.kind) {
        case "function" => "FUNC:4:func"
        case "constructor" => if (declaration.name == "init") { "INIT:4:init" } else {
            "IDENTIFIER:${declaration.name.size}:${declaration.name}"
        }
        case _ => return -1
    }
    var callable = false
    var depth: Int64 = 0
    for (index in 0..signature.size) {
        let token = signature[index]
        if (!callable) {
            callable = token == introducer
        } else if (token == "LPAREN:1:(") {
            depth++
        } else if (depth > 0 && token == "RPAREN:1:)") {
            depth--
            if (depth == 0) { return index }
        }
    }
    -1
}

private func sourceSignatureOnlyAppendsParameters(old: ApiContractDeclaration,
    current: ApiContractDeclaration): Bool {
    if (old.sourceApiSignatureState != "resolved" ||
        current.sourceApiSignatureState != "resolved") { return false }
    let before = old.sourceApiSignature
    let after = current.sourceApiSignature
    let oldEnd = parameterListEnd(old)
    let newEnd = parameterListEnd(current)
    if (oldEnd < 0 || newEnd <= oldEnd || before.size - oldEnd != after.size - newEnd) {
        return false
    }
    // The old signature must survive verbatim on both sides of the insertion.
    // Names, named-argument markers, and unresolved type spellings live here.
    for (index in 0..oldEnd) {
        if (before[index] != after[index]) { return false }
    }
    if (!old.parameters.isEmpty() && before[oldEnd - 1] != "COMMA:1:," &&
        after[oldEnd] != "COMMA:1:,") { return false }
    for (offset in 0..(before.size - oldEnd)) {
        if (before[oldEnd + offset] != after[newEnd + offset]) { return false }
    }
    true
}

private func sameSourceTokens(left: ReadOnlyList<String>, right: ReadOnlyList<String>): Bool {
    if (left.size != right.size) { return false }
    for (index in 0..left.size) {
        if (left[index] != right[index]) { return false }
    }
    true
}

private func compareSharedParameters(old: ReadOnlyList<ApiContractParameter>,
    current: ReadOnlyList<ApiContractParameter>, initialClassification: String,
    reasons: ArrayList<String>, evidence: ArrayList<ApiDiffEvidence>): String {
    var classification = initialClassification
    var index: Int64 = 0
    while (index < old.size && index < current.size) {
        let before = old[index]
        let after = current[index]
        if (before.name != after.name) {
            if (classification != "breaking") { classification = "potentially-breaking" }
            addReason(reasons, evidence, "parameters[${index}].name", "parameter name changed",
                before: Some(before.name), after: Some(after.name), state: "partial")
        }
        if (before.typeState != after.typeState || !optionalEqual(before.`type`, after.`type`)) {
            let resolved = before.typeState == "resolved" && after.typeState == "resolved"
            if (resolved) { classification = "breaking" }
            else if (classification != "breaking") { classification = "potentially-breaking" }
            addReason(reasons, evidence, "parameters[${index}].type", "parameter type contract changed",
                before: Some(parameterValue(before)), after: Some(parameterValue(after)),
                state: if (resolved) { "resolved" } else { "partial" })
        }
        if (before.defaultState == "resolved" && after.defaultState != "resolved") {
            classification = "breaking"
            addReason(reasons, evidence, "parameters[${index}].default", "default value became unavailable",
                before: before.defaultValue, after: after.defaultValue)
        } else if (before.defaultState != after.defaultState ||
            !optionalEqual(before.defaultValue, after.defaultValue)) {
            if (classification != "breaking") { classification = "potentially-breaking" }
            addReason(reasons, evidence, "parameters[${index}].default", "default value changed",
                before: before.defaultValue, after: after.defaultValue, state: "partial")
        }
        index++
    }
    classification
}

private func compareDeclaration(old: ApiContractDeclaration, current: ApiContractDeclaration,
    matchState: String): ApiDiffEntry {
    let reasons = ArrayList<String>()
    let evidence = ArrayList<ApiDiffEvidence>()
    var classification = "unchanged"
    let oldVisibility = visibilityRank(old.visibility)
    let currentVisibility = visibilityRank(current.visibility)
    let visibilityWidened = oldVisibility >= 0 && currentVisibility > oldVisibility
    if (oldVisibility >= 0 && currentVisibility >= 0 && currentVisibility < oldVisibility) {
        classification = "breaking"
        addReason(reasons, evidence, "visibility", "visibility narrowed",
            before: Some(old.visibility), after: Some(current.visibility))
    } else if (old.visibility != current.visibility) {
        if (!visibilityWidened && classification == "unchanged") { classification = "potentially-breaking" }
        addReason(reasons, evidence, "visibility", "visibility changed",
            before: Some(old.visibility), after: Some(current.visibility),
            state: if (visibilityWidened) { "resolved" } else { "partial" })
    }
    classification = compareSharedParameters(old.parameters, current.parameters, classification, reasons, evidence)
    let appendedDefaultedParameters = appendedParametersAreDefaulted(old, current)
    let optionalOnlySourceChange = appendedDefaultedParameters && sourceSignatureOnlyAppendsParameters(old, current)
    if (old.parameters.size != current.parameters.size) {
        let resolvedCollection = old.collectionState == "resolved" && current.collectionState == "resolved"
        if (resolvedCollection && appendedDefaultedParameters) {
            if (classification == "unchanged") {
                classification = if (optionalOnlySourceChange) { "additive" } else { "potentially-breaking" }
            }
        } else if (resolvedCollection) {
            classification = "breaking"
        } else if (classification != "breaking") {
            classification = "potentially-breaking"
        }
        addReason(reasons, evidence, "parameters", if (appendedDefaultedParameters) {
                "optional parameters added"
            } else {
                "parameter count changed"
            },
            before: Some(parametersValue(old.parameters)), after: Some(parametersValue(current.parameters)),
            state: if (resolvedCollection) { "resolved" } else { "partial" })
    }
    if (old.returnState != current.returnState || !optionalEqual(old.returnType, current.returnType)) {
        if (old.returnState == "resolved" && current.returnState == "resolved") {
            classification = "breaking"
        } else if (classification != "breaking") { classification = "potentially-breaking" }
        addReason(reasons, evidence, "return", "return contract changed", before: old.returnType,
            after: current.returnType,
            state: if (old.returnState == "resolved" && current.returnState == "resolved") { "resolved" } else { "partial" })
    }
    let genericArityChanged = old.genericParameters.size != current.genericParameters.size
    if (genericArityChanged || joinedStrings(old.genericParameters) != joinedStrings(current.genericParameters)) {
        let resolvedCollection = old.collectionState == "resolved" && current.collectionState == "resolved"
        if (genericArityChanged && resolvedCollection) { classification = "breaking" }
        else if (classification != "breaking") { classification = "potentially-breaking" }
        addReason(reasons, evidence, "genericParameters", "generic contract changed",
            before: Some(joinedStrings(old.genericParameters)), after: Some(joinedStrings(current.genericParameters)),
            state: if (genericArityChanged && resolvedCollection) { "resolved" } else { "partial" })
    }
    if (joinedStrings(old.relationships) != joinedStrings(current.relationships)) {
        if (removedResolvedRelationship(old, current) || old.relationships.size > current.relationships.size) {
            classification = "breaking"
        } else if (classification != "breaking") { classification = "potentially-breaking" }
        addReason(reasons, evidence, "relationships", "type or symbol relationships changed",
            before: Some(joinedStrings(old.relationships)), after: Some(joinedStrings(current.relationships)),
            state: if (old.collectionState == "resolved" && current.collectionState == "resolved") { "resolved" } else { "partial" })
    }
    if (!optionalBoolEqual(old.enumNonExhaustive, current.enumNonExhaustive)) {
        if (classification != "breaking") { classification = "potentially-breaking" }
        addReason(reasons, evidence, "enumNonExhaustive", "enum exhaustiveness evidence changed",
            before: None<String>, after: None<String>, state: "partial")
    }
    let signatureChanged = old.sourceApiSignatureState != current.sourceApiSignatureState ||
        !sameSourceTokens(old.sourceApiSignature, current.sourceApiSignature)
    if (signatureChanged && !(visibilityWidened && sourceSignatureOnlyVisibilityChange(old, current)) &&
        !optionalOnlySourceChange) {
        if (classification != "breaking") { classification = "potentially-breaking" }
        addReason(reasons, evidence, "sourceApiSignature", "source API signature changed",
            before: Some(joinedStrings(old.sourceApiSignature)), after: Some(joinedStrings(current.sourceApiSignature)),
            state: if (old.sourceApiSignatureState == "resolved" && current.sourceApiSignatureState == "resolved") { "resolved" } else { "partial" })
    }
    if (appendedDefaultedParameters && !optionalOnlySourceChange && !signatureChanged) {
        addReason(reasons, evidence, "sourceApiSignature",
            "source signature does not establish an optional-only change", state: "partial")
    }
    if (fingerprintChanged(old.documentationFingerprint, current.documentationFingerprint) && reasons.isEmpty()) {
        classification = "documentation-only"
        addReason(reasons, evidence, "documentationFingerprint", "documentation changed",
            before: Some(old.documentationFingerprint), after: Some(current.documentationFingerprint))
    }
    let languages = ArrayList<String>()
    for (item in old.documentationLanguages) {
        let language = item.language.getOrDefault({ => "unknown" })
        if (!languages.contains(language)) { languages.add(language) }
    }
    for (item in current.documentationLanguages) {
        let language = item.language.getOrDefault({ => "unknown" })
        if (!languages.contains(language)) { languages.add(language) }
    }
    for (language in languages) {
        var before: ?String = None
        var after: ?String = None
        for (item in old.documentationLanguages where item.language.getOrDefault({ => "unknown" }) == language) { before = Some(item.fingerprint) }
        for (item in current.documentationLanguages where item.language.getOrDefault({ => "unknown" }) == language) { after = Some(item.fingerprint) }
        if (before == after) { continue }
        if (classification == "unchanged") { classification = "documentation-only" }
        evidence.add(ApiDiffEvidence("documentationLanguages", before: before, after: after,
            state: if (language == "unknown") { "unavailable" } else { "resolved" },
            language: if (language == "unknown") { None } else { Some(language) }))
    }
    if (fingerprintChanged(old.metadataFingerprint, current.metadataFingerprint) &&
        classification != "breaking" && classification != "potentially-breaking") {
        classification = "metadata-only"
        addReason(reasons, evidence, "metadataFingerprint", "metadata changed",
            before: Some(old.metadataFingerprint), after: Some(current.metadataFingerprint))
    }
    if (fingerprintChanged(old.sourceFingerprint, current.sourceFingerprint) &&
        classification == "unchanged") {
        classification = "metadata-only"
        addReason(reasons, evidence, "sourceFingerprint", "source provenance changed",
            before: Some(old.sourceFingerprint), after: Some(current.sourceFingerprint))
    }
    ApiDiffEntry(current.kind, classification, matchState,
        oldId: Some(old.id), newId: Some(current.id), reasons: reasons.toArray(), evidence: evidence.toArray())
}


private func addedDeclarationEntry(value: ApiContractDeclaration,
    baseline: ApiContractSnapshot, current: ApiContractSnapshot, collectionState: String): ApiDiffEntry {
    var classification = "additive"
    var reason = "declaration added"
    var state = "resolved"
    if (value.kind == "enumCase") {
        var ownerFound = false
        var ownerInCurrent = false
        var ownerExhaustiveness: ?Bool = None
        match (value.ownerId) {
            case Some(ownerId) =>
                for (owner in baseline.declarations) {
                    if (owner.id == ownerId && owner.kind == "enum") {
                        ownerFound = true
                        ownerExhaustiveness = owner.enumNonExhaustive
                    }
                }
                for (owner in current.declarations) {
                    if (owner.id == ownerId && owner.kind == "enum") {
                        ownerInCurrent = true
                    }
                }
            case None => ()
        }
        match (ownerExhaustiveness) {
            case Some(false) =>
                if (ownerFound && baseline.collectionState == "resolved" && collectionState == "resolved") {
                    classification = "breaking"
                    reason = "enum case added to exhaustive enum"
                } else {
                    classification = "potentially-breaking"
                    reason = "enum case exhaustiveness evidence is incomplete"
                    state = "partial"
                }
            case Some(true) =>
                if (baseline.collectionState != "resolved" || collectionState != "resolved") {
                    classification = "potentially-breaking"
                    reason = "enum case addition has incomplete collection evidence"
                    state = "partial"
                }
            case None =>
                classification = "potentially-breaking"
                reason = "enum case exhaustiveness is unavailable"
                state = "partial"
        }
        if (!ownerFound) {
            classification = "potentially-breaking"
            reason = "enum case owner is unavailable"
            state = "partial"
        }
        if (!ownerFound && ownerInCurrent) {
            classification = "additive"
            reason = "enum case added with new enum"
            state = "resolved"
        }
    }
    ApiDiffEntry(value.kind, classification, "added", newId: Some(value.id), reasons: [reason],
        evidence: [ApiDiffEvidence("declaration", after: Some(value.qualifiedName), state: state)])
}

private func unmatchedEntry(old: ?ApiContractDeclaration, current: ?ApiContractDeclaration,
    state: String, collectionState: String): ApiDiffEntry {
    match ((old, current)) {
        case (Some(value), None) =>
            let classification = if (collectionState == "resolved") { "breaking" } else { "potentially-breaking" }
            ApiDiffEntry(value.kind, classification, state,
                oldId: Some(value.id), reasons: ["declaration removed"],
                evidence: [ApiDiffEvidence("declaration", before: Some(value.qualifiedName), state: collectionState)])
        case (None, Some(value)) =>
            ApiDiffEntry(value.kind, "additive", state,
                newId: Some(value.id), reasons: ["declaration added"],
                evidence: [ApiDiffEvidence("declaration", after: Some(value.qualifiedName))])
        case _ => throw IllegalArgumentException("API diff entry must have an old or new declaration")
    }
}

private func declarationBuckets(snapshot: ApiContractSnapshot):
    HashMap<String, ArrayList<ApiContractDeclaration>> {
    let buckets = HashMap<String, ArrayList<ApiContractDeclaration>>()
    for (declaration in snapshot.declarations) {
        let key = declarationBucketKey(declaration)
        match (buckets.get(key)) {
            case Some(values) => values.add(declaration)
            case None => buckets[key] = ArrayList<ApiContractDeclaration>([declaration])
        }
    }
    buckets
}
private func declarationSignatureBuckets(snapshot: ApiContractSnapshot):
    HashMap<String, ArrayList<ApiContractDeclaration>> {
    let buckets = HashMap<String, ArrayList<ApiContractDeclaration>>()
    for (declaration in snapshot.declarations) {
        let key = declarationSignatureKey(declaration)
        match (buckets.get(key)) {
            case Some(values) => values.add(declaration)
            case None => buckets[key] = ArrayList<ApiContractDeclaration>([declaration])
        }
    }
    buckets
}

protected func appendDeclarationDiffEntries(baseline: ApiContractSnapshot, current: ApiContractSnapshot,
    entries: ArrayList<ApiDiffEntry>): Unit {
    let matchedOld = HashSet<String>()
    let matchedCurrent = HashSet<String>()
    let currentById = HashMap<String, ApiContractDeclaration>()
    for (declaration in current.declarations) { currentById[declaration.id] = declaration }
    for (old in baseline.declarations) {
        match (currentById.get(old.id)) {
            case Some(value) =>
                entries.add(compareDeclaration(old, value, "exact"))
                let _ = matchedOld.add(old.id)
                let _ = matchedCurrent.add(value.id)
            case None => ()
        }
    }
    let oldBuckets = declarationBuckets(baseline)
    let currentBuckets = declarationBuckets(current)
    let currentSignatureBuckets = declarationSignatureBuckets(current)
    for (old in baseline.declarations where !matchedOld.contains(old.id)) {
        let key = declarationSignatureKey(old)
        match (currentSignatureBuckets.get(key)) {
            case Some(values) =>
                let candidates = ArrayList<ApiContractDeclaration>()
                for (value in values where !matchedCurrent.contains(value.id)) { candidates.add(value) }
                if (candidates.size == 1) {
                    let value = candidates[0]
                    entries.add(compareDeclaration(old, value, "fallback"))
                    let _ = matchedOld.add(old.id)
                    let _ = matchedCurrent.add(value.id)
                }
            case None => ()
        }
    }
    for (old in baseline.declarations where !matchedOld.contains(old.id)) {
        let key = declarationBucketKey(old)
        match (currentBuckets.get(key)) {
            case Some(values) =>
                let candidates = ArrayList<ApiContractDeclaration>()
                for (value in values where !matchedCurrent.contains(value.id)) {
                    candidates.add(value)
                }
                if (candidates.size == 1) {
                    let value = candidates[0]
                    entries.add(compareDeclaration(old, value, "fallback"))
                    let _ = matchedOld.add(old.id)
                    let _ = matchedCurrent.add(value.id)
                } else if (candidates.size > 1) {
                    entries.add(ApiDiffEntry(old.kind, "potentially-breaking", "ambiguous",
                        oldId: Some(old.id), reasons: ["fallback match is ambiguous"],
                        evidence: [ApiDiffEvidence("matching", before: Some(old.qualifiedName), state: "ambiguous")]))
                    let _ = matchedOld.add(old.id)
                }
            case None => ()
        }
    }
    for (old in baseline.declarations where !matchedOld.contains(old.id)) {
        entries.add(unmatchedEntry(Some(old), None<ApiContractDeclaration>, "removed", current.collectionState))
        let _ = matchedOld.add(old.id)
    }
    for (value in current.declarations where !matchedCurrent.contains(value.id)) {
        let key = declarationBucketKey(value)
        match (oldBuckets.get(key)) {
            case Some(values) =>
                if (values.size > 1) {
                    entries.add(ApiDiffEntry(value.kind, "potentially-breaking", "ambiguous",
                        newId: Some(value.id), reasons: ["fallback match is ambiguous"],
                        evidence: [ApiDiffEvidence("matching", after: Some(value.qualifiedName), state: "ambiguous")]))
                } else {
                    entries.add(addedDeclarationEntry(value, baseline, current, current.collectionState))
                }
            case None => entries.add(addedDeclarationEntry(value, baseline, current, current.collectionState))
        }
        let _ = matchedCurrent.add(value.id)
    }
}
