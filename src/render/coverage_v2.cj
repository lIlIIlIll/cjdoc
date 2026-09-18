package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.sort.*

public class DocumentationCoverageCounts {
    public var symbols: Int64 = 0
    public var documentedSymbols: Int64 = 0
    public var parameters: Int64 = 0
    public var documentedParameters: Int64 = 0
    public var returns: Int64 = 0
    public var documentedReturns: Int64 = 0
    public var throwsDocs: Int64 = 0
    public var documentedThrows: Int64 = 0
    public var examples: Int64 = 0
    public var documentedExamples: Int64 = 0
    public var deprecated: Int64 = 0
    public var documentedDeprecated: Int64 = 0
    public var semanticLinks: Int64 = 0
    public var resolvedSemanticLinks: Int64 = 0
}

public class DocumentationCoverageGroup {
    public let name: String
    public let metrics: DocumentationCoverageCounts

    init(name: String, metrics: DocumentationCoverageCounts) {
        this.name = name
        this.metrics = metrics
    }
}

public class DocumentationCoverageReport {
    public let metrics: DocumentationCoverageCounts
    public let packages: Array<DocumentationCoverageGroup>
    public let modules: Array<DocumentationCoverageGroup>

    init(metrics: DocumentationCoverageCounts, packages: Array<DocumentationCoverageGroup>,
        modules: Array<DocumentationCoverageGroup>) {
        this.metrics = metrics
        this.packages = packages
        this.modules = modules
    }
}

private func coverageV2Tag(comment: DocComment, name: String): Bool {
    for (tag in comment.tags) {
        if (tag.name == name && !tag.description.trimAscii().isEmpty()) { return true }
    }
    false
}

private func coverageV2Node(node: MarkdownNode, counts: DocumentationCoverageCounts): Unit {
    if (node.kind == "semantic_link") {
        counts.semanticLinks++
        match (node.metadata) {
            case Some(metadata) =>
                if (metadata.semanticState == Some("resolved")) { counts.resolvedSemanticLinks++ }
            case None => ()
        }
    }
    for (child in node.children) { coverageV2Node(child, counts) }
}

private func coverageV2Symbol(symbol: SymbolDoc, counts: DocumentationCoverageCounts): Unit {
    counts.symbols++
    match (symbol.documentation) {
        case Some(comment) =>
            if (!comment.summary.trimAscii().isEmpty()) { counts.documentedSymbols++ }
            if (symbol.returnType.isSome() && symbol.returnType.getOrThrow().spelling != "Unit") {
                counts.returns++
                if (coverageV2Tag(comment, "return")) { counts.documentedReturns++ }
            }
            counts.examples++
            if (coverageV2Tag(comment, "example")) { counts.documentedExamples++ }
            for (tag in comment.tags) {
                if (tag.name == "throws") {
                    counts.throwsDocs++
                    if (!tag.description.trimAscii().isEmpty()) { counts.documentedThrows++ }
                }
                if (tag.name == "deprecated") {
                    counts.deprecated++
                    if (!tag.description.trimAscii().isEmpty()) { counts.documentedDeprecated++ }
                }
            }
            for (tag in comment.tags) {
                if (tag.name == "see") {
                    counts.semanticLinks++
                    if (tag.referenceState == "resolved") { counts.resolvedSemanticLinks++ }
                }
            }
            coverageV2Node(comment.markdown, counts)
        case None =>
            counts.examples++
            if (symbol.returnType.isSome() && symbol.returnType.getOrThrow().spelling != "Unit") {
                counts.returns++
            }
    }
    for (parameter in symbol.parameters where !parameter.name.startsWith("_")) {
        counts.parameters++
        match (parameter.documentation) {
            case Some(value) => if (!value.trimAscii().isEmpty()) { counts.documentedParameters++ }
            case None => ()
        }
    }
}

