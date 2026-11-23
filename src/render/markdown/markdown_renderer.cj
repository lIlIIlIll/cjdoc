protected package cjdoc.render.markdown

import cjdoc.render.foundation.escapeHtml
import cjdoc.render.routes.{ApiHtmlRoutes, apiHtmlFileHref, markdownPackagePagePath, markdownSymbolPagePath}
import cjdoc.render.publication.isContainerDeclaration
import cjdoc.render.reading.{
    capturedAdmonitionLevel, capturedAdmonitionMarkdownMarker, readerRelationshipLabel,
    typeGenericSuffix, typeHeadSpelling}
import cjdoc.render.routes.{symbolAnchor, navigationHref, isCapturedLocalApiLink, label}
import cjdoc.render.codec.escapeJsonString
import cjdoc.render.foundation.{
    RenderTextBuffer, markdownNodeText, appendEscapedMarkdownText, safeLinkDestination,
    safeRelativeLinkDestination, markdownLinkDestination, encodeMarkdownDestination, assetReference,
    markdownRequestedHeadingLevel, appendMarkdownMarks, appendMarkdownCodeSpan,
    appendMarkdownCodeBlock}
import cjdoc.model.*
import std.collection.*

protected func markdownRelativeDestination(destination: String, pagePath: String): String {
    if (destination.startsWith("https://") || destination.startsWith("http://")) { return destination }
    if (pagePath.startsWith("symbols/") && destination.startsWith("symbols/")) {
        destination["symbols/".size..]
    } else if (pagePath.startsWith("packages/") || pagePath.startsWith("symbols/")) {
        "../" + destination
    } else { destination }
}

// Agent references are published inside the HTML document root. pagePath is
// relative to that root, not the generator's staging directory. Never embed
// the staging directory name: a site can be deployed at any HTTP subpath.
// Aggregate site Markdown retains its historical sibling-directory routing.
protected func markdownOutputRootPrefix(pagePath: String): String {
    let segments = ArrayList<String>()
    for (segment in pagePath.split("/")) {
        if (!segment.isEmpty()) { segments.add(segment) }
    }
    var hops = segments.size
    if (!pagePath.endsWith("/") && hops > 0) { hops-- }
    var prefix = ""
    for (_ in 0..hops) { prefix += "../" }
    prefix
}

protected func markdownCanonicalHtmlDestination(value: String, pagePath: String): ?String {
    if (value.startsWith("https://") || value.startsWith("http://")) {
        return markdownLinkDestination(value)
    }
    let relative = value.removePrefix("./")
    let parts = relative.split("#", 2)
    if (parts.isEmpty() || !safeRelativeLinkDestination(parts[0])) { return None }
    var destination = markdownOutputRootPrefix(pagePath) + parts[0]
    if (parts.size == 2) {
        if (!safeLinkDestination("#" + parts[1])) { return None }
        destination += "#" + parts[1]
    }
    Some(encodeMarkdownDestination(destination))
}

protected func markdownCanonicalSymbolDestination(symbolId: String, pagePath: String,
    routes: ApiHtmlRoutes): ?String {
    routes.filePath(symbolId).flatMap({ path => markdownCanonicalHtmlDestination(apiHtmlFileHref(path), pagePath) })
}

protected func markdownResolvedNavigationDestination(navigation: TypeNavigation,
    pagePath: String, symbolIndex: HashMap<String, SymbolDoc>,
    canonicalHtml: ?ApiHtmlRoutes): ?String {
    if (let Some(routes) <- canonicalHtml) {
        if (navigation.state != "resolved") { return None }
        if (isCapturedLocalApiLink(navigation)) {
            return markdownCanonicalSymbolDestination(navigation.symbolKey, pagePath, routes)
        }
        return markdownCanonicalHtmlDestination(navigation.url, pagePath)
    }
    return markdownNavigationDestination(navigation, pagePath, symbolIndex)
}

protected func markdownTargetPagePath(target: SymbolDoc,
    symbolIndex: HashMap<String, SymbolDoc>): String {
    if (isContainerDeclaration(target)) {
        markdownSymbolPagePath(target)
    } else {
        match (target.ownerId) {
            case Some(ownerId) => match (symbolIndex.get(ownerId)) {
                case Some(owner) => markdownSymbolPagePath(owner)
                case None => markdownPackagePagePath(target.moduleId, target.packageName)
            }
            case None => markdownPackagePagePath(target.moduleId, target.packageName)
        }
    }
}

