package cjdoc

import cjdoc.model as query_model
import std.collection.*
import yjson.*

private let QUERY_PAGE_SECTIONS: Array<String> = ["description", "source", "validation", "diff"]

internal func queryFillPage(outcome: QueryOutcome, input: QuerySnapshotInput,
    page: query_model.DocumentationPage, request: JsonObject): Unit {
    outcome.scope = "page"
    outcome.limit = 1
    let selected = queryPageSelectedSections(request)
    let chapters = queryPageChapters(input, page, selected)
    let maximum = if (request.get("maxBytes").isSome()) {
        queryInt(request, "maxBytes")
    } else { QUERY_DEFAULT_BYTES }
    outcome.selectedSections = selected
    var required: Int64 = 0
    for (chapter in chapters where chapter.mandatory) { required += queryChapterBytes(chapter) }
    if (queryRejectRequiredBudget(outcome, required, maximum)) { return }
    let _ = queryBudgetOptionalChapters(outcome, chapters, required, maximum)
    let sections = JsonNode.array()
    for (chapter in chapters) {
        sections.add(queryChapterResult(chapter))
        if (!queryChapterIncluded(chapter)) { outcome.contentComplete = false }
        if (chapter.state == "missing") { outcome.missing.add(chapter.name) }
        if (queryChapterIncluded(chapter) && QUERY_REPORT_SECTIONS.contains(chapter.name)) {
            outcome.reports.add(chapter.value.asObject())
        }
    }
    for (name in QUERY_PAGE_SECTIONS where !selected.contains(name)) {
        outcome.omitted.add(queryOmission(name, "not_selected", Some(queryRetryNode(maximum,
            "Request page section '${name}' explicitly."))))
    }
    outcome.total = Some(1)
    let item = JsonNode.object()
    item.put("kind", JsonNode.string("concept"))
    item.put("identity", queryIdentityNode(input, Option<String>.None, Some(page.id)))
    item.put("signature", JsonNode.nullValue)
    item.put("summary", JsonNode.string(page.title))
    let reason = JsonNode.object()
    reason.put("score", JsonNode.int64(0))
    reason.put("reason", JsonNode.string("requested_page_identity"))
    item.put("match", reason)
    item.put("sections", sections)
    item.put("representations", queryPageRepresentations(page))
    item.put("source", queryPageSource(page))
    item.put("exposures", JsonNode.array())
    outcome.items.add(item)
    outcome.sources.add(querySourceNode(input.snapshot.snapshotId, "html", Some(page.route),
        Some(page.route), "recorded"))
    outcome.reason = if (outcome.contentComplete) { "" } else { "content_omitted" }
    outcome.text = queryPageDetailText(input, page, chapters)
}

private func queryPageSelectedSections(request: JsonObject): ArrayList<String> {
    let selected = ArrayList<String>()
    if (let Some(values) <- request.get("sections")) {
        let array = values.asArray()
        for (name in QUERY_PAGE_SECTIONS) {
            for (index in 0..array.size()) {
                if (array[index].asString() == name) { selected.add(name); break }
            }
        }
    } else if (queryString(request, "preset") == "summary") { selected.add("description") }
    else { for (name in QUERY_PAGE_SECTIONS) { selected.add(name) } }
    selected
}

private func queryPageChapters(input: QuerySnapshotInput, page: query_model.DocumentationPage,
    selected: ArrayList<String>): ArrayList<QueryChapter> {
    let chapters = ArrayList<QueryChapter>()
    for (name in selected) {
        match (name) {
            case "description" =>
                let chapter = QueryChapter(name, "available", input.pageNodes[page.id], true)
                chapter.rendered = input.snapshot.renderPageMarkdown(page.id,
                    pagePath: "llms-full.txt").getOrDefault({ => "" })
                chapters.add(chapter)
            case "source" =>
                let chapter = QueryChapter(name, if (page.source.isEmpty()) { "unavailable" }
                    else { "available" }, queryPageSource(page), true)
                chapter.rendered = "## Source\n\n" + if (page.source.isEmpty()) {
                    "No source location was captured.\n"
                } else { page.source + "\n" }
                chapters.add(chapter)
            case _ =>
                let report = queryEvidenceReport(input, if (name == "validation") { "validation" } else { "api-diff" })
                let state = match (queryString(report, "state")) {
                    case "attached" => "available"
                    case "not_attached" => "missing"
                    case _ => "unavailable"
                }
                let chapter = QueryChapter(name, state, report, false)
                chapter.rendered = "## " + name + "\n\nCaptured evidence state: " +
                    queryString(report, "state") + ". No execution claim is inferred.\n"
                chapters.add(chapter)
        }
    }
    chapters
}

private func queryPageDetailText(input: QuerySnapshotInput, page: query_model.DocumentationPage,
    chapters: ArrayList<QueryChapter>): String {
    let out = StringBuilder()
    out.append("# " + page.title + "\n\n- page id: " + page.id + "\n- snapshot: " +
        input.snapshot.snapshotId + "\n- body language: " +
        page.language.getOrDefault({ => "unknown" }) + "\n\n")
    for (chapter in chapters) {
        if (queryChapterIncluded(chapter)) { out.append(chapter.rendered + "\n") }
        else { out.append("Section '${chapter.name}' omitted: ${chapter.state}; consult omittedSections.\n\n") }
    }
    out.toString()
}
