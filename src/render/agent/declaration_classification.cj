protected package cjdoc.render.agent

import cjdoc.render.publication.{DeclarationClassification, EMPTY_DECLARATION_CLASSIFICATION, declarationClassificationJsonNode}
import cjdoc.render.routes.label
import cjdoc.render.foundation.{RenderTextBuffer, appendEscapedMarkdownText, appendMarkdownCodeSpan}
import cjdoc.model.*
import yjson.*

protected func capturedDeclarationClassification(context: DocumentationReadSnapshot,
    symbol: ?SymbolDoc): DeclarationClassification {
    match (symbol) {
        case Some(value) =>
            let captured = match (context.findDeclaration(value.id)) {
                case Some(found) => found
                case None => throw IllegalArgumentException(
                    "classification target is absent from the captured publication")
            }
            context.projection.catalog.classificationFor(captured)
        case None => EMPTY_DECLARATION_CLASSIFICATION
    }
}

protected func capturedDeclarationClassificationNode(context: DocumentationReadSnapshot,
    symbol: ?SymbolDoc): JsonObject {
    declarationClassificationJsonNode(capturedDeclarationClassification(context, symbol))
}

protected func appendDeclarationClassificationMarkdown(out: RenderTextBuffer,
    value: DeclarationClassification, locale: String): Unit {
    if (let Some(group) <- value.group) {
        out.append(label(locale, "API group: ", "接口分组："))
        appendMarkdownCodeSpan(out, group.id)
        out.append(" · ")
        appendEscapedMarkdownText(out, group.title)
        out.append("\n\n")
    }
    if (value.tags.isEmpty()) { return }
    out.append(label(locale, "Tags: ", "标签："))
    var first = true
    for (tag in value.tags) {
        if (!first) { out.append(", ") }
        first = false
        appendMarkdownCodeSpan(out, tag.id)
        if (tag.title != tag.id) {
            out.append(" · ")
            appendEscapedMarkdownText(out, tag.title)
        }
    }
    out.append("\n\n")
}

protected func capturedDeclarationClassificationMarkdown(context: DocumentationReadSnapshot,
    symbol: ?SymbolDoc): String {
    let out = RenderTextBuffer()
    appendDeclarationClassificationMarkdown(out,
        capturedDeclarationClassification(context, symbol), context.locale)
    out.toString()
}
