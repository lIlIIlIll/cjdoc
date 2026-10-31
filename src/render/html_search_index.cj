package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.sort.*

// The index is emitted both as standalone JSON and inline inside a <script>
// element. `<`, `>` and `&` become JSON string escapes so a value containing
// `</script>` or `<script>` can never terminate the element or execute: the
// client decodes them back to the original characters before matching.
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
            case '<' => out.append("\\u003c")
            case '>' => out.append("\\u003e")
            case '&' => out.append("\\u0026")
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

internal func searchTextExcerpt(value: String, maximum!: Int64): String {
    if (maximum <= 0) { return "" }
    let out = RenderTextBuffer()
    var count: Int64 = 0
    var pending: ?Rune = None
    for (rune in value.runes()) {
        if (count < maximum - 1) {
            out.append(rune)
            count++
        } else if (count == maximum - 1) {
            pending = Some(rune)
            count++
        } else {
            out.append("…")
            return out.toString()
        }
    }
    if (let Some(last) <- pending) { out.append(last) }
    out.toString()
}

internal func appendOptionalSearchString(out: RenderTextBuffer, value: ?String): Unit {
    match (value) {
        case Some(text) => appendSearchJsonString(out, text)
        case None => out.append("null")
    }
}
private func appendSearchDocumentSetIdentity(out: RenderTextBuffer,
    value: ?DocumentSetIdentity): Unit {
    match (value) {
        case Some(identity) =>
            out.append("{\"id\":"); appendSearchJsonString(out, identity.id)
            out.append(",\"moduleId\":"); appendSearchJsonString(out, identity.moduleId)
            out.append(",\"library\":"); appendSearchJsonString(out, identity.library)
            out.append(",\"identity\":"); appendSearchJsonString(out, identity.identity)
            out.append(",\"state\":"); appendSearchJsonString(out, identity.state)
            out.append(",\"source\":"); appendSearchJsonString(out, identity.source)
            out.append(",\"target\":"); appendSearchJsonString(out, identity.target)
            out.append(",\"cfg\":"); appendSearchJsonString(out, identity.cfg)
            out.append(",\"audience\":"); appendSearchJsonString(out, identity.audience)
            out.append(",\"language\":"); appendSearchJsonString(out, identity.language)
            out.append(",\"revision\":"); appendSearchJsonString(out, identity.revision)
            out.append(",\"apiVersion\":"); appendSearchJsonString(out, identity.apiVersion)
            out.append(",\"documentationRevision\":"); appendSearchJsonString(out, identity.documentationRevision)
            out.append(",\"indexIdentity\":"); appendSearchJsonString(out, identity.indexIdentity)
            out.append(",\"baseUrl\":"); appendSearchJsonString(out, identity.baseUrl)
            out.append("}")
        case None => out.append("null")
    }
}

private func appendSearchDependencyIdentity(out: RenderTextBuffer,
    value: ?DependencyInstance): Unit {
    match (value) {
        case Some(dependency) =>
            out.append("{\"moduleId\":"); appendSearchJsonString(out, dependency.moduleId)
            out.append(",\"componentModuleId\":"); appendSearchJsonString(out, dependency.componentModuleId)
            out.append(",\"name\":"); appendSearchJsonString(out, dependency.name)
            out.append(",\"instanceId\":"); appendSearchJsonString(out, dependency.instanceId)
            out.append(",\"kind\":"); appendSearchJsonString(out, dependency.kind)
            out.append(",\"identity\":"); appendSearchJsonString(out, dependency.identity)
            out.append(",\"state\":"); appendSearchJsonString(out, dependency.state)
            out.append(",\"evidence\":"); appendSearchJsonString(out, dependency.evidence)
            out.append(",\"version\":"); appendSearchJsonString(out, dependency.version)
            out.append(",\"revision\":"); appendSearchJsonString(out, dependency.revision)
            out.append(",\"target\":"); appendSearchJsonString(out, dependency.target)
            out.append(",\"cfg\":"); appendSearchJsonString(out, dependency.cfg)
            out.append("}")
        case None => out.append("null")
    }
}

