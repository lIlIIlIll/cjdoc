protected package cjdoc.source.frontend

import cjdoc.source.model.{SourceImportItem, SourceReExport}
import cjdoc.source.{SourceLocation, joinedImportPath}
import cjdoc.source.lexing.{sourceLexerTokens, IndexedSourceBuffer}
import std.ast.*
import std.collection.*

internal func importKindName(kind: ImportKind): String {
    match (kind) {
        case ImportKind.Single => "single"
        case ImportKind.Alias => "alias"
        case ImportKind.All => "all"
        case ImportKind.Multi => "multi"
    }
}

protected func importAliasName(tokens: Tokens): ?String {
    var index = tokens.size
    while (index > 0) {
        index--
        let value = tokens[index].value
        if (!value.isEmpty() && value != "as") { return Some(value) }
    }
    None
}

protected func importPrefixPaths(tokens: Tokens): Array<String> {
    let result = ArrayList<String>()
    for (token in tokens) {
        if (!token.value.isEmpty()) { result.add(token.value) }
    }
    result.toArray()
}

internal func importLocation(path: String, value: ImportList): ?SourceLocation {
    let tokens = value.toTokens()
    if (tokens.size == 0) { return None }
    var first: Int64 = 0
    while (first < tokens.size && (tokens[first].value.isEmpty() || tokens[first].kind == NL)) { first++ }
    if (first >= tokens.size) { return None }
    var last = tokens.size
    while (last > first && (tokens[last - 1].value.isEmpty() || tokens[last - 1].kind == NL)) { last-- }
    if (last <= first) { return None }
    let endToken = tokens[last - 1]
    if (endToken.pos.line <= 0 || endToken.pos.column <= 0) { return None }
    let (endLine, endColumn) = tokenEndPosition(endToken)
    Some(SourceLocation(path, Int64(tokens[first].pos.line), Int64(tokens[first].pos.column),
        endLine, endColumn))
}

internal func collectPublicReExports(program: Program, path: String,
    packageName: String, moduleId: String, source: IndexedSourceBuffer): Array<SourceReExport> {
    let result = ArrayList<SourceReExport>()
    for (importList in program.importLists) {
        if (importList.modifier.value != "public") { continue }
        let location = match (importLocation(path, importList)) {
            case Some(value) => value
            case None => continue
        }
        let content = importList.content
        let items = ArrayList<SourceImportItem>()
        for (item in content.items) {
            if (item.identifier.value.isEmpty()) { continue }
            items.add(SourceImportItem(item.identifier.value,
                alias: importAliasName(item.importAlias)))
        }
        let sourceText = source.slice(location).trimAscii()
        let normalizedSpec = if (sourceText.startsWith("public ")) {
            sourceText.removePrefix("public ").trimAscii()
        } else {
            sourceText
        }
        result.add(SourceReExport(importKindName(content.importKind),
            if (content.orgName.value.isEmpty()) { None } else { Some(content.orgName.value) },
            content.identifier.value, importAliasName(content.importAlias), location,
            normalizedSpec, packageName, moduleId,
            prefixPaths: importPrefixPaths(content.prefixPaths), items: items.toArray()))
    }
    result.toArray()
}

private func qualifiedPackageImportPath(organization: String, packagePath: String): String {
    if (organization.isEmpty()) { return packagePath }
    organization + "::" + packagePath
}

internal func collectImportedPackagePaths(program: Program): Array<String> {
    let result = ArrayList<String>()
    for (importList in program.importLists) {
        let content = importList.content
        let prefix = ArrayList<String>(importPrefixPaths(content.prefixPaths))
        let packagePath = match (content.importKind) {
            case ImportKind.Alias =>
                if (content.identifier.value.isEmpty()) { joinedImportPath(prefix) } else {
                    joinedImportPath(prefix, tail: Some(content.identifier.value))
                }
            case _ => joinedImportPath(prefix)
        }
        let qualifiedPath = qualifiedPackageImportPath(content.orgName.value, packagePath)
        if (!packagePath.isEmpty() && !result.contains(qualifiedPath)) {
            result.add(qualifiedPath)
        }
    }
    result.toArray()
}

