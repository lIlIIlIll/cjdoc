package cjdoc_core

import markdown.{AstQuery, Markdown}
import std.collection.*
import std.sort.*
import std.unicode.*

private func repeatText(value: String, count: Int64): String {
    let builder = StringBuilder()
    for (_ in 0..count) { builder.append(value) }
    builder.toString()
}

private func setextTitle(source: String): String {
    let lines = source.split("\n")
    let builder = StringBuilder()
    var index: Int64 = 0
    var first = true
    while (index + 1 < lines.size) {
        let line = lines[index].trimAscii()
        if (!line.isEmpty()) {
            if (!first) { builder.append(" ") }
            builder.append(line)
            first = false
        }
        index++
    }
    builder.toString()
}

private func demoteHeadings(source: String, depth: Int64): String {
    if (source.isEmpty() || depth <= 0) { return source }
    let parsed = Markdown.parse(source)
    let headings = AstQuery.headings(parsed.document)
    if (headings.isEmpty()) { return source }
    let builder = StringBuilder()
    var cursor: Int64 = 0
    for (heading in headings) {
        if (let Some(span) <- heading.node.span) {
            if (span.startByte < cursor || span.endByte > source.size) { continue }
            let targetLevel = if (heading.level + depth > 6) { 6 } else { heading.level + depth }
            let headingSource = source[span.startByte..span.endByte]
            if (headingSource.trimAsciiStart().startsWith("#")) {
                var markerStart = span.startByte
                while (markerStart < span.endByte && source[markerStart] == b' ') { markerStart++ }
                builder.append(source[cursor..markerStart])
                builder.append(repeatText("#", targetLevel - heading.level))
                builder.append(source[markerStart..span.endByte])
            } else {
                builder.append(source[cursor..span.startByte])
                builder.append(repeatText("#", targetLevel))
                builder.append(" ")
                builder.append(setextTitle(headingSource))
            }
            cursor = span.endByte
        }
    }
    builder.append(source[cursor..])
    builder.toString()
}

func prepareDocumentationMarkdown(source: String, headingDepth!: Int64 = 3): String {
    if (source.trimAscii().isEmpty()) { return "" }
    let normalized = source.trimAscii()
    try {
        demoteHeadings(normalized, headingDepth)
    } catch (_: Exception) {
        normalized
    }
}

private func appendDocText(builder: StringBuilder, value: String, headingDepth!: Int64 = 3): Unit {
    let prepared = prepareDocumentationMarkdown(value, headingDepth: headingDepth)
    if (!prepared.isEmpty()) {
        builder.append(prepared)
        builder.append("\n\n")
    }
}

func markdownInputComplete(value: String): Bool {
    if (value.trimAscii().isEmpty()) { return true }
    try {
        let parsed = Markdown.parse(value)
        parsed.isComplete && parsed.errors.size == 0
    } catch (_: Exception) {
        false
    }
}

private func documentationMarkdownComplete(comment: DocComment): Bool {
    if (!markdownInputComplete(comment.summaryMarkdown) || !markdownInputComplete(comment.descriptionMarkdown)) {
        return false
    }
    for (tag in comment.params) {
        if (!markdownInputComplete(tag.description)) { return false }
    }
    if (let Some(tag) <- comment.returns) {
        if (!markdownInputComplete(tag.description)) { return false }
    }
    for (tag in comment.throwsTags) {
        if (!markdownInputComplete(tag.description)) { return false }
    }
    for (tag in comment.see) {
        if (!markdownInputComplete(tag.description)) { return false }
    }
    if (let Some(value) <- comment.since) {
        if (!markdownInputComplete(value)) { return false }
    }
    if (let Some(value) <- comment.deprecated) {
        if (!markdownInputComplete(value)) { return false }
    }
    for (author in comment.authors) {
        if (!markdownInputComplete(author)) { return false }
    }
    if (let Some(value) <- comment.version) {
        if (!markdownInputComplete(value)) { return false }
    }
    true
}

private func unsafeMarkdownDestination(destination: String): Bool {
    let lower = destination.trimAscii().toLower()
    lower.startsWith("javascript:") || lower.startsWith("data:") ||
        lower.startsWith("vbscript:") || lower.startsWith("file:")
}