private func markdownSemanticLinkDestination(destination: String, pagePath: String,
    targetSymbolId!: ?String = None,
    symbolIndex!: ?HashMap<String, SymbolDoc> = None,
    canonicalHtml!: ?ApiHtmlRoutes = None): ?String {
    match ((targetSymbolId, symbolIndex)) {
        case (Some(targetId), Some(index)) => match (index.get(targetId)) {
            case Some(target) =>
                if (let Some(routes) <- canonicalHtml) {
                    return markdownCanonicalSymbolDestination(target.id, pagePath, routes)
                }
                let targetPage = if (pagePath.isEmpty()) {
                    "#${symbolAnchor(target)}"
                } else {
                    let page = markdownTargetPagePath(target, index)
                    if (page == pagePath) {
                        "#${symbolAnchor(target)}"
                    } else {
                        "${markdownRelativeDestination(page, pagePath)}#${symbolAnchor(target)}"
                    }
                }
                return markdownLinkDestination(targetPage, allowRelative: true)
            case None => ()
        }
        case _ => ()
    }
    if (canonicalHtml.isSome()) { return markdownCanonicalHtmlDestination(destination, pagePath) }
    let localDestination = if (!pagePath.isEmpty() && destination.startsWith("symbols/") &&
        destination.endsWith(".html")) {
        destination[..destination.size - 5] + ".md"
    } else { destination }
    let relativeDestination = markdownRelativeDestination(localDestination, pagePath)
    markdownLinkDestination(relativeDestination, allowRelative: true)
}

protected func appendMarkdownInlineNode(out: RenderTextBuffer, node: MarkdownNode,
    assetLookup: HashMap<String, String>, headingBase: Int64,
    pagePath!: String = "", symbolIndex!: ?HashMap<String, SymbolDoc> = None,
    tableCell!: Bool = false, capturedLinks!: ?HashMap<String, String> = None,
    canonicalHtml!: ?ApiHtmlRoutes = None): Unit {
    match (node.kind) {
        case "text" => appendEscapedMarkdownText(out, node.literal)
        case "soft_break" => out.append(if (tableCell) { "<br>" } else { "\n" })
        case "hard_break" => out.append(if (tableCell) { "<br>" } else { "  \n" })
        case "emphasis" =>
            out.append("*"); for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, canonicalHtml: canonicalHtml, capturedLinks: capturedLinks,
                    tableCell: tableCell)
            }; out.append("*")
        case "strong" =>
            out.append("**"); for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, canonicalHtml: canonicalHtml, capturedLinks: capturedLinks,
                    tableCell: tableCell)
            }; out.append("**")
        case "strikethrough" =>
            out.append("~~"); for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, canonicalHtml: canonicalHtml, capturedLinks: capturedLinks,
                    tableCell: tableCell)
            }; out.append("~~")
        case "code_span" => appendMarkdownCodeSpan(out, node.literal, tableCell: tableCell)
        case "link" =>
            out.append("["); for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, canonicalHtml: canonicalHtml, capturedLinks: capturedLinks,
                    tableCell: tableCell)
            }; out.append("]")
            let captured: ?String = match (capturedLinks) { case Some(links) => links.get(node.literal); case None => None }
            if (let Some(destination) <- captured) {
                // Captured page routes and generated heading fragments are already validated.
                out.append("(" + encodeMarkdownDestination(destination) + ")")
            } else {
                match (markdownLinkDestination(node.literal)) {
                    case Some(destination) => out.append("(${destination})")
                    case None => ()
                }
            }
        case "semantic_link" =>
            out.append("["); for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, canonicalHtml: canonicalHtml, capturedLinks: capturedLinks,
                    tableCell: tableCell)
            }; out.append("]")
            match (node.metadata) {
                case Some(metadata) =>
                    if (let Some(navigation) <- metadata.semanticNavigation) {
                        let index = symbolIndex.getOrDefault({ => HashMap<String, SymbolDoc>() })
                        if (let Some(encoded) <- markdownResolvedNavigationDestination(navigation,
                            pagePath, index, canonicalHtml)) {
                            out.append("(" + encoded)
                            appendMarkdownNavigationTitle(out, Some(navigation))
                            out.append(")")
                        }
                    } else if (let Some(destination) <- metadata.semanticExternalUrl) {
                        if (let Some(encoded) <- markdownSemanticLinkDestination(destination, pagePath,
                            targetSymbolId: metadata.semanticTargetSymbolId, symbolIndex: symbolIndex,
                            canonicalHtml: canonicalHtml)) {
                            out.append("(" + encoded + ")")
                        }
                    }
                case None => ()
            }
        case "image" =>
            let alt = markdownNodeText(node)
            match (assetReference(assetLookup, node.literal)) {
                case Some(path) =>
                    out.append("!["); appendEscapedMarkdownText(out, alt)
                    match (markdownLinkDestination("#${path}")) {
                        case Some(encoded) => out.append("](${encoded[1..]})")
                        case None => out.append("]")
                    }
                case None => appendEscapedMarkdownText(out, alt)
            }
        case "html_inline" | "html_block" => appendEscapedMarkdownText(out, node.literal)
        case _ => for (child in node.children) {
            appendMarkdownInlineNode(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, canonicalHtml: canonicalHtml, capturedLinks: capturedLinks,
                tableCell: tableCell)
        }
    }
}

