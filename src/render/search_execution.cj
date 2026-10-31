package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.sort.*
import cjdoc.schema_data as search_schema
import yjson.*

// The shared JSON contract is parsed once, then compiled into immutable native
// lookup tables. Matchers contain only these fixed primitive names.
private let SEARCH_CONTRACT_NODE: JsonObject =
    JsonNode.parse(search_schema.documentationSearchContract()).asObject()

protected class SearchRule {
    protected let primitive: String
    protected let level: Int64
    protected let score: Int64
    protected let reason: String

    protected init(primitive: String, level: Int64, score: Int64, reason: String) {
        this.primitive = primitive
        this.level = level
        this.score = score
        this.reason = reason
    }
}
private class SearchRuleSet {
    let ordered = ArrayList<SearchRule>()
    let byPrimitive = HashMap<String, SearchRule>()
}

private class SearchFilterSpec {
    let properties = ArrayList<String>()
    let field: String
    let context: String

    init(field: String, context: String) {
        this.field = field
        this.context = context
    }
}
private class SearchSetPredicate {
    let field: String
    let property: String
    let primitive: String

    init(field: String, property: String, primitive: String) {
        this.field = field
        this.property = property
        this.primitive = primitive
    }
}


private func searchContractProperty(key: String): JsonNode {
    SEARCH_CONTRACT_NODE.get("requestProperties").getOrThrow().asObject()
        .get(key).getOrThrow()
}

private func searchReadStringList(value: JsonNode): Array<String> {
    let result = ArrayList<String>()
    let values = value.asArray()
    for (index in 0..values.size()) { result.add(values[index].asString()) }
    result.toArray()
}

private func searchReadRuleSet(key: String): SearchRuleSet {
    let result = SearchRuleSet()
    let values = SEARCH_CONTRACT_NODE.get(key).getOrThrow().asArray()
    for (index in 0..values.size()) {
        let row = values[index].asObject()
        let primitive = row.get("primitive").getOrThrow().asString()
        let rule = SearchRule(primitive, row.get("level").getOrThrow().asInt64(),
            row.get("score").getOrThrow().asInt64(),
            row.get("reason").getOrThrow().asString())
        result.ordered.add(rule)
        result.byPrimitive[primitive] = rule
    }
    result
}

private func searchReadFilterSpecs(): HashMap<String, SearchFilterSpec> {
    let result = HashMap<String, SearchFilterSpec>()
    let values = SEARCH_CONTRACT_NODE.get("filterFields").getOrThrow().asArray()
    for (index in 0..values.size()) {
        let row = values[index].asObject()
        let field = row.get("field").getOrThrow().asString()
        let context = row.get("context").getOrThrow().asString()
        let spec = SearchFilterSpec(field, context)
        let property = row.get("property").getOrThrow()
        if (property.kind() == JsonKind.String) {
            spec.properties.add(property.asString())
        } else {
            for (propertyIndex in 0..property.asArray().size()) {
                spec.properties.add(property.asArray()[propertyIndex].asString())
            }
        }
        result[field] = spec
    }
    result
}

private func searchReadFilterOps(): HashMap<String, String> {
    let result = HashMap<String, String>()
    let values = SEARCH_CONTRACT_NODE.get("filterOps").getOrThrow().asArray()
    for (index in 0..values.size()) {
        let row = values[index].asObject()
        result[row.get("op").getOrThrow().asString()] =
            row.get("primitive").getOrThrow().asString()
    }
    result
}
private func searchReadSetPredicates(): ArrayList<SearchSetPredicate> {
    let result = ArrayList<SearchSetPredicate>()
    let values = SEARCH_CONTRACT_NODE.get("setPredicates").getOrThrow().asArray()
    for (index in 0..values.size()) {
        let row = values[index].asObject()
        result.add(SearchSetPredicate(row.get("field").getOrThrow().asString(),
            row.get("property").getOrThrow().asString(),
            row.get("primitive").getOrThrow().asString()))
    }
    result
}
private let SEARCH_SET_PREDICATES = searchReadSetPredicates()
private func searchSetPredicateFor(field: String): ?SearchSetPredicate {
    for (predicate in SEARCH_SET_PREDICATES) {
        if (predicate.field == field) { return Some(predicate) }
    }
    None
}

private func searchSetValuePatternAdmits(value: String, pattern: String): Bool {
    if (pattern.isEmpty()) { return true }
    if (pattern != "^[A-Za-z0-9_-]{1,64}$") {
        throw IllegalStateException("unsupported search set-value pattern")
    }
    isDeclarationTagId(value)
}

protected func searchNormalizeSetPredicateValues(request: JsonObject,
    field: String): Array<String> {
    let predicate = match (searchSetPredicateFor(field)) {
        case Some(value) => value
        case None => throw IllegalArgumentException("search set predicate is not declared")
    }
    match (request.get(predicate.field)) {
        case Some(node) =>
            let schema = searchContractProperty(predicate.field)
            if (!searchJsonMatchesSchema(node, schema)) {
                throw IllegalArgumentException("search set predicate does not satisfy the shared schema")
            }
            let pattern = match (schema.asObject().get("items")) {
                case Some(item) =>
                    match (item.asObject().get("pattern")) {
                        case Some(value) => value.asString()
                        case None => ""
                    }
                case None => ""
            }
            let unique = ArrayList<String>()
            let seen = HashSet<String>()
            let values = node.asArray()
            for (index in 0..values.size()) {
                let value = values[index].asString()
                if (!searchSetValuePatternAdmits(value, pattern)) {
                    throw IllegalArgumentException("search set predicate value does not satisfy the shared schema")
                }
                if (seen.add(value)) { unique.add(value) }
            }
            sort(unique, lessThan: { left, right =>
                searchUtf8ByteLess(left, right)
            }, stable: true)
            unique.toArray()
        case None => []
    }
}

private func searchRequestSetPredicates(request: JsonObject): HashMap<String, Array<String>> {
    let result = HashMap<String, Array<String>>()
    for (predicate in SEARCH_SET_PREDICATES) {
        let values = searchNormalizeSetPredicateValues(request, predicate.field)
        if (!values.isEmpty()) { result[predicate.field] = values }
    }
    result
}


private class SearchTextPolicy {
    let minEditRunes: Int64
    let maxEditRunes: Int64

    init(value: JsonObject) {
        if (value.get("caseFold").getOrThrow().asString() != "ascii-only" ||
            value.get("normalization").getOrThrow().asString() != "none" ||
            value.get("tokens").getOrThrow().asString() != "ascii-alnum-underscore-or-u0080-plus" ||
            value.get("words").getOrThrow().asString() != "ascii-camel-acronym-boundaries" ||
            value.get("edit").getOrThrow().asString() != "one-scalar-insert-delete-substitute") {
            throw IllegalStateException("unsupported search text-policy primitive")
        }
        minEditRunes = value.get("minEditRunes").getOrThrow().asInt64()
        maxEditRunes = value.get("maxEditRunes").getOrThrow().asInt64()
        if (minEditRunes < 1 || maxEditRunes < minEditRunes || maxEditRunes > 128) {
            throw IllegalStateException("invalid search edit-token budget")
        }
    }
}

private let SEARCH_TEXT_POLICY = SearchTextPolicy(
    SEARCH_CONTRACT_NODE.get("textPolicy").getOrThrow().asObject())

