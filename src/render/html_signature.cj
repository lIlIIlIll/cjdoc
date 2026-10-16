package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.sort.*
import std.convert.*

// Token values come from SourceApiSignature, not a second declaration lexer.
// Alignment accepts only exact token values separated by source trivia. A stale
// or unsupported signature is kept as plain text rather than guessed at.
internal class HtmlSignatureToken {
    let kind: String
    let value: String
    let start: Int64
    let end: Int64
    init(kind: String, value: String, start: Int64, end: Int64) {
        this.kind = kind; this.value = value; this.start = start; this.end = end
    }
}

private func signatureSpace(byte: Byte): Bool {
    byte == b' ' || byte == b'\t' || byte == b'\r' || byte == b'\n'
}

private func skipSignatureTrivia(raw: String, from: Int64): Int64 {
    var cursor = from
    while (cursor < raw.size) {
        if (signatureSpace(raw[cursor])) { cursor++; continue }
        if ((cursor + 1 < raw.size && raw[cursor] == b'/' && raw[cursor + 1] == b'/')) {
            while (cursor < raw.size && raw[cursor] != b'\n') { cursor++ }
        } else if ((cursor + 1 < raw.size && raw[cursor] == b'/' && raw[cursor + 1] == b'*')) {
            var depth: Int64 = 1
            cursor += 2
            while (cursor < raw.size && depth > 0) {
                if ((cursor + 1 < raw.size && raw[cursor] == b'/' && raw[cursor + 1] == b'*')) { depth++; cursor += 2 }
                else if ((cursor + 1 < raw.size && raw[cursor] == b'*' && raw[cursor + 1] == b'/')) { depth--; cursor += 2 }
                else { cursor++ }
            }
            if (depth != 0) { return -1 }
        } else { break }
    }
    cursor
}

internal func alignedSignatureTokens(symbol: SymbolDoc): ArrayList<HtmlSignatureToken> {
    let result = ArrayList<HtmlSignatureToken>()
    if (symbol.sourceApiSignature.state != "available") { return result }
    let raw = symbol.headerSpelling
    var cursor: Int64 = 0
    for (encoded in symbol.sourceApiSignature.tokens) {
        let parts = encoded.split(":", 3)
        if (parts.size != 3 || parts[0].isEmpty() || parts[2].isEmpty()) {
            return ArrayList<HtmlSignatureToken>()
        }
        let size = try { Int64.parse(parts[1]) } catch (_: Exception) { -1 }
        cursor = skipSignatureTrivia(raw, cursor)
        if (cursor < 0 || size != parts[2].size || cursor > raw.size ||
            size > raw.size - cursor || raw[cursor..cursor + size] != parts[2]) {
            return ArrayList<HtmlSignatureToken>()
        }
        if (parts[2] == ">>") {
            result.add(HtmlSignatureToken(parts[0], ">", cursor, cursor + 1))
            result.add(HtmlSignatureToken(parts[0], ">", cursor + 1, cursor + 2))
        } else { result.add(HtmlSignatureToken(parts[0], parts[2], cursor, cursor + size)) }
        cursor += size
    }
    if (skipSignatureTrivia(raw, cursor) != raw.size) { return ArrayList<HtmlSignatureToken>() }
    result
}

private func compactSignatureType(value: String): String {
    value.replace(" ", "").replace("\t", "").replace("\r", "").replace("\n", "")
}

private func signatureTypeEnd(tokens: ArrayList<HtmlSignatureToken>, start: Int64,
    limit: Int64): Int64 {
    var angle: Int64 = 0
    var round: Int64 = 0
    var square: Int64 = 0
    var index = start
    while (index < limit) {
        let value = tokens[index].value
        if (angle == 0 && round == 0 && square == 0 &&
            (value == "," || value == ")" || value == "=" || value == "{" ||
                value == "where" || value == "&" || value == "<:")) { break }
        match (value) {
            case "<" => angle++
            case ">" => if (angle > 0) { angle-- } else { return start }
            case ">>" => if (angle >= 2) { angle -= 2 } else { return start }
            case "(" => round++
            case ")" => if (round > 0) { round-- } else { return start }
            case "[" => square++
            case "]" => if (square > 0) { square-- } else { return start }
            case _ => ()
        }
        index++
    }
    if (angle != 0 || round != 0 || square != 0) { start } else { index }
}