private func coverageV2Metrics(out: RenderTextBuffer, counts: DocumentationCoverageCounts): Unit {
    out.append("{\"symbols\":{\"total\":${counts.symbols},\"documented\":${counts.documentedSymbols},\"percent\":${coveragePercent(counts.documentedSymbols, counts.symbols)}},")
    out.append("\"parameters\":{\"total\":${counts.parameters},\"documented\":${counts.documentedParameters},\"percent\":${coveragePercent(counts.documentedParameters, counts.parameters)}},")
    out.append("\"returns\":{\"total\":${counts.returns},\"documented\":${counts.documentedReturns},\"percent\":${coveragePercent(counts.documentedReturns, counts.returns)}},")
    out.append("\"throws\":{\"total\":${counts.throwsDocs},\"documented\":${counts.documentedThrows},\"percent\":${coveragePercent(counts.documentedThrows, counts.throwsDocs)}},")
    out.append("\"examples\":{\"total\":${counts.examples},\"documented\":${counts.documentedExamples},\"percent\":${coveragePercent(counts.documentedExamples, counts.examples)}},")
    out.append("\"deprecated\":{\"total\":${counts.deprecated},\"documented\":${counts.documentedDeprecated},\"percent\":${coveragePercent(counts.documentedDeprecated, counts.deprecated)}},")
    out.append("\"semanticLinks\":{\"total\":${counts.semanticLinks},\"documented\":${counts.resolvedSemanticLinks},\"percent\":${coveragePercent(counts.resolvedSemanticLinks, counts.semanticLinks)}}}")
}

private func coverageV2GroupJson(name: String, counts: DocumentationCoverageCounts): String {
    let out = RenderTextBuffer()
    out.append("{\"name\":")
    appendSearchJsonString(out, name)
    out.append(",\"metrics\":")
    coverageV2Metrics(out, counts)
    out.append("}")
    out.toString()
}

public func documentationCoverageReport(documentation: DocumentationSet): DocumentationCoverageReport {
    validateTypedDocumentationSet(documentation)
    let projection = RenderProjection(documentation)
    let totals = DocumentationCoverageCounts()
    for (symbol in projection.visibleSymbols) { coverageV2Symbol(symbol, totals) }
    let packages = ArrayList<ProjectedPackage>(projection.packages.toArray())
    sort(packages, lessThan: { left, right => left.source.name < right.source.name }, stable: true)
    let modules = ArrayList<ProjectedModule>(projection.modules.toArray())
    sort(modules, lessThan: { left, right => left.source.name < right.source.name }, stable: true)
    let packageGroups = ArrayList<DocumentationCoverageGroup>()
    for (pkg in packages) {
        let counts = DocumentationCoverageCounts()
        for (symbol in pkg.symbols) { coverageV2Symbol(symbol, counts) }
        packageGroups.add(DocumentationCoverageGroup(pkg.source.name, counts))
    }
    let moduleGroups = ArrayList<DocumentationCoverageGroup>()
    for (module in modules) {
        let counts = DocumentationCoverageCounts()
        for (pkg in module.packages) {
            for (symbol in pkg.symbols) { coverageV2Symbol(symbol, counts) }
        }
        moduleGroups.add(DocumentationCoverageGroup(module.source.name, counts))
    }
    DocumentationCoverageReport(totals, packageGroups.toArray(), moduleGroups.toArray())
}

public func renderDocumentationCoverageV2(documentation: DocumentationSet): String {
    let report = documentationCoverageReport(documentation)
    let out = RenderTextBuffer()
    out.append("{\n  \"schemaVersion\":\"cjdoc.documentation-coverage/2\",\n  \"audience\":")
    appendSearchJsonString(out, documentation.configuration.audience)
    out.append(",\n  \"metrics\":")
    coverageV2Metrics(out, report.metrics)
    out.append(",\n  \"packages\":[")
    var first = true
    for (pkg in report.packages) {
        if (!first) { out.append(",") }
        first = false
        out.append("\n    ")
        out.append(coverageV2GroupJson(pkg.name, pkg.metrics))
    }
    if (!first) { out.append("\n  ") }
    out.append("],\n  \"modules\":[")
    first = true
    for (module in report.modules) {
        if (!first) { out.append(",") }
        first = false
        out.append("\n    ")
        out.append(coverageV2GroupJson(module.name, module.metrics))
    }
    if (!first) { out.append("\n  ") }
    out.append("]\n}\n")
    out.toString()
}