protected func appendMarkdownPrefixedBlock(out: RenderTextBuffer, content: String,
    firstPrefix: String, continuationPrefix: String,
    prefixBlankLines!: Bool = true): Unit {
    let lines = content.split("\n")
    var end = lines.size
    while (end > 0 && lines[end - 1].isEmpty()) { end-- }
    var index: Int64 = 0
    var wrote = false
    while (index < end) {
        if (!lines[index].isEmpty() || prefixBlankLines) {
            out.append(if (!wrote) { firstPrefix } else { continuationPrefix })
        }
        out.append(lines[index]); out.append("\n")
        wrote = true
        index++
    }
    if (!wrote) { out.append(firstPrefix); out.append("\n") }
}

protected func appendMarkdownTableMarkdown(out: RenderTextBuffer, node: MarkdownNode,
    assetLookup: HashMap<String, String>, headingBase: Int64, pagePath!: String = "",
    symbolIndex!: ?HashMap<String, SymbolDoc> = None,
    capturedLinks!: ?HashMap<String, String> = None,
    canonicalHtml!: ?ApiHtmlRoutes = None): Unit {
    var rowIndex: Int64 = 0
    for (row in node.children) {
        out.append("|")
        for (cell in row.children) {
            out.append(" ")
            for (child in cell.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, canonicalHtml: canonicalHtml, capturedLinks: capturedLinks,
                    tableCell: true)
            }
            out.append(" |")
        }
        out.append("\n")
        if (rowIndex == 0) {
            out.append("|")
            var column: Int64 = 0
            for (_ in row.children) {
                let alignment = match (node.metadata) {
                    case Some(metadata) => if (column < metadata.tableAlignments.size) {
                        metadata.tableAlignments[column]
                    } else { "none" }
                    case None => "none"
                }
                match (alignment) {
                    case "left" => out.append(" :--- |")
                    case "center" => out.append(" :---: |")
                    case "right" => out.append(" ---: |")
                    case _ => out.append(" --- |")
                }
                column++
            }
            out.append("\n")
        }
        rowIndex++
    }
    out.append("\n")
}

