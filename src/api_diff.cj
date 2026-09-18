package cjdoc

import cjdoc.model.*
import cjdoc.render.*
import std.collection.*
import std.fs.*
import std.sort.*

private let API_DIFF_INPUT_LIMIT: Int64 = 64 * 1024 * 1024

private func optionText(value: ?String, fallback: String): String {
    match (value) { case Some(text) => text case None => fallback }
}

private func declarationKey(value: ApiContractDeclaration): String {
    "${value.moduleId}\n${value.packageName}\n${optionText(value.ownerId, "")}\n${value.kind}\n${value.name}"
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

private func joinedStrings(values: ReadOnlyList<String>): String {
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

private func addReason(reasons: ArrayList<String>, evidence: ArrayList<ApiDiffEvidence>,
    field: String, reason: String, before!: ?String = None, after!: ?String = None,
    state!: String = "resolved"): Unit {
    reasons.add(reason)
    evidence.add(ApiDiffEvidence(field, before: before, after: after, state: state))
}

private func compareDeclaration(old: ApiContractDeclaration, current: ApiContractDeclaration,
    matchState: String): ApiDiffEntry {
    let reasons = ArrayList<String>()
    let evidence = ArrayList<ApiDiffEvidence>()
    var classification = "unchanged"
    let oldVisibility = visibilityRank(old.visibility)
    let currentVisibility = visibilityRank(current.visibility)
    if (oldVisibility >= 0 && currentVisibility >= 0 && currentVisibility < oldVisibility) {
        classification = "breaking"
        addReason(reasons, evidence, "visibility", "visibility narrowed",
            before: Some(old.visibility), after: Some(current.visibility))
    } else if (old.visibility != current.visibility) {
        if (classification == "unchanged") { classification = "potentially-breaking" }
        addReason(reasons, evidence, "visibility", "visibility changed",
            before: Some(old.visibility), after: Some(current.visibility), state: "partial")
    }
    if (old.parameters.size != current.parameters.size) {
        if (old.collectionState == "resolved" && current.collectionState == "resolved") {
            classification = "breaking"
        } else if (classification != "breaking") {
            classification = "potentially-breaking"
        }
        addReason(reasons, evidence, "parameters", "parameter count changed",
            before: Some(parametersValue(old.parameters)), after: Some(parametersValue(current.parameters)),
            state: if (old.collectionState == "resolved" && current.collectionState == "resolved") { "resolved" } else { "partial" })
    } else {
        var index: Int64 = 0
        while (index < old.parameters.size) {
            let before = old.parameters[index]
            let after = current.parameters[index]
            if (before.name != after.name) {
                if (classification != "breaking") { classification = "potentially-breaking" }
                addReason(reasons, evidence, "parameters[${index}].name", "parameter name changed",
                    before: Some(before.name), after: Some(after.name), state: "partial")
            }
            if (before.typeState != after.typeState || !optionalEqual(before.`type`, after.`type`)) {
                if (before.typeState == "resolved" && after.typeState == "resolved") {
                    classification = "breaking"
                } else if (classification != "breaking") { classification = "potentially-breaking" }
                addReason(reasons, evidence, "parameters[" + index.toString() + "].type", "parameter type contract changed",
                    before: Some(parameterValue(before)), after: Some(parameterValue(after)),
                    state: if (before.typeState == "resolved" && after.typeState == "resolved") { "resolved" } else { "partial" })
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
    }
    if (old.returnState != current.returnState || !optionalEqual(old.returnType, current.returnType)) {
        if (old.returnState == "resolved" && current.returnState == "resolved") {
            classification = "breaking"
        } else if (classification != "breaking") { classification = "potentially-breaking" }
        addReason(reasons, evidence, "return", "return contract changed", before: old.returnType,
            after: current.returnType,
            state: if (old.returnState == "resolved" && current.returnState == "resolved") { "resolved" } else { "partial" })
    }
    if (old.genericParameters.size != current.genericParameters.size ||
        joinedStrings(old.genericParameters) != joinedStrings(current.genericParameters)) {
        if (classification != "breaking") { classification = "potentially-breaking" }
        addReason(reasons, evidence, "genericParameters", "generic contract changed",
            before: Some(joinedStrings(old.genericParameters)), after: Some(joinedStrings(current.genericParameters)),
            state: "partial")
    }
    if (joinedStrings(old.relationships) != joinedStrings(current.relationships)) {
        if (old.relationships.size > current.relationships.size) { classification = "breaking" }
        else if (classification != "breaking") { classification = "potentially-breaking" }
        addReason(reasons, evidence, "relationships", "type or symbol relationships changed",
            before: Some(joinedStrings(old.relationships)), after: Some(joinedStrings(current.relationships)),
            state: "partial")
    }
    if (!optionalBoolEqual(old.enumNonExhaustive, current.enumNonExhaustive)) {
        if (classification != "breaking") { classification = "potentially-breaking" }
        addReason(reasons, evidence, "enumNonExhaustive", "enum exhaustiveness evidence changed",
            before: None<String>, after: None<String>, state: "partial")
    }
    if (old.sourceApiSignatureState != current.sourceApiSignatureState ||
        joinedStrings(old.sourceApiSignature) != joinedStrings(current.sourceApiSignature)) {
        if (classification != "breaking") { classification = "potentially-breaking" }
        addReason(reasons, evidence, "sourceApiSignature", "source API signature changed",
            before: Some(joinedStrings(old.sourceApiSignature)), after: Some(joinedStrings(current.sourceApiSignature)),
            state: if (old.sourceApiSignatureState == "resolved" && current.sourceApiSignatureState == "resolved") { "resolved" } else { "partial" })
    }
    if (fingerprintChanged(old.documentationFingerprint, current.documentationFingerprint) && reasons.isEmpty()) {
        classification = "documentation-only"
        addReason(reasons, evidence, "documentationFingerprint", "documentation changed",
            before: Some(old.documentationFingerprint), after: Some(current.documentationFingerprint))
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

private func containsExposureTarget(values: ReadOnlyList<String>, target: String): Bool {
    for (value in values) { if (value == target) { return true } }
    false
}

private func sameExposureTargets(left: ReadOnlyList<String>, right: ReadOnlyList<String>): Bool {
    if (left.size != right.size) { return false }
    for (value in left) { if (!containsExposureTarget(right, value)) { return false } }
    true
}

private func exposureKey(value: ApiContractExposure): String {
    value.moduleId + "\n" + value.packageName + "\n" + value.exposedName
}

private func exposureIdentity(value: ApiContractExposure): String {
    value.moduleId + "\n" + value.packageName + "\n" + value.id + "\n" + value.exposedName
}

private func exposurePackageKey(value: ApiContractExposure): String {
    value.moduleId + "\n" + value.packageName
}

private func exposureBuckets(snapshot: ApiContractSnapshot): HashMap<String, ArrayList<ApiContractExposure>> {
    let buckets = HashMap<String, ArrayList<ApiContractExposure>>()
    for (exposure in snapshot.exposures) {
        let key = exposureKey(exposure)
        match (buckets.get(key)) {
            case Some(values) => values.add(exposure)
            case None => buckets[key] = ArrayList<ApiContractExposure>([exposure])
        }
    }
    buckets
}
private func exposureIdentityBuckets(snapshot: ApiContractSnapshot): HashMap<String, ArrayList<ApiContractExposure>> {
    let buckets = HashMap<String, ArrayList<ApiContractExposure>>()
    for (exposure in snapshot.exposures) {
        let key = exposureIdentity(exposure)
        match (buckets.get(key)) {
            case Some(values) => values.add(exposure)
            case None => buckets[key] = ArrayList<ApiContractExposure>([exposure])
        }
    }
    buckets
}

private func exposurePackageBuckets(snapshot: ApiContractSnapshot): HashMap<String, ArrayList<ApiContractExposure>> {
    let buckets = HashMap<String, ArrayList<ApiContractExposure>>()
    for (exposure in snapshot.exposures) {
        let key = exposurePackageKey(exposure)
        match (buckets.get(key)) {
            case Some(values) => values.add(exposure)
            case None => buckets[key] = ArrayList<ApiContractExposure>([exposure])
        }
    }
    buckets
}

private func compareExposure(old: ApiContractExposure, current: ApiContractExposure,
    matchState: String): ApiDiffEntry {
    let reasons = ArrayList<String>()
    let evidence = ArrayList<ApiDiffEvidence>()
    var classification = "unchanged"
    if (old.exposedName != current.exposedName) {
        if (old.state == "resolved" && current.state == "resolved") { classification = "breaking" }
        else { classification = "potentially-breaking" }
        addReason(reasons, evidence, "exposedName", "exposure name changed",
            before: Some(old.exposedName), after: Some(current.exposedName),
            state: if (classification == "breaking") { "resolved" } else { "partial" })
    }
    if (!sameExposureTargets(old.targetIds, current.targetIds)) {
        var removedTarget = false
        for (target in old.targetIds) {
            if (!containsExposureTarget(current.targetIds, target)) { removedTarget = true }
        }
        if (old.state == "resolved" && current.state == "resolved" && removedTarget) {
            classification = "breaking"
        } else if (classification != "breaking") { classification = "potentially-breaking" }
        addReason(reasons, evidence, "targetIds", "exposure targets changed",
            before: Some(joinedStrings(old.targetIds)), after: Some(joinedStrings(current.targetIds)),
            state: if (old.state == "resolved" && current.state == "resolved") { "resolved" } else { "partial" })
    }
    if (old.state != current.state) {
        if (classification != "breaking") { classification = "potentially-breaking" }
        addReason(reasons, evidence, "state", "exposure resolution state changed",
            before: Some(old.state), after: Some(current.state), state: "partial")
    }
    ApiDiffEntry("exposure", classification, matchState,
        oldId: Some(old.id), newId: Some(current.id), reasons: reasons.toArray(), evidence: evidence.toArray())
}

private func unmatchedExposureEntry(old: ?ApiContractExposure, current: ?ApiContractExposure,
    state: String, collectionState: String): ApiDiffEntry {
    match ((old, current)) {
        case (Some(value), None) =>
            let classification = if (collectionState == "resolved" && value.state == "resolved") {
                "breaking"
            } else { "potentially-breaking" }
            ApiDiffEntry("exposure", classification, state, oldId: Some(value.id),
                reasons: ["exposure removed"],
                evidence: [ApiDiffEvidence("exposure", before: Some(value.exposedName), state: collectionState)])
        case (None, Some(value)) =>
            let classification = if (collectionState == "resolved" && value.state == "resolved") {
                "additive"
            } else { "potentially-breaking" }
            ApiDiffEntry("exposure", classification, state, newId: Some(value.id),
                reasons: ["exposure added"],
                evidence: [ApiDiffEvidence("exposure", after: Some(value.exposedName), state: collectionState)])
        case _ => throw IllegalArgumentException("API exposure diff entry must have an old or new exposure")
    }
}

private func addedDeclarationEntry(value: ApiContractDeclaration,
    baseline: ApiContractSnapshot, collectionState: String): ApiDiffEntry {
    var classification = "additive"
    var reason = "declaration added"
    var state = "resolved"
    if (value.kind == "enumCase") {
        var ownerFound = false
        var ownerExhaustiveness: ?Bool = None
        match (value.ownerId) {
            case Some(ownerId) =>
                for (owner in baseline.declarations) {
                    if (owner.id == ownerId && owner.kind == "enum") {
                        ownerFound = true
                        ownerExhaustiveness = owner.enumNonExhaustive
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
        let key = declarationKey(declaration)
        match (buckets.get(key)) {
            case Some(values) => values.add(declaration)
            case None => buckets[key] = ArrayList<ApiContractDeclaration>([declaration])
        }
    }
    buckets
}

private func validateIdentity(baseline: ApiContractSnapshot, current: ApiContractSnapshot): Unit {
    if (baseline.project != current.project || baseline.audience != current.audience ||
        (baseline.cfgProfile != "unknown" && current.cfgProfile != "unknown" &&
            baseline.cfgProfile != current.cfgProfile)) {
        throw IllegalArgumentException("API diff inputs must match project, audience, and cfgProfile")
    }
}

public func compareApiContracts(baseline: ApiContractSnapshot, current: ApiContractSnapshot): ApiDiffReport {
    validateIdentity(baseline, current)
    let entries = ArrayList<ApiDiffEntry>()
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
    for (old in baseline.declarations where !matchedOld.contains(old.id)) {
        let key = declarationKey(old)
        match (currentBuckets.get(key)) {
            case Some(values) =>
                if (values.size == 1 && !matchedCurrent.contains(values[0].id)) {
                    let value = values[0]
                    entries.add(compareDeclaration(old, value, "fallback"))
                    let _ = matchedOld.add(old.id)
                    let _ = matchedCurrent.add(value.id)
                } else if (values.size > 1) {
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
        let key = declarationKey(value)
        match (oldBuckets.get(key)) {
            case Some(values) =>
                if (values.size > 1) {
                    entries.add(ApiDiffEntry(value.kind, "potentially-breaking", "ambiguous",
                        newId: Some(value.id), reasons: ["fallback match is ambiguous"],
                        evidence: [ApiDiffEvidence("matching", after: Some(value.qualifiedName), state: "ambiguous")]))
                } else {
                    entries.add(addedDeclarationEntry(value, baseline, current.collectionState))
                }
            case None => entries.add(addedDeclarationEntry(value, baseline, current.collectionState))
        }
        let _ = matchedCurrent.add(value.id)
    }
    let matchedOldExposures = HashSet<String>()
    let matchedCurrentExposures = HashSet<String>()
    let oldExposureBuckets = exposureBuckets(baseline)
    let currentExposureBuckets = exposureBuckets(current)
    let currentExposureIdentityBuckets = exposureIdentityBuckets(current)
    let oldExposurePackageBuckets = exposurePackageBuckets(baseline)
    let currentExposurePackageBuckets = exposurePackageBuckets(current)
    // Re-export IDs identify a declaration, while exposedName distinguishes
    // bindings that share one re-export statement. Match this identity before
    // falling back to package/name buckets, which may contain overloads.
    for (old in baseline.exposures where !matchedOldExposures.contains(exposureIdentity(old))) {
        let identity = exposureIdentity(old)
        match (currentExposureIdentityBuckets.get(identity)) {
            case Some(values) =>
                if (values.size == 1 && !matchedCurrentExposures.contains(exposureIdentity(values[0]))) {
                    let value = values[0]
                    entries.add(compareExposure(old, value, "exact"))
                    let _ = matchedOldExposures.add(identity)
                    let _ = matchedCurrentExposures.add(exposureIdentity(value))
                } else if (values.size > 1) {
                    entries.add(ApiDiffEntry("exposure", "potentially-breaking", "ambiguous",
                        oldId: Some(old.id), reasons: ["exposure identity match is ambiguous"],
                        evidence: [ApiDiffEvidence("matching", before: Some(old.exposedName), state: "ambiguous")]))
                    let _ = matchedOldExposures.add(identity)
                    for (value in values) { let _ = matchedCurrentExposures.add(exposureIdentity(value)) }
                }
            case None => ()
        }
    }
    for (old in baseline.exposures where !matchedOldExposures.contains(exposureIdentity(old))) {
        let key = exposureKey(old)
        match (currentExposureBuckets.get(key)) {
            case Some(values) =>
                if (values.size == 1 && !matchedCurrentExposures.contains(exposureIdentity(values[0]))) {
                    let value = values[0]
                    entries.add(compareExposure(old, value, "fallback"))
                    let _ = matchedOldExposures.add(exposureIdentity(old))
                    let _ = matchedCurrentExposures.add(exposureIdentity(value))
                } else if (values.size > 1) {
                    entries.add(ApiDiffEntry("exposure", "potentially-breaking", "ambiguous",
                        oldId: Some(old.id), reasons: ["exposure fallback match is ambiguous"],
                        evidence: [ApiDiffEvidence("matching", before: Some(old.exposedName), state: "ambiguous")]))
                    let _ = matchedOldExposures.add(exposureIdentity(old))
                    for (value in values) { let _ = matchedCurrentExposures.add(exposureIdentity(value)) }
                }
            case None => ()
        }
    }
    for (old in baseline.exposures where !matchedOldExposures.contains(exposureIdentity(old))) {
        let key = exposurePackageKey(old)
        match ((oldExposurePackageBuckets.get(key), currentExposurePackageBuckets.get(key))) {
            case (Some(oldValues), Some(currentValues)) =>
                if (oldValues.size == 1 && currentValues.size == 1 &&
                    !matchedCurrentExposures.contains(exposureIdentity(currentValues[0]))) {
                    let value = currentValues[0]
                    entries.add(compareExposure(old, value, "fallback"))
                    let _ = matchedOldExposures.add(exposureIdentity(old))
                    let _ = matchedCurrentExposures.add(exposureIdentity(value))
                }
            case _ => ()
        }
    }
    for (old in baseline.exposures where !matchedOldExposures.contains(exposureIdentity(old))) {
        entries.add(unmatchedExposureEntry(Some(old), None<ApiContractExposure>, "removed", current.collectionState))
        let _ = matchedOldExposures.add(exposureIdentity(old))
    }
    for (value in current.exposures where !matchedCurrentExposures.contains(exposureIdentity(value))) {
        let key = exposureKey(value)
        match (oldExposureBuckets.get(key)) {
            case Some(values) =>
                if (values.size > 1) {
                    entries.add(ApiDiffEntry("exposure", "potentially-breaking", "ambiguous",
                        newId: Some(value.id), reasons: ["exposure fallback match is ambiguous"],
                        evidence: [ApiDiffEvidence("matching", after: Some(value.exposedName), state: "ambiguous")]))
                } else {
                    entries.add(unmatchedExposureEntry(None<ApiContractExposure>, Some(value), "added", current.collectionState))
                }
            case None =>
                entries.add(unmatchedExposureEntry(None<ApiContractExposure>, Some(value), "added", current.collectionState))
        }
        let _ = matchedCurrentExposures.add(exposureIdentity(value))
    }
    sort(entries, lessThan: { left, right =>
        let leftKey = "${optionText(left.oldId, "")}\n${optionText(left.newId, "")}\n${left.kind}"
        let rightKey = "${optionText(right.oldId, "")}\n${optionText(right.newId, "")}\n${right.kind}"
        leftKey < rightKey

    }, stable: true)
    var breaking: Int64 = 0
    var potentiallyBreaking: Int64 = 0
    var additive: Int64 = 0
    var documentationOnly: Int64 = 0
    var metadataOnly: Int64 = 0
    var unchanged: Int64 = 0
    for (entry in entries) {
        match (entry.classification) {
            case "breaking" => breaking++
            case "potentially-breaking" => potentiallyBreaking++
            case "additive" => additive++
            case "documentation-only" => documentationOnly++
            case "metadata-only" => metadataOnly++
            case _ => unchanged++
        }
    }
    let state = if (baseline.collectionState == "resolved" && current.collectionState == "resolved") {
        "resolved"
    } else { "partial" }
    ApiDiffReport(baseline, current, comparisonState: state,
        summary: ApiDiffSummary(breaking: breaking, potentiallyBreaking: potentiallyBreaking,
            additive: additive, documentationOnly: documentationOnly, metadataOnly: metadataOnly,
            unchanged: unchanged), entries: entries.toArray())
}

public func readApiContractSnapshot(path: String): ApiContractSnapshot {
    let text = readTextBounded(Path(path), API_DIFF_INPUT_LIMIT)
    decodeApiContractSnapshot(text)
}

public func renderApiDiffText(report: ApiDiffReport): String {
    let out = StringBuilder()
    out.append("API diff ${report.baseline.project} (${report.baseline.audience})\n")
    out.append("comparison: ${report.comparisonState}; breaking=${report.summary.breaking}, " +
        "potentially-breaking=${report.summary.potentiallyBreaking}, additive=${report.summary.additive}, " +
        "documentation-only=${report.summary.documentationOnly}, metadata-only=${report.summary.metadataOnly}\n")
    for (entry in report.entries where entry.classification != "unchanged") {
        let id = match (entry.newId) { case Some(value) => value case None => optionText(entry.oldId, "<unknown>") }
        out.append("${entry.classification}: ${entry.kind} ${id} (${entry.matchState})")
        for (reason in entry.reasons) { out.append("; ${reason}") }
        out.append("\n")
    }
    out.toString()
}

public func apiDiffExitCode(report: ApiDiffReport, denyBreaking: Bool,
    denyPotentiallyBreaking: Bool): Int64 {
    if ((denyBreaking && report.summary.breaking > 0) ||
        (denyPotentiallyBreaking && report.summary.potentiallyBreaking > 0)) { 1 } else { 0 }
}
