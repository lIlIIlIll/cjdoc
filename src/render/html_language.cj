package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func contentLanguageLabel(tag: DocTag, locale: String): String {
    let language = tag.contentLanguage.getOrDefault({ => label(locale, "unknown language", "语言未知") })
    match (tag.translationState) {
        case "fallback" => label(locale, "Translation missing. Original text: ", "暂无当前语言翻译，原文：") + language
        case "empty-fallback" => label(locale, "Empty translation; original text: ", "译文为空；原文：") + language
        case "conflict-fallback" => label(locale, "Translation conflict; original text: ", "译文冲突；原文：") + language
        case "empty" => label(locale, "Translation is empty", "译文为空")
        case "conflict" => label(locale, "Translation conflict", "译文冲突")
        case "missing" => label(locale, "Translation missing", "翻译缺失")
        case "unpaired" => if (tag.contentLanguage == Some(locale)) { "" }
            else { label(locale, "Original text: ", "原文：") + language }
        case "unknown" => language
        case _ => language
    }
}

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

internal func documentationFieldAnchor(fieldId: String): String { "doc-field-" + contractFingerprint(fieldId) }
