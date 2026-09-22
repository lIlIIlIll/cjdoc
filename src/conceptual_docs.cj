package cjdoc

import cjdoc.model.*
import cjdoc.model as public_model
import cjdoc.render as public_render
import std.collection.*
import std.fs.*

internal let CONCEPTUAL_CONFIG_MAX_BYTES: Int64 = 64 * 1024
internal let CONCEPTUAL_PAGE_MAX_BYTES: Int64 = 256 * 1024
internal let CONCEPTUAL_MAX_PAGES: Int64 = 128

internal class ConceptualPageSpec {
    var source = ""
    var route = ""
    var title = ""

    init(source!: String = "", route!: String = "", title!: String = "") {
        this.source = source
        this.route = route
        this.title = title
    }
}

internal class ConceptualDocsConfig {
    var enabled = false
    var indexSource = "docs/index.md"
    let pages = ArrayList<ConceptualPageSpec>()
    let packageSources = HashMap<String, String>()
}

internal class ConceptualApiBinding {
    let target: String
    let selector: String
    let provenance: String
    let version: String
    let sourceLine: Int64
    let language: String
    var state = "unresolved"
    var targetSymbolId: ?String = None

    init(target: String, selector: String, provenance: String, version: String,
        sourceLine: Int64, language: String) {
        this.target = target
        this.selector = selector
        this.provenance = provenance
        this.version = version
        this.sourceLine = sourceLine
        this.language = language
    }
}

internal class ConceptualPage {
    let source: String
    let route: String
    let title: String
    let kind: String
    let markdown: String
    let bindings = ArrayList<ConceptualApiBinding>()

    init(source: String, route: String, title: String, kind: String, markdown: String) {
        this.source = source
        this.route = route
        this.title = title
        this.kind = kind
        this.markdown = markdown
    }
}

private func conceptualValue(value: String): String {
    var cleaned = value.trimAscii()
    var quoted = false
    var escaped = false
    var index: Int64 = 0
    while (index < cleaned.size) {
        let byte = cleaned[index]
        if (byte == b'"' && !escaped) { quoted = !quoted }
        if (byte == b'\\' && quoted) {
            escaped = !escaped
            index++
            continue
        }
        if (byte == b'#' && !quoted) {
            cleaned = cleaned[..index].trimAscii()
            break
        }
        escaped = false
        index++
    }
    if (cleaned.startsWith("\"") && cleaned.endsWith("\"") && cleaned.size >= 2) {
        return cleaned.removePrefix("\"").removeSuffix("\"")
    }
    cleaned
}

private func conceptualSection(line: String): String {
    line.removePrefix("[").removeSuffix("]").trimAscii()
}

private func conceptualSafeRelative(value: String): Bool {
    if (value.isEmpty() || value.startsWith("/") || value.startsWith("\\") ||
        value.contains("\\") || value.contains("..") || value.contains(":")) { return false }
    true
}
private func conceptualSafeRoute(value: String): Bool {
    if (!conceptualSafeRelative(value) || value.contains("?") || value.contains("#")) { return false }
    for (byte in value.toArray()) {
        if (byte < 0x20 || byte == 0x7F) { return false }
    }
    true
}

private func conceptualBindingAttribute(line: String, key: String): String {
    let markers = [" " + key + "=\"", "\t" + key + "=\""]
    for (marker in markers) {
        match (line.indexOf(marker)) {
            case Some(start) =>
                let valueStart = start + marker.size
                match (line[valueStart..].indexOf("\"")) {
                    case Some(end) => return line[valueStart..valueStart + end]
                    case None => return ""
                }
            case None => ()
        }
    }
    ""
}

private func conceptualFenceMarker(line: String): String {
    if (line.startsWith("    ") || line.startsWith("\t")) { return "" }
    let trimmed = line.trimAscii()
    if (trimmed.isEmpty()) { return "" }
    let marker = trimmed[0]
    if (marker != b'`' && marker != b'~') { return "" }
    var count: Int64 = 0
    while (count < trimmed.size && trimmed[count] == marker) { count++ }
    if (count < 3) { return "" }
    trimmed[..count]
}

private func conceptualFenceCloses(line: String, fence: String): Bool {
    if (line.startsWith("    ") || line.startsWith("\t")) { return false }
    let trimmed = line.trimAscii()
    if (!trimmed.startsWith(fence)) { return false }
    let marker = fence[0]
    var count: Int64 = 0
    while (count < trimmed.size && trimmed[count] == marker) { count++ }
    count >= fence.size && trimmed[count..].trimAscii().isEmpty()
}

private func conceptualCollectBindings(page: ConceptualPage,
    documentation: public_model.DocumentationSet): Unit {
    var count: Int64 = 0
    var lineNumber: Int64 = 1
    var fence = ""
    var overflowReported = false
    for (rawLine in page.markdown.replace("\r\n", "\n").replace("\r", "\n").split("\n")) {
        let sourceLine = lineNumber
        lineNumber++
        let line = rawLine.trimAscii()
        if (!fence.isEmpty()) {
            if (conceptualFenceCloses(rawLine, fence)) { fence = "" }
            continue
        }
        let opening = conceptualFenceMarker(rawLine)
        if (!opening.isEmpty()) {
            fence = opening
            continue
        }
        if (rawLine.startsWith("    ") || rawLine.startsWith("\t")) { continue }
        if (!line.startsWith("<!-- cjdoc-bind ") || !line.endsWith(" -->")) { continue }
        if (count >= 32) {
            if (!overflowReported) {
                documentation.appendDiagnostic(public_model.Diagnostic("warning", "CJDOC2054",
                    "conceptual API binding limit exceeded in ${page.source}; additional bindings were omitted"))
                overflowReported = true
            }
            continue
        }
        let target = conceptualBindingAttribute(line, "target")
        if (target.isEmpty()) {
            documentation.appendDiagnostic(public_model.Diagnostic("warning", "CJDOC2056",
                "conceptual API binding marker is missing a valid target in ${page.source}"))
            continue
        }
        var language = conceptualBindingAttribute(line, "language")
        if (language.isEmpty()) { language = "markdown" }
        let selector = conceptualBindingAttribute(line, "selector")
        var duplicate = false
        for (existing in page.bindings) {
            if (existing.target == target && existing.selector == selector) { duplicate = true; break }
        }
        let binding = ConceptualApiBinding(target, selector,
            conceptualBindingAttribute(line, "provenance"),
            conceptualBindingAttribute(line, "version"),
            sourceLine, language)
        if (duplicate) {
            binding.state = "conflict"
            documentation.appendDiagnostic(public_model.Diagnostic("warning", "CJDOC2053",
                "duplicate conceptual API binding '${target}' in ${page.source}"))
        }
        page.bindings.add(binding)
        count++
    }
}

