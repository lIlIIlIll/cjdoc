protected package cjdoc.render.html

import cjdoc.render.reading.contentLanguageLabel
import cjdoc.render.routes.label
import cjdoc.model.*
import std.collection.*

internal func appendContentLanguageHtml(w: HtmlWriter, tag: DocTag, locale: String): Unit {
    if (tag.translationState.isEmpty()) { return }
    let text = contentLanguageLabel(tag, locale)
    let attrs = ArrayList<HtmlAttr>([htmlClass("cj-content-language"),
        htmlAttr("data-translation-state", tag.translationState)])
    if (text.isEmpty()) { attrs.add(htmlFlag("hidden")) }
    if (let Some(value) <- tag.contentLanguage) { attrs.add(htmlAttr("lang", value)) }
    w.open("span", attrs: attrs.toArray())
    w.text(text)
    w.close("span")
}

internal func appendDocumentationTagHtml(w: HtmlWriter, tag: DocTag,
    locale: String, assets: HashMap<String, String>, rootPrefix: String,
    context: HtmlMarkdownContext): Unit {
    let fieldIdentity = if (context.fieldAnchorNamespace.isEmpty()) { tag.fieldId }
        else { context.fieldAnchorNamespace + tag.fieldId }
    if (!tag.fieldId.isEmpty()) {
        w.open("div", attrs: [htmlAttr("id", documentationFieldAnchor(fieldIdentity))])
    }
    appendContentLanguageHtml(w, tag, locale)
    if (let Some(language) <- tag.contentLanguage) {
        w.open("div", attrs: [htmlAttr("lang", language)])
    }
    appendDocumentationTagBodyHtml(w, tag, locale, assets, rootPrefix, context, fieldIdentity)
    if (tag.contentLanguage.isSome()) { w.close("div") }
    if (!tag.fieldId.isEmpty()) { w.close("div") }
}

private func appendDocumentationTagBodyHtml(w: HtmlWriter, tag: DocTag, locale: String,
    assets: HashMap<String, String>, rootPrefix: String, context: HtmlMarkdownContext,
    fieldIdentity: String): Unit {
    match (tag.descriptionMarkdown) {
        case Some(tree) =>
            if (!tag.description.trimAscii().isEmpty() &&
                !markdownTreeHasDescriptionContent(tree, assets)) {
                appendStructuredTextHtml(w, tag.description)
                return
            }
            let fieldContext = HtmlMarkdownContext(3, locale: locale)
            collectMarkdownHeadings(tree, "field-" + contractFingerprint(
                fieldIdentity + tag.name + tag.subject),
                HashMap<String, Int64>(), fieldContext)
            appendMarkdownNodeHtml(w, tree, assets, rootPrefix, fieldContext)
        case None => appendStructuredTextHtml(w, tag.description)
    }
}

protected func documentationFieldAnchor(fieldId: String): String { "doc-field-" + contractFingerprint(fieldId) }
