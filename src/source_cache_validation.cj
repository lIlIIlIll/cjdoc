package cjdoc

import std.ast.*
import std.collection.*

internal func encodeParsedSource(cacheKey: String, parsed: ParsedSourceFile,
    capturedSourceIndex: CapturedSourceIndex, capturedSource: String,
    maxBytes!: Int64 = MAX_SOURCE_CACHE_BYTES,
    maxItems!: Int64 = MAX_SOURCE_CACHE_ITEMS): ?Array<UInt8> {
    try {
        validateDecodedSourceCache(parsed, capturedSourceIndex, capturedSource)
    } catch (_: Exception) {
        return None
    }
    let writer = SourceCacheWriter(maxBytes: maxBytes, maxItems: maxItems)
    writer.add(SOURCE_CACHE_FORMAT)
    writer.add(cacheKey)
    cacheAddOptionalString(writer, parsed.packageName)
    if (!writer.addCount(parsed.declarations.size)) { return None }
    for (declaration in parsed.declarations) {
        cacheAddDeclaration(writer, declaration)
        if (!writer.canContinue()) { return None }
    }
    if (!writer.addCount(parsed.reExports.size)) { return None }
    for (reExport in parsed.reExports) {
        cacheAddReExport(writer, reExport)
        if (!writer.canContinue()) { return None }
    }
    if (!writer.addCount(parsed.orphanDocComments.size)) { return None }
    for (comment in parsed.orphanDocComments) {
        cacheAddOrphanDocComment(writer, comment)
        if (!writer.canContinue()) { return None }
    }
    if (!writer.addCount(parsed.macroInvocations.size)) { return None }
    for (invocation in parsed.macroInvocations) {
        cacheAddMacroInvocation(writer, invocation)
        if (!writer.canContinue()) { return None }
    }
    if (!writer.addCount(parsed.unsupportedDeclarations.size)) { return None }
    for (unsupported in parsed.unsupportedDeclarations) {
        cacheAddUnsupported(writer, unsupported)
        if (!writer.canContinue()) { return None }
    }
    if (!writer.addCount(parsed.diagnostics.size)) { return None }
    for (diagnostic in parsed.diagnostics) {
        cacheAddDiagnostic(writer, diagnostic)
        if (!writer.canContinue()) { return None }
    }
    let payload = match (writer.result()) {
        case Some(value) => value
        case None => return None
    }
    writer.add(Sha256Digest.digestBytes(payload))
    writer.result()
}

internal func checkedCacheCount(reader: SourceCacheReader): Int64 {
    reader.nextCount()
}

func sourceCacheLocationMatchesCaptured(location: SourceLocation, expectedPath: String,
    capturedSourceIndex: CapturedSourceIndex): Bool {
    location.path == expectedPath && location.startLine > 0 && location.startColumn > 0 &&
        location.endLine > 0 && location.endColumn > 0 &&
        !positionLess(location.endLine, location.endColumn,
            location.startLine, location.startColumn) &&
        capturedSourceIndex.byteOffset(location.startLine, location.startColumn).isSome() &&
        capturedSourceIndex.byteOffset(location.endLine, location.endColumn).isSome()
}

internal func validCachedDeclarationKind(kind: String): Bool {
    match (kind) {
        case "class" | "struct" | "interface" | "enum" | "enumCase" | "extend" |
            "typeAlias" | "property" | "variable" | "function" | "constructor" => true
        case _ => false
    }
}

internal func validCachedVisibility(visibility: String): Bool {
    match (visibility) {
        case "public" | "protected" | "internal" | "private" => true
        case _ => false
    }
}

internal func ignoredDefaultToken(token: Token): Bool {
    token.kind == COMMENT || token.value.isEmpty()
}

internal func cachedDefaultMatchesSourceTokens(expression: String, sourceTokens: Tokens,
    start: Int64, end: Int64): Bool {
    if (expression.trimAscii().isEmpty() || start < 0 || end < start || end > sourceTokens.size) {
        return false
    }
    let cachedTokens = cangjieLex(expression)
    var sourceIndex = start
    var cachedIndex: Int64 = 0
    while (true) {
        while (sourceIndex < end && ignoredDefaultToken(sourceTokens[sourceIndex])) {
            sourceIndex++
        }
        while (cachedIndex < cachedTokens.size && ignoredDefaultToken(cachedTokens[cachedIndex])) {
            cachedIndex++
        }
        if (sourceIndex >= end || cachedIndex >= cachedTokens.size) {
            return sourceIndex >= end && cachedIndex >= cachedTokens.size
        }
        if (sourceTokens[sourceIndex].kind != cachedTokens[cachedIndex].kind ||
            sourceTokens[sourceIndex].value != cachedTokens[cachedIndex].value) {
            return false
        }
        sourceIndex++
        cachedIndex++
    }
    false
}

