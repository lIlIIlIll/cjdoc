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

private func appendSymbolIndexRelations(out: RenderTextBuffer, symbol: SymbolDoc): Unit {
    out.append(",\"relations\":[")
    var first = true
    for (relation in symbol.symbolRelationships) {
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

private func appendSymbolIndexReferences(out: RenderTextBuffer, symbol: SymbolDoc): Unit {
    out.append(",\"references\":[")
    var first = true
    match (symbol.documentation) {
        case Some(comment) =>
            for (tag in comment.tags) {
                if (tag.name != "see") { continue }
                if (!first) { out.append(",") }
                first = false
                out.append("{\"subject\":")
                appendSearchJsonString(out, tag.subject)
                out.append(",\"description\":")
                appendSearchJsonString(out, tag.description)
                out.append(",\"state\":")
                appendSearchJsonString(out, tag.referenceState)
                out.append(",\"targetId\":")
                appendSymbolIndexNullableId(out, tag.targetSymbolId)
                out.append("}")
            }
        case None => ()
    }
    out.append("]")
}

internal func renderSymbolIndex(documentation: DocumentationSet): String {
    validateTypedDocumentationSet(documentation)
    let projection = RenderProjection(documentation)
    let symbols = ArrayList<SymbolDoc>(projection.visibleSymbols.toArray())
    sort(symbols, lessThan: { left, right => left.id < right.id }, stable: true)
    let out = RenderTextBuffer()
    out.append("{\n  \"schemaVersion\": \"cjdoc.symbol-index/1\",\n  \"project\": {\"name\": ")
    appendSearchJsonString(out, documentation.project.name)
    out.append(", \"audience\": ")
    appendSearchJsonString(out, documentation.configuration.audience)
    out.append("},\n  \"entries\": [")
    var first = true
    for (symbol in symbols) {
        if (!first) { out.append(",") }
        first = false
        out.append("\n    {\"id\":")
        appendSearchJsonString(out, symbol.id)
        out.append(",\"canonicalId\":")
        appendSearchJsonString(out, symbol.id)
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
        out.append(",\"summary\":")
        match (symbol.documentation) {
            case Some(comment) => appendSearchJsonString(out, comment.summary)
            case None => out.append("\"\"")
        }
        out.append(",\"source\":")
        appendSymbolIndexSource(out, symbol.source)
        out.append(",\"href\":")
        appendSearchJsonString(out, "html/${symbolUrl(projection.visibleIndex, symbol)}")
        appendSymbolIndexRelations(out, symbol)
        appendSymbolIndexReferences(out, symbol)
        out.append("}")
    }
    if (!first) { out.append("\n  ") }
    out.append("]\n}\n")
    out.toString()
}

internal func appendSymbolIndexArtifacts(artifacts: RenderArtifactCollector,
    documentation: DocumentationSet): Unit {
    artifacts.addText("symbol-index/symbol-index.json", "application/json",
        renderSymbolIndex(documentation))
}

public class SymbolIndexDocumentationRenderer <: DocumentationRenderer {
    public prop format: String { get() { "symbol-index" } }

    public func render(documentation: DocumentationSet): Array<RenderArtifact> {
        let artifacts = RenderArtifactCollector()
        appendSymbolIndexArtifacts(artifacts, documentation)
        artifacts.toArray()
    }
}