protected func appendMarkdownNodeMarkdown(out: RenderTextBuffer, node: MarkdownNode,
    assetLookup: HashMap<String, String>, headingBase: Int64,
    pagePath!: String = "", symbolIndex!: ?HashMap<String, SymbolDoc> = None,
    capturedLinks!: ?HashMap<String, String> = None,
    canonicalHtml!: ?ApiHtmlRoutes = None, headingContext!: ?MarkdownOutputHeadingContext = None,
    headingAnchorPrefix!: String = "markdown", headingOrdinal!: Int64 = -1): Unit {
    if (headingContext.isNone()) {
        if (let Some(context) <- markdownOutputHeadingContext(node, headingBase,
            headingAnchorPrefix, headingOrdinal)) {
            let links = markdownHeadingFragmentLinks(context, capturedLinks)
            appendMarkdownNodeMarkdown(out, node, assetLookup, headingBase, pagePath: pagePath,
                symbolIndex: symbolIndex, capturedLinks: Some(links), canonicalHtml: canonicalHtml,
                headingContext: Some(context))
            return
        }
    }
    match (node.kind) {
        case "document" => for (child in node.children) {
            appendMarkdownNodeMarkdown(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, capturedLinks: capturedLinks, canonicalHtml: canonicalHtml, headingContext: headingContext)
        }
        case "paragraph" =>
            for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, capturedLinks: capturedLinks, canonicalHtml: canonicalHtml)
            }
            out.append("\n\n")
        case "heading" =>
            let level = markdownRequestedHeadingLevel(node, headingBase)
            if (let Some(context) <- headingContext) {
                let target = context.headingIds[context.nextHeading]
                context.nextHeading++
                out.append("<a id=\"${escapeHtml(target)}\"></a>\n")
            }
            // Do not promote deeper content into a sibling H6.
            if (level <= 6) { appendMarkdownMarks(out, "#", level); out.append(" ") }
            for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, capturedLinks: capturedLinks, canonicalHtml: canonicalHtml)
            }
            out.append("\n\n")
        case "text" | "soft_break" | "hard_break" | "emphasis" | "strong" |
            "strikethrough" | "code_span" | "link" | "image" | "html_inline" =>
            appendMarkdownInlineNode(out, node, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, capturedLinks: capturedLinks, canonicalHtml: canonicalHtml)
        case "code_block" =>
            match (node.metadata) {
                case Some(metadata) => if (metadata.kind == "code_block" &&
                    metadata.codeKind.getOrThrow() == "fenced") {
                    let marker = metadata.fenceCharacter.getOrThrow()
                    let fenceLength = metadata.fenceLength.getOrThrow()
                    let infoRaw = metadata.infoRaw.getOrThrow()
                    appendMarkdownCodeBlock(out, node.literal, infoRaw, marker, fenceLength)
                } else {
                    appendMarkdownCodeBlock(out, node.literal, "", "`", 3)
                }
                case None => appendMarkdownCodeBlock(out, node.literal, "", "`", 3)
            }
        case "thematic_break" => out.append("---\n\n")
        case "admonition" =>
            match (capturedAdmonitionLevel(node)) {
                case Some(level) =>
                    match (capturedAdmonitionMarkdownMarker(level)) {
                        case Some(marker) =>
                            let nested = RenderTextBuffer()
                            nested.append("[!${marker}]\n\n")
                            for (child in node.children) {
                                appendMarkdownNodeMarkdown(nested, child, assetLookup, headingBase,
                                    pagePath: pagePath, symbolIndex: symbolIndex,
                                    capturedLinks: capturedLinks, canonicalHtml: canonicalHtml,
                                    headingContext: headingContext)
                            }
                            appendMarkdownPrefixedBlock(out, nested.toString(), "> ", "> ")
                            out.append("\n")
                        case None => for (child in node.children) {
                            appendMarkdownNodeMarkdown(out, child, assetLookup, headingBase,
                                pagePath: pagePath, symbolIndex: symbolIndex,
                                capturedLinks: capturedLinks, canonicalHtml: canonicalHtml,
                                headingContext: headingContext)
                        }
                    }
                case None => for (child in node.children) {
                    appendMarkdownNodeMarkdown(out, child, assetLookup, headingBase,
                        pagePath: pagePath, symbolIndex: symbolIndex,
                        capturedLinks: capturedLinks, canonicalHtml: canonicalHtml,
                        headingContext: headingContext)
                }
            }
        case "block_quote" =>
            let nested = RenderTextBuffer()
            for (child in node.children) {
                appendMarkdownNodeMarkdown(nested, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, capturedLinks: capturedLinks, canonicalHtml: canonicalHtml, headingContext: headingContext)
            }
            appendMarkdownPrefixedBlock(out, nested.toString(), "> ", "> ")
            out.append("\n")
        case "list" =>
            var itemIndex: Int64 = 0
            let tight = match (node.metadata) {
                case Some(value) => value.kind == "list" && value.listTight.getOrThrow()
                case None => true
            }
            for (child in node.children) {
                let marker = if (let Some(value) <- node.metadata) {
                    if (value.kind == "list" && value.listKind.getOrThrow() == "ordered") {
                        let delimiter = if (value.listDelimiter.getOrThrow() == "parenthesis") {
                            ") "
                        } else { ". " }
                        "${value.listStart.getOrThrow() + itemIndex}${delimiter}"
                    } else { "- " }
                } else { "- " }
                let firstPrefix = RenderTextBuffer()
                firstPrefix.append(marker)
                if (let Some(itemMetadata) <- child.metadata) {
                    if (itemMetadata.kind == "list_item") {
                        match (itemMetadata.taskState.getOrThrow()) {
                            case "checked" => firstPrefix.append("[x] ")
                            case "unchecked" => firstPrefix.append("[ ] ")
                            case _ => ()
                        }
                    }
                }
                let nested = RenderTextBuffer()
                for (itemChild in child.children) {
                    appendMarkdownNodeMarkdown(nested, itemChild, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, capturedLinks: capturedLinks, canonicalHtml: canonicalHtml, headingContext: headingContext)
                }
                let continuation = RenderTextBuffer()
                appendMarkdownMarks(continuation, " ", firstPrefix.toString().size)
                appendMarkdownPrefixedBlock(out, nested.toString(), firstPrefix.toString(),
                    continuation.toString(), prefixBlankLines: false)
                if (!tight && itemIndex + 1 < node.children.size) { out.append("\n") }
                itemIndex++
            }
            out.append("\n")
        case "list_item" =>
            for (child in node.children) {
                appendMarkdownNodeMarkdown(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, capturedLinks: capturedLinks, canonicalHtml: canonicalHtml, headingContext: headingContext)
            }
        case "table" => appendMarkdownTableMarkdown(out, node, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, capturedLinks: capturedLinks, canonicalHtml: canonicalHtml)
        case "table_row" | "table_cell" | "custom_block" => for (child in node.children) {
            appendMarkdownNodeMarkdown(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, capturedLinks: capturedLinks, canonicalHtml: canonicalHtml, headingContext: headingContext)
        }
        case "custom_inline" => appendMarkdownInlineNode(out, node, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, capturedLinks: capturedLinks, canonicalHtml: canonicalHtml)
        case "html_block" => appendEscapedMarkdownText(out, node.literal); out.append("\n\n")
        case _ => for (child in node.children) {
            appendMarkdownNodeMarkdown(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, capturedLinks: capturedLinks, canonicalHtml: canonicalHtml, headingContext: headingContext)
        }
    }
}

