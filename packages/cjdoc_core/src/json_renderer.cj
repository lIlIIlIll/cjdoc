package cjdoc_core

import std.collection.*
import std.sort.*

private let HEX_DIGITS: Array<Rune> = [r'0', r'1', r'2', r'3', r'4', r'5', r'6', r'7',
    r'8', r'9', r'a', r'b', r'c', r'd', r'e', r'f']

private func appendHex4(builder: StringBuilder, value: UInt32): Unit {
    builder.append(HEX_DIGITS[Int64((value >> 12) & 0xFu32)])
    builder.append(HEX_DIGITS[Int64((value >> 8) & 0xFu32)])
    builder.append(HEX_DIGITS[Int64((value >> 4) & 0xFu32)])
    builder.append(HEX_DIGITS[Int64(value & 0xFu32)])
}

public func jsonEscape(value: String): String {
    let builder = StringBuilder()
    builder.append('"')
    for (rune in value.runes()) {
        match (rune) {
            case '"' => builder.append("\\\"")
            case '\\' => builder.append("\\\\")
            case '\u{0008}' => builder.append("\\b")
            case '\u{000c}' => builder.append("\\f")
            case '\n' => builder.append("\\n")
            case '\r' => builder.append("\\r")
            case '\t' => builder.append("\\t")
            case _ =>
                let code = UInt32(rune)
                if (code < 0x20u32) {
                    builder.append("\\u")
                    appendHex4(builder, code)
                } else {
                    builder.append(rune)
                }
        }
    }
    builder.append('"')
    return builder.toString()
}

private func renderOptionalString(value: ?String): String {
    return match (value) {
        case Some(actual) => jsonEscape(actual)
        case None => "null"
    }
}

private func renderStringList(values: ArrayList<String>): String {
    let builder = StringBuilder()
    builder.append("[")
    var index: Int64 = 0
    while (index < values.size) {
        if (index > 0) { builder.append(",") }
        builder.append(jsonEscape(values[index]))
        index++
    }
    builder.append("]")
    return builder.toString()
}

private func renderSource(source: SourceLocation): String {
    return "{\"path\":${jsonEscape(source.path)},\"start\":{\"line\":${source.startLine},\"column\":${source.startColumn}}," +
        "\"end\":{\"line\":${source.endLine},\"column\":${source.endColumn}}}"
}

private func renderType(typeRef: TypeRef): String {
    return "{\"display\":${jsonEscape(typeRef.display)},\"canonical\":${renderOptionalString(typeRef.canonical)}," +
        "\"state\":${jsonEscape(typeRef.state)}}"
}

private func renderOrigin(origin: DeclarationOrigin): String {
    "{\"kind\":${jsonEscape(origin.kind)},\"macroSymbolId\":${renderOptionalString(origin.macroSymbolId)}}"
}

private func renderTag(tag: DocTag): String {
    return "{\"name\":${jsonEscape(tag.name)},\"subject\":${jsonEscape(tag.subject)}," +
        "\"description\":${jsonEscape(tag.description)}}"
}

private func renderTagList(values: ArrayList<DocTag>): String {
    let builder = StringBuilder()
    builder.append("[")
    var index: Int64 = 0
    while (index < values.size) {
        if (index > 0) { builder.append(",") }
        builder.append(renderTag(values[index]))
        index++
    }
    builder.append("]")
    return builder.toString()
}

private func renderSeeTag(tag: DocTag): String {
    return "{\"name\":${jsonEscape(tag.name)},\"subject\":${jsonEscape(tag.subject)}," +
        "\"description\":${jsonEscape(tag.description)},\"state\":${jsonEscape(tag.referenceState)}," +
        "\"targetSymbolId\":${renderOptionalString(tag.targetSymbolId)}}"
}

private func renderSeeList(values: ArrayList<DocTag>): String {
    let builder = StringBuilder()
    builder.append("[")
    var index: Int64 = 0
    while (index < values.size) {
        if (index > 0) { builder.append(",") }
        builder.append(renderSeeTag(values[index]))
        index++
    }
    builder.append("]")
    return builder.toString()
}

private func renderComment(comment: DocComment): String {
    let returns = match (comment.returns) {
        case Some(tag) => renderTag(tag)
        case None => "null"
    }
    return "{\"raw\":${jsonEscape(comment.raw)},\"summaryMarkdown\":${jsonEscape(comment.summaryMarkdown)}," +
        "\"descriptionMarkdown\":${jsonEscape(comment.descriptionMarkdown)},\"params\":${renderTagList(comment.params)}," +
        "\"returns\":${returns},\"throws\":${renderTagList(comment.throwsTags)},\"see\":${renderSeeList(comment.see)}," +
        "\"since\":${renderOptionalString(comment.since)},\"deprecated\":${renderOptionalString(comment.deprecated)}," +
        "\"authors\":${renderStringList(comment.authors)},\"version\":${renderOptionalString(comment.version)}}"
}

private func renderParameter(parameter: ParameterDoc): String {
    return "{\"name\":${jsonEscape(parameter.name)},\"type\":${renderType(parameter.typeRef)}," +
        "\"documentation\":${renderOptionalString(parameter.documentation)}}"
}