private let SEARCH_PRECISE_RULE_SET = searchReadRuleSet("preciseRules")
private let SEARCH_DISCOVERY_RULE_SET = searchReadRuleSet("discoveryRules")
private let SEARCH_PRECISE_RULES = SEARCH_PRECISE_RULE_SET.byPrimitive
private let SEARCH_DISCOVERY_RULES = SEARCH_DISCOVERY_RULE_SET.byPrimitive
private let SEARCH_FILTER_SPECS = searchReadFilterSpecs()
private let SEARCH_FILTER_OPS = searchReadFilterOps()
private let SEARCH_GLOBAL_FIELD_VALUES: Array<String> =
    searchReadStringList(SEARCH_CONTRACT_NODE.get("globalFields").getOrThrow())
private let SEARCH_SEARCH_FIELD_VALUES: Array<String> =
    searchReadStringList(SEARCH_CONTRACT_NODE.get("searchFields").getOrThrow())
protected let SEARCH_PROFILE_VALUES: Array<String> =
    searchReadStringList(searchContractProperty("profile").asObject()
        .get("enum").getOrThrow())

protected func searchContractString(key: String): String {
    SEARCH_CONTRACT_NODE.get(key).getOrThrow().asString()
}

protected func searchContractInteger(key: String): Int64 {
    SEARCH_CONTRACT_NODE.get(key).getOrThrow().asInt64()
}
protected func searchContractRequestVersion(): String {
    searchContractProperty("schemaVersion").asObject()
        .get("const").getOrThrow().asString()
}

protected func searchContractProfile(index: Int64): String {
    SEARCH_PROFILE_VALUES[index]
}

protected func searchContractProfileIsKnown(profile: String): Bool {
    SEARCH_PROFILE_VALUES.contains(profile)
}

private func searchRule(mode: String, primitive: String): SearchRule {
    let rules = if (mode == "precise") { SEARCH_PRECISE_RULES } else { SEARCH_DISCOVERY_RULES }
    match (rules.get(primitive)) {
        case Some(value) => value
        case None => throw IllegalStateException("search contract does not declare primitive '${primitive}'")
    }
}

protected func searchEvidenceLevel(mode: String, reason: String): Int64 {
    let rules = if (mode == "precise") { SEARCH_PRECISE_RULES } else { SEARCH_DISCOVERY_RULES }
    for ((_, rule) in rules) {
        if (rule.reason == reason) { return rule.level }
    }
    0
}

/** One evidence row, including only the exposure contexts that proved it. */
protected class SearchEvidence {
    protected let level: Int64
    protected let score: Int64
    protected let reason: String
    protected let matchedExposureIds = ArrayList<String>()
    protected let anchor: String

    protected init(rule: SearchRule, matchedExposureIds!: Array<String> = [],
        anchor!: String = "") {
        this.level = rule.level
        this.score = rule.score
        this.reason = rule.reason
        this.anchor = anchor
        this.matchedExposureIds.add(all: matchedExposureIds)
    }
}
/**
 * ASCII-only case folding.
 *
 * Only `A`–`Z` become `a`–`z`. Every other code point, including non-ASCII
 * letters, is preserved, so no locale or compatibility rule can change which
 * declarations a query reaches in a browser and in a CLI.
 */
protected func searchAsciiFold(value: String): String {
    let out = StringBuilder()
    for (rune in value.runes()) {
        let code = UInt32(rune)
        if (code >= 0x41u32 && code <= 0x5Au32) { out.append(Rune(code + 0x20u32)) }
        else { out.append(rune) }
    }
    out.toString()
}

/**
 * Split free text into searchable tokens.
 *
 * ASCII letters, digits, `_` and every code point at or above U+0080 stay in one
 * token; every other code point separates. Chinese, accented and non-BMP text
 * therefore search as written while punctuation still splits.
 */
protected func searchTokens(value: String): Array<String> {
    let tokens = ArrayList<String>()
    var current = StringBuilder()
    var pending = false
    for (rune in value.runes()) {
        let code = UInt32(rune)
        let wordByte = (code >= 0x30u32 && code <= 0x39u32) ||
            (code >= 0x41u32 && code <= 0x5Au32) || (code >= 0x61u32 && code <= 0x7Au32) ||
            code == 0x5Fu32
        if (wordByte || code >= 0x80u32) {
            current.append(rune)
            pending = true
        } else if (pending) {
            tokens.add(searchAsciiFold(current.toString()))
            current = StringBuilder()
            pending = false
        }
    }
    if (pending) { tokens.add(searchAsciiFold(current.toString())) }
    tokens.toArray()
}

protected func searchRuneCount(value: String): Int64 {
    var count: Int64 = 0
    for (_ in value.runes()) { count++ }
    count
}

protected func searchRunes(value: String): Array<Rune> {
    let result = ArrayList<Rune>()
    for (rune in value.runes()) { result.add(rune) }
    result.toArray()
}

/**
 * Split an identifier at ASCII case boundaries only.
 *
 * `readJSONFile` becomes read / JSON / File: an acronym keeps its trailing
 * capital with the following word. Non-ASCII code points never split a word.
 */
protected func searchWordParts(value: String): Array<String> {
    let codePoints = ArrayList<UInt32>()
    let upperMatches = ArrayList<Bool>()
    let lowerMatches = ArrayList<Bool>()
    for (rune in value.runes()) {
        let code = UInt32(rune)
        codePoints.add(code)
        upperMatches.add(code >= 0x41u32 && code <= 0x5Au32)
        lowerMatches.add(code >= 0x61u32 && code <= 0x7Au32)
    }
    let words = ArrayList<String>()
    var current = StringBuilder()
    var started = false
    for (index in 0..codePoints.size) {
        let code = codePoints[index]
        let wordByte = (code >= 0x30u32 && code <= 0x39u32) ||
            (code >= 0x41u32 && code <= 0x5Au32) || (code >= 0x61u32 && code <= 0x7Au32) ||
            code == 0x5Fu32 || code >= 0x80u32
        if (!wordByte) {
            if (started) { words.add(searchAsciiFold(current.toString())) }
            current = StringBuilder()
            started = false
            continue
        }
        if (started && upperMatches[index]) {
            let previousLower = index > 0 && lowerMatches[index - 1]
            let previousUpper = index > 0 && upperMatches[index - 1]
            let nextLower = index + 1 < codePoints.size && lowerMatches[index + 1]
            if (previousLower || (previousUpper && nextLower)) {
                words.add(searchAsciiFold(current.toString()))
                current = StringBuilder()
            }
        }
        current.append(Rune(code))
        started = true
    }
    if (started) { words.add(searchAsciiFold(current.toString())) }
    words.toArray()
}

protected func searchAcronym(words: Array<String>): String {
    let out = StringBuilder()
    for (word in words) {
        for (rune in word.runes()) { out.append(rune); break }
    }
    out.toString()
}

/** Exactly one insertion, deletion or substitution; a transposition is not a match. */
protected func searchOneEditApart(query: String, candidate: String): Bool {
    searchOneEditApartRunes(searchRunes(query), searchRunes(candidate))
}

private func searchOneEditApartRunes(left: Array<Rune>, right: Array<Rune>): Bool {
    let leftSize = left.size
    let rightSize = right.size
    let difference = if (leftSize > rightSize) { leftSize - rightSize } else { rightSize - leftSize }
    if (difference > 1) { return false }
    var leftIndex = 0
    var rightIndex = 0
    var edits: Int64 = 0
    while (leftIndex < leftSize && rightIndex < rightSize) {
        if (left[leftIndex] == right[rightIndex]) {
            leftIndex++
            rightIndex++
            continue
        }
        edits++
        if (edits > 1) { return false }
        if (leftSize == rightSize) {
            leftIndex++
            rightIndex++
        } else if (leftSize > rightSize) {
            leftIndex++
        } else {
            rightIndex++
        }
    }
    if (leftIndex < leftSize || rightIndex < rightSize) { edits++ }
    edits == 1
}

