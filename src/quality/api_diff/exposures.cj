protected package cjdoc.quality.api_diff

import cjdoc.model.*
import std.collection.*

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

protected func appendExposureDiffEntries(baseline: ApiContractSnapshot, current: ApiContractSnapshot,
    entries: ArrayList<ApiDiffEntry>): Unit {
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
}
