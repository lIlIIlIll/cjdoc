package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.sort.*

internal func appendSearchJsonString(out: RenderTextBuffer, value: String): Unit {
    let digits = "0123456789abcdef"
    out.append("\"")
    for (rune in value.runes()) {
        match (rune) {
            case '"' => out.append("\\\"")
            case '\\' => out.append("\\\\")
            case '\u{0008}' => out.append("\\b")
            case '\u{000c}' => out.append("\\f")
            case '\n' => out.append("\\n")
            case '\r' => out.append("\\r")
            case '\t' => out.append("\\t")
            case _ =>
                let code = UInt32(rune)
                if (code < 0x20u32) {
                    out.append("\\u")
                    out.append(digits[Int64((code >> 12) & 0xFu32)..
                        Int64((code >> 12) & 0xFu32) + 1])
                    out.append(digits[Int64((code >> 8) & 0xFu32)..
                        Int64((code >> 8) & 0xFu32) + 1])
                    out.append(digits[Int64((code >> 4) & 0xFu32)..
                        Int64((code >> 4) & 0xFu32) + 1])
                    out.append(digits[Int64(code & 0xFu32)..Int64(code & 0xFu32) + 1])
                } else { out.append(rune) }
        }
    }
    out.append("\"")
}

internal func searchTextExcerpt(value: String, maximum!: Int64 = 240): String {
    let out = RenderTextBuffer()
    var count: Int64 = 0
    for (rune in value.runes()) {
        if (count == maximum) { out.append("…"); return out.toString() }
        out.append(rune)
        count++
    }
    out.toString()
}

internal func appendOptionalSearchString(out: RenderTextBuffer, value: ?String): Unit {
    match (value) {
        case Some(text) => appendSearchJsonString(out, text)
        case None => out.append("null")
    }
}

internal func searchModuleName(documentation: DocumentationSet, moduleId: String): ?String {
    for (module in documentation.modules) {
        if (module.id == moduleId) { return Some(module.name) }
    }
    None
}

internal func searchOwnerName(projection: RenderProjection, declaration: SymbolDoc): ?String {
    match (declaration.ownerId) {
        case Some(ownerId) =>
            match (projection.visibleIndex.get(ownerId)) {
                case Some(owner) => Some(owner.qualifiedName)
                case None => None
            }
        case None => None
    }
}

internal func appendSearchMetadata(out: RenderTextBuffer, documentation: DocumentationSet,
    projection: RenderProjection, declaration: SymbolDoc, moduleId: String): Unit {
    out.append(", \"moduleId\": ")
    appendSearchJsonString(out, moduleId)
    out.append(", \"moduleName\": ")
    appendOptionalSearchString(out, searchModuleName(documentation, moduleId))
    out.append(", \"ownerName\": ")
    appendOptionalSearchString(out, searchOwnerName(projection, declaration))
    out.append(", \"parameterTypes\": [")
    var firstParameter = true
    for (parameter in declaration.parameters) {
        if (!firstParameter) { out.append(",") }
        firstParameter = false
        appendSearchJsonString(out, parameter.typeRef.spelling)
    }
    out.append("] , \"returnType\": ")
    match (declaration.returnType) {
        case Some(typeRef) => appendSearchJsonString(out, typeRef.spelling)
        case None => out.append("null")
    }
    out.append(", \"returnCanonical\": ")
    match (declaration.returnType) {
        case Some(typeRef) => appendOptionalSearchString(out, typeRef.semantic.canonical)
        case None => out.append("null")
    }
}

internal func renderSearchIndex(documentation: DocumentationSet,
    projection: RenderProjection): String {
    let out = RenderTextBuffer()
    out.append("{\n  \"schemaVersion\": \"cjdoc.search-index/6\",\n  \"entries\": [")
    var first = true
    let visible = ArrayList<SymbolDoc>(projection.visibleSymbols.toArray())
    sort(visible, lessThan: { left, right => left.id < right.id }, stable: true)
    for (declaration in visible) {
        if (!first) { out.append(",") }
        first = false
        out.append("\n    {\"id\": "); appendSearchJsonString(out, declaration.id)
        out.append(", \"canonicalId\": "); appendSearchJsonString(out, declaration.id)
        out.append(", \"exposure\": false")
        out.append(", \"name\": "); appendSearchJsonString(out, declaration.name)
        out.append(", \"qualifiedName\": "); appendSearchJsonString(out, declaration.qualifiedName)
        out.append(", \"kind\": "); appendSearchJsonString(out, declaration.kind)
        out.append(", \"packageName\": "); appendSearchJsonString(out, declaration.packageName)
        appendSearchMetadata(out, documentation, projection, declaration, declaration.moduleId)
        let summary = match (declaration.documentation) {
            case Some(comment) => searchTextExcerpt(summaryPlainText(comment))
            case None => ""
        }
        out.append(", \"summary\": "); appendSearchJsonString(out, summary)
        out.append(", \"href\": ")
        appendSearchJsonString(out,
            symbolUrl(projection.visibleIndex, declaration))
        out.append("}")
    }
    for (pkg in documentation.packages) {
        for (reExport in pkg.reExports) {
            for (binding in reExport.bindings) {
                for (targetId in binding.targetSymbolIds) {
                    match (projection.visibleIndex.get(targetId)) {
                        case Some(target) =>
                            if (!first) { out.append(",") }; first = false
                            out.append("\n    {\"id\": ")
                            appendSearchJsonString(out,
                                "${reExport.id}:${binding.exposedName}:${target.id}")
                            out.append(", \"canonicalId\": "); appendSearchJsonString(out, target.id)
                            out.append(", \"exposure\": true, \"name\": ")
                            appendSearchJsonString(out, binding.exposedName)
                            out.append(", \"qualifiedName\": ")
                            appendSearchJsonString(out, "${pkg.name}.${binding.exposedName}")
                            out.append(", \"kind\": "); appendSearchJsonString(out, target.kind)
                            out.append(", \"packageName\": "); appendSearchJsonString(out, pkg.name)
                            appendSearchMetadata(out, documentation, projection, target, pkg.moduleId)
                            let summary = match (target.documentation) {
                                case Some(comment) => searchTextExcerpt(summaryPlainText(comment))
                                case None => ""
                            }
                            out.append(", \"summary\": "); appendSearchJsonString(out, summary)
                            out.append(", \"href\": ")
                            appendSearchJsonString(out,
                                symbolUrl(projection.visibleIndex, target))
                            out.append("}")
                        case None => ()
                    }
                }
            }
        }
    }
    if (!first) { out.append("\n  ") }
    out.append("]\n}\n")
    out.toString()
}

