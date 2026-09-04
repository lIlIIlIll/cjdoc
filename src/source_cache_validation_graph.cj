package cjdoc

import std.ast.*
import std.collection.*

func validateCachedParameterDefaults(declaration: SourceDeclaration): Unit {
    let matches = try {
        cachedParameterDefaultsMatchSignature(declaration)
    } catch (_: Exception) {
        false
    }
    if (!matches) {
        throw IllegalArgumentException("cached parameter defaults do not match captured source")
    }
}

internal func validateCachedDocComment(comment: ?DocComment): Unit {
    if (let Some(value) <- comment) {
        if (!value.raw.startsWith("/**") || value.returnTagCount < 0 ||
            value.returnTagCount > MAX_SOURCE_CACHE_ITEMS) {
            throw IllegalArgumentException("invalid cached documentation")
        }
        let expected = parseDocComment(value.raw)
        let actualWriter = SourceCacheWriter()
        let expectedWriter = SourceCacheWriter()
        cacheAddDocComment(actualWriter, Some(value))
        cacheAddDocComment(expectedWriter, Some(expected))
        let actual = actualWriter.result()
        let canonical = expectedWriter.result()
        if (actual.isNone() || canonical.isNone() ||
            String.fromUtf8(actual.getOrThrow()) != String.fromUtf8(canonical.getOrThrow())) {
            throw IllegalArgumentException("cached documentation does not match its raw source")
        }
    }
}

internal func cachedSourceSignatureMatches(declaration: SourceDeclaration,
    source: IndexedSourceBuffer): Bool {
    if (declaration.sourceSignature.isEmpty()) { return false }
    let expectedTokens = sourceApiSignatureTokens(declaration.sourceSignature)
    if (expectedTokens.size != declaration.sourceApiSignatureTokens.size) { return false }
    var tokenIndex: Int64 = 0
    while (tokenIndex < expectedTokens.size) {
        if (expectedTokens[tokenIndex] != declaration.sourceApiSignatureTokens[tokenIndex]) { return false }
        tokenIndex++
    }
    let end = source.byteOffset(declaration.source.endLine, declaration.source.endColumn)
    var cursor = source.byteOffset(declaration.source.startLine,
        declaration.source.startColumn)
    if (cursor < 0 || end <= cursor || end > source.bytes.size) { return false }
    while (cursor < end && (source.bytes[cursor] == b' ' || source.bytes[cursor] == b'\t' ||
        source.bytes[cursor] == b'\r' || source.bytes[cursor] == b'\n')) { cursor++ }
    let signature = declaration.sourceSignature.toArray()
    if (signature.size > end - cursor) { return false }
    var signatureIndex: Int64 = 0
    while (signatureIndex < signature.size) {
        if (source.bytes[cursor + signatureIndex] != signature[signatureIndex]) { return false }
        signatureIndex++
    }
    cursor += signature.size
    while (cursor < end && (source.bytes[cursor] == b' ' || source.bytes[cursor] == b'\t' ||
        source.bytes[cursor] == b'\r' || source.bytes[cursor] == b'\n')) { cursor++ }
    cursor == end || source.bytes[cursor] == b'{'
}

internal func validateCachedCommentBindings(parsed: ParsedSourceFile,
    source: IndexedSourceBuffer): Unit {
    let comments = collectDocComments(parsed.input.logicalPath, cangjieLex(source.source))
    var commentIndex: Int64 = 0
    var candidate: ?RawDocComment = None
    var symbolIndex: Int64 = 0
    while (symbolIndex < parsed.declarations.size) {
        let symbol = parsed.declarations[symbolIndex]
        while (commentIndex < comments.size &&
            positionLessOrEqual(comments[commentIndex].source.endLine,
                comments[commentIndex].source.endColumn,
                symbol.source.startLine, symbol.source.startColumn)) {
            if (!comments[commentIndex].bound) { candidate = comments[commentIndex] }
            commentIndex++
        }
        var expectedRaw: ?String = None
        if (let Some(comment) <- candidate) {
            if (!comment.bound && onlyWhitespaceBetween(source, comment.source, symbol.source)) {
                expectedRaw = Some(comment.raw)
                comment.bound = true
            }
            candidate = None
        }
        var groupedIndex = symbolIndex
        while (groupedIndex < parsed.declarations.size &&
            sameSourceRange(parsed.declarations[groupedIndex].source, symbol.source)) {
            match ((expectedRaw, parsed.declarations[groupedIndex].documentation)) {
                case (Some(expected), Some(actual)) =>
                    if (actual.raw != expected) {
                        throw IllegalArgumentException("cached documentation is bound to the wrong source")
                    }
                case (None, None) => ()
                case _ => throw IllegalArgumentException("cached documentation binding mismatch")
            }
            groupedIndex++
        }
        symbolIndex = groupedIndex
    }
    let expectedOrphans = ArrayList<RawDocComment>()
    for (comment in comments where !comment.bound) { expectedOrphans.add(comment) }
    if (expectedOrphans.size != parsed.orphanDocComments.size) {
        throw IllegalArgumentException("cached orphan documentation mismatch")
    }
    var orphanIndex: Int64 = 0
    while (orphanIndex < expectedOrphans.size) {
        let expected = expectedOrphans[orphanIndex]
        let actual = parsed.orphanDocComments[orphanIndex]
        if (actual.rawText != expected.raw || !sameSourceRange(actual.source, expected.source)) {
            throw IllegalArgumentException("cached orphan documentation is not from captured source")
        }
        orphanIndex++
    }
}