private func renderParameters(parameters: ArrayList<ParameterDoc>): String {
    let builder = StringBuilder()
    builder.append("[")
    var index: Int64 = 0
    while (index < parameters.size) {
        if (index > 0) { builder.append(",") }
        builder.append(renderParameter(parameters[index]))
        index++
    }
    builder.append("]")
    return builder.toString()
}

private func renderRelationships(relationships: ArrayList<TypeRelationship>): String {
    let builder = StringBuilder()
    builder.append("[")
    var index: Int64 = 0
    while (index < relationships.size) {
        if (index > 0) { builder.append(",") }
        let relationship = relationships[index]
        builder.append("{\"kind\":${jsonEscape(relationship.kind)},\"target\":${renderType(relationship.target)}}")
        index++
    }
    builder.append("]")
    builder.toString()
}

private func renderSymbolRelationships(relationships: ArrayList<SymbolRelationship>): String {
    let out = StringBuilder()
    out.append("[")
    var index: Int64 = 0
    while (index < relationships.size) {
        if (index > 0) { out.append(",") }
        let relationship = relationships[index]
        out.append("{\"kind\":${jsonEscape(relationship.kind)}," +
            "\"targetDisplay\":${jsonEscape(relationship.targetDisplay)}," +
            "\"state\":${jsonEscape(relationship.state)}," +
            "\"targetSymbolId\":${renderOptionalString(relationship.targetSymbolId)}}")
        index++
    }
    out.append("]")
    out.toString()
}

private func renderSymbol(symbol: SymbolDoc): String {
    let returnType = match (symbol.returnType) {
        case Some(typeRef) => renderType(typeRef)
        case None => "null"
    }
    let documentation = match (symbol.documentation) {
        case Some(comment) => renderComment(comment)
        case None => "null"
    }
    return "{\"id\":${jsonEscape(symbol.id)},\"kind\":${jsonEscape(symbol.kind)},\"name\":${jsonEscape(symbol.name)}," +
        "\"qualifiedName\":${jsonEscape(symbol.qualifiedName)},\"packageName\":${jsonEscape(symbol.packageName)}," +
        "\"ownerId\":${renderOptionalString(symbol.ownerId)},\"visibility\":${jsonEscape(symbol.visibility)}," +
        "\"genericParameters\":${renderStringList(symbol.genericParameters)},\"parameters\":${renderParameters(symbol.parameters)}," +
        "\"returnType\":${returnType},\"annotations\":${renderStringList(symbol.annotations)}," +
        "\"relationships\":${renderRelationships(symbol.relationships)}," +
        "\"symbolRelationships\":${renderSymbolRelationships(symbol.symbolRelationships)}," +
        "\"documentation\":${documentation},\"source\":${renderSource(symbol.source)}," +
        "\"sourceSignature\":${jsonEscape(symbol.sourceSignature)}," +
        "\"origin\":${renderOrigin(symbol.origin)}," +
        "\"semantic\":{\"state\":${jsonEscape(symbol.semanticState)},\"provider\":${jsonEscape(symbol.semanticProvider)}," +
        "\"canonicalSignature\":${renderOptionalString(symbol.canonicalSignature)}}}"
}

private func renderDiagnostic(diagnostic: Diagnostic): String {
    let source = match (diagnostic.source) {
        case Some(location) => renderSource(location)
        case None => "null"
    }
    return "{\"severity\":${jsonEscape(diagnostic.severity)},\"code\":${jsonEscape(diagnostic.code)}," +
        "\"message\":${jsonEscape(diagnostic.message)},\"source\":${source}," +
        "\"symbolId\":${renderOptionalString(diagnostic.symbolId)}}"
}

private func renderPackage(pkg: PackageDoc): String {
    return "{\"name\":${jsonEscape(pkg.name)},\"sourceFiles\":${renderStringList(pkg.sourceFiles)}," +
        "\"symbolIds\":${renderStringList(pkg.symbolIds)}}"
}

private func renderModule(module: ModuleDoc): String {
    return "{\"id\":${jsonEscape(module.id)},\"name\":${jsonEscape(module.name)}," +
        "\"role\":${jsonEscape(module.role)},\"sourcePrefix\":${jsonEscape(module.sourcePrefix)}," +
        "\"packageNames\":${renderStringList(module.packageNames)}," +
        "\"dependencyIds\":${renderStringList(module.dependencyIds)}}"
}

private func renderUnsupported(declaration: UnsupportedDeclaration): String {
    "{\"kind\":${jsonEscape(declaration.kind)},\"name\":${jsonEscape(declaration.name)}," +
        "\"reason\":${jsonEscape(declaration.reason)},\"source\":${renderSource(declaration.source)}," +
        "\"origin\":${renderOrigin(declaration.origin)}}"
}

private func renderCapabilities(capabilities: SemanticCapabilities): String {
    return "{\"sourceBinding\":${capabilities.sourceBinding},\"ownership\":${capabilities.ownership}," +
        "\"visibility\":${capabilities.visibility},\"canonicalTypes\":${capabilities.canonicalTypes}," +
        "\"canonicalSignatures\":${capabilities.canonicalSignatures}," +
        "\"symbolRelationships\":${capabilities.symbolRelationships}}"
}

