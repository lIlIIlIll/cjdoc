package cjdoc.render

import cjdoc.model.*
import std.collection.*

private let HEX_DIGITS: Array<Rune> = [r'0', r'1', r'2', r'3', r'4', r'5', r'6', r'7',
    r'8', r'9', r'a', r'b', r'c', r'd', r'e', r'f']

private func appendHex4(builder: StringBuilder, value: UInt32): Unit {
    builder.append(HEX_DIGITS[Int64((value >> 12) & 0xFu32)])
    builder.append(HEX_DIGITS[Int64((value >> 8) & 0xFu32)])
    builder.append(HEX_DIGITS[Int64((value >> 4) & 0xFu32)])
    builder.append(HEX_DIGITS[Int64(value & 0xFu32)])
}

public func escapeJsonString(value: String): String {
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
    builder.toString()
}

private func nullableString(value: ?String): String {
    match (value) { case Some(text) => escapeJsonString(text) case None => "null" }
}

private func appendStrings(out: StringBuilder, values: ReadOnlyList<String>): Unit {
    out.append("[")
    var first = true
    for (value in values) {
        if (!first) { out.append(",") }
        first = false
        out.append(escapeJsonString(value))
    }
    out.append("]")
}

private func appendPosition(out: StringBuilder, value: SourcePosition): Unit {
    out.append("{\"line\":${value.line},\"column\":${value.column},\"byteOffset\":${value.byteOffset}}")
}

private func appendRange(out: StringBuilder, value: SourceRange): Unit {
    out.append("{\"path\":${escapeJsonString(value.path)},\"start\":")
    appendPosition(out, value.start)
    out.append(",\"end\":")
    appendPosition(out, value.end)
    out.append("}")
}

private func appendCapabilities(out: StringBuilder, value: SemanticCapabilities): Unit {
    out.append("{\"sourceBinding\":${value.sourceBinding},\"ownership\":${value.ownership},")
    out.append("\"visibility\":${value.visibility},\"canonicalTypes\":${value.canonicalTypes},")
    out.append("\"canonicalSignatures\":${value.canonicalSignatures},\"relationships\":${value.relationships}}")
}

private func appendSemanticType(out: StringBuilder, value: SemanticType): Unit {
    out.append("{\"state\":${escapeJsonString(value.state)},\"canonical\":${nullableString(value.canonical)},")
    out.append("\"provider\":${nullableString(value.provider)}}")
}

private func appendTypeRef(out: StringBuilder, value: TypeRef): Unit {
    out.append("{\"kind\":${escapeJsonString(value.kind)},\"spelling\":${escapeJsonString(value.spelling)},")
    out.append("\"nullable\":${value.nullable},\"arguments\":[")
    var first = true
    for (argument in value.arguments) {
        if (!first) { out.append(",") }
        first = false
        appendTypeRef(out, argument)
    }
    out.append("],\"semantic\":")
    appendSemanticType(out, value.semantic)
    out.append("}")
}

private func appendTag(out: StringBuilder, value: DocTag): Unit {
    out.append("{\"name\":${escapeJsonString(value.name)},\"subject\":${escapeJsonString(value.subject)},")
    out.append("\"description\":${escapeJsonString(value.description)},")
    out.append("\"referenceState\":${escapeJsonString(value.referenceState)},")
    out.append("\"targetSymbolId\":${nullableString(value.targetSymbolId)}}")
}

private func appendMarkdown(out: StringBuilder, value: MarkdownNode): Unit {
    out.append("{\"kind\":${escapeJsonString(value.kind)},\"literal\":${escapeJsonString(value.literal)},\"source\":")
    match (value.source) { case Some(range) => appendRange(out, range) case None => out.append("null") }
    out.append(",\"children\":[")
    var first = true
    for (child in value.children) {
        if (!first) { out.append(",") }
        first = false
        appendMarkdown(out, child)
    }
    out.append("]}")
}

private func appendComment(out: StringBuilder, value: DocComment): Unit {
    out.append("{\"rawText\":${escapeJsonString(value.rawText)},\"summary\":${escapeJsonString(value.summary)},")
    out.append("\"description\":${escapeJsonString(value.description)},\"markdown\":")
    appendMarkdown(out, value.markdown)
    out.append(",\"tags\":[")
    var first = true
    for (tag in value.tags) {
        if (!first) { out.append(",") }
        first = false
        appendTag(out, tag)
    }
    out.append("]}")
}

private func appendParameter(out: StringBuilder, value: ParameterDoc): Unit {
    out.append("{\"name\":${escapeJsonString(value.name)},\"type\":")
    appendTypeRef(out, value.typeRef)
    out.append(",\"documentation\":${nullableString(value.documentation)},")
    out.append("\"defaultExpression\":${nullableString(value.defaultExpression)}}")
}