internal class HtmlSignatureLinkSpan {
    let start: Int64
    let end: Int64
    let url: String
    let title: String
    let navigation: ?TypeNavigation
    init(start: Int64, end: Int64, url: String, title!: String = "", navigation!: ?TypeNavigation = None) {
        this.start = start; this.end = end; this.url = url; this.title = title; this.navigation = navigation
    }
}
private func appendSignatureHeadLinks(spans: ArrayList<HtmlSignatureLinkSpan>,
    tokens: ArrayList<HtmlSignatureToken>, start: Int64, end: Int64, url: String,
    navigation: ?TypeNavigation): Unit {
    var first = tokens[start].start
    var last = tokens[start].end
    for (index in start + 1..end) {
        // Captured lexical tokens exclude comments. Every gap stays outside
        // anchors, including comment trivia between qualified-name components.
        if (tokens[index].start > last) {
            spans.add(HtmlSignatureLinkSpan(first, last, url, navigation: navigation))
            first = tokens[index].start
        }
        last = tokens[index].end
    }
    spans.add(HtmlSignatureLinkSpan(first, last, url, navigation: navigation))
}


private func signatureSpellingEnd(tokens: ArrayList<HtmlSignatureToken>, start: Int64,
    end: Int64, spelling: String): Int64 {
    let compact = compactSignatureType(spelling)
    var offset: Int64 = 0
    var cursor = start
    while (cursor < end) {
        let value = tokens[cursor].value
        if (value.size > compact.size - offset || compact[offset..offset + value.size] != value) { return start }
        offset += value.size
        cursor++
        if (offset == compact.size) { return cursor }
    }
    start
}

private func signatureTypeMatches(tokens: ArrayList<HtmlSignatureToken>, start: Int64,
    end: Int64, spelling: String): Bool {
    end > start && signatureSpellingEnd(tokens, start, end, spelling) == end
}

private func signatureChildEnd(tokens: ArrayList<HtmlSignatureToken>, start: Int64,
    end: Int64, child: TypeRef): Int64 {
    signatureSpellingEnd(tokens, start, end, child.spelling)
}

private func signatureTypeRange(tokens: ArrayList<HtmlSignatureToken>, from: Int64,
    limit: Int64, kind: String): (Int64, Int64) {
    var start = from
    var end = limit
    while (start + 1 < end && tokens[start].value == "(" && tokens[end - 1].value == ")") {
        var depth: Int64 = 0
        var close = start
        for (index in start..end) {
            if (tokens[index].value == "(") { depth++ }
            else if (tokens[index].value == ")") { depth-- }
            if (depth == 0) { close = index; break }
        }
        if (close != end - 1) { break }
        start++; end--
    }
    // Tuple syntax owns one pair; additional enclosing pairs are ParenType.
    if (kind == "tuple" && start > from) { start--; end++ }
    (start, end)
}

private func appendSignatureShapeSpans(spans: ArrayList<HtmlSignatureLinkSpan>,
    tokens: ArrayList<HtmlSignatureToken>, start: Int64, end: Int64, typeRef: TypeRef,
    links: HtmlTypeLinkIndex): Unit {
    var cursor = start + 1
    if (typeRef.kind == "optional") {
        if (tokens[start].value == "?" && typeRef.arguments.size == 1) {
            appendSignatureTypeSpans(spans, tokens, cursor, end, typeRef.arguments[0], links)
        }
        return
    }
    if (tokens[start].value != "(") { return }
    for (index in 0..typeRef.arguments.size) {
        if (typeRef.kind == "function" && index == typeRef.arguments.size - 1) {
            if (cursor + 1 >= end || tokens[cursor].value != ")" || tokens[cursor + 1].value != "->") { return }
            cursor += 2
        }
        let child = typeRef.arguments[index]
        let childEnd = signatureChildEnd(tokens, cursor, end, child)
        if (childEnd == cursor) { return }
        appendSignatureTypeSpans(spans, tokens, cursor, childEnd, child, links)
        cursor = childEnd
        if (cursor < end && tokens[cursor].value == ",") { cursor++ }
    }
}