protected func searchContainsAll(haystack: String, tokens: Array<String>): Bool {
    if (tokens.isEmpty()) { return false }
    for (token in tokens) {
        if (!haystack.contains(token)) { return false }
    }
    true
}

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



private func searchContainsAllDocumentationText(facts: SearchPreparedEntry,
    tokens: Array<String>): Bool {
    if (tokens.isEmpty()) { return false }
    for (token in tokens) {
        if (!facts.summaryBodyFolded.contains(token) &&
            !facts.metadataTextFolded.contains(token)) { return false }
    }
    true
}


protected func searchUtf8ByteLess(left: String, right: String): Bool {
    let common = if (left.size < right.size) { left.size } else { right.size }
    var index: Int64 = 0
    while (index < common) {
        if (left[index] != right[index]) { return left[index] < right[index] }
        index++
    }
    left.size < right.size
}
protected func searchIdentityKey(snapshotId: String, canonicalId: String): String {
    snapshotId + "\u{0}" + canonicalId
}

private func searchRuleEvidence(mode: String, primitive: String,
    selectorPrimitive: String, hasSelectors: Bool,
    matchedExposureIds!: Array<String> = [], anchor!: String = ""): SearchEvidence {
    let selectedPrimitive = if (mode == "precise" && hasSelectors &&
        !selectorPrimitive.isEmpty()) { selectorPrimitive } else { primitive }
    SearchEvidence(searchRule(mode, selectedPrimitive),
        matchedExposureIds: matchedExposureIds, anchor: anchor)
}

private func searchHasExposureName(facts: SearchPreparedEntry, name: String): Bool {
    for (prepared in facts.exposures) {
        if (prepared.exposure.name == name) { return true }
    }
    false
}

private func searchExposureIdsByName(facts: SearchPreparedEntry, name: String): Array<String> {
    let result = ArrayList<String>()
    for (prepared in facts.exposures) {
        let exposure = prepared.exposure
        if (exposure.name == name && !result.contains(exposure.id)) { result.add(exposure.id) }
    }
    sort(result, lessThan: { left, right => searchUtf8ByteLess(left, right) }, stable: true)
    result.toArray()
}

private func searchBodyAnchor(facts: SearchPreparedEntry, tokens: Array<String>): String {
    if (facts.entry.concept || tokens.isEmpty()) { return "" }
    let anchors = ArrayList<String>()
    var index: Int64 = 0
    while (index < facts.entry.sections.size) {
        let section = facts.entry.sections[index]
        if (searchContainsAll(facts.sectionTextsFolded[index], tokens) &&
            !anchors.contains(section.anchor)) {
            anchors.add(section.anchor)
        }
        index++
    }
    if (anchors.isEmpty()) { return "" }
    sort(anchors, lessThan: { left, right => searchUtf8ByteLess(left, right) }, stable: true)
    anchors[0]
}

/** An immutable fold of one captured exposure, built before the view is published. */
protected class SearchPreparedExposure {
    protected let exposure: SearchExposure
    protected let nameFolded: String
    protected let qualifiedNameFolded: String
    protected let packageNameFolded: String

    protected init(exposure: SearchExposure) {
        this.exposure = exposure
        nameFolded = searchAsciiFold(exposure.name)
        qualifiedNameFolded = searchAsciiFold(exposure.qualifiedName)
        packageNameFolded = searchAsciiFold(exposure.packageName)
    }
}

/** Entry facts that are expensive to derive and independent of any query. */
protected class SearchPreparedEntry {
    protected let entry: SearchProjectedEntry
    protected let nameFolded: String
    protected let qualifiedNameFolded: String
    protected let packageNameFolded: String
    protected let ownerNameFolded: String
    protected let ownerQualifiedNameFolded: String
    protected let ownerMemberName: String
    protected let kindFolded: String
    protected let returnTypeFolded: String
    protected let returnCanonicalFolded: String
    protected let parameterTypesFolded: Array<String>
    protected let summaryBodyFolded: String
    protected let metadataTextFolded: String
    protected let identifierTextFolded: String
    protected let discoveryStructuredTextFolded: String
    protected let sectionTextsFolded: Array<String>
    protected let nameWords: Array<String>
    protected let ownerNameWords: Array<String>
    protected let nameAcronym: String
    protected let qualifiedNameAcronym: String
    protected let editCandidateRunes: Array<Array<Rune>>
    protected let exposures: Array<SearchPreparedExposure>

    protected init(entry: SearchProjectedEntry) {
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
    protected let projection: DocumentationSearchProjection
    protected let entries: ArrayList<SearchPreparedEntry>

    protected init(projection: DocumentationSearchProjection,
        entries: ArrayList<SearchPreparedEntry>) {
        this.projection = projection
        this.entries = entries
    }

    protected prop profile: String { get() { projection.profile } }
    protected prop scopeSnapshotId: String { get() { projection.scopeSnapshotId } }
    protected prop contentId: String { get() { projection.contentId } }
    protected prop apiCollectionState: String { get() { projection.apiCollectionState } }
    protected prop bodyComplete: Bool { get() { projection.bodyComplete } }
    protected prop truncatedCount: Int64 { get() { projection.truncatedCount } }
}

/** Build all immutable native facts before the prepared view is cached/published. */
protected func prepareDocumentationSearchProjection(
    projection: DocumentationSearchProjection): PreparedDocumentationSearchProjection {
    let entries = ArrayList<SearchPreparedEntry>()
    for (entry in projection.entries) { entries.add(SearchPreparedEntry(entry)) }
    PreparedDocumentationSearchProjection(projection, entries)
}


private class SearchSelectorResult {
    let selected: Bool
    let evidence: ?SearchEvidence