private func appendOrigin(out: StringBuilder, value: DeclarationOrigin): Unit {
    out.append("{\"kind\":${escapeJsonString(value.kind)},\"macroSymbolId\":${nullableString(value.macroSymbolId)}}")
}

private func appendTypeRelationship(out: StringBuilder, value: TypeRelationship): Unit {
    out.append("{\"kind\":${escapeJsonString(value.kind)},\"target\":")
    appendTypeRef(out, value.target)
    out.append("}")
}

private func appendSymbolRelationship(out: StringBuilder, value: SymbolRelationship): Unit {
    out.append("{\"kind\":${escapeJsonString(value.kind)},")
    out.append("\"targetDisplay\":${escapeJsonString(value.targetDisplay)},")
    out.append("\"state\":${escapeJsonString(value.state)},")
    out.append("\"targetSymbolId\":${nullableString(value.targetSymbolId)}}")
}

private func appendSymbol(out: StringBuilder, value: SymbolDoc): Unit {
    out.append("{\"id\":${escapeJsonString(value.id)},\"kind\":${escapeJsonString(value.kind)},")
    out.append("\"name\":${escapeJsonString(value.name)},\"qualifiedName\":${escapeJsonString(value.qualifiedName)},")
    out.append("\"packageName\":${escapeJsonString(value.packageName)},\"ownerId\":${nullableString(value.ownerId)},")
    out.append("\"visibility\":${escapeJsonString(value.visibility)},\"genericParameters\":")
    appendStrings(out, value.genericParameters)
    out.append(",\"parameters\":[")
    var first = true
    for (parameter in value.parameters) {
        if (!first) { out.append(",") }
        first = false
        appendParameter(out, parameter)
    }
    out.append("],\"returnType\":")
    match (value.returnType) { case Some(typeRef) => appendTypeRef(out, typeRef) case None => out.append("null") }
    out.append(",\"annotations\":")
    appendStrings(out, value.annotations)
    out.append(",\"typeRelationships\":[")
    first = true
    for (relationship in value.typeRelationships) {
        if (!first) { out.append(",") }
        first = false
        appendTypeRelationship(out, relationship)
    }
    out.append("],\"symbolRelationships\":[")
    first = true
    for (relationship in value.symbolRelationships) {
        if (!first) { out.append(",") }
        first = false
        appendSymbolRelationship(out, relationship)
    }
    out.append("]")
    out.append(",\"documentation\":")
    match (value.documentation) { case Some(comment) => appendComment(out, comment) case None => out.append("null") }
    out.append(",\"source\":")
    appendRange(out, value.source)
    out.append(",\"headerSpelling\":${escapeJsonString(value.headerSpelling)},\"semantic\":{")
    out.append("\"state\":${escapeJsonString(value.semantic.state)},")
    out.append("\"provider\":${escapeJsonString(value.semantic.provider)},")
    out.append("\"canonicalSignature\":${nullableString(value.semantic.canonicalSignature)}},\"origin\":")
    appendOrigin(out, value.origin)
    out.append("}")
}

private func appendModule(out: StringBuilder, value: ModuleDoc): Unit {
    out.append("{\"id\":${escapeJsonString(value.id)},\"name\":${escapeJsonString(value.name)},")
    out.append("\"role\":${escapeJsonString(value.role)},\"sourcePrefix\":${escapeJsonString(value.sourcePrefix)},")
    out.append("\"packageNames\":")
    appendStrings(out, value.packageNames)
    out.append(",\"dependencyIds\":")
    appendStrings(out, value.dependencyIds)
    out.append("}")
}

private func appendPackage(out: StringBuilder, value: PackageDoc): Unit {
    out.append("{\"name\":${escapeJsonString(value.name)},\"moduleId\":${escapeJsonString(value.moduleId)},")
    out.append("\"sourceFiles\":")
    appendStrings(out, value.sourceFiles)
    out.append(",\"symbolIds\":")
    appendStrings(out, value.symbolIds)
    out.append("}")
}

private func appendDiagnostic(out: StringBuilder, value: Diagnostic): Unit {
    out.append("{\"severity\":${escapeJsonString(value.severity)},\"code\":${escapeJsonString(value.code)},")
    out.append("\"message\":${escapeJsonString(value.message)},\"source\":")
    match (value.source) { case Some(range) => appendRange(out, range) case None => out.append("null") }
    out.append(",\"symbolId\":${nullableString(value.symbolId)}}")
}

