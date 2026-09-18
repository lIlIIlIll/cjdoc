package cjdoc

import std.collection.*
import std.convert.Parsable

class DocumentationCoverage {
    public var publicSymbols: Int64 = 0
    public var documentedPublicSymbols: Int64 = 0
    public var publicParameters: Int64 = 0
    public var documentedPublicParameters: Int64 = 0
    public var publicReturns: Int64 = 0
    public var documentedPublicReturns: Int64 = 0
    public var publicThrows: Int64 = 0
    public var documentedPublicThrows: Int64 = 0
    public var publicExamples: Int64 = 0
    public var documentedPublicExamples: Int64 = 0
    public var publicDeprecated: Int64 = 0
    public var documentedPublicDeprecated: Int64 = 0
    public var semanticLinks: Int64 = 0
    public var resolvedSemanticLinks: Int64 = 0

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
    None
}

private func qualitySeverity(config: ?DocumentationQualityConfig, rule: String,
    fallback: String): ?String {
    match (config) {
        case Some(value) =>
            let severity = value.severity(rule)
            if (severity == "off") { None } else { Some(severity) }
        case None => Some(fallback)
    }
}

private func addQualityDiagnostic(documentation: DocumentationSet, symbol: SymbolDoc,
    config: ?DocumentationQualityConfig, rule: String, code: String, message: String,
    fallback!: String = "warning"): Unit {
    match (qualitySeverity(config, rule, fallback)) {
        case Some(severity) => documentation.diagnostics.add(Diagnostic(severity, code, message,
            source: symbol.source, symbolId: symbol.id))
        case None => ()
    }
}

private func qualityVisible(symbol: SymbolDoc, audience: String,
    index: HashMap<String, SymbolDoc>): Bool {
    var current: ?SymbolDoc = Some(symbol)
    while (current.isSome()) {
        let value = current.getOrThrow()
        let visible = match (audience) {
            case "external" => isExternallyVisible(value)
            case "package" => value.visibility != "private"
            case _ => true
        }
        if (!visible) { return false }
        current = match (value.ownerId) {
            case Some(ownerId) => index.get(ownerId)
            case None => None
        }
    }
    true
}

private func validVersion(value: String): Bool {
    let parts = value.trimAscii().split(".")
    if (parts.size < 2 || parts.size > 4) { return false }
    for (part in parts) {
        if (part.isEmpty()) { return false }
        try { let _ = Int64.parse(part) } catch (_: Exception) { return false }
    }
    true
}