private func validateMarkdownValue(value: String, symbol: SymbolDoc,
    knownSymbolAnchors: HashSet<String>, diagnostics: ArrayList<Diagnostic>): Unit {
    if (value.trimAscii().isEmpty()) { return }
    try {
        let parsed = Markdown.parse(value)
        for (link in AstQuery.links(parsed.document)) {
            let destination = link.destination.trimAscii()
            if (destination.isEmpty() || unsafeMarkdownDestination(destination)) {
                diagnostics.add(Diagnostic("warning", "CJDOC1024",
                    "unsafe or empty Markdown link destination",
                    source: symbol.source, symbolId: symbol.id))
            } else if (destination.startsWith("#cjdoc-symbol-") &&
                !knownSymbolAnchors.contains(destination[1..])) {
                diagnostics.add(Diagnostic("warning", "CJDOC1024",
                    "broken Markdown symbol anchor '${destination}'",
                    source: symbol.source, symbolId: symbol.id))
            }
        }
    } catch (_: Exception) {
        // Parse completeness is reported separately as CJDOC1014.
    }
}

private func validateCommentLinks(comment: DocComment, symbol: SymbolDoc,
    knownSymbolAnchors: HashSet<String>, diagnostics: ArrayList<Diagnostic>): Unit {
    validateMarkdownValue(comment.summaryMarkdown, symbol, knownSymbolAnchors, diagnostics)
    validateMarkdownValue(comment.descriptionMarkdown, symbol, knownSymbolAnchors, diagnostics)
    for (tag in comment.params) {
        validateMarkdownValue(tag.description, symbol, knownSymbolAnchors, diagnostics)
    }
    if (let Some(tag) <- comment.returns) {
        validateMarkdownValue(tag.description, symbol, knownSymbolAnchors, diagnostics)
    }
    for (tag in comment.throwsTags) {
        validateMarkdownValue(tag.description, symbol, knownSymbolAnchors, diagnostics)
    }
    for (tag in comment.see) {
        validateMarkdownValue(tag.description, symbol, knownSymbolAnchors, diagnostics)
    }
}

public func validateDocumentationMarkdown(documentation: DocumentationSet): Unit {
    let knownSymbolAnchors = HashSet<String>()
    for (symbol in documentation.symbols) {
        let _ = knownSymbolAnchors.add(markdownSymbolAnchor(symbol))
    }
    for (symbol in documentation.symbols) {
        if (let Some(comment) <- symbol.documentation) {
            if (!documentationMarkdownComplete(comment)) {
                documentation.diagnostics.add(Diagnostic("warning", "CJDOC1014",
                    "Markdown documentation could not be parsed completely", source: symbol.source,
                    symbolId: symbol.id))
            }
            validateCommentLinks(comment, symbol, knownSymbolAnchors, documentation.diagnostics)
        }
    }
}

private func maxBacktickRun(value: String): Int64 {
    var maximum: Int64 = 0
    var current: Int64 = 0
    for (rune in value.runes()) {
        if (rune == r'`') {
            current++
            if (current > maximum) { maximum = current }
        } else {
            current = 0
        }
    }
    maximum
}

private func codeSpan(value: String): String {
    let maximum = maxBacktickRun(value)
    if (maximum == 0 && !value.startsWith(" ") && !value.endsWith(" ")) {
        return "`" + value + "`"
    }
    let fence = repeatText("`", maximum + 1)
    fence + " " + value + " " + fence
}

private func appendCodeBlock(builder: StringBuilder, value: String): Unit {
    let length = maxBacktickRun(value) + 1
    let fence = repeatText("`", if (length < 3) { 3 } else { length })
    builder.append(fence)
    builder.append("cj\n")
    builder.append(value)
    if (!value.endsWith("\n")) { builder.append("\n") }
    builder.append(fence)
    builder.append("\n\n")
}

private func appendMetadata(builder: StringBuilder, label: String, value: String): Unit {
    builder.append("- ")
    builder.append(label)
    builder.append(": ")
    builder.append(codeSpan(value))
    builder.append("\n")
}

private func markdownRelationshipLabel(kind: String): String {
    match (kind) {
        case "extensionTarget" => "Extension target"
        case "superType" => "Supertype"
        case _ => kind
    }
}

private func moduleName(documentation: DocumentationSet, id: String): String {
    for (module in documentation.modules) {
        if (module.id == id) { return module.name }
    }
    id
}