private func compactDocIr(documentation: DocumentationSet): String {
    let out = StringBuilder()
    out.append("{\"schemaVersion\":${escapeJsonString(documentation.schemaVersion)},")
    out.append("\"generator\":{\"name\":${escapeJsonString(documentation.generator.name)},")
    out.append("\"version\":${escapeJsonString(documentation.generator.version)}},")
    out.append("\"status\":${escapeJsonString(documentation.status)},")
    out.append("\"project\":{\"name\":${escapeJsonString(documentation.project.name)},")
    out.append("\"kind\":${escapeJsonString(documentation.project.kind)}},")
    out.append("\"configuration\":{\"audience\":${escapeJsonString(documentation.configuration.audience)},")
    out.append("\"lintProfile\":${escapeJsonString(documentation.configuration.lintProfile)},")
    out.append("\"cfgProfile\":${escapeJsonString(documentation.configuration.cfgProfile)}},")
    out.append("\"providers\":[")
    var first = true
    for (provider in documentation.providers) {
        if (!first) { out.append(",") }
        first = false
        out.append("{\"name\":${escapeJsonString(provider.name)},\"version\":${escapeJsonString(provider.version)},")
        out.append("\"state\":${escapeJsonString(provider.state)},\"capabilities\":")
        appendCapabilities(out, provider.capabilities)
        out.append("}")
    }
    out.append("],\"modules\":[")
    first = true
    for (module in documentation.modules) {
        if (!first) { out.append(",") }; first = false; appendModule(out, module)
    }
    out.append("],\"packages\":[")
    first = true
    for (pkg in documentation.packages) {
        if (!first) { out.append(",") }; first = false; appendPackage(out, pkg)
    }
    out.append("],\"files\":[")
    first = true
    for (file in documentation.files) {
        if (!first) { out.append(",") }; first = false
        out.append("{\"path\":${escapeJsonString(file.path)},\"moduleId\":${escapeJsonString(file.moduleId)},")
        out.append("\"packageName\":${escapeJsonString(file.packageName)}}")
    }
    out.append("],\"declarations\":[")
    first = true
    for (declaration in documentation.declarations) {
        if (!first) { out.append(",") }; first = false; appendSymbol(out, declaration)
    }
    out.append("],\"assets\":[")
    first = true
    for (asset in documentation.assets) {
        if (!first) { out.append(",") }; first = false
        out.append("{\"id\":${escapeJsonString(asset.id)},\"mediaType\":${escapeJsonString(asset.mediaType)},")
        out.append("\"sourcePath\":${escapeJsonString(asset.sourcePath)},\"base64\":${escapeJsonString(asset.base64)}}")
    }
    out.append("],\"orphanDocComments\":[")
    first = true
    for (comment in documentation.orphanDocComments) {
        if (!first) { out.append(",") }; first = false
        out.append("{\"rawText\":${escapeJsonString(comment.rawText)},\"source\":")
        appendRange(out, comment.source); out.append("}")
    }
    out.append("],\"macroInvocations\":[")
    first = true
    for (invocation in documentation.macroInvocations) {
        if (!first) { out.append(",") }; first = false
        out.append("{\"name\":${escapeJsonString(invocation.name)},\"source\":")
        appendRange(out, invocation.source); out.append("}")
    }
    out.append("],\"unsupportedDeclarations\":[")
    first = true
    for (item in documentation.unsupportedDeclarations) {
        if (!first) { out.append(",") }; first = false
        out.append("{\"kind\":${escapeJsonString(item.kind)},\"name\":${escapeJsonString(item.name)},")
        out.append("\"reason\":${escapeJsonString(item.reason)},\"source\":")
        appendRange(out, item.source); out.append("}")
    }
    out.append("],\"unboundSemanticDeclarations\":[")
    first = true
    for (item in documentation.unboundSemanticDeclarations) {
        if (!first) { out.append(",") }; first = false
        out.append("{\"provider\":${escapeJsonString(item.provider)},\"display\":${escapeJsonString(item.display)},")
        out.append("\"reason\":${escapeJsonString(item.reason)}}")
    }
    out.append("],\"diagnostics\":[")
    first = true
    for (diagnostic in documentation.diagnostics) {
        if (!first) { out.append(",") }; first = false; appendDiagnostic(out, diagnostic)
    }
    out.append("]}")
    out.toString()
}

private func appendIndent(out: StringBuilder, depth: Int64): Unit {
    var index: Int64 = 0
    while (index < depth) { out.append("  "); index++ }
}

private func prettyJson(compact: String): String {
    let out = StringBuilder()
    var depth: Int64 = 0
    var inString = false
    var escaped = false
    for (rune in compact.runes()) {
        if (inString) {
            out.append(rune)
            if (escaped) {
                escaped = false
            } else {
                match (rune) {
                    case '\\' => escaped = true
                    case '"' => inString = false
                    case _ => ()
                }
            }
            continue
        }
        match (rune) {
            case '"' => inString = true; out.append(rune)
            case '{' | '[' => depth++; out.append(rune); out.append("\n"); appendIndent(out, depth)
            case '}' | ']' => depth--; out.append("\n"); appendIndent(out, depth); out.append(rune)
            case ',' => out.append(",\n"); appendIndent(out, depth)
            case ':' => out.append(": ")
            case _ => out.append(rune)
        }
    }
    out.append("\n")
    out.toString()
}

public func encodeDocIr(documentation: DocumentationSet): String {
    prettyJson(compactDocIr(documentation))
}
