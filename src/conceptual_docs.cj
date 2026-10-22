package cjdoc

import cjdoc.model.*
import cjdoc.model as public_model
import std.collection.*
import std.fs.*

internal let CONCEPTUAL_CONFIG_MAX_BYTES: Int64 = 64 * 1024
internal let CONCEPTUAL_PAGE_MAX_BYTES: Int64 = 256 * 1024
internal let CONCEPTUAL_MAX_PAGES: Int64 = 128

internal class ConceptualPageSpec {
    var source = ""
    var route = ""
    var title = ""
    var id = ""
    var language: ?String = None
    var kind = "guide"
    var packageName = ""
    let sections = ArrayList<public_model.DocumentationSection>()

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
    var id = ""
    var language: ?String = None
    var packageName = ""
    let sections = ArrayList<public_model.DocumentationSection>()

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
    if (marker == b'`') {
        var infoIndex: Int64 = count
        while (infoIndex < trimmed.size) {
            if (trimmed[infoIndex] == b'`') { return "" }
            infoIndex++
        }
    }
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

// Maximum explicit API bindings honoured per guide page.
internal let CONCEPTUAL_BINDING_LIMIT: Int64 = 32

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
        if (count >= CONCEPTUAL_BINDING_LIMIT) {
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


// A sentinel that survives Markdown rendering as a plain paragraph, so the
// rendered page can replace it with the matching binding chip. It carries no
// author-visible text and never derives a target from a heading or a name.

internal func conceptualInlineBindingSentinel(index: Int64): String {
    "cjdoc-inline-binding-" + index.toString()
}

internal func conceptualMarkdownWithoutBindings(markdown: String,
    sentinels!: Bool = true): String {
    let out = StringBuilder()
    var fence = ""
    var bindingIndex: Int64 = 0
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
        if (line.startsWith("<!-- cjdoc-bind ") && line.endsWith(" -->")) {
            let target = conceptualBindingAttribute(line, "target")
            // Mirror the collector exactly: a marker without a target, or one
            // beyond the binding cap, produces no binding and so no placeholder.
            if (!target.isEmpty() && bindingIndex < CONCEPTUAL_BINDING_LIMIT) {
                if (sentinels) {
                    // A bare block keeps the placeholder out of an adjacent
                    // paragraph without breaking an enclosing table or list.
                    out.append(conceptualInlineBindingSentinel(bindingIndex))
                    out.append("\n")
                }
                bindingIndex++
            }
            continue
        }
        out.append(rawLine)
        out.append("\n")
    }
    out.toString()
}

internal func conceptualVisibleForAudience(symbol: public_model.SymbolDoc,
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
            let matchesTarget = conceptualBindingMatches(symbol, binding.target, binding.selector)
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
            if (line == "[docs.pages.sections]" && current.isSome()) {
                section = "docs.pages.sections"
                continue
            }
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
            } else if (key == "id") {
                page.id = conceptualValue(value)
            } else if (key == "language") {
                page.language = Some(public_model.documentationLanguage(conceptualValue(value)))
            } else if (key == "kind") {
                page.kind = conceptualValue(value)
            } else if (key == "package") {
                page.packageName = conceptualValue(value)
            }
        } else if (section == "docs.pages.sections" && current.isSome()) {
            current.getOrThrow().sections.add(public_model.DocumentationSection(conceptualValue(key), conceptualValue(value)))
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

internal func conceptualSymbolSlug(value: String): String {
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

private func conceptualRoute(route: String, fallback: String): String {
    let selected = if (route.isEmpty()) { fallback } else { route }
    let normalized = if (selected.endsWith(".html")) { selected } else { "${selected}.html" }
    if (!conceptualSafeRoute(normalized) || !normalized.startsWith("concepts/")) {
        throw IllegalArgumentException("conceptual page route must stay under concepts/")
    }
    normalized
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
    let routeKey = page.language.getOrDefault({ => "unknown" }) + ":" + page.route
    if (routes.add(routeKey)) {
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
    while (!routes.add(page.language.getOrDefault({ => "unknown" }) + ":" + candidate)) {
        candidate = stem + "--" + suffix + "-" + serial.toString() + ".html"
        serial++
    }
    documentation.appendDiagnostic(public_model.Diagnostic("warning", "CJDOC4060",
        "conceptual route collision at ${page.route}; emitted ${candidate}"))
    let routedPage = ConceptualPage(page.source, candidate, page.title, page.kind, page.markdown)
    routedPage.id = page.id; routedPage.language = page.language; routedPage.packageName = page.packageName
    routedPage.sections.add(all: page.sections)
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
        let page = ConceptualPage(source, route, conceptualTitle(markdown, pkg.name), "package", markdown)
        // Synthetic fallback pages deliberately carry no author package association.
        if (exists(configured)) { page.packageName = pkg.name }
        conceptualAddPage(documentation, pages, routes, page)
    }
    for (spec in config.pages) {
        let route = conceptualRoute(spec.route, "concepts/guides/${conceptualSlug(spec.source.removeSuffix(".md"))}")
        let page = conceptualPageFromSource(root, spec.source, route, spec.title, spec.kind, spec.source)
        page.id = spec.id; page.language = spec.language; page.packageName = spec.packageName
        page.sections.add(all: spec.sections)
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