private func appendModules(builder: StringBuilder, documentation: DocumentationSet): Unit {
    if (documentation.modules.isEmpty()) { return }
    builder.append("## Modules\n\n")
    for (module in documentation.modules) {
        builder.append("### ")
        builder.append(codeSpan(module.name))
        builder.append("\n\n")
        appendMetadata(builder, "Module ID", module.id)
        appendMetadata(builder, "Role", module.role)
        appendMetadata(builder, "Source prefix", if (module.sourcePrefix.isEmpty()) { "." } else { module.sourcePrefix })
        builder.append("\nPackages:\n\n")
        if (module.packageNames.isEmpty()) {
            builder.append("- None\n")
        } else {
            for (packageName in module.packageNames) {
                builder.append("- ")
                builder.append(codeSpan(packageName))
                builder.append("\n")
            }
        }
        builder.append("\nDirect dependencies:\n\n")
        if (module.dependencyIds.isEmpty()) {
            builder.append("- None\n")
        } else {
            for (dependencyId in module.dependencyIds) {
                builder.append("- ")
                builder.append(codeSpan(moduleName(documentation, dependencyId)))
                builder.append("\n")
            }
        }
        builder.append("\n")
    }
}

private func markdownSymbolAnchor(symbol: SymbolDoc): String {
    "cjdoc-symbol-" + htmlStableSlug(symbol.id)
}

private func appendSymbolDocumentation(builder: StringBuilder, documentation: DocumentationSet,
    symbol: SymbolDoc): Unit {
    builder.append("<a id=\"")
    builder.append(markdownSymbolAnchor(symbol))
    builder.append("\"></a>\n\n")
    builder.append("### ")
    builder.append(codeSpan(symbol.qualifiedName))
    builder.append("\n\n")
    appendMetadata(builder, "Kind", symbol.kind)
    appendMetadata(builder, "Visibility", symbol.visibility)
    appendMetadata(builder, "Symbol ID", symbol.id)
    if (let Some(owner) <- symbol.ownerId) { appendMetadata(builder, "Owner", owner) }
    appendMetadata(builder, "Source", "${symbol.source.path}:${symbol.source.startLine}:${symbol.source.startColumn}")
    builder.append("\n")
    appendCodeBlock(builder, symbol.sourceSignature)

    if (!symbol.relationships.isEmpty() || !symbol.symbolRelationships.isEmpty()) {
        builder.append("#### Relationships\n\n")
        for (relationship in symbol.relationships) {
            builder.append("- ")
            builder.append(markdownRelationshipLabel(relationship.kind))
            builder.append(": ")
            builder.append(codeSpan(relationship.target.display))
            builder.append(" — semantic state ")
            builder.append(codeSpan(relationship.target.state))
            builder.append("\n")
        }
        for (relationship in symbol.symbolRelationships) {
            builder.append("- ")
            builder.append(if (relationship.kind == "override") { "Override target" } else { relationship.kind })
            builder.append(": ")
            builder.append(codeSpan(relationship.targetDisplay))
            builder.append(" — semantic state ")
            builder.append(codeSpan(relationship.state))
            builder.append("\n")
        }
        builder.append("\n")
    }

    if (!symbol.genericParameters.isEmpty()) {
        builder.append("#### Generic parameters\n\n")
        for (parameter in symbol.genericParameters) {
            builder.append("- ")
            builder.append(codeSpan(parameter))
            builder.append("\n")
        }
        builder.append("\n")
    }

    if (!symbol.annotations.isEmpty()) {
        builder.append("#### Annotations\n\n")
        for (annotation in symbol.annotations) {
            builder.append("- ")
            builder.append(codeSpan(annotation))
            builder.append("\n")
        }
        builder.append("\n")
    }

    if (let Some(comment) <- symbol.documentation) {
        if (let Some(deprecated) <- comment.deprecated) {
            builder.append("#### Deprecated\n\n")
            appendDocText(builder, deprecated, headingDepth: 4)
        }
        appendDocText(builder, comment.summaryMarkdown)
        appendDocText(builder, comment.descriptionMarkdown)
    }

    if (!symbol.parameters.isEmpty()) {
        builder.append("#### Parameters\n\n")
        for (parameter in symbol.parameters) {
            builder.append("##### ")
            builder.append(codeSpan(parameter.name))
            builder.append("\n\nType: ")
            builder.append(codeSpan(parameter.typeRef.display))
            builder.append("\n\n")
            if (let Some(description) <- parameter.documentation) {
                appendDocText(builder, description, headingDepth: 5)
            }
        }
    }

    if (let Some(returnType) <- symbol.returnType) {
        builder.append("#### Returns\n\nType: ")
        builder.append(codeSpan(returnType.display))
        builder.append("\n\n")
        if (let Some(comment) <- symbol.documentation) {
            if (let Some(tag) <- comment.returns) {
                appendDocText(builder, tag.description, headingDepth: 4)
            }
        }
    }

    if (let Some(comment) <- symbol.documentation) {
        if (!comment.throwsTags.isEmpty()) {
            builder.append("#### Throws\n\n")
            for (tag in comment.throwsTags) {
                builder.append("##### ")
                builder.append(codeSpan(tag.subject))
                builder.append("\n\n")
                appendDocText(builder, tag.description, headingDepth: 5)
            }
        }
        if (!comment.see.isEmpty()) {
            builder.append("#### See also\n\n")
            for (tag in comment.see) {
                builder.append("##### ")
                if (let Some(target) <- resolvedReferenceTarget(documentation, tag)) {
                    builder.append("[")
                    builder.append(codeSpan(tag.subject))
                    builder.append("](#")
                    builder.append(markdownSymbolAnchor(target))
                    builder.append(")")
                } else {
                    builder.append(codeSpan(tag.subject))
                }
                builder.append("\n\n")
                if (!tag.description.isEmpty()) {
                    appendDocText(builder, tag.description, headingDepth: 5)
                }
            }
        }
        if (let Some(since) <- comment.since) {
            builder.append("#### Since\n\n")
            appendDocText(builder, since, headingDepth: 4)
        }
        if (!comment.authors.isEmpty()) {
            builder.append("#### Authors\n\n")
            for (author in comment.authors) {
                builder.append("- ")
                builder.append(codeSpan(author))
                builder.append("\n")
            }
            builder.append("\n")
        }
        if (let Some(version) <- comment.version) {
            builder.append("#### Version\n\n")
            appendDocText(builder, version, headingDepth: 4)
        }
    }
}