private func conceptualMarkdownWithoutBindings(markdown: String): String {
    let out = StringBuilder()
    var fence = ""
    for (rawLine in markdown.replace("\r\n", "\n").replace("\r", "\n").split("\n")) {
        let line = rawLine.trimAscii()
        if (!fence.isEmpty()) {
            if (conceptualFenceCloses(rawLine, fence)) { fence = "" }
            out.append(rawLine)
            out.append("\n")
            continue
        }
        let opening = conceptualFenceMarker(rawLine)
        if (!opening.isEmpty()) {
            fence = opening
            out.append(rawLine)
            out.append("\n")
            continue
        }
        if (rawLine.startsWith("    ") || rawLine.startsWith("\t")) {
            out.append(rawLine)
            out.append("\n")
            continue
        }
        if (line.startsWith("<!-- cjdoc-bind ") && line.endsWith(" -->") &&
            !conceptualBindingAttribute(line, "target").isEmpty()) { continue }
        out.append(rawLine)
        out.append("\n")
    }
    out.toString()
}

private func conceptualVisibleForAudience(symbol: public_model.SymbolDoc,
    documentation: public_model.DocumentationSet): Bool {
    var current: ?public_model.SymbolDoc = Some(symbol)
    while (current.isSome()) {
        let value = current.getOrThrow()
        let visible = match (documentation.configuration.audience) {
            case "external" => value.visibility == "public" || value.visibility == "protected"
            case "package" => value.visibility != "private"
            case "all" => true
            case _ => false
        }
        if (!visible) { return false }
        current = match (value.ownerId) {
            case Some(ownerId) =>
                var owner: ?public_model.SymbolDoc = None
                for (candidate in documentation.declarations) {
                    if (candidate.id == ownerId) { owner = Some(candidate); break }
                }
                owner
            case None => None
        }
    }
    true
}

private func conceptualResolveBindings(page: ConceptualPage,
    documentation: public_model.DocumentationSet): Unit {
    for (binding in page.bindings) {
        if (binding.state == "conflict") { continue }
        var matches = ArrayList<public_model.SymbolDoc>()
        var allMatches = ArrayList<public_model.SymbolDoc>()
        for (symbol in documentation.declarations) {
            let matchesTarget = if (binding.target.startsWith("id:")) {
                symbol.id == binding.target.removePrefix("id:")
            } else {
                symbol.qualifiedName == binding.target
            }
            if (matchesTarget) {
                allMatches.add(symbol)
                if (conceptualVisibleForAudience(symbol, documentation)) {
                    matches.add(symbol)
                }
            }
        }
        if (matches.size == 1) {
            binding.state = "resolved"
            binding.targetSymbolId = Some(matches[0].id)
        } else if (matches.size > 1) {
            binding.state = "ambiguous"
            documentation.appendDiagnostic(public_model.Diagnostic("warning", "CJDOC2052",
                "ambiguous conceptual API binding '${binding.target}' in ${page.source}"))
        } else if (!allMatches.isEmpty()) {
            binding.state = "unavailable"
            documentation.appendDiagnostic(public_model.Diagnostic("warning", "CJDOC2055",
                "conceptual API binding '${binding.target}' is unavailable for audience '" +
                    documentation.configuration.audience + "' in ${page.source}"))
        } else {
            binding.state = "unresolved"
            documentation.appendDiagnostic(public_model.Diagnostic("warning", "CJDOC2051",
                "unresolved conceptual API binding '${binding.target}' in ${page.source}"))
        }
    }
}

private func conceptualPathFromValue(value: String, setting: String): String {
    let path = conceptualValue(value)
    if (!conceptualSafeRelative(path) || !path.endsWith(".md")) {
        throw IllegalArgumentException("[docs] ${setting} must be a safe relative Markdown path")
    }
    path
}

private func finishConceptualPage(config: ConceptualDocsConfig, current: ?ConceptualPageSpec): Unit {
    match (current) {
        case Some(page) =>
            if (page.source.isEmpty()) {
                throw IllegalArgumentException("[[docs.pages]] requires source")
            }
            if (!conceptualSafeRelative(page.source) || !page.source.endsWith(".md")) {
                throw IllegalArgumentException("[[docs.pages]] source must be a safe relative Markdown path")
            }
            if (!page.route.isEmpty() && !conceptualSafeRoute(page.route)) {
                throw IllegalArgumentException("[[docs.pages]] route must be a safe relative path")
            }
            config.pages.add(page)
        case None => ()
    }
}

private func loadConceptualDocsConfig(projectRoot: String): ConceptualDocsConfig {
    let config = ConceptualDocsConfig()
    let root = Path(projectRoot)
    let configPath = root.join("cjdoc.toml")
    if (!exists(configPath)) { return config }
    let text = readTextBounded(configPath, CONCEPTUAL_CONFIG_MAX_BYTES)
    var section = ""
    var current: ?ConceptualPageSpec = None
    for (rawLine in text.split("\n")) {
        let line = rawLine.trimAscii()
        if (line.isEmpty() || line.startsWith("#")) { continue }
        if (line == "[[docs.pages]]") {
            finishConceptualPage(config, current)
            current = Some(ConceptualPageSpec())
            section = "docs.pages"
            config.enabled = true
            continue
        }
        if (line.startsWith("[") && line.endsWith("]")) {
            finishConceptualPage(config, current)
            current = None
            section = conceptualSection(line)
            if (section == "docs" || section == "docs.packages" || section.startsWith("docs.packages.")) {
                config.enabled = true
            }
            continue
        }
        let equals = line.indexOf("=")
        if (equals.isNone()) { continue }
        let splitAt = equals.getOrThrow()
        let key = line[..splitAt].trimAscii()
        let value = line[splitAt + 1..].trimAscii()
        if (section == "docs") {
            if (key == "index" || key == "index-source") {
                config.indexSource = conceptualPathFromValue(value, key)
            }
        } else if (section == "docs.pages" && current.isSome()) {
            let page = current.getOrThrow()
            if (key == "source" || key == "path") {
                page.source = conceptualPathFromValue(value, key)
            } else if (key == "route") {
                page.route = conceptualValue(value)
            } else if (key == "title") {
                page.title = conceptualValue(value)
            }
        } else if (section == "docs.packages") {
            let source = conceptualPathFromValue(value, "package overview")
            if (!conceptualSafeRelative(key)) {
                throw IllegalArgumentException("[docs.packages] package name is unsafe")
            }
            config.packageSources[key] = source
        } else if (section.startsWith("docs.packages.")) {
            let packageName = section.removePrefix("docs.packages.")
            if (!conceptualSafeRelative(packageName)) {
                throw IllegalArgumentException("[docs.packages] package name is unsafe")
            }
            if (key == "source" || key == "path" || key == "overview") {
                config.packageSources[packageName] = conceptualPathFromValue(value, key)
            }
        }
    }
    finishConceptualPage(config, current)
    config
}

private func conceptualSlug(value: String): String {
    let out = StringBuilder()
    var lastDash = false
    for (rune in value.runes()) {
        let safe = (rune >= r'a' && rune <= r'z') || (rune >= r'A' && rune <= r'Z') ||
            (rune >= r'0' && rune <= r'9')
        if (safe) {
            out.append(rune)
            lastDash = false
        } else if (!lastDash) {
            out.append(r'-')
            lastDash = true
        }
    }
    var slug = out.toString()
    while (slug.startsWith("-")) { slug = slug.removePrefix("-") }
    while (slug.endsWith("-")) { slug = slug.removeSuffix("-") }
    if (slug.isEmpty()) { slug = "page" }
    slug
}

