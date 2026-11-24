protected package cjdoc.render.search

import std.collection.*
import std.sort.*
import yjson.*

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

private func searchContainsAllDocumentationText(facts: SearchPreparedEntry,
    tokens: Array<String>): Bool {
    if (tokens.isEmpty()) { return false }
    for (token in tokens) {
        if (!facts.summaryBodyFolded.contains(token) &&
            !facts.metadataTextFolded.contains(token) &&
            !facts.commentFieldsFolded.contains(token)) { return false }
    }
    true
}

internal func searchRuleEvidence(mode: String, primitive: String,
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

internal class SearchSelectorResult {
    internal let selected: Bool
    internal let evidence: ?SearchEvidence

    init(selected: Bool, evidence: ?SearchEvidence) {
        this.selected = selected
        this.evidence = evidence
    }
}

internal func searchExplicitSelector(facts: SearchPreparedEntry, request: JsonObject,
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

internal func searchPreciseQueryEvidence(facts: SearchPreparedEntry, query: String,
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

internal func searchDiscoveryEvidence(facts: SearchPreparedEntry, query: String,
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
