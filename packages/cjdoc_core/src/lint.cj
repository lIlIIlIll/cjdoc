package cjdoc_core

public class DocumentationCoverage {
    public var publicSymbols: Int64 = 0
    public var documentedPublicSymbols: Int64 = 0
    public var publicParameters: Int64 = 0
    public var documentedPublicParameters: Int64 = 0

    public func symbolPercent(): Int64 {
        if (publicSymbols == 0) { 100 } else { documentedPublicSymbols * 100 / publicSymbols }
    }

    public func parameterPercent(): Int64 {
        if (publicParameters == 0) { 100 } else { documentedPublicParameters * 100 / publicParameters }
    }
}

private func findParameter(symbol: SymbolDoc, name: String): ?ParameterDoc {
    for (parameter in symbol.parameters) {
        if (parameter.name == name) { return parameter }
    }
    return None
}

public func documentationCoverage(documentation: DocumentationSet): DocumentationCoverage {
    let coverage = DocumentationCoverage()
    for (symbol in documentation.symbols) {
        if (symbol.visibility != "public" && symbol.visibility != "protected") { continue }
        coverage.publicSymbols++
        if (symbol.documentation.isSome()) { coverage.documentedPublicSymbols++ }
        for (parameter in symbol.parameters where !parameter.name.startsWith("_")) {
            coverage.publicParameters++
            if (parameter.documentation.isSome()) { coverage.documentedPublicParameters++ }
        }
    }
    coverage
}

public func lintDocumentation(documentation: DocumentationSet, missingParameterDocs: Bool,
    missingSymbolDocs!: Bool = false): Unit {
    resolveDocumentationReferences(documentation)
    for (symbol in documentation.symbols) {
        if (let Some(doc) <- symbol.documentation) {
            var index: Int64 = 0
            while (index < doc.params.size) {
                let tag = doc.params[index]
                match (findParameter(symbol, tag.subject)) {
                    case Some(parameter) => parameter.documentation = tag.description
                    case None => documentation.diagnostics.add(Diagnostic("warning", "CJDOC1001",
                        "unknown @param '${tag.subject}'", source: symbol.source, symbolId: symbol.id))
                }
                var previous: Int64 = 0
                while (previous < index) {
                    if (doc.params[previous].subject == tag.subject) {
                        documentation.diagnostics.add(Diagnostic("warning", "CJDOC1002",
                            "duplicate @param '${tag.subject}'", source: symbol.source, symbolId: symbol.id))
                        break
                    }
                    previous++
                }
                index++
            }
            if (doc.returnTagCount > 1) {
                documentation.diagnostics.add(Diagnostic("warning", "CJDOC1003",
                    "duplicate @return", source: symbol.source, symbolId: symbol.id))
            }
            if (doc.returnTagCount > 0 && (symbol.returnType.isNone() ||
                symbol.returnType.getOrThrow().display.trimAscii() == "Unit")) {
                documentation.diagnostics.add(Diagnostic("warning", "CJDOC1023",
                    "@return is present on a declaration without a value return",
                    source: symbol.source, symbolId: symbol.id))
            }
            var throwsIndex: Int64 = 0
            while (throwsIndex < doc.throwsTags.size) {
                var previousThrows: Int64 = 0
                while (previousThrows < throwsIndex) {
                    if (doc.throwsTags[previousThrows].subject == doc.throwsTags[throwsIndex].subject) {
                        documentation.diagnostics.add(Diagnostic("warning", "CJDOC1022",
                            "duplicate @throws '${doc.throwsTags[throwsIndex].subject}'",
                            source: symbol.source, symbolId: symbol.id))
                        break
                    }
                    previousThrows++
                }
                throwsIndex++
            }
            for (tag in doc.see) {
                if (tag.referenceState == "broken") {
                    documentation.diagnostics.add(Diagnostic("warning", "CJDOC1005",
                        "broken @see", source: symbol.source, symbolId: symbol.id))
                } else if (tag.referenceState == "unresolved") {
                    documentation.diagnostics.add(Diagnostic("warning", "CJDOC1008",
                        "unresolved semantic reference '${tag.subject}'", source: symbol.source, symbolId: symbol.id))
                } else if (tag.referenceState == "ambiguous") {
                    documentation.diagnostics.add(Diagnostic("warning", "CJDOC1008",
                        "ambiguous semantic reference '${tag.subject}'", source: symbol.source, symbolId: symbol.id))
                }
            }
        }
        if (missingSymbolDocs && (symbol.visibility == "public" || symbol.visibility == "protected") &&
            symbol.documentation.isNone()) {
            documentation.diagnostics.add(Diagnostic("warning", "CJDOC1025",
                "undocumented public symbol '${symbol.qualifiedName}'",
                source: symbol.source, symbolId: symbol.id))
        }
        if (missingParameterDocs && (symbol.visibility == "public" || symbol.visibility == "protected")) {
            for (parameter in symbol.parameters) {
                if (!parameter.name.startsWith("_") && parameter.documentation.isNone()) {
                    documentation.diagnostics.add(Diagnostic("warning", "CJDOC1004",
                        "undocumented parameter '${parameter.name}'", source: symbol.source, symbolId: symbol.id))
                }
            }
        }
    }
}