private func appendSearchPageNavigation(out: RenderTextBuffer, value: ?TypeNavigation): Unit {
    match (value) {
        case Some(navigation) =>
            if (contextFreeNavigationFailure(navigation)) {
                out.append("[")
                appendSearchJsonString(out, navigation.state)
                out.append(",")
                appendSearchJsonString(out, navigation.reason)
                out.append("]")
                return
            }
            out.append("{\"state\":"); appendSearchJsonString(out, navigation.state)
            out.append(",\"matchLevel\":"); appendSearchJsonString(out, navigation.matchLevel)
            out.append(",\"reason\":"); appendSearchJsonString(out, navigation.reason)
            out.append(",\"dependencyInstanceId\":")
            appendSearchJsonString(out, navigation.dependencyInstanceId)
            out.append(",\"documentSetId\":"); appendSearchJsonString(out, navigation.documentSetId)
            out.append(",\"indexIdentity\":"); appendSearchJsonString(out, navigation.indexIdentity)
            out.append(",\"symbolKey\":"); appendSearchJsonString(out, navigation.symbolKey)
            out.append(",\"url\":"); appendSearchJsonString(out, navigation.url)
            out.append(",\"apiIdentity\":"); appendSearchJsonString(out, navigation.apiIdentity)
            out.append(",\"language\":"); appendSearchJsonString(out, navigation.language)
            out.append("}")
        case None => out.append("null")
    }
}

private func appendSearchProjectedBindings(out: RenderTextBuffer,
    bindings: ArrayList<SearchPageBinding>): Unit {
    out.append("[")
    var first = true
    for (binding in bindings) {
        if (!first) { out.append(",") }
        first = false
        out.append("{\"target\":"); appendSearchJsonString(out, binding.target)
        out.append(",\"selector\":"); appendSearchJsonString(out, binding.selector)
        out.append(",\"provenance\":"); appendSearchJsonString(out, binding.provenance)
        out.append(",\"version\":"); appendSearchJsonString(out, binding.version)
        out.append(",\"sourceLine\":${binding.sourceLine},\"language\":")
        appendSearchJsonString(out, binding.language)
        out.append(",\"state\":"); appendSearchJsonString(out, binding.state)
        out.append(",\"targetSymbolId\":"); appendOptionalSearchString(out, binding.targetSymbolId)
        out.append(",\"href\":"); appendOptionalSearchString(out, binding.href)
        out.append(",\"navigationTitle\":"); appendSearchJsonString(out, binding.navigationTitle)
        out.append(",\"navigation\":"); appendSearchPageNavigation(out, binding.navigation)
        out.append("}")
    }
    out.append("]")
}



private func appendSearchClassification(out: RenderTextBuffer,
    value: DeclarationClassification): Unit {
    out.append("{\"group\":")
    match (value.group) {
        case Some(group) =>
            out.append("{\"id\":"); appendSearchJsonString(out, group.id)
            out.append(",\"packageName\":"); appendSearchJsonString(out, group.packageName)
            out.append(",\"ownerId\":"); appendOptionalSearchString(out, group.ownerId)
            out.append(",\"title\":"); appendSearchJsonString(out, group.title)
            out.append(",\"order\":")
            match (group.order) {
                case Some(order) => out.append(order.toString())
                case None => out.append("null")
            }
            out.append("}")
        case None => out.append("null")
    }
    out.append(",\"tags\":[")
    var first = true
    for (tag in value.tags) {
        if (!first) { out.append(",") }
        first = false
        out.append("{\"id\":"); appendSearchJsonString(out, tag.id)
        out.append(",\"title\":"); appendSearchJsonString(out, tag.title)
        out.append("}")
    }
    out.append("]}")
}

/**
 * Serialize the bounded-static projection captured and shared with Agent output.
 * The exact public search contract is embedded so the browser consumes the same
 * field mapping, rank rows and limits as the native executor.
 */