private func appendSignatureTypeSpans(spans: ArrayList<HtmlSignatureLinkSpan>,
    tokens: ArrayList<HtmlSignatureToken>, rawStart: Int64, rawEnd: Int64, typeRef: TypeRef,
    links: HtmlTypeLinkIndex): Unit {
    if (!signatureTypeMatches(tokens, rawStart, rawEnd, typeRef.spelling)) { return }
    let (start, end) = signatureTypeRange(tokens, rawStart, rawEnd, typeRef.kind)
    if (start >= end) { return }
    if (typeRef.kind == "optional" || typeRef.kind == "tuple" || typeRef.kind == "function") {
        appendSignatureShapeSpans(spans, tokens, start, end, typeRef, links)
        return
    }
    var headEnd = end
    if (!typeRef.arguments.isEmpty()) {
        for (index in start..end) {
            if (tokens[index].value == "<") { headEnd = index; break }
        }
    }
    if (headEnd > start) {
        match (links.targetUrl(typeRef)) {
            case Some(url) => appendSignatureHeadLinks(spans, tokens, start, headEnd, url, typeRef.navigation)
            case None => if (typeRef.navigation.isSome()) {
                spans.add(HtmlSignatureLinkSpan(tokens[start].start, tokens[headEnd - 1].end,
                    "", title: typeNavigationTitle(typeRef, "en")))
            }
        }
    }
    if (headEnd == end) { return }
    var cursor = headEnd + 1
    for (argument in typeRef.arguments) {
        // Match an argument at its structural position; never search ahead.
        let argumentEnd = signatureChildEnd(tokens, cursor, end, argument)
        if (argumentEnd == cursor) { return }
        appendSignatureTypeSpans(spans, tokens, cursor, argumentEnd, argument, links)
        cursor = argumentEnd
        if (cursor < end && tokens[cursor].value == ",") { cursor++ }
    }
}

private func signatureParameters(tokens: ArrayList<HtmlSignatureToken>, symbol: SymbolDoc): (Int64, Int64) {
    var declaration = false
    var angle: Int64 = 0
    var opening: Int64 = -1
    for (index in 0..tokens.size) {
        let token = tokens[index]
        if (token.kind == "FUNC" || token.kind == "INIT") { declaration = true }
        if (!declaration) { continue }
        if (token.value == "<") { angle++ }
        else if (token.value == ">" && angle > 0) { angle-- }
        else if (token.value == "(" && angle == 0) { opening = index; break }
    }
    if (opening < 0) { return (-1, -1) }
    var depth: Int64 = 1
    var index = opening + 1
    while (index < tokens.size) {
        if (tokens[index].value == "(") { depth++ }
        else if (tokens[index].value == ")") {
            depth--
            if (depth == 0) { return (opening, index) }
        }
        index++
    }
    (-1, -1)
}

private func signatureConstraintStart(tokens: ArrayList<HtmlSignatureToken>): Int64 {
    var round: Int64 = 0
    var square: Int64 = 0
    for (index in 0..tokens.size) {
        let token = tokens[index]
        if (round == 0 && square == 0) {
            if (token.kind == "WHERE") { return index + 1 }
            if (token.value == "{") { break }
        }
        match (token.value) {
            case "(" => round++
            case ")" => if (round > 0) { round-- }
            case "[" => square++
            case "]" => if (square > 0) { square-- }
            case _ => ()
        }
    }
    tokens.size
}

