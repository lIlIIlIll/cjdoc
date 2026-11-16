package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func typeNavigationTitle(typeRef: TypeRef, locale: String): String {
    let title = label(locale, "Documentation link unavailable", "暂无文档链接")
    if (let Some(navigation) <- typeRef.navigation) {
        if (!navigation.reason.isEmpty()) { return title + ": " + navigation.reason }
    }
    title
}
internal func navigationAttrs(navigation: ?TypeNavigation): Array<HtmlAttr> {
    let attrs = ArrayList<HtmlAttr>()
    if (let Some(value) <- navigation) {
        if (value.state != "resolved") { return attrs.toArray() }
        attrs.add(htmlAttr("data-doc-match", value.matchLevel))
        attrs.add(htmlAttr("title", value.matchLevel + ": " + value.reason))
    }
    attrs.toArray()
}

/**
 * Attributes for a documentation destination that already passed
 * `navigationHref`. Absolute references stay absolute; everything else is a
 * generated site route.
 */
internal func documentationHrefAttrs(value: String, navigation!: ?TypeNavigation = None,
    cssClass!: String): Array<HtmlAttr> {
    let attrs = ArrayList<HtmlAttr>([htmlClass(cssClass)])
    attrs.add(htmlHref(documentationHrefUrl(value)))
    attrs.add(all: navigationAttrs(navigation))
    attrs.toArray()
}

private func documentationHrefUrl(value: String): SafeUrl {
    if (value.startsWith("https://") || value.startsWith("http://")) {
        match (SafeUrl.external(value)) {
            case Some(url) => return url
            case None => throw IllegalArgumentException("unsafe documentation URL")
        }
    }
    if (value.startsWith("#")) { return SafeUrl.fragment(value[1..]) }
    documentationRouteHref(value)
}


internal func typeHeadSpelling(spelling: String): String {
    match (spelling.indexOf("<")) {
        case Some(index) => spelling[..index].trimAscii()
        case None => spelling
    }
}

internal func typeGenericSuffix(spelling: String): String {
    let bytes = spelling.toArray()
    var depth: Int64 = 0
    var genericEnd: Int64 = -1
    var index: Int64 = 0
    for (byte in bytes) {
        if (byte == b'<') {
            depth++
        } else if (byte == b'>' && depth > 0) {
            depth--
            if (depth == 0) { genericEnd = index }
        }
        index++
    }
    if (genericEnd < 0 || genericEnd + 1 >= spelling.size) { "" }
    else { spelling[genericEnd + 1..] }
}

// Some source/AST providers record a generic type's spelling with trivia around
// angle brackets. Normalize only this display spelling; source signatures and
// semantic identities must remain byte-for-byte intact. Function arrows and
// generic constraints are deliberately left untouched.
internal func genericTypeDisplaySpelling(spelling: String): String {
    if (!spelling.contains("<") || spelling.contains("->") || spelling.contains("<:")) {
        return spelling
    }
    spelling.replace(" <", "<").replace("< ", "<")
        .replace(" >", ">").replace("> ", ">").replace(" ,", ",")
}

internal func appendTypeAtomHtml(w: HtmlWriter, typeRef: TypeRef,
    spelling: String, typeLinkIndex: HtmlTypeLinkIndex, rootPrefix: String): Unit {
    match (typeLinkIndex.targetUrl(typeRef)) {
        case Some(url) =>
            if (let Some(href) <- navigationHref(rootPrefix, url)) {
                w.open("a", attrs: documentationHrefAttrs(href, navigation: typeRef.navigation,
                    cssClass: "cj-type-link"))
                w.text(spelling)
                w.close("a")
            } else { w.text(spelling) }
        case None =>
            if (typeRef.navigation.isSome()) {
                w.textElement("span", spelling,
                    attrs: [htmlAttr("title", typeNavigationTitle(typeRef, "en"))])
            } else { w.text(spelling) }
    }
}

internal func appendTypeRefContentHtml(w: HtmlWriter, typeRef: TypeRef,
    typeLinkIndex: HtmlTypeLinkIndex, rootPrefix: String): Unit {
    if (typeRef.kind == "optional" && typeRef.arguments.size == 1) {
        w.text("?")
        appendTypeRefContentHtml(w, typeRef.arguments[0], typeLinkIndex, rootPrefix)
        return
    }
    if ((typeRef.kind == "tuple" || typeRef.kind == "function") && !typeRef.arguments.isEmpty()) {
        w.text("(")
        for (index in 0..typeRef.arguments.size) {
            if (typeRef.kind == "function" && index == typeRef.arguments.size - 1) {
                w.text(") -> ")
            } else if (index > 0) { w.text(", ") }
            appendTypeRefContentHtml(w, typeRef.arguments[index], typeLinkIndex, rootPrefix)
        }
        if (typeRef.kind == "tuple") { w.text(")") }
        return
    }
    match (typeRef.spelling.indexOf("<")) {
        case Some(_) =>
            if (typeRef.arguments.isEmpty()) {
                appendTypeAtomHtml(w, typeRef,
                    genericTypeDisplaySpelling(typeRef.spelling), typeLinkIndex, rootPrefix)
                return
            }
            appendTypeAtomHtml(w, typeRef, typeHeadSpelling(typeRef.spelling),
                typeLinkIndex, rootPrefix)
            w.text("<")
            var first = true
            for (argument in typeRef.arguments) {
                if (!first) { w.text(", ") }
                first = false
                appendTypeRefContentHtml(w, argument, typeLinkIndex, rootPrefix)
            }
            w.text(">")
            let suffix = typeGenericSuffix(typeRef.spelling)
            if (!suffix.isEmpty()) { w.text(suffix) }
        case None => appendTypeAtomHtml(w, typeRef, typeRef.spelling, typeLinkIndex, rootPrefix)
    }
}

internal func appendTypeRefCodeHtml(w: HtmlWriter, typeRef: TypeRef,
    typeLinkIndex: HtmlTypeLinkIndex, rootPrefix: String, locale: String,
    className!: String = ""): Unit {
    let attrs = ArrayList<HtmlAttr>()
    if (!className.isEmpty()) { attrs.add(htmlClass(className)) }
    if (typeLinkIndex.shouldShowUnavailableTitle(typeRef)) {
        attrs.add(htmlAttr("title", typeNavigationTitle(typeRef, locale)))
    }
    w.open("code", attrs: attrs.toArray())
    appendTypeRefContentHtml(w, typeRef, typeLinkIndex, rootPrefix)
    w.close("code")
}