func validateSourceCacheOwnerGraph(declarations: ArrayList<SourceDeclaration>,
    maxDepth!: Int64 = MAX_SOURCE_OWNER_DEPTH): Unit {
    if (maxDepth < 1) { throw IllegalArgumentException("cache owner depth limit must be positive") }
    let declarationsByKey = HashMap<String, SourceDeclaration>()
    for (declaration in declarations) {
        if (declarationsByKey.contains(declaration.sourceKey)) {
            throw IllegalArgumentException("duplicate cached declaration owner key")
        }
        declarationsByKey[declaration.sourceKey] = declaration
    }
    let ownerState = HashMap<String, Int64>()
    let ownerDepth = HashMap<String, Int64>()
    for (declaration in declarations) {
        let alreadyDone = match (ownerState.get(declaration.sourceKey)) {
            case Some(2) => true
            case _ => false
        }
        if (alreadyDone) { continue }
        let path = ArrayList<String>()
        var current = declaration
        var complete = false
        var inheritedDepth: Int64 = 0
        while (!complete) {
            match (ownerState.get(current.sourceKey)) {
                case Some(1) =>
                    throw IllegalArgumentException("cyclic cached declaration ownership")
                case Some(2) =>
                    inheritedDepth = ownerDepth.get(current.sourceKey).getOrThrow()
                    complete = true
                case _ =>
                    ownerState[current.sourceKey] = 1
                    path.add(current.sourceKey)
                    if (path.size > maxDepth) {
                        throw IllegalArgumentException("cached declaration ownership is too deep")
                    }
                    match (current.ownerSourceKey) {
                        case None => complete = true
                        case Some(ownerKey) =>
                            if (ownerKey == current.sourceKey) {
                                throw IllegalArgumentException("cached declaration owns itself")
                            }
                            current = match (declarationsByKey.get(ownerKey)) {
                                case Some(owner) => owner
                                case None => throw IllegalArgumentException(
                                    "unknown cached declaration owner")
                            }
                    }
            }
        }
        if (inheritedDepth > maxDepth || path.size > maxDepth - inheritedDepth) {
            throw IllegalArgumentException("cached declaration ownership is too deep")
        }
        var pathIndex = path.size
        var depth = inheritedDepth
        while (pathIndex > 0) {
            pathIndex--
            depth++
            ownerState[path[pathIndex]] = 2
            ownerDepth[path[pathIndex]] = depth
        }
    }
}