private func conceptualSymbolSlug(value: String): String {
    let digits = "0123456789abcdef"
    let out = StringBuilder()
    if (value.isEmpty()) { return "root" }
    for (byte in value.toArray()) {
        let high = Int64((byte >> 4) & 0x0Fu8)
        let low = Int64(byte & 0x0Fu8)
        out.append(digits[high..high + 1])
        out.append(digits[low..low + 1])
    }
    out.toString()
}

private func conceptualStableHash(value: String): String {
    var first: Int64 = 0
    var second: Int64 = 0
    for (byte in value.toArray()) {
        first = (first * 131 + Int64(byte)) % 2147483647
        second = (second * 257 + Int64(byte)) % 2147483629
    }
    "${first}-${second}"
}

private func conceptualSymbolPath(symbolId: String): String {
    let slug = conceptualSymbolSlug(symbolId)
    let bounded = if (slug.size <= 96) { slug } else {
        slug[..64] + "--" + conceptualStableHash(symbolId)
    }
    "symbols/symbol-${bounded}.html"
}
private func conceptualMarkdownSymbolPath(symbolId: String): String {
    conceptualSymbolPath(symbolId).removeSuffix(".html") + ".md"
}

private func conceptualMarkdownPackagePath(moduleId: String, packageName: String): String {
    let route = moduleId.size.toString() + ":" + moduleId + packageName
    let slug = conceptualSymbolSlug(route)
    let bounded = if (slug.size <= 96) { slug } else {
        slug[..64] + "--" + conceptualStableHash(route)
    }
    "packages/package-" + bounded + ".md"
}

private func conceptualMarkdownContainer(kind: String): Bool {
    kind == "class" || kind == "struct" || kind == "interface" || kind == "enum" ||
        kind == "extend"
}

private func conceptualMarkdownBindingPath(symbol: public_model.SymbolDoc,
    documentation: public_model.DocumentationSet): String {
    var page = if (conceptualMarkdownContainer(symbol.kind)) {
        conceptualMarkdownSymbolPath(symbol.id)
    } else {
        conceptualMarkdownPackagePath(symbol.moduleId, symbol.packageName)
    }
    if (!conceptualMarkdownContainer(symbol.kind)) {
        match (symbol.ownerId) {
            case Some(ownerId) =>
                for (owner in documentation.declarations) {
                    if (owner.id == ownerId) {
                        page = conceptualMarkdownSymbolPath(owner.id)
                        break
                    }
                }
            case None => ()
        }
    }
    page + "#symbol-" + conceptualSymbolSlug(symbol.id)
}
private func conceptualRoute(route: String, fallback: String): String {
    let selected = if (route.isEmpty()) { fallback } else { route }
    let normalized = if (selected.endsWith(".html")) { selected } else { "${selected}.html" }
    if (!conceptualSafeRoute(normalized) || !normalized.startsWith("concepts/")) {
        throw IllegalArgumentException("conceptual page route must stay under concepts/")
    }
    normalized
}

private func conceptualMarkdownLinkText(value: String): String {
    if (!value.contains("\\") && !value.contains("[") && !value.contains("]")) { return value }
    let out = StringBuilder()
    for (rune in value.runes()) {
        if (rune == r'\\' || rune == r'[' || rune == r']') {
            out.append("\\")
        }
        out.append(rune)
    }
    out.toString()
}
private func conceptualPathWithinRoot(root: Path, path: Path): Bool {
    let canonicalRoot = canonicalize(root).toString()
    let canonicalPath = canonicalize(path).toString()
    if (canonicalPath == canonicalRoot) { return false }
    canonicalPath.startsWith(canonicalRoot + "/") || canonicalPath.startsWith(canonicalRoot + "\\")
}

private func conceptualRejectSymlinkComponents(root: Path, source: String): Unit {
    var candidate = root
    for (segment in source.split("/")) {
        candidate = candidate.join(segment)
        if (exists(candidate) && FileInfo(candidate).isSymbolicLink()) {
            throw IllegalArgumentException("conceptual Markdown source must not use a symbolic link: ${source}")
        }
    }
}

private func conceptualRead(root: Path, source: String): String {
    if (!conceptualSafeRelative(source)) {
        throw IllegalArgumentException("conceptual source path is unsafe")
    }
    let path = root.join(source)
    if (!exists(path)) {
        throw IllegalArgumentException("conceptual Markdown source does not exist: ${source}")
    }
    conceptualRejectSymlinkComponents(root, source)
    if (!conceptualPathWithinRoot(root, path)) {
        throw IllegalArgumentException("conceptual Markdown source escapes the project root: ${source}")
    }
    readTextBounded(path, CONCEPTUAL_PAGE_MAX_BYTES)
}

private func conceptualTitle(markdown: String, fallback: String): String {
    var fence = ""
    for (rawLine in markdown.replace("\r\n", "\n").replace("\r", "\n").split("\n")) {
        let text = rawLine.trimAscii()
        if (!fence.isEmpty()) {
            if (conceptualFenceCloses(rawLine, fence)) { fence = "" }
            continue
        }
        let opening = conceptualFenceMarker(rawLine)
        if (!opening.isEmpty()) {
            fence = opening
            continue
        }
        if (rawLine.startsWith("    ") || rawLine.startsWith("\t")) { continue }
        if (text.startsWith("# ")) { return text.removePrefix("# ").trimAscii() }
    }
    fallback
}

private func conceptualDefaultProjectMarkdown(documentation: public_model.DocumentationSet): String {
    let out = StringBuilder()
    out.append("# ${documentation.project.name}\n\n")
    out.append("This site contains the conceptual documentation and generated API reference.\n")
    out.toString()
}

private func conceptualDefaultModuleMarkdown(module: public_model.ModuleDoc): String {
    let out = StringBuilder()
    out.append("# Module `${module.name}`\n\n")
    out.append("Role: `${module.role}`.\n\n")
    if (!module.packageNames.isEmpty()) {
        out.append("## Packages\n\n")
        for (packageName in module.packageNames) {
            out.append("- `${packageName}`\n")
        }
    }
    out.toString()
}

private func conceptualDefaultPackageMarkdown(pkg: public_model.PackageDoc): String {
    let out = StringBuilder()
    out.append("# Package `${pkg.name}`\n\n")
    out.append("This page describes the conceptual role of the package.\n")
    out.toString()
}

private func conceptualPageFromSource(root: Path, source: String, route: String,
    title: String, kind: String, fallback: String): ConceptualPage {
    let markdown = conceptualRead(root, source)
    let selectedTitle = if (title.isEmpty()) { conceptualTitle(markdown, fallback) } else { title }
    ConceptualPage(source, route, selectedTitle, kind, markdown)
}