internal func cachedParameterNameMatches(sourceTokens: Tokens, start: Int64,
    colon: Int64, expected: String): Bool {
    var index = colon - 1
    while (index >= start) {
        let token = sourceTokens[index]
        if (!ignoredDefaultToken(token) && token.value != "!") {
            return token.value == expected
        }
        index--
    }
    false
}

internal func hasMeaningfulDefaultTokens(sourceTokens: Tokens, start: Int64, end: Int64): Bool {
    var index = start
    while (index < end) {
        if (!ignoredDefaultToken(sourceTokens[index])) { return true }
        index++
    }
    false
}

internal func cachedParameterDefaultMatches(parameter: SourceParameter, sourceTokens: Tokens,
    assign: Int64, end: Int64): Bool {
    match (parameter.defaultExpression) {
        case None => assign < 0
        case Some(expression) => assign >= 0 &&
            cachedDefaultMatchesSourceTokens(expression, sourceTokens, assign + 1, end)
    }
}

internal func cachedParameterDefaultsMatchSignature(declaration: SourceDeclaration): Bool {
    if (declaration.kind != "function" && declaration.kind != "constructor") {
        for (parameter in declaration.parameters) {
            if (parameter.defaultExpression.isSome()) { return false }
        }
        return true
    }

    let tokens = cangjieLex(declaration.sourceSignature)
    var searchFrom: Int64 = 0
    var markerFound = false
    var index: Int64 = 0
    while (index < tokens.size) {
        let value = tokens[index].value
        if (value == "func" || (declaration.kind == "constructor" && value == "init")) {
            searchFrom = index + 1
            markerFound = true
            break
        }
        index++
    }
    if (!markerFound && declaration.kind == "constructor") {
        index = 0
        while (index < tokens.size) {
            let value = tokens[index].value
            if (value == "class" || value == "struct") {
                searchFrom = index + 1
                markerFound = true
                break
            }
            index++
        }
    }

    index = if (markerFound) { searchFrom } else { 0 }
    while (index < tokens.size && tokens[index].kind != LPAREN) { index++ }
    if (index >= tokens.size) { return false }

    let parameterStart = index + 1
    var segmentStart = parameterStart
    var parameterIndex: Int64 = 0
    var colon: Int64 = -1
    var assign: Int64 = -1
    var lastComma: Int64 = -1
    var roundDepth: Int64 = 1
    var squareDepth: Int64 = 0
    var braceDepth: Int64 = 0
    index++
    while (index < tokens.size) {
        let kind = tokens[index].kind
        if (kind == RPAREN && roundDepth == 1) {
            if (declaration.parameters.isEmpty()) {
                return colon < 0 &&
                    !hasMeaningfulDefaultTokens(tokens, parameterStart, index)
            }
            if (colon < 0 || parameterIndex >= declaration.parameters.size) { return false }
            var end = index
            if (lastComma > colon &&
                !hasMeaningfulDefaultTokens(tokens, lastComma + 1, index)) {
                end = lastComma
            }
            if (!cachedParameterDefaultMatches(declaration.parameters[parameterIndex],
                tokens, assign, end)) { return false }
            parameterIndex++
            return parameterIndex == declaration.parameters.size
        }

        if (roundDepth == 1 && squareDepth == 0 && braceDepth == 0) {
            match (kind) {
                case COLON =>
                    if (colon >= 0) {
                        if (lastComma <= colon || parameterIndex >= declaration.parameters.size ||
                            !cachedParameterDefaultMatches(declaration.parameters[parameterIndex],
                                tokens, assign, lastComma)) { return false }
                        parameterIndex++
                        segmentStart = lastComma + 1
                    }
                    if (parameterIndex >= declaration.parameters.size ||
                        !cachedParameterNameMatches(tokens, segmentStart, index,
                            declaration.parameters[parameterIndex].name)) { return false }
                    colon = index
                    assign = -1
                case ASSIGN =>
                    if (colon < 0 || assign >= 0) { return false }
                    assign = index
                case COMMA => lastComma = index
                case _ => ()
            }
        }

        match (kind) {
            case LPAREN => roundDepth++
            case RPAREN => roundDepth--
            case LSQUARE => squareDepth++
            case RSQUARE => if (squareDepth > 0) { squareDepth-- }
            case LCURL => braceDepth++
            case RCURL => if (braceDepth > 0) { braceDepth-- }
            case _ => ()
        }
        index++
    }
    false
}