private func appendDiagnostics(builder: StringBuilder, documentation: DocumentationSet): Unit {
    if (documentation.diagnostics.isEmpty()) { return }
    builder.append("## Diagnostics\n\n")
    for (diagnostic in documentation.diagnostics) {
        builder.append("- **")
        builder.append(diagnostic.severity)
        builder.append("[")
        builder.append(diagnostic.code)
        builder.append("]**: ")
        builder.append(diagnostic.message)
        if (let Some(source) <- diagnostic.source) {
            builder.append(" (")
            builder.append(codeSpan("${source.path}:${source.startLine}:${source.startColumn}"))
            builder.append(")")
        }
        builder.append("\n")
    }
    builder.append("\n")
}

public func renderDocumentationMarkdown(documentation: DocumentationSet): String {
    sortDocumentationDeterministically(documentation)
    sort(documentation.symbols, lessThan: { left, right =>
        left.packageName < right.packageName ||
            (left.packageName == right.packageName && left.source.path < right.source.path) ||
            (left.packageName == right.packageName && left.source.path == right.source.path &&
                left.source.startLine < right.source.startLine) ||
            (left.packageName == right.packageName && left.source.path == right.source.path &&
                left.source.startLine == right.source.startLine && left.source.startColumn < right.source.startColumn) ||
            (left.packageName == right.packageName && left.source.path == right.source.path &&
                left.source.startLine == right.source.startLine && left.source.startColumn == right.source.startColumn &&
                left.id < right.id)
    }, stable: true)
    let builder = StringBuilder()
    builder.append("# ")
    builder.append(codeSpan(documentation.projectName))
    builder.append(" API documentation\n\n")
    builder.append("Generated by `cjdoc 0.3.0`.\n\n")
    appendModules(builder, documentation)

    var symbolIndex: Int64 = 0
    for (pkg in documentation.packages) {
        builder.append("## Package ")
        builder.append(codeSpan(pkg.name))
        builder.append("\n\n")
        if (!pkg.sourceFiles.isEmpty()) {
            builder.append("Sources:\n\n")
            for (path in pkg.sourceFiles) {
                builder.append("- ")
                builder.append(codeSpan(path))
                builder.append("\n")
            }
            builder.append("\n")
        }
        while (symbolIndex < documentation.symbols.size &&
            documentation.symbols[symbolIndex].packageName == pkg.name) {
            appendSymbolDocumentation(builder, documentation, documentation.symbols[symbolIndex])
            symbolIndex++
        }
    }
    appendDiagnostics(builder, documentation)
    builder.toString()
}