internal func linkedSignatureSpans(symbol: SymbolDoc,
    links: HtmlTypeLinkIndex): ArrayList<HtmlSignatureLinkSpan> {
    let spans = ArrayList<HtmlSignatureLinkSpan>()
    let tokens = alignedSignatureTokens(symbol)
    if (tokens.isEmpty()) { return spans }
    let (opening, closing) = signatureParameters(tokens, symbol)
    if (opening >= 0) {
        var parameterIndex: Int64 = 0
        var round: Int64 = 0
        var square: Int64 = 0
        var brace: Int64 = 0
        var index = opening + 1
        while (index < closing && parameterIndex < symbol.parameters.size) {
            let token = tokens[index]
            if (round == 0 && square == 0 && brace == 0 && token.kind == "IDENTIFIER" &&
                token.value == symbol.parameters[parameterIndex].name) {
                var colon = index + 1
                if (colon < closing && tokens[colon].value == "!") { colon++ }
                if (colon < closing && tokens[colon].value == ":") {
                    let end = signatureTypeEnd(tokens, colon + 1, closing)
                    appendSignatureTypeSpans(spans, tokens, colon + 1, end,
                        symbol.parameters[parameterIndex].typeRef, links)
                    parameterIndex++
                    index = if (end > colon) { end } else { colon + 1 }
                    continue
                }
            }
            match (token.value) {
                case "(" => round++
                case ")" => if (round > 0) { round-- }
                case "[" => square++
                case "]" => if (square > 0) { square-- }
                case "{" => brace++
                case "}" => if (brace > 0) { brace-- }
                case _ => ()
            }
            index++
        }
        if (closing + 1 < tokens.size && tokens[closing + 1].value == ":") {
            match (symbol.returnType) {
                case Some(value) => appendSignatureTypeSpans(spans, tokens, closing + 2,
                    signatureTypeEnd(tokens, closing + 2, tokens.size), value, links)
                case None => ()
            }
        }
    } else if (symbol.kind == "property" || symbol.kind == "variable") {
        for (index in 0..tokens.size) {
            if (tokens[index].kind == "IDENTIFIER" && tokens[index].value == symbol.name &&
                index + 1 < tokens.size && tokens[index + 1].value == ":") {
                match (symbol.returnType) {
                    case Some(value) => appendSignatureTypeSpans(spans, tokens, index + 2,
                        signatureTypeEnd(tokens, index + 2, tokens.size), value, links)
                    case None => ()
                }
                break
            }
        }
    }
    // Relationships are resolved facts. Only match their types immediately after
    // the appropriate source delimiter, never inside an initializer or literal.
    var relationCursor: Int64 = 0
    var constraintCursor = signatureConstraintStart(tokens)
    for (relationship in symbol.typeRelationships) {
        var start: Int64 = -1
        if (relationship.kind == "extensionTarget") {
            for (index in 0..tokens.size) {
                if (tokens[index].kind == "EXTEND") { start = index + 1; break }
            }
            if (start >= 0 && start < tokens.size && tokens[start].value == "<") {
                var depth: Int64 = 0
                while (start < tokens.size) {
                    if (tokens[start].value == "<") { depth++ }
                    else if (tokens[start].value == ">") { depth-- }
                    start++
                    if (depth == 0) { break }
                }
            }
        } else if (relationship.kind == "genericConstraint") {
            for (index in constraintCursor..tokens.size) {
                if (tokens[index].value == "{") { break }
                if (tokens[index].value == "<:" || tokens[index].value == "&") {
                    start = index + 1; break
                }
            }
        } else if (relationship.kind == "superType") {
            for (index in relationCursor..tokens.size) {
                if (tokens[index].value == "<:" || tokens[index].value == "&") {
                    start = index + 1; break
                }
            }
        }
        if (start >= 0 && start < tokens.size) {
            let end = signatureTypeEnd(tokens, start, tokens.size)
            appendSignatureTypeSpans(spans, tokens, start, end, relationship.target, links)
            if (relationship.kind == "genericConstraint") { constraintCursor = end }
            else { relationCursor = end }
        }
    }
    sort(spans, lessThan: { left, right => left.start < right.start }, stable: true)
    spans
}

// Only validated presentation metadata supplies colours. The signature witness
// remains an alignment/navigation fact, including for legacy and mode=off IR.
private func appendSignatureRangeHtml(out: RenderTextBuffer, raw: String,
    start: Int64, end: Int64, highlight!: ?CodeHighlight = None): Unit {
    if (let Some(prepared) <- highlight) {
        appendCodeHighlightRangeHtml(out, raw, prepared, start, end)
    } else { appendHtmlEscapedValue(out, raw[start..end]) }
}

internal func appendSignatureTextHtml(out: RenderTextBuffer, symbol: SymbolDoc): Unit {
    if (let Some(prepared) <- symbol.signatureHighlight) {
        if (!prepared.matchesSource(symbol.headerSpelling)) {
            appendHtmlEscapedValue(out, symbol.headerSpelling); return
        }
    }
    appendSignatureRangeHtml(out, symbol.headerSpelling,
        0, symbol.headerSpelling.size, highlight: symbol.signatureHighlight)
}

internal func appendLinkedSignatureHtml(out: RenderTextBuffer, symbol: SymbolDoc,
    links: HtmlTypeLinkIndex, rootPrefix: String): Unit {
    let raw = symbol.headerSpelling
    // Stale highlight metadata is dropped, but the type links come from the
    // declaration model and must survive: losing them would remove structure the
    // document still asserts.
    var prepared = symbol.signatureHighlight
    if (let Some(value) <- prepared) {
        if (!value.matchesSource(raw)) { prepared = None }
    }
    var position: Int64 = 0
    for (span in linkedSignatureSpans(symbol, links)) {
        if (span.start < position) { continue }
        appendSignatureRangeHtml(out, raw, position, span.start, highlight: prepared)
        let href = navigationHref(rootPrefix, span.url)
        match (href) {
            case Some(url) =>
                out.append("<a class=\"type-link signature-type-link\" href=\"" + escapeHtml(url) + "\"")
                appendNavigationAttributes(out, span.navigation)
                out.append(">")
            case None => out.append("<span title=\"" + escapeHtml(span.title) + "\">")
        }
        appendSignatureRangeHtml(out, raw, span.start, span.end, highlight: prepared)
        out.append(if (href.isSome()) { "</a>" } else { "</span>" })
        position = span.end
    }
    appendSignatureRangeHtml(out, raw, position, raw.size, highlight: prepared)
}
