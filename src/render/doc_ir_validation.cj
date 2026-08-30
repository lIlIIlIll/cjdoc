package cjdoc.render

import cjdoc.model.*
import std.collection.*

private func domainFail(path: String, message: String): Nothing {
    throw IllegalArgumentException("invalid Doc IR domain at ${path}: ${message}")
}

private func compositeKey(left: String, right: String): String {
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

private func stringListContains(values: ReadOnlyList<String>, expected: String): Bool {
    for (value in values) { if (value == expected) { return true } }
    false
}

private func safeRelativePath(value: String): Bool {
    if (value.isEmpty() || value.startsWith("/") || value.contains("\\")) { return false }
    let segments = value.split("/")
    for (segment in segments) {
        if (segment.isEmpty() || segment == "." || segment == "..") { return false }
    }
    if (segments[0].size == 2 && segments[0].toArray()[1] == b':') { return false }
    true
}

private func validateRange(value: SourceRange, path: String): Unit {
    if (!safeRelativePath(value.path)) { domainFail("${path}.path", "unsafe portable path") }
    if (value.end.byteOffset < value.start.byteOffset || value.end.line < value.start.line ||
        (value.end.line == value.start.line && value.end.column < value.start.column)) {
        domainFail(path, "source range ends before it starts")
    }
}

private func validateType(value: TypeRef, path: String, depth: Int64,
    providers: ReadOnlyList<ProviderInfo>, moduleId: String): Unit {
    if (depth > 64) { domainFail(path, "type nesting exceeds 64") }
    if (value.kind.isEmpty()) { domainFail("${path}.kind", "must not be empty") }
    match (value.semantic.provider) {
        case Some(provider) =>
            if (!containsProvider(providers, moduleId, provider)) {
                domainFail("${path}.semantic.provider", "provider is not declared for the module")
            }
        case None => if (value.semantic.state == "resolved") {
            domainFail("${path}.semantic.provider", "resolved type requires a provider")
        }
    }
    var index: Int64 = 0
    for (argument in value.arguments) {
        validateType(argument, "${path}.arguments[${index}]", depth + 1, providers, moduleId)
        index++
    }
}

private func validateMarkdown(value: MarkdownNode, path: String, depth: Int64): Unit {
    if (depth > 64) { domainFail(path, "Markdown nesting exceeds 64") }
    match (value.kind) {
        case "document" | "block_quote" | "list" | "list_item" | "paragraph" | "heading" |
            "thematic_break" | "code_block" | "html_block" | "table" | "table_row" |
            "table_cell" | "custom_block" | "text" | "soft_break" | "hard_break" |
            "code_span" | "emphasis" | "strong" | "strikethrough" | "link" | "image" |
            "html_inline" | "custom_inline" => ()
        case _ => domainFail("${path}.kind", "unknown Markdown node kind")
    }
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
        validateMarkdown(child, "${path}.children[${index}]", depth + 1)
        index++
    }
}

private func bytesStartWith(value: Array<Byte>, expected: Array<Byte>): Bool {
    if (value.size < expected.size) { return false }
    var index: Int64 = 0
    while (index < expected.size) {
        if (value[index] != expected[index]) { return false }
        index++
    }
    true
}

private func validAssetMagic(mediaType: String, value: Array<Byte>): Bool {
    match (mediaType) {
        case "image/png" => bytesStartWith(value, [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A])
        case "image/jpeg" => value.size >= 3 && value[0] == 0xFF && value[1] == 0xD8 && value[2] == 0xFF
        case "image/gif" => bytesStartWith(value, "GIF87a".toArray()) ||
            bytesStartWith(value, "GIF89a".toArray())
        case "image/webp" => value.size >= 12 && bytesStartWith(value, "RIFF".toArray()) &&
            value[8] == b'W' && value[9] == b'E' && value[10] == b'B' && value[11] == b'P'
        case "image/avif" => value.size >= 12 && value[4] == b'f' && value[5] == b't' &&
            value[6] == b'y' && value[7] == b'p' && value[8] == b'a' && value[9] == b'v' &&
            value[10] == b'i' && (value[11] == b'f' || value[11] == b's')
        case _ => false
    }
}

private func containsProvider(providers: ReadOnlyList<ProviderInfo>, moduleId: String,
    name: String): Bool {
    for (provider in providers) {
        if (provider.moduleId == moduleId && provider.name == name) { return true }
    }
    false
}

private func providerSupportsAnnotations(providers: ReadOnlyList<ProviderInfo>, moduleId: String,
    name: String): Bool {
    for (provider in providers) {
        if (provider.moduleId == moduleId && provider.name == name) {
            return provider.capabilities.annotations
        }
    }
    false
}