protected func markdownNavigationDestination(navigation: TypeNavigation, pagePath: String,
    symbolIndex: HashMap<String, SymbolDoc>): ?String {
    if (navigation.state != "resolved" || navigationHref("", navigation.url).isNone()) { return None }
    if (isCapturedLocalApiLink(navigation)) {
        if (let Some(target) <- symbolIndex.get(navigation.symbolKey)) {
            let destination = if (pagePath.isEmpty()) { "#" + symbolAnchor(target) } else {
                let targetPage = markdownTargetPagePath(target, symbolIndex)
                if (targetPage == pagePath) { "#" + symbolAnchor(target) } else {
                    markdownRelativeDestination(targetPage, pagePath) + "#" + symbolAnchor(target)
                }
            }
            return Some(encodeMarkdownDestination(destination))
        }
        return None
    }
    let prefix = if (pagePath.startsWith("packages/") || pagePath.startsWith("symbols/")) { "../../html/" } else { "../html/" }
    let destination = if (navigation.url.startsWith("https://") || navigation.url.startsWith("http://")) {
        navigation.url
    } else { prefix + navigation.url.removePrefix("./") }
    // The document-root route was validated above. Only this renderer adds
    // the fixed parent prefix needed to reach html/; untrusted parent paths
    // never pass navigationHref. Do not reclassify that layout prefix as input.
    Some(encodeMarkdownDestination(destination))
}
private func appendMarkdownNavigationTitle(out: RenderTextBuffer, navigation: ?TypeNavigation): Unit {
    if (let Some(value) <- navigation) {
        if (value.state == "resolved") {
            // JSON's quoted-string escaping also protects Markdown's double-quoted
            // title delimiters, without altering the link label or destination.
            out.append(" "); out.append(escapeJsonString(value.matchLevel + ": " + value.reason))
        }
    }
}


protected func appendTagSubjectMarkdown(out: RenderTextBuffer, tag: DocTag,
    pagePath: String, symbolIndex: ?HashMap<String, SymbolDoc>,
    canonicalHtml!: ?ApiHtmlRoutes = None): Unit {
    let index = symbolIndex.getOrDefault({ => HashMap<String, SymbolDoc>() })
    let destination: ?String = match (tag.navigation) {
        case Some(navigation) => markdownResolvedNavigationDestination(navigation, pagePath,
            index, canonicalHtml)
        case None => None
    }
    if (destination.isSome()) { out.append("[") }
    appendMarkdownCodeSpan(out, tag.subject)
    if (let Some(url) <- destination) {
        out.append("](" + url); appendMarkdownNavigationTitle(out, tag.navigation); out.append(")")
    }
}

