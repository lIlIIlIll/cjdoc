package cjdoc.schema_data

import yjson.*

private func querySearchRuleRows(values: Array<(String, Int64, Int64, String)>): JsonArray {
    let rows = JsonArray()
    for ((primitive, level, score, reason) in values) {
        let row = JsonObject()
        row.put("primitive", JsonNode.string(primitive))
        row.put("level", JsonNode.int64(level))
        row.put("score", JsonNode.int64(score))
        row.put("reason", JsonNode.string(reason))
        rows.add(row)
    }
    rows
}

private func queryPreciseSearchRules(): JsonArray {
    querySearchRuleRows([
        ("exact_symbol_id", 4, 4000, "symbol_id"),
        ("exact_symbol_key", 4, 4000, "symbol_key"),
        ("exact_qualified_name", 3, 3000, "qualified_name"),
        ("exact_qualified_name_with_selector", 3, 3000, "qualified_name_with_overload_selector"),
        ("exact_name", 2, 2040, "declaration_name"),
        ("exact_name_with_selector", 2, 2040, "declaration_name_with_overload_selector"),
        ("query_exact_name", 2, 2000, "declaration_name"),
        ("query_exact_name_with_selector", 2, 2000, "declaration_name_with_overload_selector"),
        ("exact_owner_member", 2, 2020, "owner_member_name"),
        ("exact_owner_member_with_selector", 2, 2020, "owner_member_name_with_overload_selector"),
        ("exact_alias", 2, 2030, "exposed_reexport_alias"),
        ("exact_alias_with_selector", 2, 2030, "exposed_reexport_alias_with_overload_selector"),
        ("structured_text", 1, 1010, "declaration_text"),
        ("structured_text_with_selector", 1, 1010, "declaration_text_with_overload_selector"),
        ("documentation_text", 1, 1010, "documentation_text"),
        ("documentation_text_with_selector", 1, 1010, "documentation_text_with_overload_selector"),
        ("concept_text", 1, 1010, "guide_text"),
        ("filter_only", 0, 0, "filter_only")
    ])
}

private func queryDiscoverySearchRules(): JsonArray {
    querySearchRuleRows([
        ("exact_symbol_id", 12, 12000, "symbol_id"),
        ("exact_symbol_key", 12, 12000, "symbol_key"),
        ("exact_qualified_name", 11, 11000, "qualified_name"),
        ("exact_name", 10, 10000, "declaration_name"),
        ("exact_owner_member", 10, 10000, "owner_member_name"),
        ("exact_alias", 10, 10000, "exposed_reexport_alias"),
        ("ascii_fold_name", 9, 9000, "name_casefold"),
        ("name_prefix", 8, 8000, "name_prefix"),
        ("qualified_prefix", 7, 7000, "qualified_prefix"),
        ("all_token_word_prefix", 6, 6000, "word_prefix"),
        ("acronym", 5, 5000, "acronym"),
        ("structured_text", 4, 4000, "declaration_text"),
        ("one_edit", 3, 3000, "edit_distance_one"),
        ("documentation_text", 2, 2000, "documentation_text"),
        ("concept_text", 2, 2000, "guide_text"),
        ("filter_only", 0, 0, "filter_only")
    ])
}

private func querySearchTextPolicy(): JsonObject {
    JsonNode.parse("""
{
  "caseFold": "ascii-only",
  "normalization": "none",
  "tokens": "ascii-alnum-underscore-or-u0080-plus",
  "words": "ascii-camel-acronym-boundaries",
  "edit": "one-scalar-insert-delete-substitute",
  "minEditRunes": 4,
  "maxEditRunes": 128
}
""").asObject()
}
/**
 * The one machine-readable statement of the search contract.
 *
 * The request schema, native executor and published static index all consume
 * these exact values. Runtime code keeps only fixed comparison primitives.
 */
public func documentationSearchContract(): String {
    let declaration = queryDeclaration()
    let operations = declaration.get("operations").getOrThrow().asObject()
    let search = operations.get("search").getOrThrow().asObject()
    let properties = declaration.get("properties").getOrThrow().asObject()
    let contract = JsonObject()
    contract.put("version", JsonNode.string("cjdoc.search-contract/2"))
    contract.put("textPolicy", querySearchTextPolicy())
    contract.put("maxRequestBytes", JsonNode.int64(1048576))
    contract.put("defaultMode", JsonNode.string("precise"))
    contract.put("defaultProfile", JsonNode.string("full-ir"))
    contract.put("defaultLimit", JsonNode.int64(20))
    contract.put("maxLimit", properties.get("limit").getOrThrow().asObject()
        .get("maximum").getOrThrow())
    contract.put("maxFilters", properties.get("filters").getOrThrow().asObject()
        .get("maxItems").getOrThrow())
    contract.put("maxTags", properties.get("tags").getOrThrow().asObject()
        .get("maxItems").getOrThrow())
    contract.put("staticBodyTextLimit", JsonNode.int64(2000))
    contract.put("summaryDisplayLimit", JsonNode.int64(240))
    contract.put("signatureDisplayLimit", JsonNode.int64(512))
    contract.put("requestProperties", declaration.get("properties").getOrThrow())
    contract.put("globalFields", declaration.get("globalFields").getOrThrow())
    contract.put("searchFields", search.get("fields").getOrThrow())
    contract.put("filterFields", querySearchFilterFields())
    contract.put("filterOps", querySearchFilterOps())
    contract.put("setPredicates", JsonNode.parse(
        "[{\"field\":\"tags\",\"property\":\"tagIds\",\"primitive\":\"all_exact\"}]"))
    contract.put("preciseRules", queryPreciseSearchRules())
    contract.put("discoveryRules", queryDiscoverySearchRules())
    contract.toJson()
}
