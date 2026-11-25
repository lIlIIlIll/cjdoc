protected package cjdoc.source.frontend

import cjdoc.source.joinedImportPath
import cjdoc.source.model.{SourceImportFacts, SourceImportItem}
import cjdoc.source.lexing.sourceLexerTokens
import std.ast.*
import std.collection.*

// std.ast already resolves modifiers, whitespace, comments, aliases and `{...}`
// lists. Projecting those fields instead of re-parsing statement text is what
// keeps legal spellings from changing the selected package.
private func importFactsItems(content: ImportContent): Array<SourceImportItem> {
    let result = ArrayList<SourceImportItem>()
    for (item in content.items) {
        if (item.identifier.value.isEmpty()) { continue }
        let segments = ArrayList<String>(importPrefixPaths(item.prefixPaths))
        segments.add(item.identifier.value)
        result.add(SourceImportItem(joinedImportPath(segments),
            alias: importAliasName(item.importAlias)))
    }
    result.toArray()
}

internal func sourceImportFacts(importList: ImportList, path: String): SourceImportFacts {
    let content = importList.content
    SourceImportFacts(importList.modifier.value, importKindName(content.importKind),
        content.orgName.value,
        prefixPaths: importPrefixPaths(content.prefixPaths),
        member: content.identifier.value,
        alias: importAliasName(content.importAlias),
        items: importFactsItems(content), source: importLocation(path, importList))
}

internal func collectImportFacts(program: Program, path: String): Array<SourceImportFacts> {
    let result = ArrayList<SourceImportFacts>()
    for (importList in program.importLists) {
        result.add(sourceImportFacts(importList, path))
    }
    result.toArray()
}

// Fallback for an origin without captured AST facts: the statement text is
// parsed by std.ast, never by string inspection, so the derived facts are the
// same ones the source parse would report.
protected func sourceImportFactsFromText(path: String, importText: String):
    Array<SourceImportFacts> {
    let program = try {
        parseProgram(sourceLexerTokens(importText))
    } catch (_: Exception) {
        return []
    }
    collectImportFacts(program, path)
}

protected func importFactsCanonicalTexts(facts: Array<SourceImportFacts>): Array<String> {
    let result = ArrayList<String>()
    for (entry in facts) { result.add(entry.canonicalText()) }
    result.toArray()
}
