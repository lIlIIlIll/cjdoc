protected package cjdoc.render.search

import std.collection.*
import std.sort.*

/** One ranked canonical result before pagination. */
protected class SearchRankedEntry {
    protected let entry: SearchProjectedEntry
    protected let evidence: SearchEvidence

    protected init(entry: SearchProjectedEntry, evidence: SearchEvidence) {
        this.entry = entry
        this.evidence = evidence
    }
}

/** The one global order: score descending, then UTF-8 identity and reason bytes. */
private func searchRankLess(left: SearchRankedEntry, right: SearchRankedEntry): Bool {
    if (left.evidence.score != right.evidence.score) {
        return left.evidence.score > right.evidence.score
    }
    if (left.entry.snapshotId != right.entry.snapshotId) {
        return searchUtf8ByteLess(left.entry.snapshotId, right.entry.snapshotId)
    }
    if (left.entry.canonicalId != right.entry.canonicalId) {
        return searchUtf8ByteLess(left.entry.canonicalId, right.entry.canonicalId)
    }
    searchUtf8ByteLess(left.evidence.reason, right.evidence.reason)
}

private func searchEvidenceLess(left: SearchEvidence, right: SearchEvidence): Bool {
    if (left.score != right.score) { return left.score > right.score }
    if (left.reason != right.reason) { return searchUtf8ByteLess(left.reason, right.reason) }
    let common = if (left.matchedExposureIds.size < right.matchedExposureIds.size) {
        left.matchedExposureIds.size
    } else { right.matchedExposureIds.size }
    var index: Int64 = 0
    while (index < common) {
        let leftId = left.matchedExposureIds[index]
        let rightId = right.matchedExposureIds[index]
        if (leftId != rightId) { return searchUtf8ByteLess(leftId, rightId) }
        index++
    }
    if (left.matchedExposureIds.size != right.matchedExposureIds.size) {
        return left.matchedExposureIds.size < right.matchedExposureIds.size
    }
    searchUtf8ByteLess(left.anchor, right.anchor)
}

protected func searchSortRanked(entries: ArrayList<SearchRankedEntry>): Unit {
    sort(entries, lessThan: { left, right => searchRankLess(left, right) }, stable: true)
}

/**
 * Collapse canonical capture identity, retaining the best evidence. Exposure
 * spellings remain evidence on the single canonical result.
 */
protected func searchDeduplicate(candidates: ArrayList<SearchRankedEntry>):
    ArrayList<SearchRankedEntry> {
    let best = HashMap<String, SearchRankedEntry>()
    for (candidate in candidates) {
        let key = searchIdentityKey(candidate.entry.snapshotId, candidate.entry.canonicalId)
        match (best.get(key)) {
            case Some(existing) =>
                let candidateWins = searchEvidenceLess(candidate.evidence, existing.evidence)
                let winner = if (candidateWins) { candidate } else { existing }
                let other = if (candidateWins) { existing } else { candidate }
                for (exposureId in other.evidence.matchedExposureIds) {
                    if (!winner.evidence.matchedExposureIds.contains(exposureId)) {
                        winner.evidence.matchedExposureIds.add(exposureId)
                    }
                }
                sort(winner.evidence.matchedExposureIds,
                    lessThan: { left, right => searchUtf8ByteLess(left, right) }, stable: true)
                best[key] = winner
            case None => best[key] = candidate
        }
    }
    let result = ArrayList<SearchRankedEntry>()
    for ((_, value) in best) { result.add(value) }
    result
}
protected class SearchTagFacet {
    protected let tag: SearchProjectionTag
    protected let count: Int64

    protected init(tag: SearchProjectionTag, count: Int64) {
        this.tag = tag
        this.count = count
    }
}

private class SearchTagFacetCount {
    let tag: SearchProjectionTag
    var count: Int64 = 0

    init(tag: SearchProjectionTag) { this.tag = tag }
}
private func searchTagFacetLess(left: SearchTagFacet, right: SearchTagFacet): Bool {
    if (left.tag.snapshotId != right.tag.snapshotId) {
        return searchUtf8ByteLess(left.tag.snapshotId, right.tag.snapshotId)
    }
    if (left.tag.module.moduleId != right.tag.module.moduleId) {
        return searchUtf8ByteLess(left.tag.module.moduleId, right.tag.module.moduleId)
    }
    searchUtf8ByteLess(left.tag.id, right.tag.id)
}

internal func searchBuildTagFacets(entries: ArrayList<SearchRankedEntry>):
    ArrayList<SearchTagFacet> {
    let counts = HashMap<String, SearchTagFacetCount>()
    for (candidate in entries) {
        for (tag in candidate.entry.tagFacets) {
            match (counts.get(tag.key)) {
                case Some(value) => value.count++
                case None =>
                    let value = SearchTagFacetCount(tag)
                    value.count = 1
                    counts[tag.key] = value
            }
        }
    }
    let result = ArrayList<SearchTagFacet>()
    for ((_, value) in counts) {
        result.add(SearchTagFacet(value.tag, value.count))
    }
    sort(result, lessThan: { left, right => searchTagFacetLess(left, right) }, stable: true)
    result
}