private func appendMarkdownTypeAtom(out: RenderTextBuffer, typeRef: TypeRef,
    spelling: String, pagePath: String, symbolIndex: HashMap<String, SymbolDoc>,
    canonicalHtml: ?ApiHtmlRoutes): Unit {
    if (typeRef.navigation.isNone()) {
        appendMarkdownCodeSpan(out, spelling); return
    }
    let destination: ?String = match (typeRef.navigation) {
        case Some(navigation) => markdownResolvedNavigationDestination(navigation, pagePath,
            symbolIndex, canonicalHtml)
        case None => None
    }
    if (destination.isSome()) { out.append("[") }
    appendMarkdownCodeSpan(out, spelling)
    if (let Some(url) <- destination) {
        out.append("](" + url); appendMarkdownNavigationTitle(out, typeRef.navigation); out.append(")")
    }
}

protected func appendTypeRefMarkdown(out: RenderTextBuffer, typeRef: TypeRef,
    pagePath: String, symbolIndex: HashMap<String, SymbolDoc>,
    canonicalHtml!: ?ApiHtmlRoutes = None): Unit {
    if (typeRef.kind == "optional" && typeRef.arguments.size == 1) {
        out.append("?")
        appendTypeRefMarkdown(out, typeRef.arguments[0], pagePath, symbolIndex,
            canonicalHtml: canonicalHtml)
    } else if ((typeRef.kind == "tuple" || typeRef.kind == "function") && !typeRef.arguments.isEmpty()) {
        appendEscapedMarkdownText(out, "(")
        for (index in 0..typeRef.arguments.size) {
            if (typeRef.kind == "function" && index == typeRef.arguments.size - 1) {
                appendEscapedMarkdownText(out, ") -> ")
            } else if (index > 0) { out.append(", ") }
            appendTypeRefMarkdown(out, typeRef.arguments[index], pagePath, symbolIndex,
                canonicalHtml: canonicalHtml)
        }
        if (typeRef.kind == "tuple") { appendEscapedMarkdownText(out, ")") }
    } else if (!typeRef.arguments.isEmpty() && typeRef.spelling.contains("<")) {
        appendMarkdownTypeAtom(out, typeRef, typeHeadSpelling(typeRef.spelling), pagePath, symbolIndex,
            canonicalHtml)
        appendEscapedMarkdownText(out, "<")
        var first = true
        for (child in typeRef.arguments) {
            if (!first) { out.append(", ") }; first = false
            appendTypeRefMarkdown(out, child, pagePath, symbolIndex, canonicalHtml: canonicalHtml)
        }
        appendEscapedMarkdownText(out, ">" + typeGenericSuffix(typeRef.spelling))
    } else {
        appendMarkdownTypeAtom(out, typeRef, typeRef.spelling, pagePath, symbolIndex, canonicalHtml)
    }
}

private func hasResolvedTypeNavigation(value: TypeRef): Bool {
    if (let Some(navigation) <- value.navigation) { if (navigation.state == "resolved") { return true } }
    for (child in value.arguments) { if (hasResolvedTypeNavigation(child)) { return true } }
    false
}

// Keep the source signature in a copyable fence; expose links where readers
// inspect parameter, return and relationship types rather than rewriting code.
protected func appendMarkdownTypeDetails(out: RenderTextBuffer, symbol: SymbolDoc,
    pagePath: String, symbolIndex: HashMap<String, SymbolDoc>, locale: String): Unit {
    var linked = false
    for (parameter in symbol.parameters) { linked = linked || hasResolvedTypeNavigation(parameter.typeRef) }
    if (let Some(value) <- symbol.returnType) { linked = linked || hasResolvedTypeNavigation(value) }
    for (relationship in symbol.typeRelationships) { linked = linked || hasResolvedTypeNavigation(relationship.target) }
    if (!linked) { return }
    for (parameter in symbol.parameters) {
        out.append("- " + label(locale, "Parameter", "参数") + " ")
        appendMarkdownCodeSpan(out, parameter.name); out.append(": ")
        appendTypeRefMarkdown(out, parameter.typeRef, pagePath, symbolIndex); out.append("\n")
    }
    if (let Some(value) <- symbol.returnType) {
        out.append("- " + label(locale, "Returns", "返回值") + ": ")
        appendTypeRefMarkdown(out, value, pagePath, symbolIndex); out.append("\n")
    }
    for (relationship in symbol.typeRelationships where !pagePath.isEmpty()) {
        out.append("- "); appendEscapedMarkdownText(out, readerRelationshipLabel(relationship.kind, locale))
        out.append(": "); appendTypeRefMarkdown(out, relationship.target, pagePath, symbolIndex); out.append("\n")
    }
    if (!symbol.parameters.isEmpty() || symbol.returnType.isSome() ||
        (!pagePath.isEmpty() && !symbol.typeRelationships.isEmpty())) { out.append("\n") }
}
