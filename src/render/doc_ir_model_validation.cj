package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func compositeKey(left: String, right: String): String {
    "${left.size}:${left}${right}"
}

func symbolIdModulePrefix(moduleId: String): String {
    let out = StringBuilder()
    out.append("cjdoc:v2:")
    for (rune in moduleId.runes()) {
        match (rune) {
            case ':' => out.append("%3A")
            case '#' => out.append("%23")
            case '(' => out.append("%28")
            case ')' => out.append("%29")
            case ',' => out.append("%2C")
            case '%' => out.append("%25")
            case _ => out.append(rune)
        }
    }
    out.append("::")
    out.toString()
}

func safeRelativePath(value: String): Bool {
    if (value.isEmpty() || value.startsWith("/") || value.endsWith("/") ||
        value.contains("//") || value.contains("\\")) { return false }
    let segments = value.split("/")
    for (segment in segments) {
        if (segment.isEmpty() || segment == "." || segment == "..") { return false }
    }
    let first = segments[0].toArray()
    if (first.size >= 2 && first[1] == b':' &&
        ((first[0] >= b'A' && first[0] <= b'Z') ||
        (first[0] >= b'a' && first[0] <= b'z'))) {
        return false
    }
    true
}

internal func validateRange(value: SourceRange, path: String): Unit {
    if (!safeRelativePath(value.path)) { domainFail("${path}.path", "unsafe portable path") }
    if (value.end.byteOffset < value.start.byteOffset || value.end.line < value.start.line ||
        (value.end.line == value.start.line && value.end.column < value.start.column)) {
        domainFail(path, "source range ends before it starts")
    }
}

internal func validateType(value: TypeRef, path: String, depth: Int64,
    providers: HashMap<String, ProviderInfo>, moduleId: String): Unit {
    if (depth > DOC_IR_MAX_TYPE_DEPTH) {
        domainFail(path, "type nesting exceeds ${DOC_IR_MAX_TYPE_DEPTH}")
    }
    if (value.kind.isEmpty()) { domainFail("${path}.kind", "must not be empty") }
    match (value.semantic.canonical) {
        case Some(canonical) => if (canonical.trimAscii().isEmpty()) {
            domainFail("${path}.semantic.canonical", "canonical type spelling must not be empty")
        }
        case None => ()
    }
    if (value.semantic.state == "unavailable") {
        if (value.semantic.canonical.isSome() || value.semantic.provider.isSome()) {
            domainFail("${path}.semantic",
                "unavailable type semantics cannot carry canonical or provider data")
        }
    } else {
        if (value.semantic.provider.isNone()) {
            domainFail("${path}.semantic.provider",
                "non-unavailable type semantics require a provider")
        }
        if (value.semantic.state == "resolved" && value.semantic.canonical.isNone()) {
            domainFail("${path}.semantic.canonical",
                "resolved type semantics require a canonical spelling")
        }
    }
    match (value.semantic.provider) {
        case Some(provider) =>
            match (providerFor(providers, moduleId, provider)) {
                case Some(info) =>
                    if (info.state == "unavailable") {
                        domainFail("${path}.semantic.provider",
                            "unavailable provider cannot supply type semantics")
                    }
                    if (value.semantic.canonical.isSome() && !info.capabilities.canonicalTypes) {
                        domainFail("${path}.semantic", "canonical type data lacks provider capability")
                    }
                case None =>
                    domainFail("${path}.semantic.provider", "provider is not declared for the module")
            }
        case None => ()
    }
    var index: Int64 = 0
    for (argument in value.arguments) {
        validateType(argument, "${path}.arguments[${index}]", depth + 1, providers, moduleId)
        index++
    }
}

internal func validMarkdownAlignment(value: String): Bool {
    value == "none" || value == "left" || value == "center" || value == "right"
}

internal func markdownBlockKind(kind: String): Bool {
    match (kind) {
        case "block_quote" | "list" | "paragraph" | "heading" | "thematic_break" |
            "code_block" | "html_block" | "table" | "custom_block" => true
        case _ => false
    }
}

internal func markdownInlineKind(kind: String): Bool {
    match (kind) {
        case "text" | "soft_break" | "hard_break" | "code_span" | "emphasis" |
            "strong" | "strikethrough" | "link" | "image" | "html_inline" |
            "custom_inline" => true
        case _ => false
    }
}