private func conceptualAddPage(documentation: public_model.DocumentationSet,
    pages: ArrayList<ConceptualPage>, routes: HashSet<String>, page: ConceptualPage): Unit {
    if (routes.add(page.route)) {
        if (pages.size >= CONCEPTUAL_MAX_PAGES) {
            throw IllegalArgumentException("conceptual documentation exceeds ${CONCEPTUAL_MAX_PAGES} pages")
        }
        pages.add(page)
        return
    }
    let stem = page.route.removeSuffix(".html")
    let suffix = conceptualStableHash(page.kind + ":" + page.source + ":" + page.route)
    var candidate = stem + "--" + suffix + ".html"
    var serial: Int64 = 2
    while (!routes.add(candidate)) {
        candidate = stem + "--" + suffix + "-" + serial.toString() + ".html"
        serial++
    }
    documentation.appendDiagnostic(public_model.Diagnostic("warning", "CJDOC4060",
        "conceptual route collision at ${page.route}; emitted ${candidate}"))
    let routedPage = ConceptualPage(page.source, candidate, page.title, page.kind, page.markdown)
    if (pages.size >= CONCEPTUAL_MAX_PAGES) {
        throw IllegalArgumentException("conceptual documentation exceeds ${CONCEPTUAL_MAX_PAGES} pages")
    }
    pages.add(routedPage)
}

private func conceptualPages(root: Path, documentation: public_model.DocumentationSet,
    config: ConceptualDocsConfig): ArrayList<ConceptualPage> {
    let pages = ArrayList<ConceptualPage>()
    let routes = HashSet<String>()
    let indexPath = root.join(config.indexSource)
    if (exists(indexPath)) {
        let page = conceptualPageFromSource(root, config.indexSource, "concepts/index.html", "", "project",
            documentation.project.name)
        conceptualAddPage(documentation, pages, routes, page)
    } else if (config.enabled) {
        conceptualAddPage(documentation, pages, routes,
            ConceptualPage(config.indexSource, "concepts/index.html", documentation.project.name, "project",
                conceptualDefaultProjectMarkdown(documentation)))
    }
    for (module in documentation.modules) {
        let source = "docs/modules/${conceptualSlug(module.name)}.md"
        let configured = root.join(source)
        let markdown = if (exists(configured)) {
            conceptualRead(root, source)
        } else {
            conceptualDefaultModuleMarkdown(module)
        }
        let route = conceptualRoute("concepts/modules/${conceptualSlug(module.name)}", "concepts/modules/module")
        conceptualAddPage(documentation, pages, routes,
            ConceptualPage(source, route, conceptualTitle(markdown, module.name), "module", markdown))
    }
    for (pkg in documentation.packages) {
        var source = "docs/packages/${conceptualSlug(pkg.name)}.md"
        match (config.packageSources.get(pkg.name)) {
            case Some(value) => source = value
            case None => ()
        }
        let configured = root.join(source)
        let markdown = if (exists(configured)) {
            conceptualRead(root, source)
        } else {
            conceptualDefaultPackageMarkdown(pkg)
        }
        let route = conceptualRoute("concepts/packages/${conceptualSlug(pkg.name)}", "concepts/packages/package")
        conceptualAddPage(documentation, pages, routes,
            ConceptualPage(source, route, conceptualTitle(markdown, pkg.name), "package", markdown))
    }
    for (spec in config.pages) {
        let route = conceptualRoute(spec.route, "concepts/guides/${conceptualSlug(spec.source.removeSuffix(".md"))}")
        let page = conceptualPageFromSource(root, spec.source, route, spec.title, "guide", spec.source)
        conceptualAddPage(documentation, pages, routes, page)
    }
    for (page in pages) {
        conceptualCollectBindings(page, documentation)
        conceptualResolveBindings(page, documentation)
    }
    pages
}
internal func conceptualPagesForProject(projectRoot: String,
    documentation: public_model.DocumentationSet): ArrayList<ConceptualPage> {
    let config = loadConceptualDocsConfig(projectRoot)
    if (!config.enabled) { return ArrayList<ConceptualPage>() }
    conceptualPages(Path(projectRoot), documentation, config)
}
internal func conceptualAgentPages(pages: ArrayList<ConceptualPage>): Array<public_render.AgentConceptualPage> {
    let result = ArrayList<public_render.AgentConceptualPage>()
    for (page in pages) {
        result.add(public_render.AgentConceptualPage(page.route, page.title, page.kind,
            markdown: page.markdown))
    }
    result.toArray()
}

private func conceptualRelativePrefix(route: String): String {
    let segments = route.split("/")
    var prefix = ""
    var index: Int64 = 0
    while (index + 1 < segments.size) {
        prefix += "../"
        index++
    }
    prefix
}

private func conceptualIndexHref(route: String): String {
    let segments = route.split("/")
    var prefix = ""
    var index: Int64 = 1
    while (index + 1 < segments.size) {
        prefix += "../"
        index++
    }
    prefix + "index.html"
}

private func conceptualHtmlPage(documentation: public_model.DocumentationSet, page: ConceptualPage,
    body: String, locale!: String = "en", docVersion!: ?String = None): String {
    let prefix = conceptualRelativePrefix(page.route)
    public_render.renderConceptualHtmlPage(documentation, page.title, body, prefix,
        source: Some(page.source), locale: locale, docVersion: docVersion)
}
private func conceptualBindingsMarkdown(page: ConceptualPage,
    documentation: public_model.DocumentationSet): String {
    if (page.bindings.isEmpty()) { return "" }
    let prefix = conceptualRelativePrefix(page.route)
    let out = StringBuilder()
    out.append("\n## API associations\n\n")
    for (binding in page.bindings) {
        out.append("- [")
        out.append(binding.state)
        out.append("] ")
        match (binding.targetSymbolId) {
            case Some(targetId) =>
                var found: ?public_model.SymbolDoc = None
                for (symbol in documentation.declarations) {
                    if (symbol.id == targetId) { found = Some(symbol); break }
                }
                match (found) {
                    case Some(symbol) =>
                        let href = prefix + conceptualMarkdownBindingPath(symbol, documentation)
                        out.append("[")
                        out.append(public_render.escapeStandaloneHtml(symbol.qualifiedName))
                        out.append("](<")
                        out.append(href)
                        out.append(">)")
                    case None =>
                        out.append(public_render.escapeStandaloneHtml(binding.target))
                }
            case None => out.append(public_render.escapeStandaloneHtml(binding.target))
        }
        out.append(" — ")
        out.append(public_render.escapeStandaloneHtml(binding.language))
        out.append(" line ")
        out.append(binding.sourceLine.toString())
        if (!binding.provenance.isEmpty()) {
            out.append("; source: ")
            out.append(public_render.escapeStandaloneHtml(binding.provenance))
        }
        out.append("\n")
    }
    out.toString()
}

private func conceptualMarkdownPage(page: ConceptualPage, pages: ArrayList<ConceptualPage>,
    documentation: public_model.DocumentationSet): String {
    let prefix = conceptualRelativePrefix(page.route)
    let conceptsHref = conceptualIndexHref(page.route).removeSuffix(".html") + ".md"
    let out = StringBuilder()
    out.append("[API reference](<")
    out.append(prefix)
    out.append("index.md>) · [Concepts](<")
    out.append(conceptsHref)
    out.append(">)\n\n")
    out.append("<!-- source: ${page.source} -->\n\n")
    let markdown = conceptualMarkdownWithoutBindings(page.markdown)
    out.append(markdown)
    if (!markdown.endsWith("\n")) { out.append("\n") }
    out.append(conceptualBindingsMarkdown(page, documentation))
    if (page.kind == "project") { out.append(conceptualProjectMarkdownNavigation(pages)) }
    out.toString()
}