private func lintQualityRules(documentation: DocumentationSet,
    config: ?DocumentationQualityConfig, audience: String,
    strictMissingSymbolDocs!: Bool = false): Unit {
    let index = HashMap<String, SymbolDoc>()
    for (symbol in documentation.symbols) { index[symbol.id] = symbol }
    for (symbol in documentation.symbols) {
        if (!qualityVisible(symbol, audience, index)) { continue }
        match (symbol.documentation) {
            case None =>
                let missingSymbolCode = if (strictMissingSymbolDocs) { "CJDOC1025" } else { "CJDOC1034" }
                addQualityDiagnostic(documentation, symbol, config, "missing-symbol-doc", missingSymbolCode,
                    "undocumented public symbol '${symbol.qualifiedName}'")
            case Some(doc) =>
                if (doc.summaryMarkdown.trimAscii().isEmpty()) {
                    addQualityDiagnostic(documentation, symbol, config, "missing-summary", "CJDOC1035",
                        "documentation summary is missing")
                }
                if (doc.descriptionMarkdown.trimAscii().isEmpty()) {
                    addQualityDiagnostic(documentation, symbol, config, "empty-description", "CJDOC1036",
                        "documentation description is empty")
                }
                if (symbol.returnType.isSome() &&
                    symbol.returnType.getOrThrow().display.trimAscii() != "Unit" &&
                    (doc.returns.isNone() || doc.returns.getOrThrow().description.trimAscii().isEmpty())) {
                    addQualityDiagnostic(documentation, symbol, config, "missing-return", "CJDOC1037",
                        "value-returning symbol is missing @return documentation")
                }
                if (doc.examples.isEmpty()) {
                    addQualityDiagnostic(documentation, symbol, config, "missing-example", "CJDOC1038",
                        "public symbol is missing an @example")
                }
                match (doc.since) {
                    case Some(value) =>
                        if (!validVersion(value)) {
                            addQualityDiagnostic(documentation, symbol, config, "invalid-since-version", "CJDOC1039",
                                "invalid @since version '${value}'")
                        }
                    case None => ()
                }
                match (doc.deprecated) {
                    case Some(value) =>
                        if (value.trimAscii().isEmpty()) {
                            addQualityDiagnostic(documentation, symbol, config, "deprecated-without-message", "CJDOC1040",
                                "@deprecated is missing a message")
                        }
                    case None => ()
                }
                for (parameter in symbol.parameters where !parameter.name.startsWith("_")) {
                    if (parameter.documentation.isNone()) {
                        addQualityDiagnostic(documentation, symbol, config, "missing-param", "CJDOC1004",
                            "undocumented parameter '${parameter.name}'")
                    }
                    if (parameter.typeRef.state != "resolved") {
                        addQualityDiagnostic(documentation, symbol, config, "unresolved-type-link", "CJDOC1041",
                            "parameter '${parameter.name}' has an unresolved type link")
                    }
                }
                match (symbol.returnType) {
                    case Some(typeRef) =>
                        if (typeRef.state != "resolved") {
                            addQualityDiagnostic(documentation, symbol, config, "unresolved-type-link", "CJDOC1041",
                                "return type has an unresolved type link")
                        }
                    case None => ()
                }
                for (tag in doc.throwsTags) {
                    if (tag.description.trimAscii().isEmpty()) {
                        addQualityDiagnostic(documentation, symbol, config, "missing-throws", "CJDOC1042",
                            "@throws '${tag.subject}' is missing a description")
                    }
                }
                for (tag in doc.see) {
                    if (tag.referenceState == "broken") {
                        addQualityDiagnostic(documentation, symbol, config, "broken-link", "CJDOC1005",
                            "broken @see")
                    } else if (tag.referenceState == "unresolved") {
                        addQualityDiagnostic(documentation, symbol, config, "unresolved-type-link", "CJDOC1008",
                            "unresolved semantic reference '${tag.subject}'")
                    } else if (tag.referenceState == "ambiguous") {
                        addQualityDiagnostic(documentation, symbol, config, "ambiguous-link", "CJDOC1043",
                            "ambiguous semantic reference '${tag.subject}'")
                    }
                }
        }
        if (symbol.documentation.isSome()) {
            let doc = symbol.documentation.getOrThrow()
            var index: Int64 = 0
            while (index < doc.params.size) {
                var previous: Int64 = 0
                while (previous < index) {
                    if (doc.params[previous].subject == doc.params[index].subject) {
                        addQualityDiagnostic(documentation, symbol, config, "duplicate-param", "CJDOC1002",
                            "duplicate @param '${doc.params[index].subject}'")
                        break
                    }
                    previous++
                }
                index++
            }
            if (doc.returnTagCount > 1) {
                addQualityDiagnostic(documentation, symbol, config, "duplicate-return", "CJDOC1003",
                    "duplicate @return")
            }
            var throwsIndex: Int64 = 0
            while (throwsIndex < doc.throwsTags.size) {
                var previousThrows: Int64 = 0
                while (previousThrows < throwsIndex) {
                    if (doc.throwsTags[previousThrows].subject == doc.throwsTags[throwsIndex].subject) {
                        addQualityDiagnostic(documentation, symbol, config, "duplicate-throws", "CJDOC1022",
                            "duplicate @throws '${doc.throwsTags[throwsIndex].subject}'")
                        break
                    }
                    previousThrows++
                }
                throwsIndex++
            }
        }
    }
}

func documentationCoverage(documentation: DocumentationSet): DocumentationCoverage {
    let coverage = DocumentationCoverage()
    for (symbol in documentation.symbols) {
        if (symbol.visibility != "public" && symbol.visibility != "protected") { continue }
        coverage.publicSymbols++
        match (symbol.documentation) {
            case Some(doc) =>
                coverage.documentedPublicSymbols++
                if (symbol.returnType.isSome() && symbol.returnType.getOrThrow().display != "Unit") {
                    coverage.publicReturns++
                    if (doc.returns.isSome() && !doc.returns.getOrThrow().description.trimAscii().isEmpty()) {
                        coverage.documentedPublicReturns++
                    }
                }
                if (!doc.examples.isEmpty()) { coverage.publicExamples++; coverage.documentedPublicExamples++ }
                if (doc.deprecated.isSome()) {
                    coverage.publicDeprecated++
                    if (!doc.deprecated.getOrThrow().trimAscii().isEmpty()) { coverage.documentedPublicDeprecated++ }
                }
                for (tag in doc.throwsTags) {
                    coverage.publicThrows++
                    if (!tag.description.trimAscii().isEmpty()) { coverage.documentedPublicThrows++ }
                }
            case None => ()
        }
        for (parameter in symbol.parameters where !parameter.name.startsWith("_")) {
            coverage.publicParameters++
            if (parameter.documentation.isSome()) { coverage.documentedPublicParameters++ }
        }
    }
    coverage
}

func lintDocumentation(documentation: DocumentationSet, missingParameterDocs: Bool,
    missingSymbolDocs!: Bool = false, qualityConfig!: ?DocumentationQualityConfig = None,
    audience!: String = "all"): Unit {
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
                index++
            }
            if (doc.returnTagCount > 0 && (symbol.returnType.isNone() ||
                symbol.returnType.getOrThrow().display.trimAscii() == "Unit")) {
                documentation.diagnostics.add(Diagnostic("warning", "CJDOC1023",
                    "@return is present on a declaration without a value return",
                    source: symbol.source, symbolId: symbol.id))
            }
        }
    }
    if (missingParameterDocs || missingSymbolDocs || qualityConfig.isSome()) {
        lintQualityRules(documentation, qualityConfig, audience,
            strictMissingSymbolDocs: missingSymbolDocs)
    }
}
