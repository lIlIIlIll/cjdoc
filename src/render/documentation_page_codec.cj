package cjdoc.render

import cjdoc.model.*
import std.collection.*
import yjson.*

internal func appendDocumentationPages(out: StringBuilder, pages: ReadOnlyList<DocumentationPage>): Unit {
    out.append("[")
    var first = true
    for (page in pages) {
        if (!first) { out.append(",") }; first = false
        out.append("{\"id\":${escapeJsonString(page.id)},\"source\":${escapeJsonString(page.source)},\"route\":${escapeJsonString(page.route)},")
        out.append("\"title\":${escapeJsonString(page.title)},\"kind\":${escapeJsonString(page.kind)},\"packageName\":${escapeJsonString(page.packageName)},")
        out.append("\"language\":${nullableString(page.language)},\"defaultLanguage\":${nullableString(page.defaultLanguage)},\"text\":${escapeJsonString(page.text)},\"markdown\":")
        appendMarkdown(out, page.markdown)
        out.append(",\"targetSymbolIds\":"); appendStrings(out, page.targetSymbolIds)
        out.append(",\"sections\":[")
        var firstSection = true
        for (section in page.sections) {
            if (!firstSection) { out.append(",") }; firstSection = false
            out.append("{\"id\":${escapeJsonString(section.id)},\"anchor\":${escapeJsonString(section.anchor)}}")
        }
        out.append("],\"bindings\":[")
        var firstBinding = true
        for (binding in page.bindings) {
            if (!firstBinding) { out.append(",") }; firstBinding = false
            out.append("{\"target\":${escapeJsonString(binding.target)},\"selector\":${escapeJsonString(binding.selector)},\"provenance\":${escapeJsonString(binding.provenance)},\"version\":${escapeJsonString(binding.version)},")
            out.append("\"sourceLine\":${binding.sourceLine},\"language\":${escapeJsonString(binding.language)},\"state\":${escapeJsonString(binding.state)},\"targetSymbolId\":${nullableString(binding.targetSymbolId)},\"navigation\":")
            appendTypeNavigation(out, binding.navigation)
            out.append("}")
        }
        out.append("]}")
    }
    out.append("]")
}

internal func decodeDocumentationPages(node: ?JsonNode): Array<DocumentationPage> {
    if (node.isNone()) { return [] }
    let pages = ArrayList<DocumentationPage>()
    for (value in jsonArrayValues(node.getOrThrow().asArray())) {
        let path = "$.pages[" + pages.size.toString() + "]"
        let object = strictObject(value, path, ["id", "source", "route", "title", "kind", "packageName",
            "language", "defaultLanguage", "text", "markdown", "sections", "targetSymbolIds", "bindings"])
        let sections = ArrayList<DocumentationSection>()
        for (item in jsonArrayValues(arrayAt(object, "sections", path))) {
            let section = strictObject(item, path + ".sections", ["id", "anchor"])
            sections.add(DocumentationSection(stringAt(section, "id", path),
                stringAt(section, "anchor", path)))
        }
        let bindings = ArrayList<DocumentationPageBinding>()
        if (let Some(items) <- object.get("bindings")) {
            for (item in jsonArrayValues(items.asArray())) {
                let bindingPath = path + ".bindings[" + bindings.size.toString() + "]"
                let binding = strictObject(item, bindingPath,
                    ["target", "selector", "provenance", "version", "sourceLine", "language",
                        "state", "targetSymbolId", "navigation"])
                bindings.add(DocumentationPageBinding(stringAt(binding, "target", bindingPath),
                    stringAt(binding, "selector", bindingPath), stringAt(binding, "provenance", bindingPath),
                    stringAt(binding, "version", bindingPath), intAt(binding, "sourceLine", bindingPath),
                    language: stringAt(binding, "language", bindingPath),
                    state: stringAt(binding, "state", bindingPath),
                    targetSymbolId: nullableStringAt(binding, "targetSymbolId", bindingPath),
                    navigation: decodeTypeNavigation(Some(required(binding, "navigation", bindingPath)),
                        bindingPath + ".navigation")))
            }
        }
        pages.add(DocumentationPage(stringAt(object, "id", path), stringAt(object, "source", path),
            stringAt(object, "route", path), stringAt(object, "title", path), stringAt(object, "kind", path),
            stringAt(object, "text", path), decodeMarkdown(required(object, "markdown", path),
                path + ".markdown", 0),
            language: optionalDocumentationLanguage(Some(required(object, "language", path)), path),
            defaultLanguage: optionalDocumentationLanguage(Some(required(object, "defaultLanguage", path)), path),
            packageName: stringAt(object, "packageName", path), sections: sections.toArray(),
            targetSymbolIds: stringsAt(object, "targetSymbolIds", path), bindings: bindings.toArray()))
    }
    pages.toArray()
}

internal func consumeDocumentationPages(value: DocumentationSet, budget: DocIrEncodingBudget): Unit {
    budget.consumeCollection(value.pages.size, "$.pages", depth: 1)
    for (page in value.pages) {
        budget.consumeObject("$.pages[]", depth: 2, fields: 13)
        for (text in [page.id, page.source, page.route, page.title, page.kind, page.packageName, page.text]) { budget.consumeString(text, "$.pages[]") }
        budget.consumeOptionalString(page.language, "$.pages[].language")
        budget.consumeOptionalString(page.defaultLanguage, "$.pages[].defaultLanguage")
        consumeMarkdownEncoding(page.markdown, "$.pages[].markdown", 0, 3, budget)
        budget.consumeCollection(page.sections.size, "$.pages[].sections", depth: 3)
        for (section in page.sections) {
            budget.consumeObject("$.pages[].sections[]", depth: 4, fields: 2)
            budget.consumeString(section.id, "$.pages[].sections[].id")
            budget.consumeString(section.anchor, "$.pages[].sections[].anchor")
        }
        budget.consumeCollection(page.targetSymbolIds.size, "$.pages[].targetSymbolIds", depth: 3)
        for (id in page.targetSymbolIds) { budget.consumeString(id, "$.pages[].targetSymbolIds[]") }
        budget.consumeCollection(page.bindings.size, "$.pages[].bindings", depth: 3)
        for (binding in page.bindings) {
            budget.consumeObject("$.pages[].bindings[]", depth: 4, fields: 9)
            for (text in [binding.target, binding.selector, binding.provenance, binding.version, binding.language, binding.state]) {
                budget.consumeString(text, "$.pages[].bindings[]")
            }
            budget.consumeOptionalString(binding.targetSymbolId, "$.pages[].bindings[].targetSymbolId")
            consumeNavigationEncoding(binding.navigation, "$.pages[].bindings[].navigation", 5, budget)
        }
    }
}