private func conceptualJsonString(value: String): String {
    public_render.escapeJsonString(value)
}

private func externalSearchObjectEnd(value: String, start: Int64): ?Int64 {
    if (start >= value.size || value[start] != b'{') { return None }
    var depth: Int64 = 0
    var quoted = false
    var escaped = false
    var index = start
    while (index < value.size) {
        let byte = value[index]
        if (quoted) {
            if (escaped) {
                escaped = false
            } else if (byte == b'\\') {
                escaped = true
            } else if (byte == b'"') {
                quoted = false
            }
        } else if (byte == b'"') {
            quoted = true
        } else if (byte == b'{') {
            depth++
        } else if (byte == b'}') {
            depth--
            if (depth == 0) { return Some(index) }
        }
        index++
    }
    None
}

private func externalSearchJson(value: String): String {
    public_render.escapeJsonString(value)
}

private func externalSearchDocJson(resolver: ExternalDocResolver, state: String, url: String): String {
    let version = match (resolver.version) {
        case Some(value) => value
        case None => ""
    }
    let out = StringBuilder()
    out.append("{\"name\":")
    out.append(externalSearchJson(resolver.name))
    out.append(",\"state\":")
    out.append(externalSearchJson(state))
    out.append(",\"url\":")
    out.append(externalSearchJson(url))
    out.append(",\"reason\":")
    out.append(externalSearchJson(resolver.reason))
    out.append(",\"version\":")
    out.append(externalSearchJson(version))
    out.append(",\"index\":")
    out.append(externalSearchJson(resolver.indexPath))
    out.append(",\"format\":")
    out.append(externalSearchJson(resolver.format))
    out.append(",\"fingerprint\":")
    out.append(externalSearchJson(resolver.fingerprint))
    out.append("}")
    out.toString()
}

private func externalSearchBindings(symbol: public_model.SymbolDoc,
    resolvers: Array<ExternalDocResolver>): String {
    let values = ArrayList<String>()
    for (resolver in resolvers) {
        let (idUrl, idAmbiguous) = resolver.matchTarget(symbol.id)
        let (url, ambiguous) = if (idUrl.isEmpty() && !idAmbiguous) {
            resolver.matchTarget(symbol.qualifiedName)
        } else { (idUrl, idAmbiguous) }
        if (url.isEmpty() && !ambiguous && resolver.state == "available") { continue }
        let state = if (ambiguous) { "ambiguous" } else { resolver.state }
        values.add(externalSearchDocJson(resolver, state, url))
    }
    if (values.isEmpty()) { return "" }
    let out = StringBuilder()
    for (index in 0..values.size) {
        if (index > 0) { out.append(",") }
        out.append(values[index])
    }
    out.toString()
}

private func externalSearchCanonicalValue(value: String, objectStart: Int64,
    objectEnd: Int64): ?String {
    let marker = "\"canonicalId\": "
    match (value[objectStart..objectEnd].indexOf(marker)) {
        case None => None
        case Some(relative) =>
            let stringStart = objectStart + relative + marker.size
            if (stringStart >= objectEnd || value[stringStart] != b'\"') { return None }
            var index = stringStart + 1
            var escaped = false
            while (index < objectEnd) {
                let byte = value[index]
                if (escaped) {
                    escaped = false
                } else if (byte == b'\\') {
                    escaped = true
                } else if (byte == b'\"') {
                    return Some(value[stringStart..index + 1])
                }
                index++
            }
            None
    }
}

private func externalSearchSymbolIndex(documentation: public_model.DocumentationSet): HashMap<String, Int64> {
    let result = HashMap<String, Int64>()
    var index: Int64 = 0
    for (symbol in documentation.declarations) {
        result[externalSearchJson(symbol.id)] = index
        index++
    }
    result
}

private func externalSearchIndex(base: String, documentation: public_model.DocumentationSet,
    resolvers: Array<ExternalDocResolver>): String {
    if (base.isEmpty() || resolvers.isEmpty()) { return base }
    let symbolIndex = externalSearchSymbolIndex(documentation)
    if (symbolIndex.isEmpty()) { return base }
    let marker = "\"entries\": ["
    match (base.indexOf(marker)) {
        case None => base
        case Some(markerStart) =>
            let arrayStart = markerStart + marker.size
            let out = StringBuilder()
            out.append(base[..arrayStart])
            var cursor = arrayStart
            while (cursor < base.size) {
                var objectStart = cursor
                while (objectStart < base.size &&
                    (base[objectStart] == b' ' || base[objectStart] == b'\n' ||
                        base[objectStart] == b'\r' || base[objectStart] == b'\t' ||
                        base[objectStart] == b',')) { objectStart++ }
                if (objectStart >= base.size || base[objectStart] == b']') {
                    out.append(base[cursor..])
                    return out.toString()
                }
                if (base[objectStart] != b'{') { return base }
                let objectEnd = match (externalSearchObjectEnd(base, objectStart)) {
                    case Some(value) => value
                    case None => return base
                }
                out.append(base[cursor..objectEnd])
                match (externalSearchCanonicalValue(base, objectStart, objectEnd)) {
                    case Some(key) => match (symbolIndex.get(key)) {
                        case Some(index) =>
                            let bindings = externalSearchBindings(documentation.declarations[index], resolvers)
                            if (!bindings.isEmpty()) {
                                out.append(",\"externalDocs\":[" + bindings + "]")
                            }
                        case None => ()
                    }
                    case None => ()
                }
                out.append("}")
                cursor = objectEnd + 1
            }
            out.toString()
    }
}

private func conceptualSearchIndex(base: String, pages: ArrayList<ConceptualPage>): String {
    let suffix = "\n  ]\n}\n"
    if (!base.endsWith(suffix)) { return base }
    let prefix = base.removeSuffix(suffix)
    let out = StringBuilder()
    out.append(prefix)
    let hasEntries = base.contains("\n    {")
    var conceptIndex: Int64 = 0
    for (page in pages) {
        if (hasEntries || conceptIndex > 0) { out.append(",") }
        conceptIndex++
        out.append("\n    {\"id\":")
        out.append(conceptualJsonString("cjdoc:concept:${page.route}"))
        out.append(",\"canonicalId\":")
        out.append(conceptualJsonString("cjdoc:concept:${page.route}"))
        out.append(",\"exposure\":false,\"name\":")
        out.append(conceptualJsonString(page.title))
        out.append(",\"qualifiedName\":")
        out.append(conceptualJsonString(page.route))
        out.append(",\"kind\":\"concept\",\"packageName\":\"\",\"summary\":\"\",\"href\":")
        out.append(conceptualJsonString(page.route))
        out.append(",\"bindings\":[")
        var firstBinding = true
        for (binding in page.bindings) {
            if (!firstBinding) { out.append(",") }
            firstBinding = false
            out.append("{\"target\":")
            out.append(conceptualJsonString(binding.target))
            out.append(",\"state\":")
            out.append(conceptualJsonString(binding.state))
            out.append(",\"selector\":")
            out.append(conceptualJsonString(binding.selector))
            out.append(",\"provenance\":")
            out.append(conceptualJsonString(binding.provenance))
            out.append(",\"version\":")
            out.append(conceptualJsonString(binding.version))
            out.append(",\"language\":")
            out.append(conceptualJsonString(binding.language))
            out.append(",\"sourceLine\":")
            out.append(binding.sourceLine.toString())
            out.append(",\"targetSymbolId\":")
            match (binding.targetSymbolId) {
                case Some(value) => out.append(conceptualJsonString(value))
                case None => out.append("null")
            }
            out.append("}")
        }
        out.append("]")
        out.append("}")
    }
    out.append(suffix)
    out.toString()
}