internal func validMarkdownChild(parent: String, child: String): Bool {
    match (parent) {
        case "document" | "block_quote" | "list_item" | "custom_block" =>
            markdownBlockKind(child)
        case "list" => child == "list_item"
        case "table" => child == "table_row"
        case "table_row" => child == "table_cell"
        case "paragraph" | "heading" | "table_cell" | "emphasis" | "strong" |
            "strikethrough" | "link" | "image" | "custom_inline" =>
            markdownInlineKind(child)
        case _ => false
    }
}

internal func validateMarkdownMetadata(node: MarkdownNode, path: String): Unit {
    match (node.metadata) {
        case None => ()
        case Some(value) =>
            if (value.kind != node.kind) {
                domainFail("${path}.metadata", "metadata kind does not match Markdown node kind")
            }
            match (node.kind) {
                case "heading" =>
                    let level = value.headingLevel.getOrThrow()
                    if (level < 1 || level > 6) {
                        domainFail("${path}.metadata.level", "heading level must be in 1..6")
                    }
                case "list" =>
                    let listKind = value.listKind.getOrThrow()
                    let delimiter = value.listDelimiter.getOrThrow()
                    let start = value.listStart.getOrThrow()
                    if ((listKind != "bullet" && listKind != "ordered") ||
                        start < 0 ||
                        (listKind == "bullet" && (start != 0 || delimiter != "none")) ||
                        (listKind == "ordered" && start < 1) ||
                        (listKind == "ordered" && delimiter != "period" && delimiter != "parenthesis")) {
                        domainFail("${path}.metadata", "invalid list metadata")
                    }
                    if (listKind == "ordered" && !node.children.isEmpty() &&
                        start > DOC_IR_MAX_ORDERED_LIST_NUMBER - (node.children.size - 1)) {
                        domainFail("${path}.metadata.start",
                            "ordered list numbering must remain within 1..${DOC_IR_MAX_ORDERED_LIST_NUMBER}")
                    }
                    let _ = value.listTight.getOrThrow()
                case "list_item" =>
                    let state = value.taskState.getOrThrow()
                    if (state != "notTask" && state != "checked" && state != "unchecked") {
                        domainFail("${path}.metadata.taskState", "invalid task state")
                    }
                case "code_block" =>
                    let codeKind = value.codeKind.getOrThrow()
                    let fenceLength = value.fenceLength.getOrThrow()
                    let infoRaw = value.infoRaw.getOrThrow()
                    if (infoRaw.contains("\n") || infoRaw.contains("\r")) {
                        domainFail("${path}.metadata.infoRaw", "code fence info must be a single line")
                    }
                    if (codeKind == "indented") {
                        if (value.fenceCharacter.isSome() || fenceLength != 0) {
                            domainFail("${path}.metadata", "indented code must not carry a fence")
                        }
                    } else if (codeKind == "fenced") {
                        let marker = match (value.fenceCharacter) {
                            case Some(item) => item
                            case None => domainFail("${path}.metadata.fenceCharacter",
                                "fenced code requires a marker")
                        }
                        if ((marker != "`" && marker != "~") || fenceLength < 3 ||
                            fenceLength > DOC_IR_MAX_FENCE_LENGTH) {
                            domainFail("${path}.metadata", "invalid fenced-code metadata")
                        }
                        if (marker == "`" && infoRaw.contains("`")) {
                            domainFail("${path}.metadata.infoRaw",
                                "backtick-fenced code info must not contain a backtick")
                        }
                    } else {
                        domainFail("${path}.metadata.codeKind", "invalid code block kind")
                    }
                    let _ = value.language.getOrThrow()
                    let _ = value.attributesRaw.getOrThrow()
                case "table" => for (alignment in value.tableAlignments) {
                    if (!validMarkdownAlignment(alignment)) {
                        domainFail("${path}.metadata.alignments", "invalid table alignment")
                    }
                }
                case "table_row" => let _ = value.tableHeader.getOrThrow()
                case "table_cell" => if (!validMarkdownAlignment(value.tableAlignment.getOrThrow())) {
                    domainFail("${path}.metadata.alignment", "invalid table-cell alignment")
                }
                case _ => domainFail("${path}.metadata", "metadata is not allowed for this Markdown kind")
            }
    }
}

