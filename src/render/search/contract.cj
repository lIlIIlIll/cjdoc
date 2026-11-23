protected package cjdoc.render.search

import std.collection.*
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
protected class SearchRuleSet {
    internal let ordered = ArrayList<SearchRule>()
    internal let byPrimitive = HashMap<String, SearchRule>()
}

protected class SearchFilterSpec {
    internal let properties = ArrayList<String>()
    internal let field: String
    internal let context: String

    init(field: String, context: String) {
        this.field = field
        this.context = context
    }
}
protected class SearchSetPredicate {
    internal let field: String
    internal let property: String
    internal let primitive: String

    init(field: String, property: String, primitive: String) {
        this.field = field
        this.property = property
        this.primitive = primitive
    }
}


protected func searchContractProperty(key: String): JsonNode {
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
protected let SEARCH_SET_PREDICATES = searchReadSetPredicates()
protected func searchSetPredicateFor(field: String): ?SearchSetPredicate {
    for (predicate in SEARCH_SET_PREDICATES) {
        if (predicate.field == field) { return Some(predicate) }
    }
    None
}


protected class SearchTextPolicy {
    protected let minEditRunes: Int64
    protected let maxEditRunes: Int64

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

protected let SEARCH_TEXT_POLICY = SearchTextPolicy(
    SEARCH_CONTRACT_NODE.get("textPolicy").getOrThrow().asObject())

protected let SEARCH_PRECISE_RULE_SET = searchReadRuleSet("preciseRules")
protected let SEARCH_DISCOVERY_RULE_SET = searchReadRuleSet("discoveryRules")
private let SEARCH_PRECISE_RULES = SEARCH_PRECISE_RULE_SET.byPrimitive
private let SEARCH_DISCOVERY_RULES = SEARCH_DISCOVERY_RULE_SET.byPrimitive
protected let SEARCH_FILTER_SPECS = searchReadFilterSpecs()
protected let SEARCH_FILTER_OPS = searchReadFilterOps()
protected let SEARCH_GLOBAL_FIELD_VALUES: Array<String> =
    searchReadStringList(SEARCH_CONTRACT_NODE.get("globalFields").getOrThrow())
protected let SEARCH_SEARCH_FIELD_VALUES: Array<String> =
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

protected func searchContractProfileIsKnown(profile: String): Bool {
    SEARCH_PROFILE_VALUES.contains(profile)
}

protected func searchRule(mode: String, primitive: String): SearchRule {
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