private func conceptualNavigationHtml(locale: String): String {
    let title = if (locale == "zh-CN") { "从指南开始" } else { "Start with the guide" }
    let copy = if (locale == "zh-CN") { "先阅读项目指南，再浏览完整的生成 API 索引。" } else { "Read the project guide before browsing the full generated API index." }
    let link = if (locale == "zh-CN") { "打开概念文档" } else { "Open conceptual documentation" }
    let out = StringBuilder()
    out.append("<section class=\"conceptual-entry\" aria-labelledby=\"conceptual-entry-title\"><h2 id=\"conceptual-entry-title\">")
    out.append(title)
    out.append("</h2><p>")
    out.append(copy)
    out.append("</p><a href=\"concepts/index.html\">")
    out.append(link)
    out.append("</a></section>\n")
    out.toString()
}

private func conceptualNavigationMarkdown(): String {
    "\n## Conceptual documentation\n\n[Open conceptual documentation](concepts/index.md)\n"
}

private func conceptualProjectHtmlNavigation(pages: ArrayList<ConceptualPage>): String {
    let out = StringBuilder()
    out.append("<h2>Conceptual navigation</h2><ul>")
    for (entry in pages) {
        if (entry.kind != "project") {
            out.append("<li><a href=\"${entry.route.removePrefix("concepts/")}\">")
            out.append(public_render.escapeStandaloneHtml(entry.title))
            out.append("</a></li>")
        }
    }
    out.append("</ul>\n")
    out.toString()
}

private func conceptualProjectMarkdownNavigation(pages: ArrayList<ConceptualPage>): String {
    let out = StringBuilder()
    out.append("\n## Conceptual navigation\n\n")
    for (entry in pages) {
        if (entry.kind != "project") {
            let path = entry.route.removePrefix("concepts/").removeSuffix(".html") + ".md"
            out.append("- [")
            out.append(conceptualMarkdownLinkText(entry.title))
            out.append("](<")
            out.append(path)
            out.append(">)\n")
        }
    }
    out.toString()
}

private func conceptualBindingLabel(locale: String, english: String, chinese: String): String {
    if (locale == "zh-CN") { chinese } else { english }
}

private func conceptualBindingsHtml(page: ConceptualPage,
    documentation: public_model.DocumentationSet, locale: String): String {
    if (page.bindings.isEmpty()) { return "" }
    let out = StringBuilder()
    let prefix = conceptualRelativePrefix(page.route)
    out.append("<section class=\"conceptual-bindings\" aria-labelledby=\"conceptual-bindings-heading\"><h2 id=\"conceptual-bindings-heading\">")
    out.append(conceptualBindingLabel(locale, "API associations", "API 关联"))
    out.append("</h2><p class=\"binding-scope\">")
    out.append(conceptualBindingLabel(locale, "Explicit bindings from this Markdown page; no name guessing or network lookup is used.", "此 Markdown 页的显式关联；不猜测名称，也不联网获取。"))
    out.append("</p><ul>")
    for (binding in page.bindings) {
        out.append("<li><span class=\"binding-state\" data-state=\"")
        out.append(public_render.escapeStandaloneHtml(binding.state))
        out.append("\">")
        out.append(public_render.escapeStandaloneHtml(binding.state))
        out.append("</span> ")
        match (binding.targetSymbolId) {
            case Some(targetId) =>
                var found: ?public_model.SymbolDoc = None
                for (symbol in documentation.declarations) {
                    if (symbol.id == targetId) { found = Some(symbol); break }
                }
                match (found) {
                    case Some(symbol) =>
                        out.append("<a href=\"")
                        out.append(prefix + conceptualSymbolPath(symbol.id))
                        out.append("\"><code>")
                        out.append(public_render.escapeStandaloneHtml(symbol.qualifiedName))
                        out.append("</code></a>")
                    case None => out.append("<code>" + public_render.escapeStandaloneHtml(binding.target) + "</code>")
                }
            case None => out.append("<code>" + public_render.escapeStandaloneHtml(binding.target) + "</code>")
        }
        if (!binding.selector.isEmpty()) {
            out.append(" <span class=\"binding-meta\">selector: ")
            out.append(public_render.escapeStandaloneHtml(binding.selector))
            out.append("</span>")
        }
        if (!binding.version.isEmpty()) {
            out.append(" <span class=\"binding-meta\">version: ")
            out.append(public_render.escapeStandaloneHtml(binding.version))
            out.append("</span>")
        }
        if (!binding.provenance.isEmpty()) {
            out.append(" <span class=\"binding-meta\">source: ")
            out.append(public_render.escapeStandaloneHtml(binding.provenance))
            out.append("</span>")
        }
        out.append(" <span class=\"binding-meta\">language: " + public_render.escapeStandaloneHtml(binding.language) + "; line: " + binding.sourceLine.toString() + "</span>")
        out.append("</li>")
    }
    out.append("</ul></section>\n")
    out.toString()
}

private func conceptualMarkdownBodyHtml(documentation: public_model.DocumentationSet,
    page: ConceptualPage, markdown: String): String {
    try {
        public_render.renderStandaloneMarkdownHtml(parseStandaloneMarkdown(markdown))
    } catch (_: Exception) {
        let source = public_model.SourceRange(page.source, public_model.SourcePosition(1, 1, 0),
            public_model.SourcePosition(1, 1, 0))
        documentation.appendDiagnostic(public_model.Diagnostic("warning", "CJDOC3026",
            "conceptual Markdown was replaced by a bounded fallback after parsing or resource-limit failure",
            source: Some(source)))
        public_render.renderStandaloneMarkdownHtml(fallbackPublicMarkdown())
    }
}