internal func validateDecodedSourceCache(parsed: ParsedSourceFile,
    capturedSourceIndex: CapturedSourceIndex, capturedSource: String): Unit {
    let expectedPath = parsed.input.logicalPath
    let sourceBuffer = IndexedSourceBuffer(capturedSource)
    let packageName = match (parsed.packageName) {
        case Some(value) =>
            if (value.isEmpty()) { throw IllegalArgumentException("empty cached package") }
            value
        case None =>
            if (!parsed.declarations.isEmpty() || !parsed.reExports.isEmpty() || !parsed.orphanDocComments.isEmpty() ||
                !parsed.macroInvocations.isEmpty() || !parsed.unsupportedDeclarations.isEmpty()) {
                throw IllegalArgumentException("cached source facts require a package")
            }
            ""
    }
    let declarationsByKey = HashMap<String, SourceDeclaration>()
    var previous: ?SourceDeclaration = None
    for (declaration in parsed.declarations) {
        if (!validCachedDeclarationKind(declaration.kind) || declaration.name.isEmpty() ||
            declaration.packageName != packageName || declaration.moduleId != parsed.input.module.id ||
            !validCachedVisibility(declaration.visibility) ||
            !sourceCacheLocationMatchesCaptured(declaration.source, expectedPath,
                capturedSourceIndex) ||
            !cachedSourceSignatureMatches(declaration, sourceBuffer) ||
            declaration.sourceKey != makeSourceDeclarationKey(declaration.source,
                declaration.kind, declaration.name) ||
            declarationsByKey.contains(declaration.sourceKey)) {
            throw IllegalArgumentException("invalid cached declaration")
        }
        if ((declaration.kind == "enum" && declaration.enumNonExhaustive.isNone()) ||
            (declaration.kind != "enum" && declaration.enumNonExhaustive.isSome())) {
            throw IllegalArgumentException("invalid cached enum exhaustiveness")
        }
        validateCachedParameterDefaults(declaration)
        if (let Some(value) <- previous) {
            if (sourceOrderLess(declaration, value)) {
                throw IllegalArgumentException("cached declarations are not source ordered")
            }
        }
        validateCachedDocComment(declaration.documentation)
        declarationsByKey[declaration.sourceKey] = declaration
        previous = Some(declaration)
    }
    validateCachedCommentBindings(parsed, sourceBuffer)
    for (declaration in parsed.declarations) {
        if (let Some(ownerKey) <- declaration.ownerSourceKey) {
            if (ownerKey == declaration.sourceKey) {
                throw IllegalArgumentException("cached declaration owns itself")
            }
            match (declarationsByKey.get(ownerKey)) {
                case Some(owner) =>
                    if (!owner.isContainer || owner.packageName != declaration.packageName ||
                        owner.moduleId != declaration.moduleId ||
                        !rangeContains(owner.source, declaration.source)) {
                        throw IllegalArgumentException("invalid cached declaration owner")
                    }
                case None => throw IllegalArgumentException("unknown cached declaration owner")
            }
        }
    }
    // The shared validator uses three-state iterative DFS and memoized depth,
    // so every owner edge is visited once and total nesting is still capped.
    validateSourceCacheOwnerGraph(parsed.declarations)
    for (reExport in parsed.reExports) {
        if ((reExport.kind != "single" && reExport.kind != "alias" &&
            reExport.kind != "all" && reExport.kind != "multi") ||
            reExport.packageName != packageName || reExport.moduleId != parsed.input.module.id ||
            reExport.normalizedSpec.isEmpty() ||
            !sourceCacheLocationMatchesCaptured(reExport.source, expectedPath, capturedSourceIndex)) {
            throw IllegalArgumentException("invalid cached public import")
        }
        let exact = sourceBuffer.slice(reExport.source)
        if (exact.isEmpty() || cangjieLex(exact).toString().trimAscii() != reExport.normalizedSpec) {
            throw IllegalArgumentException("cached public import does not match source")
        }
    }
    for (comment in parsed.orphanDocComments) {
        if (!comment.rawText.startsWith("/**") ||
            !sourceCacheLocationMatchesCaptured(comment.source, expectedPath,
                capturedSourceIndex)) {
            throw IllegalArgumentException("invalid cached orphan documentation")
        }
    }
    for (invocation in parsed.macroInvocations) {
        if (invocation.name.isEmpty() || !sourceCacheLocationMatchesCaptured(invocation.source,
            expectedPath, capturedSourceIndex)) {
            throw IllegalArgumentException("invalid cached macro invocation")
        }
    }
    for (unsupported in parsed.unsupportedDeclarations) {
        if (unsupported.kind.isEmpty() || unsupported.name.isEmpty() ||
            unsupported.reason.isEmpty() || !sourceCacheLocationMatchesCaptured(unsupported.source,
                expectedPath, capturedSourceIndex) ||
            (unsupported.origin.kind != "source" && unsupported.origin.kind != "macro")) {
            throw IllegalArgumentException("invalid cached unsupported declaration")
        }
    }
    for (diagnostic in parsed.diagnostics) {
        if ((diagnostic.severity != "warning" && diagnostic.severity != "error") ||
            !diagnostic.code.startsWith("CJDOC1") || diagnostic.message.isEmpty() ||
            diagnostic.symbolId.isSome()) {
            throw IllegalArgumentException("invalid cached source diagnostic")
        }
        if (let Some(location) <- diagnostic.source) {
            if (!sourceCacheLocationMatchesCaptured(location, expectedPath,
                capturedSourceIndex)) {
                throw IllegalArgumentException("invalid cached diagnostic location")
            }
        }
    }
}
