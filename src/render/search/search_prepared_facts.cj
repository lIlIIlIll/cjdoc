protected package cjdoc.render.search

import cjdoc.model.*
import std.collection.*
import std.sort.*

private func searchStructuredText(entry: SearchProjectedEntry): String {
    let out = StringBuilder()
    out.append(entry.qualifiedName)
    out.append("\n")
    out.append(entry.name)
    out.append("\n")
    out.append(entry.ownerName)
    out.append("\n")
    out.append(entry.ownerQualifiedName)
    out.append("\n")
    out.append(entry.packageName)
    out.append("\n")
    out.append(entry.kind)
    out.append("\n")
    for (parameter in entry.parameterTypes) {
        out.append(parameter)
        out.append("\n")
    }
    out.append(entry.returnType)
    out.append("\n")
    out.append(entry.returnCanonical)
    out.toString()
}
private func searchIdentifierText(entry: SearchProjectedEntry): String {
    let out = StringBuilder(entry.qualifiedName.size + entry.name.size + entry.ownerName.size + 2)
    out.append(entry.qualifiedName)
    out.append("\n")
    out.append(entry.name)
    out.append("\n")
    out.append(entry.ownerName)
    out.toString()
}

/** An immutable fold of one captured exposure, built before the view is published. */
internal class SearchPreparedExposure {
    internal let exposure: SearchExposure
    internal let nameFolded: String
    internal let qualifiedNameFolded: String
    internal let packageNameFolded: String

    internal init(exposure: SearchExposure) {
        this.exposure = exposure
        nameFolded = searchAsciiFold(exposure.name)
        qualifiedNameFolded = searchAsciiFold(exposure.qualifiedName)
        packageNameFolded = searchAsciiFold(exposure.packageName)
    }
}

/** Entry facts that are expensive to derive and independent of any query. */
internal class SearchPreparedEntry {
    internal let entry: SearchProjectedEntry
    internal let nameFolded: String
    internal let qualifiedNameFolded: String
    internal let packageNameFolded: String
    internal let ownerNameFolded: String
    internal let ownerQualifiedNameFolded: String
    internal let ownerMemberName: String
    internal let kindFolded: String
    internal let returnTypeFolded: String
    internal let returnCanonicalFolded: String
    internal let parameterTypesFolded: Array<String>
    internal let summaryBodyFolded: String
    internal let metadataTextFolded: String
    // Published comment field values, folded once. They are retrieval text with
    // the same token rules as documentation prose, but never part of `body`, so
    // the body budget and the name scores stay untouched.
    internal let commentFieldsFolded: String
    internal let identifierTextFolded: String
    internal let discoveryStructuredTextFolded: String
    internal let sectionTextsFolded: Array<String>
    internal let nameWords: Array<String>
    internal let ownerNameWords: Array<String>
    internal let nameAcronym: String
    internal let qualifiedNameAcronym: String
    internal let editCandidateRunes: Array<Array<Rune>>
    internal let exposures: Array<SearchPreparedExposure>

    internal init(entry: SearchProjectedEntry) {
        this.entry = entry
        nameFolded = searchAsciiFold(entry.name)
        qualifiedNameFolded = searchAsciiFold(entry.qualifiedName)
        packageNameFolded = searchAsciiFold(entry.packageName)
        ownerNameFolded = searchAsciiFold(entry.ownerName)
        ownerQualifiedNameFolded = searchAsciiFold(entry.ownerQualifiedName)
        ownerMemberName = if (entry.ownerName.isEmpty()) { "" } else { entry.ownerName + "." + entry.name }
        kindFolded = searchAsciiFold(entry.kind)
        returnTypeFolded = searchAsciiFold(entry.returnType)
        returnCanonicalFolded = searchAsciiFold(entry.returnCanonical)
        let foldedParameters = ArrayList<String>()
        for (parameter in entry.parameterTypes) { foldedParameters.add(searchAsciiFold(parameter)) }
        parameterTypesFolded = foldedParameters.toArray()
        let summaryBody = StringBuilder()
        summaryBody.append(entry.summary)
        summaryBody.append("\n")
        summaryBody.append(entry.body)
        summaryBodyFolded = searchAsciiFold(summaryBody.toString())
        metadataTextFolded = searchAsciiFold(entry.metadataText)
        let fieldText = StringBuilder()
        for (row in entry.commentFieldRows) {
            for (value in row.values()) {
                fieldText.append("\n")
                fieldText.append(value)
            }
        }
        commentFieldsFolded = searchAsciiFold(fieldText.toString())
        let structuredText = searchStructuredText(entry)
        identifierTextFolded = searchAsciiFold(searchIdentifierText(entry))
        let discoveryText = StringBuilder()
        discoveryText.append(structuredText)
        discoveryText.append("\n")
        discoveryText.append(entry.metadataText)
        discoveryStructuredTextFolded = searchAsciiFold(discoveryText.toString())
        let foldedSections = ArrayList<String>()
        for (section in entry.sections) { foldedSections.add(searchAsciiFold(section.text)) }
        sectionTextsFolded = foldedSections.toArray()
        nameWords = searchWordParts(entry.name)
        ownerNameWords = searchWordParts(entry.ownerName)
        let qualifiedNameWords = searchWordParts(entry.qualifiedName)
        nameAcronym = searchAcronym(nameWords)
        qualifiedNameAcronym = searchAcronym(qualifiedNameWords)
        let candidateNames = ArrayList<String>()
        let seenCandidateNames = HashSet<String>()
        if (seenCandidateNames.add(nameFolded)) { candidateNames.add(nameFolded) }
        for (word in nameWords) {
            if (seenCandidateNames.add(word)) { candidateNames.add(word) }
        }
        let editCandidates = candidateNames.toArray()
        let runeCandidates = ArrayList<Array<Rune>>()
        for (candidate in editCandidates) { runeCandidates.add(searchRunes(candidate)) }
        editCandidateRunes = runeCandidates.toArray()
        let preparedExposures = ArrayList<SearchPreparedExposure>()
        for (exposure in entry.exposures) {
            preparedExposures.add(SearchPreparedExposure(exposure))
        }
        exposures = preparedExposures.toArray()
    }
}