    init(selected: Bool, evidence: ?SearchEvidence) {
        this.selected = selected
        this.evidence = evidence
    }
}

private func searchRequestString(request: JsonObject, key: String): String {
    match (request.get(key)) {
        case Some(value) => if (value.kind() == JsonKind.String) { value.asString() } else { "" }
        case None => ""
    }
}

private func searchExplicitSelector(facts: SearchPreparedEntry, request: JsonObject,
    mode: String, hasSelectors: Bool): SearchSelectorResult {
    let entry = facts.entry
    let symbolId = searchRequestString(request, "symbolId")
    if (!symbolId.isEmpty()) {
        return SearchSelectorResult(true,
            if (!entry.concept && entry.canonicalId == symbolId) {
                Some(searchRuleEvidence(mode, "exact_symbol_id", "", false))
            } else { None })
    }
    let symbolKey = searchRequestString(request, "symbolKey")
    if (!symbolKey.isEmpty()) {
        return SearchSelectorResult(true,
            if (!entry.concept && entry.symbolKey == symbolKey) {
                Some(searchRuleEvidence(mode, "exact_symbol_key", "", false))
            } else { None })
    }
    let qualifiedName = searchRequestString(request, "qualifiedName")
    if (!qualifiedName.isEmpty()) {
        return SearchSelectorResult(true,
            if (!entry.concept && entry.qualifiedName == qualifiedName) {
                Some(searchRuleEvidence(mode, "exact_qualified_name",
                    "exact_qualified_name_with_selector", hasSelectors))
            } else { None })
    }
    let name = searchRequestString(request, "name")
    if (name.isEmpty()) { return SearchSelectorResult(false, None) }
    if (entry.name == name) {
        return SearchSelectorResult(true,
            Some(searchRuleEvidence(mode, "exact_name", "exact_name_with_selector", hasSelectors)))
    }
    if (!entry.concept && entry.qualifiedName == name) {
        return SearchSelectorResult(true,
            Some(searchRuleEvidence(mode, "exact_qualified_name",
                "exact_qualified_name_with_selector", hasSelectors)))
    }
    if (!entry.concept && !entry.ownerName.isEmpty() && facts.ownerMemberName == name) {
        return SearchSelectorResult(true,
            Some(searchRuleEvidence(mode, "exact_owner_member",
                "exact_owner_member_with_selector", hasSelectors)))
    }
    if (!entry.concept && searchHasExposureName(facts, name)) {
        let exposureIds = searchExposureIdsByName(facts, name)
        return SearchSelectorResult(true,
            Some(searchRuleEvidence(mode, "exact_alias", "exact_alias_with_selector",
                hasSelectors, matchedExposureIds: exposureIds)))
    }
    SearchSelectorResult(true, None)
}

private func searchPrecisePrimitiveMatches(facts: SearchPreparedEntry, query: String,
    tokens: Array<String>, hasSelectors: Bool, primitive: String): Bool {
    let entry = facts.entry
    match (primitive) {
        case "exact_symbol_id" => !entry.concept && entry.canonicalId == query
        case "exact_symbol_key" =>
            !entry.concept && !entry.symbolKey.isEmpty() && entry.symbolKey == query
        case "exact_qualified_name" =>
            !hasSelectors && !entry.concept && entry.qualifiedName == query
        case "exact_qualified_name_with_selector" =>
            hasSelectors && !entry.concept && entry.qualifiedName == query
        case "query_exact_name" => !hasSelectors && !entry.concept && entry.name == query
        case "query_exact_name_with_selector" =>
            hasSelectors && !entry.concept && entry.name == query
        case "exact_owner_member" =>
            !hasSelectors && !entry.concept && !entry.ownerName.isEmpty() &&
                facts.ownerMemberName == query
        case "exact_owner_member_with_selector" =>
            hasSelectors && !entry.concept && !entry.ownerName.isEmpty() &&
                facts.ownerMemberName == query
        case "exact_alias" => !hasSelectors && !entry.concept &&
            searchHasExposureName(facts, query)
        case "exact_alias_with_selector" => hasSelectors && !entry.concept &&
            searchHasExposureName(facts, query)
        case "structured_text" =>
            !hasSelectors && !entry.concept && searchContainsAll(facts.identifierTextFolded, tokens)
        case "structured_text_with_selector" =>
            hasSelectors && !entry.concept && searchContainsAll(facts.identifierTextFolded, tokens)
        case "documentation_text" =>
            !hasSelectors && !entry.concept && searchContainsAllDocumentationText(facts, tokens)
        case "documentation_text_with_selector" =>
            hasSelectors && !entry.concept && searchContainsAllDocumentationText(facts, tokens)
        case "concept_text" => entry.concept && searchContainsAllDocumentationText(facts, tokens)
        case _ => false
    }
}

private func searchPreciseQueryEvidence(facts: SearchPreparedEntry, query: String,
    tokens: Array<String>, hasSelectors: Bool): ?SearchEvidence {
    if (query.isEmpty()) { return None }
    for (rule in SEARCH_PRECISE_RULE_SET.ordered) {
        if (!searchPrecisePrimitiveMatches(facts, query, tokens, hasSelectors, rule.primitive)) {
            continue
        }
        let exposureIds: Array<String> = if (rule.primitive == "exact_alias" ||
            rule.primitive == "exact_alias_with_selector") {
            searchExposureIdsByName(facts, query)
        } else { [] }
        let anchor = if (rule.primitive == "documentation_text" ||
            rule.primitive == "documentation_text_with_selector" ||
            rule.primitive == "concept_text") { searchBodyAnchor(facts, tokens) } else { "" }
        return Some(searchRuleEvidence("precise", rule.primitive, "", false,
            matchedExposureIds: exposureIds, anchor: anchor))
    }
    None
}

/**
 * Discovery priority is read from the shared contract. Each returned row
 * denotes one fixed comparison and its exact published reason/score.
 */
private func searchDiscoveryPrimitiveMatches(facts: SearchPreparedEntry, query: String,
    foldedQuery: String, tokens: Array<String>, editTokenRunes: Array<Rune>,
    primitive: String): Bool {
    let entry = facts.entry
    match (primitive) {
        case "exact_symbol_id" => !entry.concept && entry.canonicalId == query
        case "exact_symbol_key" =>
            !entry.concept && !entry.symbolKey.isEmpty() && entry.symbolKey == query
        case "exact_qualified_name" => !entry.concept && entry.qualifiedName == query
        case "exact_name" => !entry.concept && entry.name == query
        case "exact_owner_member" => !entry.concept && !entry.ownerName.isEmpty() &&
            facts.ownerMemberName == query
        case "exact_alias" => !entry.concept && searchHasExposureName(facts, query)
        case "ascii_fold_name" => facts.nameFolded == foldedQuery
        case "name_prefix" => facts.nameFolded.startsWith(foldedQuery)
        case "qualified_prefix" =>
            !entry.concept && facts.qualifiedNameFolded.startsWith(foldedQuery)
        case "all_token_word_prefix" =>
            if (tokens.isEmpty()) { false } else {
                var allPrefix = true
                for (token in tokens) {
                    var found = false
                    for (word in facts.nameWords) {
                        if (word.startsWith(token)) { found = true; break }
                    }
                    if (!found) {
                        for (word in facts.ownerNameWords) {
                            if (word.startsWith(token)) { found = true; break }
                        }
                    }
                    if (!found) { allPrefix = false; break }
                }
                allPrefix
            }
        case "acronym" =>
            if (entry.concept || tokens.size != 1) { false } else {
                let token = tokens[0]
                facts.nameAcronym == token || facts.qualifiedNameAcronym == token
            }
        case "structured_text" =>
            !entry.concept && searchContainsAll(facts.discoveryStructuredTextFolded, tokens)
        case "one_edit" =>
            if (entry.concept || tokens.size != 1) { false } else {
                let length = editTokenRunes.size
                var matched = false
                if (length >= SEARCH_TEXT_POLICY.minEditRunes &&
                    length <= SEARCH_TEXT_POLICY.maxEditRunes) {
                    var candidateIndex: Int64 = 0
                    while (candidateIndex < facts.editCandidateRunes.size) {
                        if (searchOneEditApartRunes(editTokenRunes,
                            facts.editCandidateRunes[candidateIndex])) {
                            matched = true
                            break
                        }
                        candidateIndex++
                    }
                }
                matched
            }
        case "documentation_text" =>
            !entry.concept && searchContainsAllDocumentationText(facts, tokens)
        case "concept_text" =>
            entry.concept && searchContainsAllDocumentationText(facts, tokens)
        case _ => false
    }
}

protected func searchDiscoveryEvidence(facts: SearchPreparedEntry, query: String,
    foldedQuery: String, tokens: Array<String>, editTokenRunes: Array<Rune>): ?SearchEvidence {
    if (query.isEmpty()) { return None }
    for (rule in SEARCH_DISCOVERY_RULE_SET.ordered) {
        if (!searchDiscoveryPrimitiveMatches(facts, query, foldedQuery, tokens,
            editTokenRunes, rule.primitive)) {
            continue
        }
        let exposureIds: Array<String> = if (rule.primitive == "exact_alias") {
            searchExposureIdsByName(facts, query)
        } else { [] }
        let anchor = if (rule.primitive == "documentation_text" ||
            rule.primitive == "concept_text") { searchBodyAnchor(facts, tokens) } else { "" }
        return Some(searchRuleEvidence("discovery", rule.primitive, "", false,
            matchedExposureIds: exposureIds, anchor: anchor))
    }
    None
}

/** One normalized request filter: `{field, op, value}`. */
protected class SearchFilter {
    protected let field: String
    protected let op: String
    protected let value: String
    protected let foldedValue: String