internal func validateMarkdownTable(value: MarkdownNode, path: String): Unit {
    if (value.kind != "table") { return }
    if (value.children.isEmpty()) {
        domainFail("${path}.children", "table must contain a header row")
    }
    let columnCount = value.children[0].children.size
    if (columnCount == 0) {
        domainFail("${path}.children[0].children", "table rows must contain at least one cell")
    }
    let hasMetadata = value.metadata.isSome()
    if (hasMetadata && value.metadata.getOrThrow().tableAlignments.size != columnCount) {
        domainFail("${path}.metadata.alignments", "table alignment count does not match its columns")
    }
    var rowIndex: Int64 = 0
    for (row in value.children) {
        if (row.children.size != columnCount) {
            domainFail("${path}.children[${rowIndex}].children", "table rows must have equal column counts")
        }
        match (row.metadata) {
            case Some(metadata) =>
                if (!hasMetadata || metadata.tableHeader.getOrThrow() != (rowIndex == 0)) {
                    domainFail("${path}.children[${rowIndex}].metadata.header",
                        "only the first table row may be a header")
                }
            case None => if (hasMetadata) {
                domainFail("${path}.children[${rowIndex}].metadata",
                    "closed table metadata requires row metadata")
            }
        }
        var columnIndex: Int64 = 0
        for (cell in row.children) {
            match (cell.metadata) {
                case Some(metadata) =>
                    if (!hasMetadata || metadata.tableAlignment.getOrThrow() !=
                        value.metadata.getOrThrow().tableAlignments[columnIndex]) {
                        domainFail("${path}.children[${rowIndex}].children[${columnIndex}].metadata.alignment",
                            "table-cell alignment does not match table metadata")
                    }
                case None => if (hasMetadata) {
                    domainFail("${path}.children[${rowIndex}].children[${columnIndex}].metadata",
                        "closed table metadata requires cell metadata")
                }
            }
            columnIndex++
        }
        rowIndex++
    }
}

internal func validateMarkdown(value: MarkdownNode, path: String, depth: Int64): Unit {
    if (depth > DOC_IR_MAX_MARKDOWN_DEPTH) {
        domainFail(path, "Markdown nesting exceeds ${DOC_IR_MAX_MARKDOWN_DEPTH}")
    }
    match (value.kind) {
        case "document" | "block_quote" | "list" | "list_item" | "paragraph" | "heading" |
            "thematic_break" | "code_block" | "html_block" | "table" | "table_row" |
            "table_cell" | "custom_block" | "text" | "soft_break" | "hard_break" |
            "code_span" | "emphasis" | "strong" | "strikethrough" | "link" | "image" |
            "html_inline" | "custom_inline" => ()
        case _ => domainFail("${path}.kind", "unknown Markdown node kind")
    }
    validateMarkdownMetadata(value, path)
    if ((value.kind == "document" || value.kind == "block_quote" || value.kind == "list" ||
        value.kind == "list_item" || value.kind == "paragraph" || value.kind == "heading" ||
        value.kind == "thematic_break" || value.kind == "table" || value.kind == "table_row" ||
        value.kind == "table_cell" || value.kind == "emphasis" || value.kind == "strong" ||
        value.kind == "strikethrough") && !value.literal.isEmpty()) {
        domainFail("${path}.literal", "container Markdown node must not carry fallback text")
    }
    if ((value.kind == "text" || value.kind == "soft_break" || value.kind == "hard_break" ||
        value.kind == "thematic_break" || value.kind == "code_block" || value.kind == "code_span" ||
        value.kind == "html_block" || value.kind == "html_inline") && !value.children.isEmpty()) {
        domainFail("${path}.children", "leaf Markdown node must not contain children")
    }
    match (value.source) { case Some(range) => validateRange(range, "${path}.source") case None => () }
    var index: Int64 = 0
    for (child in value.children) {
        if (!validMarkdownChild(value.kind, child.kind)) {
            domainFail("${path}.children[${index}]",
                "Markdown kind '${child.kind}' is not allowed under '${value.kind}'")
        }
        validateMarkdown(child, "${path}.children[${index}]", depth + 1)
        index++
    }
    validateMarkdownTable(value, path)
}