/** Immutable native matching facts over one unchanged raw projection. */
protected class PreparedDocumentationSearchProjection {
    internal let projection: DocumentationSearchProjection
    internal let entries: ArrayList<SearchPreparedEntry>

    internal init(projection: DocumentationSearchProjection,
        entries: ArrayList<SearchPreparedEntry>) {
        this.projection = projection
        this.entries = entries
    }

    internal prop profile: String { get() { projection.profile } }
    internal prop scopeSnapshotId: String { get() { projection.scopeSnapshotId } }
    internal prop contentId: String { get() { projection.contentId } }
    internal prop apiCollectionState: String { get() { projection.apiCollectionState } }
    internal prop bodyComplete: Bool { get() { projection.bodyComplete } }
    internal prop truncatedCount: Int64 { get() { projection.truncatedCount } }
}

/** Build all immutable native facts before the prepared view is cached/published. */
protected func prepareDocumentationSearchProjection(
    projection: DocumentationSearchProjection): PreparedDocumentationSearchProjection {
    searchValidateCommentFields(projection)
    let entries = ArrayList<SearchPreparedEntry>()
    for (entry in projection.entries) { entries.add(SearchPreparedEntry(entry)) }
    PreparedDocumentationSearchProjection(projection, entries)
}

/**
 * One projection plus the request-independent facts a host needs to resolve a
 * hit back to a captured identity.
 */
protected class SearchProjectionSet {
    internal let projections = ArrayList<PreparedDocumentationSearchProjection>()
    internal var cachedProjectionId: ?String = None

    protected init() {}

    /** Data-only callers may prepare on demand; session callers supply cached facts. */
    protected func add(projection: DocumentationSearchProjection): Unit {
        addPrepared(prepareDocumentationSearchProjection(projection))
    }

    protected func addPrepared(projection: PreparedDocumentationSearchProjection): Unit {
        projections.add(projection)
        cachedProjectionId = None
    }

    protected func entryOf(snapshotId: String, canonicalId: String): ?SearchProjectedEntry {
        for (projection in projections) {
            if (projection.scopeSnapshotId != snapshotId) { continue }
            for (facts in projection.entries where facts.entry.canonicalId == canonicalId) {
                return Some(facts.entry)
            }
        }
        None
    }

    protected prop sourceComplete: Bool {
        get() {
            for (projection in projections) {
                if (projection.apiCollectionState != "resolved") { return false }
            }
            true
        }
    }

    protected prop bodyComplete: Bool {
        get() {
            for (projection in projections) {
                if (!projection.bodyComplete) { return false }
            }
            true
        }
    }

    protected prop truncatedCount: Int64 {
        get() {
            var count: Int64 = 0
            for (projection in projections) { count += projection.truncatedCount }
            count
        }
    }

    protected prop profile: String {
        get() {
            for (projection in projections) { return projection.profile }
            searchContractString("defaultProfile")
        }
    }

    protected prop projectionId: String {
        get() {
            if (projections.size == 1) { return projections[0].contentId }
            match (cachedProjectionId) {
                case Some(value) => return value
                case None => ()
            }
            let ordered = ArrayList<PreparedDocumentationSearchProjection>()
            for (projection in projections) { ordered.add(projection) }
            sort(ordered, lessThan: { left, right =>
                searchUtf8ByteLess(left.scopeSnapshotId, right.scopeSnapshotId)
            }, stable: true)
            let out = StringBuilder()
            out.append("cjdoc.search-projection-set/1\n")
            for (projection in ordered) {
                out.append(projection.scopeSnapshotId + "\n" + projection.contentId + "\n")
            }
            let value = contractFingerprint(out.toString())
            cachedProjectionId = Some(value)
            value
        }
    }
}