    protected init(field: String, op: String, value: String) {
        this.field = field
        this.op = op
        this.value = value
        foldedValue = searchAsciiFold(value)
    }

    protected func key(): String { field + "\u{0}" + op + "\u{0}" + value }
}

protected func searchFilterKey(filter: SearchFilter): String { filter.key() }

private func searchFilterSpec(field: String): ?SearchFilterSpec {
    SEARCH_FILTER_SPECS.get(field)
}

private func searchFieldMatches(actual: String, actualFolded: String,
    filter: SearchFilter): Bool {
    let primitive = match (SEARCH_FILTER_OPS.get(filter.op)) {
        case Some(value) => value
        case None => ""
    }
    match (primitive) {
        case "exact_string_equal" => actual == filter.value
        case "ascii_fold_contains" => actualFolded.contains(filter.foldedValue)
        case _ => false
    }
}

protected class SearchFilterMatch {
    protected let admitted: Bool
    protected let matchedExposureIds: Array<String>

    protected init(admitted: Bool, matchedExposureIds!: Array<String> = []) {
        this.admitted = admitted
        this.matchedExposureIds = matchedExposureIds
    }
}

private func searchContextPropertyMatches(property: String, filter: SearchFilter,
    name: String, nameFolded: String, qualifiedName: String, qualifiedNameFolded: String,
    packageName: String, packageNameFolded: String): Bool {
    match (property) {
        case "name" => searchFieldMatches(name, nameFolded, filter)
        case "qualifiedName" => searchFieldMatches(qualifiedName, qualifiedNameFolded, filter)
        case "packageName" => searchFieldMatches(packageName, packageNameFolded, filter)
        case _ => false
    }
}

private func searchContextAdmits(name: String, nameFolded: String,
    qualifiedName: String, qualifiedNameFolded: String, packageName: String,
    packageNameFolded: String, filters: ArrayList<SearchFilter>): Bool {
    for (filter in filters) {
        let spec = match (searchFilterSpec(filter.field)) {
            case Some(value) => value
            case None => return false
        }
        if (spec.context != "canonical-or-exposure") { continue }
        let property = if (spec.properties.isEmpty()) { "" } else { spec.properties[0] }
        if (!searchContextPropertyMatches(property, filter, name, nameFolded,
            qualifiedName, qualifiedNameFolded, packageName, packageNameFolded)) {
            return false
        }
    }
    true
}

private func searchContextFiltersPresent(filters: ArrayList<SearchFilter>): Bool {
    for (filter in filters) {
        match (searchFilterSpec(filter.field)) {
            case Some(spec) =>
                if (spec.context == "canonical-or-exposure") { return true }
            case None => ()
        }
    }
    false
}

private func searchEntryPropertyMatches(facts: SearchPreparedEntry,
    property: String, filter: SearchFilter): Bool {
    let entry = facts.entry
    match (property) {
        case "ownerName" =>
            !entry.ownerName.isEmpty() &&
                searchFieldMatches(entry.ownerName, facts.ownerNameFolded, filter)
        case "ownerQualifiedName" =>
            !entry.ownerQualifiedName.isEmpty() &&
                searchFieldMatches(entry.ownerQualifiedName, facts.ownerQualifiedNameFolded, filter)
        case "parameterTypes" =>
            var index: Int64 = 0
            while (index < entry.parameterTypes.size) {
                if (searchFieldMatches(entry.parameterTypes[index],
                    facts.parameterTypesFolded[index], filter)) { return true }
                index++
            }
            false
        case "returnType" =>
            !entry.returnType.isEmpty() &&
                searchFieldMatches(entry.returnType, facts.returnTypeFolded, filter)
        case "returnCanonical" =>
            !entry.returnCanonical.isEmpty() &&
                searchFieldMatches(entry.returnCanonical, facts.returnCanonicalFolded, filter)
        case "kind" =>
            !entry.kind.isEmpty() && searchFieldMatches(entry.kind, facts.kindFolded, filter)
        case _ => false
    }
}

private func searchEntryFilterAdmits(facts: SearchPreparedEntry,
    filters: ArrayList<SearchFilter>): Bool {
    for (filter in filters) {
        let spec = match (searchFilterSpec(filter.field)) {
            case Some(value) => value
            case None => return false
        }
        if (spec.context != "entry") { continue }
        var satisfied = false
        for (property in spec.properties) {
            if (searchEntryPropertyMatches(facts, property, filter)) {
                satisfied = true
                break
            }
        }
        if (!satisfied) { return false }
    }
    true
}

private func searchPreparedContextAdmits(facts: SearchPreparedEntry,
    filters: ArrayList<SearchFilter>): SearchFilterMatch {
    let entry = facts.entry
    let canonicalAdmits = searchContextAdmits(entry.name, facts.nameFolded,
        if (entry.concept) { "" } else { entry.qualifiedName },
        if (entry.concept) { "" } else { facts.qualifiedNameFolded },
        if (entry.concept) { "" } else { entry.packageName },
        if (entry.concept) { "" } else { facts.packageNameFolded }, filters)
    let matchedExposures = ArrayList<String>()
    if (!entry.concept) {
        for (prepared in facts.exposures) {
            let exposure = prepared.exposure
            if (searchContextAdmits(exposure.name, prepared.nameFolded,
                exposure.qualifiedName, prepared.qualifiedNameFolded,
                exposure.packageName, prepared.packageNameFolded, filters)) {
                matchedExposures.add(exposure.id)
            }
        }
    }
    if (!canonicalAdmits && matchedExposures.isEmpty()) {
        return SearchFilterMatch(false)
    }
    sort(matchedExposures,
        lessThan: { left, right => searchUtf8ByteLess(left, right) }, stable: true)
    SearchFilterMatch(true, matchedExposureIds: matchedExposures.toArray())
}

/**
 * All canonical-or-exposure predicates must hold in one spelling context.
 * Entry-field predicates then independently narrow that same canonical result.
 */
protected func searchFilterAdmits(facts: SearchPreparedEntry,
    filters: ArrayList<SearchFilter>): SearchFilterMatch {
    if (filters.isEmpty()) { return SearchFilterMatch(true) }
    if (!searchEntryFilterAdmits(facts, filters)) { return SearchFilterMatch(false) }
    if (!searchContextFiltersPresent(filters)) { return SearchFilterMatch(true) }
    searchPreparedContextAdmits(facts, filters)
}
private func searchSortedTagIdContains(sortedIds: Array<String>, requested: String): Bool {
    var low: Int64 = 0
    var high: Int64 = sortedIds.size
    while (low < high) {
        let middle = low + (high - low) / 2
        let candidate = sortedIds[middle]
        if (candidate == requested) { return true }
        if (searchUtf8ByteLess(candidate, requested)) { low = middle + 1 }
        else { high = middle }
    }
    false
}

private func searchSetPredicateAdmits(entry: SearchProjectedEntry,
    predicate: SearchSetPredicate, requested: Array<String>): Bool {
    if (requested.isEmpty()) { return true }
    match (predicate.primitive) {
        case "all_exact" =>
            if (entry.concept) { return false }
            let actual = match (predicate.property) {
                case "tagIds" => entry.tagIds
                case _ => throw IllegalStateException("unsupported search set-predicate property")
            }
            for (value in requested) {
                if (!searchSortedTagIdContains(actual, value)) { return false }
            }
            true
        case _ => throw IllegalStateException("unsupported search set-predicate primitive")
    }
}

private func searchSetPredicatesAdmit(entry: SearchProjectedEntry,
    requested: HashMap<String, Array<String>>): Bool {
    for (predicate in SEARCH_SET_PREDICATES) {
        match (requested.get(predicate.field)) {
            case Some(values) =>
                if (!searchSetPredicateAdmits(entry, predicate, values)) { return false }
            case None => ()
        }
    }
    true
}


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

private func searchBuildTagFacets(entries: ArrayList<SearchRankedEntry>):
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
    protected var coverage: ?SearchCoverage = None