internal func renderConceptualDocumentationArtifacts(documentation: public_model.DocumentationSet, formats: Array<String>, pages: ArrayList<ConceptualPage>, locale!: String = "en", docVersion!: ?String = None): Array<public_render.RenderArtifact> {
    let artifacts = ArrayList<public_render.RenderArtifact>()
    for (format in formats) {
        if (format == "html") {
            for (page in pages) {
                let markdown = conceptualMarkdownWithoutBindings(page.markdown)
                let body = conceptualMarkdownBodyHtml(documentation, page, markdown)
                let bindings = conceptualBindingsHtml(page, documentation, locale)
                let pageBody = if (page.kind == "project") {
                    body + conceptualProjectHtmlNavigation(pages) + bindings
                } else {
                    body + bindings
                }
                artifacts.add(public_render.RenderArtifact("html/${page.route}", "text/html; charset=utf-8",
                    conceptualHtmlPage(documentation, page, pageBody, locale: locale, docVersion: docVersion)))
            }
        } else if (format == "markdown") {
            for (page in pages) {
                let path = page.route.removePrefix("concepts/").removeSuffix(".html")
                artifacts.add(public_render.RenderArtifact("markdown/concepts/${path}.md",
                    "text/markdown; charset=utf-8", conceptualMarkdownPage(page, pages, documentation)))
            }
        }
    }
    artifacts.toArray()
}

private func injectConceptualNavigation(content: String, locale: String): String {
    let marker = "</header>\n<section class=\"quick-start\""
    match (content.indexOf(marker)) {
        case Some(index) => content[..index] + conceptualNavigationHtml(locale) + content[index..]
        case None =>
            let mainMarker = "<main class=\"docs-main\""
            match (content.indexOf(mainMarker)) {
                case Some(index) => content[..index] + conceptualNavigationHtml(locale) + content[index..]
                case None => content + "\n" + conceptualNavigationHtml(locale)
            }
    }
}
internal func conceptualIndexNavigation(projectRoot: String,
    format: String, content: String, locale!: String = "en"): String {
    let config = loadConceptualDocsConfig(projectRoot)
    if (!config.enabled) { return content }
    if (format == "html") { return injectConceptualNavigation(content, locale) }
    if (format == "markdown") { return content + conceptualNavigationMarkdown() }
    content
}

private func conceptualBindingPages(pages: ArrayList<ConceptualPage>, symbolId: String): ArrayList<ConceptualPage> {
    let result = ArrayList<ConceptualPage>()
    for (page in pages) {
        for (binding in page.bindings) {
            if (binding.state == "resolved" && binding.targetSymbolId == Some(symbolId)) {
                result.add(page)
                break
            }
        }
    }
    result
}

private func conceptualApiUsageHtml(pages: ArrayList<ConceptualPage>,
    symbolId: String, locale: String): String {
    let usages = conceptualBindingPages(pages, symbolId)
    if (usages.isEmpty()) { return "" }
    let out = StringBuilder()
    out.append("<section class=\"conceptual-bindings api-usages\" aria-labelledby=\"conceptual-api-usages-heading\"><h2 id=\"conceptual-api-usages-heading\">")
    out.append(conceptualBindingLabel(locale, "Related guides and examples", "相关指南和示例"))
    out.append("</h2><ul>")
    for (page in usages) {
        out.append("<li><a href=\"../")
        out.append(page.route)
        out.append("\">")
        out.append(public_render.escapeStandaloneHtml(page.title))
        out.append("</a> <span class=\"binding-meta\">")
        out.append(public_render.escapeStandaloneHtml(page.source))
        out.append("</span></li>")
    }
    out.append("</ul></section>\n")
    out.toString()
}

private func conceptualApiUsageMarkdown(pages: ArrayList<ConceptualPage>, symbolId: String): String {
    let usages = conceptualBindingPages(pages, symbolId)
    if (usages.isEmpty()) { return "" }
    let out = StringBuilder()
    out.append("\n## Related guides and examples\n\n")
    for (page in usages) {
        let route = page.route.removeSuffix(".html") + ".md"
        out.append("- [")
        out.append(conceptualMarkdownLinkText(page.title))
        out.append("](<")
        out.append("../")
        out.append(route)
        out.append(">) — ")
        out.append(public_render.escapeStandaloneHtml(page.source))
        out.append("\n")
    }
    out.toString()
}

private func conceptualExternalUsageHtml(symbol: public_model.SymbolDoc,
    resolvers: Array<ExternalDocResolver>, locale: String): String {
    if (resolvers.isEmpty()) { return "" }
    let out = StringBuilder()
    var count: Int64 = 0
    for (resolver in resolvers) {
        let (url, ambiguous) = resolver.matchTarget(symbol.id)
        let (qualifiedUrl, qualifiedAmbiguous) = if (url.isEmpty() && !ambiguous) {
            resolver.matchTarget(symbol.qualifiedName)
        } else { (url, ambiguous) }
        if (qualifiedUrl.isEmpty() && !qualifiedAmbiguous && resolver.state == "available") { continue }
        if (count == 0) {
            out.append("<section class=\"external-documentation\" aria-labelledby=\"external-documentation-heading\"><h2 id=\"external-documentation-heading\">")
            out.append(conceptualBindingLabel(locale, "External documentation", "外部文档"))
            out.append("</h2><ul>")
        }
        count++
        out.append("<li><strong>")
        out.append(public_render.escapeStandaloneHtml(resolver.name))
        out.append("</strong> ")
        if (!qualifiedUrl.isEmpty()) {
            out.append("<a rel=\"noreferrer\" href=\"")
            out.append(public_render.escapeStandaloneHtml(qualifiedUrl))
            out.append("\">")
            out.append(conceptualBindingLabel(locale, "Open official reference", "打开官方参考"))
            out.append("</a>")
        } else if (qualifiedAmbiguous) {
            out.append("<span class=\"badge\" data-state=\"ambiguous\">ambiguous</span>")
        } else {
            out.append("<span class=\"badge\" data-state=\"unavailable\">")
            out.append(public_render.escapeStandaloneHtml(resolver.state))
            out.append("</span> ")
            out.append(public_render.escapeStandaloneHtml(resolver.reason))
        }
        match (resolver.version) {
            case Some(value) => out.append(" <span class=\"binding-meta\">version: " + public_render.escapeStandaloneHtml(value) + "</span>")
            case None => ()
        }
        if (!resolver.indexPath.isEmpty()) {
            out.append(" <span class=\"binding-meta\">index: " + public_render.escapeStandaloneHtml(resolver.indexPath) + "</span>")
        }
        if (!resolver.format.isEmpty()) {
            out.append(" <span class=\"binding-meta\">format: " + public_render.escapeStandaloneHtml(resolver.format) + "</span>")
        }
        if (!resolver.fingerprint.isEmpty()) {
            out.append(" <span class=\"binding-meta\">fingerprint: " + public_render.escapeStandaloneHtml(resolver.fingerprint) + "</span>")
        }
        out.append("</li>")
    }
    if (count > 0) { out.append("</ul></section>\n") }
    out.toString()
}

private func conceptualMarkdownDestination(value: String): String {
    "<" + value.replace("\\", "\\\\").replace("<", "\\<").replace(">", "\\>") + ">"
}