private func renderBindingStats(stats: SemanticBindingStats): String {
    return "{\"provider\":${jsonEscape(stats.provider)},\"capabilities\":${renderCapabilities(stats.capabilities)}," +
        "\"matched\":${stats.matched},\"missing\":${stats.missing},\"ambiguous\":${stats.ambiguous}," +
        "\"extraneous\":${stats.extraneous},\"contractViolations\":${stats.contractViolations}}"
}

private func renderCfgProfile(profile: CfgProfile): String {
    let out = StringBuilder()
    out.append("{\"cfg\":[")
    var index: Int64 = 0
    while (index < profile.values.size) {
        if (index > 0) { out.append(",") }
        let value = profile.values[index]
        out.append("{\"name\":${jsonEscape(value.name)},\"value\":${jsonEscape(value.value)}}")
        index++
    }
    out.append("]}")
    out.toString()
}

public func renderDocumentationJson(documentation: DocumentationSet): String {
    sortDocumentationDeterministically(documentation)
    let builder = StringBuilder()
    builder.append("{\"schemaVersion\":\"cjdoc.doc-ir/4\",\"generator\":{\"name\":\"cjdoc\",\"version\":\"0.3.0\"},")
    builder.append("\"project\":{\"name\":")
    builder.append(jsonEscape(documentation.projectName))
    builder.append(",\"modules\":[")
    var index: Int64 = 0
    while (index < documentation.modules.size) {
        if (index > 0) { builder.append(",") }
        builder.append(renderModule(documentation.modules[index]))
        index++
    }
    builder.append("]},\"configuration\":")
    builder.append(renderCfgProfile(documentation.cfgProfile))
    builder.append(",\"semanticBinding\":")
    builder.append(renderBindingStats(documentation.semanticBinding))
    builder.append(",\"packages\":[")
    index = 0
    while (index < documentation.packages.size) {
        if (index > 0) { builder.append(",") }
        builder.append(renderPackage(documentation.packages[index]))
        index++
    }
    builder.append("],\"symbols\":[")
    index = 0
    while (index < documentation.symbols.size) {
        if (index > 0) { builder.append(",") }
        builder.append(renderSymbol(documentation.symbols[index]))
        index++
    }
    builder.append("],\"unsupportedDeclarations\":[")
    index = 0
    while (index < documentation.unsupportedDeclarations.size) {
        if (index > 0) { builder.append(",") }
        builder.append(renderUnsupported(documentation.unsupportedDeclarations[index]))
        index++
    }
    builder.append("],\"diagnostics\":[")
    index = 0
    while (index < documentation.diagnostics.size) {
        if (index > 0) { builder.append(",") }
        builder.append(renderDiagnostic(documentation.diagnostics[index]))
        index++
    }
    builder.append("]}\n")
    return builder.toString()
}

public class CfgMatrixDocumentation {
    public let name: String
    public let documentation: DocumentationSet

    public init(name: String, documentation: DocumentationSet) {
        this.name = name
        this.documentation = documentation
    }
}

public func renderCfgMatrixJson(entries: Array<CfgMatrixDocumentation>): String {
    if (entries.isEmpty()) {
        throw IllegalArgumentException("cfg matrix requires at least one profile")
    }
    let ordered = ArrayList<CfgMatrixDocumentation>()
    ordered.add(all: entries)
    sort(ordered, lessThan: { left, right => left.name < right.name }, stable: true)
    let seen = HashSet<String>()
    for (entry in ordered) {
        if (!isCfgProfileNameValid(entry.name)) {
            throw IllegalArgumentException("invalid cfg matrix profile name '${entry.name}'")
        }
        if (!seen.add(entry.name)) {
            throw IllegalArgumentException("duplicate cfg matrix profile '${entry.name}'")
        }
    }
    let builder = StringBuilder()
    builder.append("{\"schemaVersion\":\"cjdoc.cfg-matrix/1\"," +
        "\"generator\":{\"name\":\"cjdoc\",\"version\":\"0.3.0\"},\"profiles\":[")
    var index: Int64 = 0
    while (index < ordered.size) {
        if (index > 0) { builder.append(",") }
        builder.append("{\"name\":")
        builder.append(jsonEscape(ordered[index].name))
        builder.append(",\"documentation\":")
        builder.append(renderDocumentationJson(ordered[index].documentation).trimEnd())
        builder.append("}")
        index++
    }
    builder.append("]}\n")
    builder.toString()
}

public func hasFatalDiagnostics(documentation: DocumentationSet): Bool {
    for (diagnostic in documentation.diagnostics) {
        if (diagnostic.severity == "error" && diagnostic.code != "CJDOC1011" &&
            diagnostic.code != "CJDOC1012" && diagnostic.code != "CJDOC1020") { return true }
    }
    return false
}

public func hasErrorDiagnostics(documentation: DocumentationSet): Bool {
    for (diagnostic in documentation.diagnostics) {
        if (diagnostic.severity == "error") { return true }
    }
    return false
}