    protected init() {}
}

/**
 * One projection plus the request-independent facts a host needs to resolve a
 * hit back to a captured identity.
 */
protected class SearchProjectionSet {
    protected let projections = ArrayList<PreparedDocumentationSearchProjection>()
    protected var cachedProjectionId: ?String = None

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

/** Profile of one request; absence means the shared contract's default. */
protected func searchRequestProfile(profile: String): String {
    if (profile.isEmpty()) { return searchContractString("defaultProfile") }
    profile
}

/** One normalized request, validated against the shared contract. */
protected class SearchRequest {
    protected let fields: JsonObject
    protected let query: String
    protected let mode: String
    protected let profile: String
    protected let limit: Int64
    protected let offset: Int64
    protected let filters: ArrayList<SearchFilter>
    protected let setPredicates: HashMap<String, Array<String>>
    protected let filterOnly: Bool
    // Canonical capture identities admitted by native snapshot/module/source
    // selection. Keys are `snapshotId\0canonicalId`.
    protected let admitted: ?HashSet<String>

    protected init(fields: JsonObject, query: String, mode: String, profile: String,
        limit: Int64, offset: Int64, filters: ArrayList<SearchFilter>,
        setPredicates: HashMap<String, Array<String>>,
        filterOnly: Bool, admitted: ?HashSet<String>) {
        this.fields = fields
        this.query = query
        this.mode = mode
        this.profile = profile
        this.limit = limit
        this.offset = offset
        this.setPredicates = setPredicates
        this.filters = filters
        this.filterOnly = filterOnly
        this.admitted = admitted
    }
}

private func searchContractEnumContains(property: String, value: String): Bool {
    let propertyNode = searchContractProperty(property).asObject()
    match (propertyNode.get("enum")) {
        case Some(node) =>
            for (index in 0..node.asArray().size()) {
                if (node.asArray()[index].asString() == value) { return true }
            }
            false
        case None => false
    }
}

private func searchRequestFilters(request: JsonObject): ArrayList<SearchFilter> {
    let filters = ArrayList<SearchFilter>()
    match (request.get("filters")) {
        case Some(node) =>
            if (node.kind() != JsonKind.Array) {
                throw IllegalArgumentException("search filters must be an array")
            }
            let values = node.asArray()
            if (values.size() > searchContractInteger("maxFilters")) {
                throw IllegalArgumentException("search filter count exceeds the contract")
            }
            for (index in 0..values.size()) {
                let item = values[index].asObject()
                if (item.size() != 3) {
                    throw IllegalArgumentException("search filters must contain exactly field, op and value")
                }
                let field = searchRequestString(item, "field")
                let op = searchRequestString(item, "op")
                let value = searchRequestString(item, "value")
                let knownField = match (searchFilterSpec(field)) {
                    case Some(_) => true
                    case None => false
                }
                if (!knownField || !SEARCH_FILTER_OPS.contains(op) || value.isEmpty() ||
                    searchRuneCount(value) > 16384) {
                    throw IllegalArgumentException("search filter does not satisfy the contract")
                }
                filters.add(SearchFilter(field, op, value))
            }
        case None => ()
    }
    searchNormalizeFilters(filters)
}

private func searchRequestHasFlatSelector(request: JsonObject): Bool {
    for (field in ["symbolId", "symbolKey", "qualifiedName", "name"]) {
        if (!searchRequestString(request, field).isEmpty()) { return true }
    }
    false
}

protected func searchRequestIsFilterOnly(request: JsonObject): Bool {
    if (!searchRequestString(request, "query").trimAscii().isEmpty() ||
        searchRequestHasFlatSelector(request)) { return false }
    if (let Some(filters) <- request.get("filters")) {
        if (filters.asArray().size() > 0) { return true }
    }
    for (index in 0..request.size()) {
        let field = request.nameAt(index)
        if (["operation", "schemaVersion", "query", "mode", "profile", "limit", "cursor",
            "filters", "symbolId", "symbolKey", "qualifiedName", "name",
            "languageFallback"].contains(field)) { continue }
        if (field == "latest") {
            if (request.get(field).getOrThrow().asBool()) { return true }
            continue
        }
        return true
    }
    false
}

private func searchRequestFieldAllowed(field: String): Bool {
    if (SEARCH_GLOBAL_FIELD_VALUES.contains(field) || SEARCH_SEARCH_FIELD_VALUES.contains(field)) {
        return true
    }
    false
}
private func searchJsonMatchesType(value: JsonNode, expected: String): Bool {
    match (expected) {
        case "string" => value.kind() == JsonKind.String
        case "array" => value.kind() == JsonKind.Array
        case "object" => try { let _ = value.asObject(); true } catch (_: Exception) { false }
        case "boolean" => try { let _ = value.asBool(); true } catch (_: Exception) { false }
        case "integer" => try { let _ = value.asInt64(); true } catch (_: Exception) { false }
        case "null" => value.kind() == JsonKind.Null
        case _ => false
    }
}

private func searchJsonMatchesSchema(value: JsonNode, schemaNode: JsonNode): Bool {
    let schema = schemaNode.asObject()
    match (schema.get("type")) {
        case Some(typeNode) =>
            let matched = if (typeNode.kind() == JsonKind.Array) {
                var anyType = false
                let types = typeNode.asArray()
                for (index in 0..types.size()) {
                    if (searchJsonMatchesType(value, types[index].asString())) {
                        anyType = true
                        break
                    }
                }
                anyType
            } else { searchJsonMatchesType(value, typeNode.asString()) }
            if (!matched) { return false }
        case None => ()
    }
    match (schema.get("const")) {
        case Some(constant) => if (value.toJson() != constant.toJson()) { return false }
        case None => ()
    }
    match (schema.get("enum")) {
        case Some(enumNode) =>
            var found = false
            let values = enumNode.asArray()
            for (index in 0..values.size()) {
                if (value.toJson() == values[index].toJson()) { found = true; break }
            }
            if (!found) { return false }
        case None => ()
    }
    if (value.kind() == JsonKind.String) {
        let count = searchRuneCount(value.asString())
        match (schema.get("minLength")) {
            case Some(minimum) => if (count < minimum.asInt64()) { return false }
            case None => ()
        }
        match (schema.get("maxLength")) {
            case Some(maximum) => if (count > maximum.asInt64()) { return false }
            case None => ()
        }
    }
    if (searchJsonMatchesType(value, "integer")) {
        let number = value.asInt64()
        match (schema.get("minimum")) {
            case Some(minimum) => if (number < minimum.asInt64()) { return false }
            case None => ()
        }
        match (schema.get("maximum")) {
            case Some(maximum) => if (number > maximum.asInt64()) { return false }
            case None => ()
        }
    }
    if (value.kind() == JsonKind.Array) {
        let values = value.asArray()
        match (schema.get("minItems")) {
            case Some(minimum) => if (values.size() < minimum.asInt64()) { return false }
            case None => ()
        }
        match (schema.get("maxItems")) {
            case Some(maximum) => if (values.size() > maximum.asInt64()) { return false }
            case None => ()
        }
        match (schema.get("items")) {
            case Some(itemSchema) =>
                for (index in 0..values.size()) {
                    if (!searchJsonMatchesSchema(values[index], itemSchema)) { return false }
                }
            case None => ()
        }
    }
    if (searchJsonMatchesType(value, "object")) {
        let object = value.asObject()
        let properties: ?JsonObject = match (schema.get("properties")) {
            case Some(value) => Some(value.asObject())
            case None => Option<JsonObject>.None
        }
        let additionalProperties = match (schema.get("additionalProperties")) {
            case Some(value) => value.asBool()
            case None => true
        }
        for (index in 0..object.size()) {
            let key = object.nameAt(index)
            match (properties) {
                case Some(declared) =>
                    match (declared.get(key)) {
                        case Some(childSchema) =>
                            if (!searchJsonMatchesSchema(object.valueAt(index), childSchema)) {
                                return false
                            }
                        case None => if (!additionalProperties) { return false }
                    }
                case None => if (!additionalProperties) { return false }
            }
        }
        match (schema.get("required")) {
            case Some(required) =>
                let names = required.asArray()
                for (index in 0..names.size()) {
                    if (object.get(names[index].asString()).isNone()) { return false }
                }
            case None => ()
        }
    }
    true
}

private func searchRequestMatchesContractSchema(request: JsonObject): Bool {
    if (request.get("operation").isNone() ||
        request.toJson().toArray().size > searchContractInteger("maxRequestBytes")) {
        return false
    }
    for (index in 0..request.size()) {
        let field = request.nameAt(index)
        if (!searchRequestFieldAllowed(field) ||
            !searchJsonMatchesSchema(request.valueAt(index), searchContractProperty(field))) {
            return false
        }
    }
    true
}

private func searchBuildRequest(request: JsonObject, admitted: ?HashSet<String>,
    filterOnlyOverride: ?Bool, offset: Int64): SearchRequest {
    let operation = searchRequestString(request, "operation")
    if (!operation.isEmpty() && operation != "search") {
        throw IllegalArgumentException("search executor only accepts the search operation")
    }
    if (!searchRequestMatchesContractSchema(request)) {
        throw IllegalArgumentException("search request does not satisfy the shared schema")
    }
    let modeValue = searchRequestString(request, "mode")
    let mode = if (modeValue.isEmpty()) { searchContractString("defaultMode") } else { modeValue }
    if (!searchContractEnumContains("mode", mode)) {
        throw IllegalArgumentException("search mode is not declared by the contract")
    }
    let profileValue = searchRequestString(request, "profile")
    let profile = searchRequestProfile(profileValue)
    if (!searchContractProfileIsKnown(profile)) {
        throw IllegalArgumentException("search profile is not declared by the contract")
    }
    let limit = match (request.get("limit")) {
        case Some(value) => value.asInt64()
        case None => searchContractInteger("defaultLimit")
    }
    if (limit < 0 || limit > searchContractInteger("maxLimit")) {
        throw IllegalArgumentException("search limit is outside the contract")
    }
    if (offset < 0) { throw IllegalArgumentException("search offset cannot be negative") }
    let filters = searchRequestFilters(request)
    let setPredicates = searchRequestSetPredicates(request)
    let filterOnly = match (filterOnlyOverride) {
        case Some(value) => value
        case None => searchRequestIsFilterOnly(request)
    }
    SearchRequest(request, searchRequestString(request, "query"), mode, profile,
        limit, offset, filters, setPredicates, filterOnly, admitted)
}

/**
 * Normalize filters once: remove duplicates, then sort by field/op/value UTF-8
 * bytes so request order cannot affect execution or cursor identity.
 */
protected func searchNormalizeFilters(filters: ArrayList<SearchFilter>): ArrayList<SearchFilter> {
    let unique = ArrayList<SearchFilter>()
    let seen = HashSet<String>()
    for (filter in filters) {
        if (!seen.contains(filter.key())) {
            let _ = seen.add(filter.key())
            unique.add(filter)
        }
    }
    sort(unique, lessThan: { left, right =>
        if (left.field != right.field) { searchUtf8ByteLess(left.field, right.field) }
        else if (left.op != right.op) { searchUtf8ByteLess(left.op, right.op) }
        else { searchUtf8ByteLess(left.value, right.value) }
    }, stable: true)
    unique
}

private func searchSelectorsAdmit(entry: SearchProjectedEntry, request: JsonObject): Bool {
    let hasParameters = match (request.get("parameterTypes")) {
        case Some(_) => true
        case None => false
    }
    let hasArity = match (request.get("genericArity")) {
        case Some(_) => true
        case None => false
    }
    if (!hasParameters && !hasArity) { return true }
    if (entry.concept) { return false }
    if (hasArity && entry.genericArity != request.get("genericArity").getOrThrow().asInt64()) {
        return false
    }
    if (hasParameters) {
        let requested = request.get("parameterTypes").getOrThrow().asArray()
        if (requested.size() != entry.parameterTypes.size) { return false }
        for (index in 0..requested.size()) {
            if (requested[index].asString() != entry.parameterTypes[index]) { return false }
        }
    }
    true
}

private func searchApplyMatchedExposures(evidence: SearchEvidence,
    filterMatch: SearchFilterMatch): Unit {
    for (exposureId in filterMatch.matchedExposureIds) {
        if (!evidence.matchedExposureIds.contains(exposureId)) {
            evidence.matchedExposureIds.add(exposureId)
        }
    }
    sort(evidence.matchedExposureIds,
        lessThan: { left, right => searchUtf8ByteLess(left, right) }, stable: true)
}

/** Execute a single projection through the same JSON contract as native search. */
protected func executeDocumentationSearch(projection: DocumentationSearchProjection,
    request: JsonObject): JsonObject {
    let set = SearchProjectionSet()
    set.add(projection)
    executeDocumentationSearchAcross(set, request)
}

/** Execute a request across snapshots as one globally ranked/paged candidate set. */
protected func executeDocumentationSearchAcross(set: SearchProjectionSet,
    request: JsonObject): JsonObject {
    executeDocumentationSearchAcross(set, request, None, None, 0)
}

/**
 * Native bridge overload supplies source-admitted identities, filter-only
 * eligibility, and a cursor-validated offset while using the same JSON matcher.
 */
protected func executeDocumentationSearchAcross(set: SearchProjectionSet,
    request: JsonObject, admitted: ?HashSet<String>, filterOnly: ?Bool,
    offset: Int64): JsonObject {
    let operation = searchRequestString(request, "operation")
    if (!operation.isEmpty() && operation != "search") {
        let unavailable = SearchExecutionResult()
        unavailable.status = "invalid_request"
        unavailable.errorCode = "operation_unavailable"
        unavailable.errorMessage = "The search executor only accepts operation 'search'."
        return searchExecutionJson(unavailable)
    }
    var normalized: ?SearchRequest = None
    try {
        normalized = Some(searchBuildRequest(request, admitted, filterOnly, offset))
    } catch (error: Exception) {
        let _ = error
        let failure = SearchExecutionResult()
        failure.status = "invalid_request"
        failure.errorCode = "request_schema"
        failure.errorMessage = "Search request does not satisfy the shared contract."
        return searchExecutionJson(failure)
    }
    searchExecutionJson(searchExecute(set, normalized.getOrThrow()))
}

private func searchTopLevelAmbiguous(entries: ArrayList<SearchRankedEntry>): Bool {
    if (entries.size < 2) { return false }
    let highestLevel = entries[0].evidence.level
    if (highestLevel <= 0) { return false }
    var count: Int64 = 0
    for (entry in entries) {
        if (entry.evidence.level != highestLevel) { break }
        count++
    }
    count > 1
}
private func searchExecute(set: SearchProjectionSet, request: SearchRequest): SearchExecutionResult {
    let result = SearchExecutionResult()
    result.coverage = Some(searchCoverageOf(set))
    if (request.profile != set.profile) {
        result.status = "unavailable"
        result.errorCode = "search_profile_unavailable"
        result.errorMessage = "The requested search profile is not available in this projection."
        result.coverage = None
        return result
    }
    for (projection in set.projections) {
        if (projection.profile != request.profile) {
            result.status = "unavailable"
            result.errorCode = "search_profile_unavailable"
            result.errorMessage = "Search projections in one execution must share a profile."
            result.coverage = None
            return result
        }
    }
    let query = request.query
    let emptyQuery = query.trimAscii().isEmpty()
    if (emptyQuery && !request.filterOnly && !searchRequestHasFlatSelector(request.fields)) {
        result.status = "not_found"
        result.reason = "no_match_in_scope"
        result.complete = true
        return result
    }
    let tokens = searchTokens(query)
    let editTokenRunes: Array<Rune> =
        if (request.mode == "discovery" && tokens.size == 1) {
            searchRunes(tokens[0])
        } else { [] }
    let foldedQuery = if (query.isEmpty()) { "" } else { searchAsciiFold(query) }
    let candidates = ArrayList<SearchRankedEntry>()
    let hasSelectors = match (request.fields.get("parameterTypes")) {
        case Some(_) => true
        case None => match (request.fields.get("genericArity")) {
            case Some(_) => true
            case None => false
        }
    }
    for (projection in set.projections) {
        for (facts in projection.entries) {
            let entry = facts.entry
            if (let Some(allowed) <- request.admitted) {
                if (!allowed.contains(searchIdentityKey(entry.snapshotId, entry.canonicalId))) {
                    continue
                }
            }
            if (!searchSelectorsAdmit(entry, request.fields)) { continue }
            let filterMatch = searchFilterAdmits(facts, request.filters)
            if (!filterMatch.admitted ||
                !searchSetPredicatesAdmit(entry, request.setPredicates)) { continue }
            let explicit = searchExplicitSelector(facts, request.fields, request.mode, hasSelectors)
            let evidence: ?SearchEvidence = if (explicit.selected) {
                explicit.evidence
            } else if (emptyQuery && request.filterOnly) {
                Some(searchRuleEvidence(request.mode, "filter_only", "", false))
            } else if (emptyQuery) {
                None
            } else if (request.mode == "precise") {
                searchPreciseQueryEvidence(facts, query, tokens, hasSelectors)
            } else {
                searchDiscoveryEvidence(facts, query, foldedQuery, tokens, editTokenRunes)
            }
            match (evidence) {
                case Some(value) =>
                    searchApplyMatchedExposures(value, filterMatch)
                    candidates.add(SearchRankedEntry(entry, value))
                case None => ()
            }
        }
    }
    let unique = searchDeduplicate(candidates)
    searchSortRanked(unique)
    result.offset = request.offset
    result.total = unique.size
    if (request.offset > unique.size) {
        result.status = "stale_cursor"
        result.errorCode = "cursor_out_of_range"
        result.errorMessage = "Continuation cursor is beyond the current result set."
        return result
    }
    for (facet in searchBuildTagFacets(unique)) { result.facets.add(facet) }
    let end = if (request.offset + request.limit > unique.size) {
        unique.size
    } else { request.offset + request.limit }
    result.complete = end >= unique.size
    result.reason = if (unique.isEmpty()) { "no_match_in_scope" }
        else if (request.filterOnly && emptyQuery) { "filter_only" } else { "" }
    var position = request.offset
    while (position < end) {
        let candidate = unique[position]
        result.hits.add(SearchHit(candidate.entry.snapshotId, candidate.entry.canonicalId,
            candidate.evidence.score, candidate.evidence.reason,
            candidate.evidence.matchedExposureIds.toArray(), candidate.evidence.anchor,
            candidate.entry.classification))
        position++
    }
    result.returned = result.hits.size
    let ambiguous = request.mode == "precise" && !request.filterOnly &&
        searchTopLevelAmbiguous(unique)
    result.status = if (unique.isEmpty()) { "not_found" }
        else if (ambiguous) { "ambiguous" } else { "ok" }
    if (ambiguous) { result.reason = "several_captured_identities_tie" }
    if (unique.isEmpty() && !set.sourceComplete) {
        result.status = "source_incomplete"
        result.reason = "no_match_with_incomplete_api_collection"
    }
    if (request.limit == 0 && !unique.isEmpty()) { result.reason = "zero_limit_requested" }
    result
}

private func searchCoverageOf(set: SearchProjectionSet): SearchCoverage {
    let profile = set.profile
    SearchCoverage(profile, set.projectionId,
        if (profile == searchContractString("defaultProfile")) { None }
            else { Some(searchContractInteger("staticBodyTextLimit")) },
        set.bodyComplete, set.truncatedCount)
}

private func searchNullableString(value: ?String): JsonNode {
    match (value) {
        case Some(text) => JsonNode.string(text)
        case None => JsonNode.nullValue
    }
}

private func searchCoverageJson(coverage: ?SearchCoverage): JsonNode {
    match (coverage) {
        case Some(value) =>
            let node = JsonObject()
            node.put("profile", JsonNode.string(value.profile))
            node.put("projectionId", JsonNode.string(value.projectionId))
            match (value.bodyTextLimit) {
                case Some(limit) => node.put("bodyTextLimit", JsonNode.int64(limit))
                case None => node.put("bodyTextLimit", JsonNode.nullValue)
            }
            node.put("bodyComplete", JsonNode.boolean(value.bodyComplete))
            node.put("truncatedEntries", JsonNode.int64(value.truncatedEntries))
            node
        case None => JsonNode.nullValue
    }
}
private func searchTagFacetsJson(facets: ArrayList<SearchTagFacet>): JsonObject {
    let out = StringBuilder()
    out.append("{\"tags\":[")
    var first = true
    for (facet in facets) {
        if (!first) { out.append(",") }
        first = false
        appendSearchTagFacetJson(out, facet.tag, facet.count)
    }
    out.append("]}")
    JsonNode.parse(out.toString()).asObject()
}


private func searchExecutionJson(result: SearchExecutionResult): JsonObject {
    let node = JsonObject()
    node.put("status", JsonNode.string(result.status))
    node.put("errorCode", JsonNode.string(result.errorCode))
    node.put("reason", JsonNode.string(result.reason))
    let items = JsonArray()
    for (hit in result.hits) {
        let item = JsonObject()
        item.put("snapshotId", JsonNode.string(hit.snapshotId))
        item.put("canonicalId", JsonNode.string(hit.canonicalId))
        item.put("score", JsonNode.int64(hit.score))
        item.put("reason", JsonNode.string(hit.reason))
        let exposures = JsonArray()
        for (id in hit.matchedExposureIds) { exposures.add(JsonNode.string(id)) }
        item.put("matchedExposureIds", exposures)
        item.put("anchor", JsonNode.string(hit.anchor))
        item.put("classification", declarationClassificationJsonNode(hit.classification))
        items.add(item)
    }
    node.put("items", items)
    node.put("offset", JsonNode.int64(result.offset))
    node.put("returned", JsonNode.int64(result.returned))
    node.put("total", JsonNode.int64(result.total))
    node.put("complete", JsonNode.boolean(result.complete))
    node.put("next", searchNullableString(result.next))
    node.put("coverage", searchCoverageJson(result.coverage))
    node.put("facets", searchTagFacetsJson(result.facets))
    node
}