internal func collectImports(program: Program, path: String,
    source: IndexedSourceBuffer): Array<String> {
    let imports = ArrayList<String>()
    for (importList in program.importLists) {
        let location = match (importLocation(path, importList)) {
            case Some(value) => value
            case None => continue
        }
        let text = source.slice(location).trimAscii()
        if (!text.isEmpty()) { imports.add(text) }
    }
    imports.toArray()
}

private func sourceImportStatementEnd(tokens: Tokens, importIndex: Int64): Int64 {
    var index = importIndex
    var lastIndex = importIndex
    var braceDepth: Int64 = 0
    while (index < tokens.size) {
        let token = tokens[index]
        if (braceDepth == 0 && token.kind == NL) { return lastIndex }
        if (braceDepth == 0 && token.value == ";") { return lastIndex }
        match (token.kind) {
            case LCURL => braceDepth++
            case RCURL => if (braceDepth > 0) { braceDepth-- }
            case _ => ()
        }
        if (token.kind != NL && token.kind != COMMENT && !token.value.isEmpty()) {
            lastIndex = index
        }
        index++
    }
    lastIndex
}

private func sourceImportStart(tokens: Tokens, importIndex: Int64): Int64 {
    var index = importIndex
    while (index > 0) {
        index--
        let token = tokens[index]
        if (token.kind == NL || token.kind == COMMENT || token.value.isEmpty()) { continue }
        match (token.value) {
            case "public" | "protected" | "internal" | "private" => return index
            case _ => return importIndex
        }
    }
    importIndex
}

private func previousImportToken(tokens: Tokens, before: Int64): Int64 {
    var index = before
    while (index > 0) {
        index--
        let token = tokens[index]
        if (token.kind != NL && token.kind != COMMENT && !token.value.isEmpty()) { return index }
    }
    -1
}

private func conditionalSourceImportStart(tokens: Tokens, importIndex: Int64): Int64 {
    var start = sourceImportStart(tokens, importIndex)
    var before = start
    while (before > 0) {
        var opening = previousImportToken(tokens, before)
        if (opening < 0 || tokens[opening].kind != RSQUARE) { break }
        var squareDepth: Int64 = 1
        while (opening > 0 && squareDepth > 0) {
            opening--
            match (tokens[opening].kind) {
                case RSQUARE => squareDepth++
                case LSQUARE => squareDepth--
                case _ => ()
            }
        }
        if (squareDepth != 0) { break }
        let name = previousImportToken(tokens, opening)
        if (name < 0 || tokens[name].kind != IDENTIFIER || tokens[name].value != "When") { break }
        let annotation = previousImportToken(tokens, name)
        if (annotation < 0 || tokens[annotation].kind != AT) { break }
        start = annotation
        before = start
    }
    start
}

protected func sourceImportTextsFromSource(path: String, source: String,
    includeWhen: Bool): ArrayList<String> {
    let tokens = sourceLexerTokens(source)
    let sourceIndex = IndexedSourceBuffer(source)
    let imports = ArrayList<String>()
    var declarationDepth: Int64 = 0
    var index: Int64 = 0
    while (index < tokens.size) {
        let token = tokens[index]
        if (declarationDepth == 0 && token.kind == IMPORT) {
            let start = if (includeWhen) { conditionalSourceImportStart(tokens, index) } else {
                sourceImportStart(tokens, index)
            }
            let first = tokens[start]
            let importEnd = sourceImportStatementEnd(tokens, index)
            let last = tokens[importEnd]
            if (first.pos.line <= 0 || first.pos.column <= 0 ||
                last.pos.line <= 0 || last.pos.column <= 0) {
                throw IllegalArgumentException("source import has invalid token positions")
            }
            let (endLine, endColumn) = tokenEndPosition(last)
            let location = match (sourceLocationFromAstRange(path, sourceIndex,
                Int64(first.pos.line), Int64(first.pos.column), endLine, endColumn)) {
                case Some(value) => value
                case None => throw IllegalArgumentException("source import range is invalid")
            }
            let text = sourceIndex.slice(location).trimAscii()
            if (text.isEmpty()) { throw IllegalArgumentException("source import is empty") }
            imports.add(text)
            index = importEnd + 1
            continue
        }
        match (token.kind) {
            case LCURL => declarationDepth++
            case RCURL => if (declarationDepth > 0) { declarationDepth-- }
            case _ => ()
        }
        index++
    }
    imports
}