private func validateModuleDependencyDag(modules: ReadOnlyList<ModuleDoc>,
    byId: HashMap<String, ModuleDoc>): Unit {
    for (root in modules) {
        let active = HashSet<String>()
        let stack = ArrayList<(ModuleDoc, Int64)>()
        stack.add((root, 0))
        while (!stack.isEmpty()) {
            let (current, edge) = stack[stack.size - 1]
            if (edge == 0 && !active.add(current.id)) {
                domainFail("$.modules", "dependency cycle contains '${current.id}'")
            }
            if (edge >= current.dependencyIds.size) {
                let _ = active.remove(current.id)
                stack.remove(at: stack.size - 1)
                continue
            }
            stack[stack.size - 1] = (current, edge + 1)
            let dependency = byId[current.dependencyIds[edge]]
            if (active.contains(dependency.id)) {
                domainFail("$.modules", "dependency cycle contains '${dependency.id}'")
            }
            stack.add((dependency, 0))
        }
    }
}

private func validateOwnerDag(declarations: ReadOnlyList<SymbolDoc>, byId: HashMap<String, SymbolDoc>): Unit {
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

public func validateDocumentationSet(documentation: DocumentationSet): Unit {
    if (documentation.schemaVersion != DOC_IR_SCHEMA_VERSION) {
        domainFail("$.schemaVersion", "typed documentation must be v7")
    }
    if (documentation.status != "complete" && documentation.status != "partial") {
        domainFail("$.status", "invalid structural status")
    }
    if (documentation.modules.isEmpty()) { domainFail("$.modules", "must contain at least one module") }

    let moduleIds = HashSet<String>()
    let modulesById = HashMap<String, ModuleDoc>()
    var index: Int64 = 0
    for (module in documentation.modules) {
        if (!module.id.startsWith("cjdoc:module:v1:") || !moduleIds.add(module.id)) {
            domainFail("$.modules[${index}].id", "empty or duplicate module id")
        }
        modulesById[module.id] = module
        let packageNames = HashSet<String>()
        for (name in module.packageNames) {
            if (name.isEmpty() || !packageNames.add(name)) {
                domainFail("$.modules[${index}].packageNames", "empty or duplicate package name")
            }
        }
        index++
    }
    index = 0
    for (module in documentation.modules) {
        let dependencies = HashSet<String>()
        for (dependencyId in module.dependencyIds) {
            if (dependencyId == module.id || !moduleIds.contains(dependencyId) ||
                !dependencies.add(dependencyId)) {
                domainFail("$.modules[${index}].dependencyIds", "invalid module dependency")
            }
        }
        index++
    }
    validateModuleDependencyDag(documentation.modules, modulesById)

    let providerKeys = HashSet<String>()
    let providerModules = HashSet<String>()
    index = 0
    for (provider in documentation.providers) {
        if (!moduleIds.contains(provider.moduleId) ||
            !providerKeys.add(compositeKey(provider.moduleId, provider.name))) {
            domainFail("$.providers[${index}]", "unknown module or duplicate provider/module pair")
        }
        let _ = providerModules.add(provider.moduleId)
        index++
    }
    for (module in documentation.modules) {
        if (!providerModules.contains(module.id)) {
            domainFail("$.providers", "module '${module.id}' has no provider result")
        }
    }

    let packageKeys = HashSet<String>()
    index = 0
    for (pkg in documentation.packages) {
        let key = compositeKey(pkg.moduleId, pkg.name)
        if (!moduleIds.contains(pkg.moduleId) || !packageKeys.add(key)) {
            domainFail("$.packages[${index}]", "unknown module or duplicate module/package pair")
        }
        var declaredByModule = false
        for (module in documentation.modules) {
            if (module.id == pkg.moduleId && stringListContains(module.packageNames, pkg.name)) {
                declaredByModule = true
                break
            }
        }
        if (!declaredByModule) { domainFail("$.packages[${index}]", "package is not listed by its module") }
        index++
    }
    for (module in documentation.modules) {
        for (name in module.packageNames) {
            if (!packageKeys.contains(compositeKey(module.id, name))) {
                domainFail("$.modules", "module '${module.id}' lists unknown package '${name}'")
            }
        }
    }

    let filePaths = HashSet<String>()
    let fileKeys = HashSet<String>()
    index = 0
    for (file in documentation.files) {
        if (!safeRelativePath(file.path) || !filePaths.add(file.path) ||
            !packageKeys.contains(compositeKey(file.moduleId, file.packageName))) {
            domainFail("$.files[${index}]", "unsafe/duplicate path or unknown module/package")
        }
        let _ = fileKeys.add(compositeKey(compositeKey(file.moduleId, file.packageName), file.path))
        index++
    }

    let byId = HashMap<String, SymbolDoc>()
    index = 0
    for (declaration in documentation.declarations) {
        if (!declaration.id.startsWith(symbolIdModulePrefix(declaration.moduleId))) {
            domainFail("$.declarations[${index}].id", "SymbolId '${declaration.id}' does not " +
                "encode owning module '${declaration.moduleId}'")
        }
        if (byId.contains(declaration.id)) {
            domainFail("$.declarations[${index}].id", "duplicate SymbolId '${declaration.id}'")
        }
        byId[declaration.id] = declaration
        if (!packageKeys.contains(compositeKey(declaration.moduleId, declaration.packageName))) {
            domainFail("$.declarations[${index}]", "unknown module/package")
        }
        if (!fileKeys.contains(compositeKey(compositeKey(declaration.moduleId,
            declaration.packageName), declaration.source.path))) {
            domainFail("$.declarations[${index}].source", "source file is not owned by declaration module/package")
        }
        validateRange(declaration.source, "$.declarations[${index}].source")
        for (parameter in declaration.parameters) {
            validateType(parameter.typeRef, "$.declarations[${index}].parameters", 0,
                documentation.providers, declaration.moduleId)
        }
        match (declaration.returnType) {
            case Some(typeRef) => validateType(typeRef, "$.declarations[${index}].returnType", 0,
                documentation.providers, declaration.moduleId)
            case None => ()
        }
        for (relationship in declaration.typeRelationships) {
            validateType(relationship.target, "$.declarations[${index}].typeRelationships", 0,
                documentation.providers, declaration.moduleId)
        }
        var annotationIndex: Int64 = 0
        for (annotation in declaration.annotations) {
            if (annotation.provenance == "provider") {
                let provider = annotation.provider.getOrThrow()
                if (!providerSupportsAnnotations(documentation.providers, declaration.moduleId, provider)) {
                    domainFail("$.declarations[${index}].annotations[${annotationIndex}]",
                        "provider annotation lacks a matching module capability")
                }
            }
            annotationIndex++
        }
        if (!containsProvider(documentation.providers, declaration.moduleId,
            declaration.semantic.provider)) {
            domainFail("$.declarations[${index}].semantic.provider", "provider is not declared for the module")
        }
        match (declaration.documentation) {
            case Some(comment) =>
                if (comment.markdown.kind != "document") {
                    domainFail("$.declarations[${index}].documentation.markdown",
                        "documentation Markdown root must be a document")
                }
                validateMarkdown(comment.markdown, "$.declarations[${index}].documentation.markdown", 0)
            case None => ()
        }
        index++
    }

    index = 0
    for (declaration in documentation.declarations) {
        match (declaration.ownerId) {
            case Some(ownerId) => match (byId.get(ownerId)) {
                case Some(owner) => if (owner.moduleId != declaration.moduleId ||
                    owner.packageName != declaration.packageName) {
                    domainFail("$.declarations[${index}].ownerId",
                        "owner crosses module/package boundary")
                }
                case None => domainFail("$.declarations[${index}].ownerId", "unknown owner")
            }
            case None => ()
        }
        for (relationship in declaration.symbolRelationships) {
            match (relationship.targetSymbolId) {
                case Some(targetId) => if (!byId.contains(targetId)) {
                    domainFail("$.declarations[${index}].symbolRelationships", "unknown target SymbolId")
                }
                case None => if (relationship.state == "resolved") {
                    domainFail("$.declarations[${index}].symbolRelationships", "resolved target is missing")
                }
            }
        }
        if (let Some(comment) <- declaration.documentation) {
            for (tag in comment.tags) {
                match (tag.targetSymbolId) {
                    case Some(targetId) => if (!byId.contains(targetId)) {
                        domainFail("$.declarations[${index}].documentation.tags", "unknown target SymbolId")
                    }
                    case None => if (tag.referenceState == "resolved") {
                        domainFail("$.declarations[${index}].documentation.tags", "resolved target is missing")
                    }
                }
            }
        }
        index++
    }
    validateOwnerDag(documentation.declarations, byId)

    index = 0
    for (pkg in documentation.packages) {
        let sourceFiles = HashSet<String>()
        for (path in pkg.sourceFiles) {
            if (!sourceFiles.add(path) || !fileKeys.contains(compositeKey(compositeKey(pkg.moduleId,
                pkg.name), path))) {
                domainFail("$.packages[${index}].sourceFiles", "duplicate or unknown source file")
            }
        }
        let symbolIds = HashSet<String>()
        for (id in pkg.symbolIds) {
            match (byId.get(id)) {
                case Some(symbol) => if (!symbolIds.add(id) || symbol.moduleId != pkg.moduleId ||
                    symbol.packageName != pkg.name) {
                    domainFail("$.packages[${index}].symbolIds", "duplicate or foreign symbol")
                }
                case None => domainFail("$.packages[${index}].symbolIds", "unknown symbol")
            }
        }
        index++
    }
    for (declaration in documentation.declarations) {
        var listed = false
        for (pkg in documentation.packages) {
            if (pkg.moduleId == declaration.moduleId && pkg.name == declaration.packageName &&
                stringListContains(pkg.symbolIds, declaration.id)) { listed = true; break }
        }
        if (!listed) { domainFail("$.packages", "declaration '${declaration.id}' is not listed") }
    }
    for (file in documentation.files) {
        var listed = false
        for (pkg in documentation.packages) {
            if (pkg.moduleId == file.moduleId && pkg.name == file.packageName &&
                stringListContains(pkg.sourceFiles, file.path)) { listed = true; break }
        }
        if (!listed) { domainFail("$.packages", "file '${file.path}' is not listed") }
    }

    let assetIds = HashSet<String>()
    let assetPaths = HashSet<String>()
    let assetReferences = HashMap<String, String>()
    var totalAssetBytes: Int64 = 0
    index = 0
    for (asset in documentation.assets) {
        if (asset.id.isEmpty() || !assetIds.add(asset.id) || !safeRelativePath(asset.sourcePath) ||
            !assetPaths.add(asset.sourcePath)) {
            domainFail("$.assets[${index}]", "duplicate asset id/path or unsafe source path")
        }
        for (reference in [asset.id, asset.sourcePath]) {
            match (assetReferences.get(reference)) {
                case Some(owner) => if (owner != asset.id) {
                    domainFail("$.assets[${index}]", "ambiguous asset id/sourcePath reference")
                }
                case None => assetReferences[reference] = asset.id
            }
        }
        let decoded = try {
            let _ = assetMediaExtension(asset.mediaType)
            decodeAssetBase64(asset.base64)
        } catch (_: Exception) {
            domainFail("$.assets[${index}]", "unsupported media type or invalid base64")
        }
        if (decoded.isEmpty() || decoded.size > 16 * 1024 * 1024 ||
            !validAssetMagic(asset.mediaType, decoded)) {
            domainFail("$.assets[${index}]", "invalid or oversized local image asset")
        }
        totalAssetBytes += decoded.size
        if (totalAssetBytes > 64 * 1024 * 1024) {
            domainFail("$.assets", "decoded local assets exceed 64 MiB")
        }
        index++
    }
    for (orphan in documentation.orphanDocComments) { validateRange(orphan.source, "$.orphanDocComments") }
    for (invocation in documentation.macroInvocations) { validateRange(invocation.source, "$.macroInvocations") }
    for (item in documentation.unsupportedDeclarations) { validateRange(item.source, "$.unsupportedDeclarations") }
    for (diagnostic in documentation.diagnostics) {
        match (diagnostic.source) { case Some(range) => validateRange(range, "$.diagnostics.source") case None => () }
        if (let Some(symbolId) <- diagnostic.symbolId) {
            if (!byId.contains(symbolId)) { domainFail("$.diagnostics.symbolId", "unknown SymbolId") }
        }
    }
    var hasError = false
    for (diagnostic in documentation.diagnostics) {
        if (diagnostic.severity == "error") { hasError = true; break }
    }
    var hasUnavailableSemantic = false
    for (provider in documentation.providers) {
        if (provider.state == "unavailable" || provider.state == "ambiguous") {
            hasUnavailableSemantic = true
            break
        }
    }
    if (!hasUnavailableSemantic) {
        for (declaration in documentation.declarations) {
            if (declaration.semantic.state == "unavailable" ||
                declaration.semantic.state == "ambiguous") {
                hasUnavailableSemantic = true
                break
            }
        }
    }
    if (documentation.status == "complete" && (hasError || hasUnavailableSemantic ||
        !documentation.orphanDocComments.isEmpty() || !documentation.macroInvocations.isEmpty() ||
        !documentation.unsupportedDeclarations.isEmpty() ||
        !documentation.unboundSemanticDeclarations.isEmpty())) {
        domainFail("$.status", "complete status conflicts with incomplete source or semantic structure")
    }
}