private func conceptualExternalUsageMarkdown(symbol: public_model.SymbolDoc,
    resolvers: Array<ExternalDocResolver>): String {
    if (resolvers.isEmpty()) { return "" }
    let out = StringBuilder()
    var count: Int64 = 0
    for (resolver in resolvers) {
        let (url, ambiguous) = resolver.matchTarget(symbol.id)
        let (qualifiedUrl, qualifiedAmbiguous) = if (url.isEmpty() && !ambiguous) {
            resolver.matchTarget(symbol.qualifiedName)
        } else { (url, ambiguous) }
        if (qualifiedUrl.isEmpty() && !qualifiedAmbiguous && resolver.state == "available") { continue }
        if (count == 0) { out.append("\n## External documentation\n\n") }
        count++
        out.append("- **" + public_render.escapeStandaloneHtml(resolver.name) + "** ")
        if (!qualifiedUrl.isEmpty()) {
            out.append("[Open official reference](" + conceptualMarkdownDestination(qualifiedUrl) + ")")
        } else if (qualifiedAmbiguous) {
            out.append("ambiguous")
        } else {
            out.append(resolver.state + " — " + public_render.escapeStandaloneHtml(resolver.reason))
        }
        match (resolver.version) {
            case Some(value) => out.append(" — version: " + public_render.escapeStandaloneHtml(value))
            case None => ()
        }
        if (!resolver.indexPath.isEmpty()) {
            out.append("; index: " + public_render.escapeStandaloneHtml(resolver.indexPath))
        }
        if (!resolver.format.isEmpty()) {
            out.append("; format: " + public_render.escapeStandaloneHtml(resolver.format))
        }
        if (!resolver.fingerprint.isEmpty()) {
            out.append("; fingerprint: " + public_render.escapeStandaloneHtml(resolver.fingerprint))
        }
        out.append("\n")
    }
    if (count == 0) { return "" }
    out.toString()
}

private func conceptualArtifactSymbolIndex(documentation: public_model.DocumentationSet): HashMap<String, Int64> {
    let result = HashMap<String, Int64>()
    var index: Int64 = 0
    for (symbol in documentation.declarations) {
        result[conceptualSymbolPath(symbol.id)] = index
        index++
    }
    result
}

private func conceptualAugmentApiArtifact(path: String, content: String,
    documentation: public_model.DocumentationSet,
    symbolIndex: HashMap<String, Int64>,
    pages: ArrayList<ConceptualPage>,
    resolvers: Array<ExternalDocResolver>, locale: String): String {
    let isHtml = path.startsWith("html/")
    let relative = if (isHtml) {
        path.removePrefix("html/")
    } else {
        path.removePrefix("markdown/")
    }
    let symbolPath = if (isHtml) {
        relative
    } else {
        if (!relative.endsWith(".md")) { return content }
        relative.removeSuffix(".md") + ".html"
    }
    let symbolIndexValue = match (symbolIndex.get(symbolPath)) {
        case Some(value) => value
        case None => return content
    }
    let symbol = documentation.declarations[symbolIndexValue]
    let section = if (isHtml) {
        conceptualApiUsageHtml(pages, symbol.id, locale) + conceptualExternalUsageHtml(symbol, resolvers, locale)
    } else {
        conceptualApiUsageMarkdown(pages, symbol.id) + conceptualExternalUsageMarkdown(symbol, resolvers)
    }
    if (section.isEmpty()) { return content }
    if (!isHtml) { return content + section }
    let marker = "</main>"
    match (content.indexOf(marker)) {
        case Some(index) => content[..index] + section + content[index..]
        case None => content + section
    }
}

internal func appendConceptualArtifacts(projectRoot: String,
    documentation: public_model.DocumentationSet, formats: Array<String>,
    baseArtifacts: Array<public_render.RenderArtifact>, pages: ArrayList<ConceptualPage>,
    locale!: String = "en", docVersion!: ?String = None): Array<public_render.RenderArtifact> {
    var hasHtml = false
    var hasMarkdown = false
    for (format in formats) {
        if (format == "html") { hasHtml = true }
        if (format == "markdown") { hasMarkdown = true }
    }
    if (!hasHtml && !hasMarkdown) { return baseArtifacts }
    let config = loadConceptualDocsConfig(projectRoot)
    let resolvers = if (hasHtml || hasMarkdown) {
        loadExternalDocResolvers(projectRoot)
    } else { Array<ExternalDocResolver>() }
    if (!config.enabled && pages.isEmpty() && resolvers.isEmpty()) {
        return baseArtifacts
    }
    var search = ""
    for (artifact in baseArtifacts) {
        if (artifact.path == "html/search-index.json") { search = artifact.content }
    }
    var shouldAugmentApiArtifacts = false
    if (hasHtml || hasMarkdown) {
        shouldAugmentApiArtifacts = !resolvers.isEmpty()
        if (!shouldAugmentApiArtifacts) {
            for (page in pages) {
                if (!page.bindings.isEmpty()) {
                    shouldAugmentApiArtifacts = true
                    break
                }
            }
        }
    }
    let symbolIndex = if (shouldAugmentApiArtifacts) {
        conceptualArtifactSymbolIndex(documentation)
    } else {
        HashMap<String, Int64>()
    }
    let conceptualSearch = if (config.enabled && hasHtml) {
        conceptualSearchIndex(search, pages)
    } else { search }
    let augmentedSearch = if (hasHtml) {
        externalSearchIndex(conceptualSearch, documentation, resolvers)
    } else { conceptualSearch }
    let result = ArrayList<public_render.RenderArtifact>()
    for (artifact in baseArtifacts) {
        if (artifact.path == "html/index.html") {
            result.add(public_render.RenderArtifact(artifact.path, artifact.mediaType,
                conceptualIndexNavigation(projectRoot, "html", artifact.content, locale: locale)))
        } else if (artifact.path == "markdown/index.md") {
            result.add(public_render.RenderArtifact(artifact.path, artifact.mediaType,
                conceptualIndexNavigation(projectRoot, "markdown", artifact.content, locale: locale)))
        } else if (artifact.path == "html/search-index.json") {
            result.add(public_render.RenderArtifact(artifact.path, artifact.mediaType, augmentedSearch))
        } else if (artifact.path == "html/search-index.js") {
            let searchScript = match (artifact.content.indexOf(";\nglobalThis.__CJDOC_SEARCH_SIGNATURES__ = ")) {
                case Some(index) => "globalThis.__CJDOC_SEARCH_INDEX__ = ${augmentedSearch.trimAscii()}" + artifact.content[index..]
                case None => "globalThis.__CJDOC_SEARCH_INDEX__ = ${augmentedSearch.trimAscii()};\n"
            }
            result.add(public_render.RenderArtifact(artifact.path, artifact.mediaType,
                searchScript))
        } else if (shouldAugmentApiArtifacts && (artifact.path.startsWith("html/symbols/") || artifact.path.startsWith("markdown/symbols/"))) {
            let content = conceptualAugmentApiArtifact(artifact.path, artifact.content,
                documentation, symbolIndex, pages, resolvers, locale)
            result.add(public_render.RenderArtifact(artifact.path, artifact.mediaType, content))
        } else {
            result.add(artifact)
        }
    }
    result.add(all: renderConceptualDocumentationArtifacts(documentation, formats, pages, locale: locale, docVersion: docVersion))
    result.toArray()
}