internal func renderSearchIndex(snapshot: DocumentationReadSnapshot): String {
    let built = buildDocumentationSearchProjection(snapshot, searchStaticProfileName())
    let out = RenderTextBuffer()
    out.append("{\n  \"schemaVersion\": \"cjdoc.search-index/11\",\n  \"profile\": ")
    appendSearchJsonString(out, built.profile)
    out.append(",\n  \"contract\": ")
    out.append(searchContractJson())
    out.append(",\n  \"projectionId\": ")
    appendSearchJsonString(out, built.contentId)
    out.append(",\n  \"scope\": {\"snapshotId\": ")
    appendSearchJsonString(out, built.scopeSnapshotId)
    out.append(", \"sourceSnapshotId\": ")
    appendSearchJsonString(out, built.sourceSnapshotId)
    out.append(", \"publicationRevision\": ")
    appendSearchJsonString(out, built.publicationRevision)
    out.append(", \"project\": "); appendSearchJsonString(out, built.project)
    out.append(", \"language\": "); appendSearchJsonString(out, built.language)
    out.append(", \"audience\": "); appendSearchJsonString(out, built.audience)
    out.append(", \"cfgProfile\": "); appendSearchJsonString(out, built.cfgProfile)
    out.append(", \"apiCollectionState\": ")
    appendSearchJsonString(out, built.apiCollectionState)
    out.append("},\n  \"coverage\": {\"profile\": ")
    appendSearchJsonString(out, built.profile)
    out.append(", \"projectionId\": "); appendSearchJsonString(out, built.contentId)
    out.append(", \"bodyTextLimit\": ")
    match (built.bodyTextLimit) {
        case Some(value) => out.append(value.toString())
        case None => out.append("null")
    }
    out.append(", \"bodyComplete\": "); out.append(built.bodyComplete.toString())
    out.append(", \"truncatedEntries\": "); out.append(built.truncatedCount.toString())
    out.append("},\n  \"modules\": [")
    var firstModule = true
    for (index in 0..built.modules.size) {
        if (!firstModule) { out.append(",") }
        firstModule = false
        let module = built.modules[index]
        out.append("\n    {\"moduleId\": "); appendSearchJsonString(out, module.moduleId)
        out.append(", \"moduleName\": "); appendOptionalSearchString(out, module.moduleName)
        out.append(", \"documentSet\": ")
        appendSearchDocumentSetIdentity(out, module.documentSet)
        out.append(", \"dependency\": ")
        appendSearchDependencyIdentity(out, module.dependency)
        out.append(", \"dependencyInstanceState\": ")
        appendSearchJsonString(out, module.dependencyState)
        out.append("}")
    }
    if (!firstModule) { out.append("\n  ") }
    out.append("],\n  \"tags\": [")
    var firstTag = true
    for (tag in built.tagDictionary) {
        if (!firstTag) { out.append(",") }
        firstTag = false
        out.append("{\"scope\":${tag.scope},\"id\":")
        appendSearchJsonString(out, tag.id)
        out.append(",\"title\":"); appendSearchJsonString(out, tag.title)
        out.append("}")
    }
    out.append("],\n  \"entries\": [")
    var first = true
    for (entry in built.entries) {
        if (!first) { out.append(",") }
        first = false
        out.append("\n    {\"id\": "); appendSearchJsonString(out, entry.id)
        out.append(", \"canonicalId\": "); appendSearchJsonString(out, entry.canonicalId)
        out.append(", \"snapshotId\": "); appendSearchJsonString(out, entry.snapshotId)
        out.append(", \"scope\": "); out.append(entry.scope.toString())
        out.append(", \"concept\": "); out.append(entry.concept.toString())
        out.append(", \"genericArity\": "); out.append(entry.genericArity.toString())
        out.append(", \"ownerId\": "); appendOptionalSearchString(out, entry.ownerId)
        out.append(", \"name\": "); appendSearchJsonString(out, entry.name)
        out.append(", \"packageName\": ")
        appendOptionalSearchString(out, if (entry.concept) { None } else { Some(entry.packageName) })
        out.append(", \"qualifiedName\": ")
        appendOptionalSearchString(out, if (entry.concept) { None } else { Some(entry.qualifiedName) })
        out.append(", \"kind\": "); appendSearchJsonString(out, entry.kind)
        out.append(", \"ownerName\": ")
        appendOptionalSearchString(out, if (entry.ownerName.isEmpty()) { None } else { Some(entry.ownerName) })
        out.append(", \"ownerQualifiedName\": ")
        appendOptionalSearchString(out,
            if (entry.ownerQualifiedName.isEmpty()) { None } else { Some(entry.ownerQualifiedName) })
        out.append(", \"symbolKey\": ")
        appendOptionalSearchString(out, if (entry.symbolKey.isEmpty()) { None } else { Some(entry.symbolKey) })
        out.append(", \"parameterTypes\": [")
        var firstParameter = true
        for (parameter in entry.parameterTypes) {
            if (!firstParameter) { out.append(",") }
            firstParameter = false
            appendSearchJsonString(out, parameter)
        }
        out.append("], \"returnType\": ")
        appendOptionalSearchString(out, if (entry.returnType.isEmpty()) { None } else { Some(entry.returnType) })
        out.append(", \"returnCanonical\": ")
        appendOptionalSearchString(out,
            if (entry.returnCanonical.isEmpty()) { None } else { Some(entry.returnCanonical) })
        out.append(", \"summary\": "); appendSearchJsonString(out, entry.summary)
        out.append(", \"summaryDisplay\": ")
        appendSearchJsonString(out, searchTextExcerpt(entry.summary, maximum: built.summaryDisplayLimit))
        out.append(", \"body\": "); appendSearchJsonString(out, entry.body)
        out.append(", \"bodyTruncated\": "); out.append(entry.bodyTruncated.toString())
        out.append(", \"classification\": "); appendSearchClassification(out, entry.classification)
        out.append(", \"href\": "); appendSearchJsonString(out, entry.href)
        out.append(", \"exposures\": [")
        var firstExposure = true
        for (exposure in entry.exposures) {
            if (!firstExposure) { out.append(",") }
            firstExposure = false
            out.append("{\"id\": "); appendSearchJsonString(out, exposure.id)
            out.append(", \"name\": "); appendSearchJsonString(out, exposure.name)
            out.append(", \"qualifiedName\": "); appendSearchJsonString(out, exposure.qualifiedName)
            out.append(", \"packageName\": "); appendSearchJsonString(out, exposure.packageName)
            out.append(", \"scope\": "); out.append(exposure.scope.toString())
            out.append("}")
        }
        out.append("], \"externalDocs\": [")
        var firstExternal = true
        for (reference in entry.externalDocs) {
            if (!firstExternal) { out.append(",") }
            firstExternal = false
            out.append("{\"name\": "); appendSearchJsonString(out, reference.name)
            out.append(", \"state\": "); appendSearchJsonString(out, reference.state)
            out.append(", \"url\": "); appendSearchJsonString(out, reference.url)
            out.append(", \"reason\": "); appendSearchJsonString(out, reference.reason)
            out.append(", \"version\": "); appendSearchJsonString(out, reference.version)
            out.append(", \"index\": "); appendSearchJsonString(out, reference.index)
            out.append(", \"format\": "); appendSearchJsonString(out, reference.format)
            out.append(", \"fingerprint\": "); appendSearchJsonString(out, reference.fingerprint)
            out.append("}")
        }
        out.append("], \"bindings\": ")
        appendSearchProjectedBindings(out, entry.pageBindings)
        out.append(", \"sections\": [")
        var firstSection = true
        for (section in entry.sections) {
            if (!firstSection) { out.append(",") }
            firstSection = false
            out.append("{\"kind\": "); appendSearchJsonString(out, section.kind)
            out.append(", \"anchor\": "); appendSearchJsonString(out, section.anchor)
            out.append(", \"text\": "); appendSearchJsonString(out, section.text)
            out.append("}")
        }
        out.append("]}")
    }
    if (!first) { out.append("\n  ") }
    out.append("]\n}\n")
    out.toString()
}

private func searchDeclarationKeywordMatches(token: HtmlSignatureToken,
    symbolKind: String): Bool {
    match (symbolKind) {
        case "function" => token.kind == "FUNC"
        case "macro" => token.kind == "MACRO"
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
    let signatureDisplayLimit = searchContractLimits().signatureDisplayLimit
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
        appendSearchJsonString(out, searchTextExcerpt(symbol.headerSpelling,
            maximum: signatureDisplayLimit))
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
                                searchSignatureForExposure(target, binding.exposedName),
                                maximum: signatureDisplayLimit))
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
