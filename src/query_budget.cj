package cjdoc

import std.collection.*
import yjson.*

internal func queryChapterBytes(chapter: QueryChapter): Int64 {
    let structured = chapter.value.toJson().size
    var bytes = chapter.rendered.size + if (QUERY_REPORT_SECTIONS.contains(chapter.name)) {
        structured * 2
    } else { structured }
    if (chapter.name == "signature") {
        bytes += chapter.value.asObject().get("headerSpelling").getOrThrow().toJson().size
    }
    bytes
}

internal func queryRejectRequiredBudget(outcome: QueryOutcome, required: Int64,
    maximum: Int64): Bool {
    if (required <= maximum && required <= QUERY_MAX_BYTES) { return false }
    let resource = required > QUERY_MAX_BYTES
    let code = if (resource) { "required_unit_exceeds_resource_limit" }
        else { "required_unit_exceeds_budget" }
    let limit = if (resource) { QUERY_MAX_BYTES } else { maximum }
    outcome.status = if (resource) { "resource_limit" } else { "budget_exceeded" }
    outcome.error = queryErrorNode(code, "The intact mandatory documentation units do not fit the content byte limit.",
        Some(required), Some(limit))
    outcome.contentComplete = false
    outcome.reason = code
    if (!resource) {
        let retry = queryRetryNode(required, "Retry the same sections with maxBytes at least ${required}.")
        outcome.retry = retry
        outcome.omitted.add(queryOmission("required", "budget", Some(retry)))
    } else {
        outcome.omitted.add(queryOmission("required", "resource_limit", Option<JsonNode>.None))
    }
    outcome.text = "Intact mandatory documentation requires ${required} UTF-8 content bytes; " +
        "the applicable limit is ${limit}. " + if (resource) {
            "This unit exceeds the supported resource limit; no truncated unit or unavailable retry is returned."
        } else { "Retry with maxBytes ${required}; no unit was truncated." }
    true
}

internal func queryBudgetOptionalChapters(outcome: QueryOutcome, chapters: ArrayList<QueryChapter>,
    required: Int64, maximum: Int64): Int64 {
    var used = required
    for (chapter in chapters) {
        if (chapter.mandatory || chapter.state == "missing") { continue }
        let size = queryChapterBytes(chapter)
        if (size > QUERY_MAX_BYTES) {
            chapter.state = "resource_limit"
            outcome.omitted.add(queryOmission(chapter.name, "resource_limit", Option<JsonNode>.None))
        } else if (used + size > maximum) {
            chapter.state = "budget_omitted"
            outcome.omitted.add(queryOmission(chapter.name, "budget", Some(queryRetryNode(size,
                "Request section '${chapter.name}' alone with maxBytes at least ${size}."))))
        } else { used += size }
    }
    used
}

internal func queryChapterIncluded(chapter: QueryChapter): Bool {
    chapter.state != "budget_omitted" && chapter.state != "resource_limit"
}

internal func queryChapterResult(chapter: QueryChapter): JsonObject {
    let state = if (chapter.state == "resource_limit") { "unavailable" } else { chapter.state }
    querySection(chapter.name, state, if (queryChapterIncluded(chapter)) {
        chapter.value
    } else { JsonNode.nullValue })
}