private func searchDeclarationKeywordMatches(token: HtmlSignatureToken,
    symbolKind: String): Bool {
    match (symbolKind) {
        case "function" => token.kind == "FUNC"
        case "class" => token.kind == "CLASS"
        case "struct" => token.kind == "STRUCT"
        case "interface" => token.kind == "INTERFACE"
        case "enum" => token.kind == "ENUM"
        case "typeAlias" => token.kind == "TYPE" || token.kind == "TYPE_ALIAS" ||
            token.kind == "TYPEALIAS"
        case "property" => token.kind == "LET" || token.kind == "VAR" || token.kind == "PROP"
        case "variable" => token.kind == "LET" || token.kind == "VAR"
        case _ => false
    }
}

private func searchDeclarationIdentifier(symbol: SymbolDoc): ?HtmlSignatureToken {
    let tokens = alignedSignatureTokens(symbol)
    if (tokens.size < 2) { return None }
    for (index in 1..tokens.size) {
        let candidate = tokens[index]
        if (candidate.kind == "IDENTIFIER" && candidate.value == symbol.name &&
            searchDeclarationKeywordMatches(tokens[index - 1], symbol.kind)) {
            return Some(candidate)
        }
    }
    None
}

private func searchSignatureForExposure(symbol: SymbolDoc, exposedName: String): String {
    let signature = symbol.headerSpelling
    if (exposedName == symbol.name) { return signature }
    if (signature.isEmpty()) { return exposedName }
    if (symbol.sourceApiSignature.state != "available") {
        return "${exposedName}: ${signature}"
    }
    match (searchDeclarationIdentifier(symbol)) {
        case Some(declaration) => signature[..declaration.start] + exposedName +
            signature[declaration.end..]
        case None => "${exposedName}: ${signature}"
    }
}

internal func renderSearchSignatureIndex(documentation: DocumentationSet,
    projection: RenderProjection): String {
    let visible = ArrayList<SymbolDoc>(projection.visibleSymbols.toArray())
    sort(visible, lessThan: { left, right => left.id < right.id }, stable: true)
    let out = RenderTextBuffer()
    out.append("{")
    var first = true
    for (symbol in visible) {
        if (!first) { out.append(",") }
        first = false
        appendSearchJsonString(out, symbol.id)
        out.append(":")
        appendSearchJsonString(out, searchTextExcerpt(symbol.headerSpelling, maximum: 512))
    }
    for (pkg in documentation.packages) {
        for (reExport in pkg.reExports) {
            for (binding in reExport.bindings) {
                for (targetId in binding.targetSymbolIds) {
                    match (projection.visibleIndex.get(targetId)) {
                        case Some(target) =>
                            if (!first) { out.append(",") }
                            first = false
                            appendSearchJsonString(out,
                                "${reExport.id}:${binding.exposedName}:${target.id}")
                            out.append(":")
                            appendSearchJsonString(out, searchTextExcerpt(
                                searchSignatureForExposure(target, binding.exposedName), maximum: 512))
                        case None => ()
                    }
                }
            }
        }
    }
    out.append("}")
    out.toString()
}

internal func renderSearchIndexScript(searchIndex: String, signatures: String): String {
    let out = RenderTextBuffer()
    out.append("globalThis.__CJDOC_SEARCH_INDEX__ = ")
    out.append(searchIndex.trimAscii())
    out.append(";\nglobalThis.__CJDOC_SEARCH_SIGNATURES__ = ")
    out.append(signatures.trimAscii())
    out.append(";\n")
    out.toString()
}