internal func validateMarkdownAssetReferences(value: MarkdownNode, path: String,
    assetIds: HashSet<String>): Unit {
    if (value.kind == "image" && value.literal.startsWith("sha256-") &&
        !assetIds.contains(value.literal)) {
        domainFail("${path}.literal", "content-addressed image does not reference a document asset")
    }
    var index: Int64 = 0
    for (child in value.children) {
        validateMarkdownAssetReferences(child, "${path}.children[${index}]", assetIds)
        index++
    }
}

internal func providerFor(providers: HashMap<String, ProviderInfo>, moduleId: String,
    name: String): ?ProviderInfo {
    providers.get(compositeKey(moduleId, name))
}

internal func providerSupportsAnnotations(providers: HashMap<String, ProviderInfo>, moduleId: String,
    name: String): Bool {
    match (providerFor(providers, moduleId, name)) {
        case Some(provider) => provider.capabilities.annotations
        case None => false
    }
}

internal func providerSupportsRelationships(providers: HashMap<String, ProviderInfo>, moduleId: String,
    name: String): Bool {
    match (providerFor(providers, moduleId, name)) {
        case Some(provider) => provider.capabilities.relationships
        case None => false
    }
}

internal func moduleColor(colors: HashMap<String, Int64>, id: String): Int64 {
    match (colors.get(id)) { case Some(value) => value case None => 0 }
}

internal func validateModuleDependencyDag(modules: ReadOnlyList<ModuleDoc>,
    byId: HashMap<String, ModuleDoc>): Unit {
    // 0/absent = white, 1 = gray, 2 = black. Each node and edge is completed once.
    let colors = HashMap<String, Int64>()
    for (root in modules) {
        if (moduleColor(colors, root.id) == 2) { continue }
        let stack = ArrayList<(ModuleDoc, Int64)>()
        colors[root.id] = 1
        stack.add((root, 0))
        while (!stack.isEmpty()) {
            let (current, edge) = stack[stack.size - 1]
            if (edge >= current.dependencyIds.size) {
                colors[current.id] = 2
                stack.remove(at: stack.size - 1)
                continue
            }
            stack[stack.size - 1] = (current, edge + 1)
            let dependency = byId[current.dependencyIds[edge]]
            let color = moduleColor(colors, dependency.id)
            if (color == 1) {
                domainFail("$.modules", "dependency cycle contains '${dependency.id}'")
            }
            if (color == 0) {
                colors[dependency.id] = 1
                stack.add((dependency, 0))
            }
        }
    }
}

internal func validateOwnerDag(declarations: ReadOnlyList<SymbolDoc>, byId: HashMap<String, SymbolDoc>): Unit {
    let complete = HashSet<String>()
    for (declaration in declarations) {
        if (complete.contains(declaration.id)) { continue }
        let local = HashSet<String>()
        let path = ArrayList<String>()
        var current: ?SymbolDoc = Some(declaration)
        while (current.isSome()) {
            let symbol = current.getOrThrow()
            if (complete.contains(symbol.id)) { break }
            if (!local.add(symbol.id)) {
                domainFail("$.declarations", "owner cycle contains '${symbol.id}'")
            }
            path.add(symbol.id)
            current = match (symbol.ownerId) {
                case Some(ownerId) => byId.get(ownerId)
                case None => None
            }
        }
        for (id in path) { let _ = complete.add(id) }
    }
}

protected func isDocIrContainerKind(kind: String): Bool {
    kind == "class" || kind == "struct" || kind == "interface" || kind == "enum" ||
        kind == "extend"
}

internal func validSha256AssetId(value: String): Bool {
    if (!value.startsWith("sha256-") || value.size != 71) { return false }
    let bytes = value.toArray()
    var index: Int64 = 7
    while (index < bytes.size) {
        let byte = bytes[index]
        if (!((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) {
            return false
        }
        index++
    }
    true
}

internal func validReExportId(value: String): Bool {
    let prefix = "cjdoc:reexport:v1:"
    if (!value.startsWith(prefix) || value.size != prefix.size + 64) { return false }
    let bytes = value.toArray()
    var index = prefix.size
    while (index < bytes.size) {
        let byte = bytes[index]
        if (!((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) {
            return false
        }
        index++
    }
    true
}

