package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.sort.*

private func appendSymbolIndexNullableId(out: RenderTextBuffer, value: ?String): Unit {
    match (value) {
        case Some(id) => appendSearchJsonString(out, id)
        case None => out.append("null")
    }
}

private func appendSymbolIndexSource(out: RenderTextBuffer, source: SourceRange): Unit {
    out.append("{\"path\":")
    appendSearchJsonString(out, source.path)
    out.append(",\"start\":{\"line\":${source.start.line},\"column\":${source.start.column},\"byteOffset\":${source.start.byteOffset}}")
    out.append(",\"end\":{\"line\":${source.end.line},\"column\":${source.end.column},\"byteOffset\":${source.end.byteOffset}}}")
}

private func appendSymbolIndexRelations(out: RenderTextBuffer, symbol: SymbolDoc,
    visibleIndex: HashMap<String, SymbolDoc>): Unit {
    out.append(",\"relations\":[")
    var first = true
    for (relation in symbol.symbolRelationships) {
        match (relation.targetSymbolId) {
            case Some(targetId) => if (!visibleIndex.contains(targetId)) { continue }
            case None => ()
        }
        if (!first) { out.append(",") }
        first = false
        out.append("{\"kind\":")
        appendSearchJsonString(out, relation.kind)
        out.append(",\"display\":")
        appendSearchJsonString(out, relation.targetDisplay)
        out.append(",\"state\":")
        appendSearchJsonString(out, relation.state)
        out.append(",\"targetId\":")
        appendSymbolIndexNullableId(out, relation.targetSymbolId)
        out.append("}")
    }
    out.append("]")
}

private func appendSymbolIndexReferences(out: RenderTextBuffer, symbol: SymbolDoc,
    visibleIndex: HashMap<String, SymbolDoc>, hrefPrefix: String): Unit {
    out.append(",\"references\":[")
    var first = true
    match (symbol.documentation) {
        case Some(comment) =>
            for (tag in comment.tags) {
                if (tag.name != "see") { continue }
                match (tag.targetSymbolId) {
                    case Some(targetId) => if (!visibleIndex.contains(targetId)) { continue }
                    case None => ()
                }
                if (!first) { out.append(",") }
                first = false
                out.append("{\"subject\":")
                appendSearchJsonString(out, tag.subject)
                out.append(",\"description\":")
                appendSearchJsonString(out, documentationTagPlainText(tag))
                out.append(",\"state\":")
                appendSearchJsonString(out, tag.referenceState)
                out.append(",\"targetId\":")
                appendSymbolIndexNullableId(out, tag.targetSymbolId)
                out.append(",\"navigation\":"); appendInventoryNavigation(out, tag.navigation, hrefPrefix)
                out.append("}")
            }
        case None => ()
    }
    out.append("]")
}

internal func renderSymbolIndex(documentation: DocumentationSet, hrefPrefix!: String = "html/", version!: ?String = None): String {
    validateTypedDocumentationSet(documentation)
    let projection = RenderProjection(documentation)
    let identities = SymbolInventoryIdentity(documentation, publicationRevision: version)
    let symbols = ArrayList<SymbolDoc>(projection.visibleSymbols.toArray())
    sort(symbols, lessThan: { left, right => left.id < right.id }, stable: true)
    let out = RenderTextBuffer()
    out.append("{\n  \"schemaVersion\": \"cjdoc.symbol-index/2\",\n  \"project\": {\"name\": ")
    appendSearchJsonString(out, documentation.project.name)
    out.append(", \"audience\": ")
    appendSearchJsonString(out, documentation.configuration.audience)
    out.append("}")
    match (version) {
        case Some(value) =>
            out.append(",\n  \"version\": ")
            appendSearchJsonString(out, value)
        case None => ()
    }
    appendInventoryMetadata(out, documentation, identities)
    out.append(",\n  \"entries\": [")
    var first = true
    for (symbol in symbols) {
        if (!first) { out.append(",") }
        first = false
        out.append("\n    {\"id\":")
        appendSearchJsonString(out, symbol.id)
        out.append(",\"canonicalId\":")
        appendSearchJsonString(out, symbol.id)
        out.append(",\"identity\":")
        let documentSet = identities.byModule.get(symbol.moduleId)
        appendSearchJsonString(out, documentSet.map({ value => value.identity }).getOrDefault({ => "" }))
        out.append(",\"documentSetId\":")
        appendSearchJsonString(out, documentSet.map({ value => value.id }).getOrDefault({ => "" }))
        out.append(",\"symbolKey\":")
        appendSearchJsonString(out, symbolInventoryKey(symbol))
        out.append(",\"name\":")
        appendSearchJsonString(out, symbol.name)
        out.append(",\"qualifiedName\":")
        appendSearchJsonString(out, symbol.qualifiedName)
        out.append(",\"kind\":")
        appendSearchJsonString(out, symbol.kind)
        out.append(",\"moduleId\":")
        appendSearchJsonString(out, symbol.moduleId)
        out.append(",\"packageName\":")
        appendSearchJsonString(out, symbol.packageName)
        out.append(",\"ownerId\":")
        appendSymbolIndexNullableId(out, symbol.ownerId)
        out.append(",\"visibility\":")
        appendSearchJsonString(out, symbol.visibility)
        out.append(",\"semanticState\":")
        appendSearchJsonString(out, symbol.semantic.state)
        out.append(",\"sourceHeader\":")
        appendSearchJsonString(out, symbol.headerSpelling)
        out.append(",\"summary\":")
        match (symbol.documentation) {
            case Some(comment) => appendSearchJsonString(out, summaryPlainText(comment))
            case None => out.append("\"\"")
        }
        out.append(",\"source\":")
        appendSymbolIndexSource(out, symbol.source)
        out.append(",\"href\":")
        appendSearchJsonString(out, hrefPrefix + symbolUrl(projection.visibleIndex, symbol))
        appendSymbolIndexRelations(out, symbol, projection.visibleIndex)
        appendSymbolIndexReferences(out, symbol, projection.visibleIndex, hrefPrefix)
        appendInventoryTypeNavigations(out, symbol, hrefPrefix)
        out.append("}")
    }
    if (!first) { out.append("\n  ") }
    out.append("]\n}\n")
    out.toString()
}

internal func appendSymbolIndexArtifacts(artifacts: RenderArtifactCollector,
    documentation: DocumentationSet, version!: ?String = None): Unit {
    artifacts.addText("symbol-index/symbol-index.json", "application/json",
        renderSymbolIndex(documentation, version: version))
}

public class SymbolIndexDocumentationRenderer <: DocumentationRenderer {
    public prop format: String { get() { "symbol-index" } }

    public func render(documentation: DocumentationSet): Array<RenderArtifact> {
        let artifacts = RenderArtifactCollector()
        let locale = documentation.readingLanguage.getOrDefault({ => "en" })
        appendSymbolIndexArtifacts(artifacts, projectDocumentationLanguage(documentation, locale))
        artifacts.toArray()
    }
}
