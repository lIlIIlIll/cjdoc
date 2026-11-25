protected package cjdoc.render.search

import cjdoc.render.publication.DeclarationClassification
import std.collection.*

import yjson.JsonObject

/** One internal search hit; the native bridge maps this to QueryOutcome. */
protected class SearchHit {
    protected let snapshotId: String
    protected let canonicalId: String
    protected let score: Int64
    protected let reason: String
    protected let matchedExposureIds = ArrayList<String>()
    protected let anchor: String
    protected let classification: DeclarationClassification

    protected init(snapshotId: String, canonicalId: String, score: Int64, reason: String,
        matchedExposureIds: Array<String>, anchor: String,
        classification: DeclarationClassification) {
        this.snapshotId = snapshotId
        this.canonicalId = canonicalId
        this.score = score
        this.reason = reason
        this.matchedExposureIds.add(all: matchedExposureIds)
        this.anchor = anchor
        this.classification = classification
    }
}


/**
 * Coverage of the projection a search ran against.
 *
 * `bounded-static` reports an explicit body limit and the number of truncated
 * entries; `full-ir` reports no limit. A caller can therefore tell a complete
 * projection from a truncated one without guessing.
 */
protected class SearchCoverage {
    protected let profile: String
    protected let projectionId: String
    protected let bodyTextLimit: ?Int64
    protected let bodyComplete: Bool
    protected let truncatedEntries: Int64

    protected init(profile: String, projectionId: String, bodyTextLimit: ?Int64, bodyComplete: Bool,
        truncatedEntries: Int64) {
        this.profile = profile
        this.projectionId = projectionId
        this.bodyTextLimit = bodyTextLimit
        this.bodyComplete = bodyComplete
        this.truncatedEntries = truncatedEntries
    }
}

/**
 * The pure outcome of one search execution.
 *
 * Both executors return exactly this: hit identities, stable order, counts and
 * coverage. A host builds its own presentation from it, so a browser and a CLI
 * cannot disagree about which declarations matched.
 */
/**
 * The pure result of a search execution, before the host builds its public
 * response envelope.
 */
protected class SearchExecutionResult {
    protected var status: String = "ok"
    protected var errorCode: String = ""
    protected var errorMessage: String = ""
    protected let hits = ArrayList<SearchHit>()
    protected var offset: Int64 = 0
    protected var returned: Int64 = 0
    protected var total: Int64 = 0
    protected var complete: Bool = true
    protected var next: ?String = None
    protected var reason: String = ""
    protected let facets = ArrayList<SearchTagFacet>()
    // Absent when the request did not ask for a value catalog: the executor then
    // performs no counting work at all.
    protected var commentFacetPage: ?JsonObject = None
    protected var coverage: ?SearchCoverage = None

    protected init() {}
}
