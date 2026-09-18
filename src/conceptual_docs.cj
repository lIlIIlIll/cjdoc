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

internal class ConceptualPage {
    let source: String
    let route: String
    let title: String
    let kind: String
    let markdown: String

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
            if (!page.route.isEmpty() && !conceptualSafeRelative(page.route)) {
                throw IllegalArgumentException("[[docs.pages]] route must be a safe relative path")
            }
            config.pages.add(page)
        case None => ()
    }
}

private func loadConceptualDocsConfig(projectRoot: String): ConceptualDocsConfig {
    let config = ConceptualDocsConfig()
    let root = Path(projectRoot)
    let docsRoot = root.join("docs")
    if (exists(docsRoot)) { config.enabled = true }
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

private func conceptualRoute(route: String, fallback: String): String {
    let selected = if (route.isEmpty()) { fallback } else { route }
    let normalized = if (selected.endsWith(".html")) { selected } else { "${selected}.html" }
    if (!conceptualSafeRelative(normalized) || !normalized.startsWith("concepts/")) {
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
    for (line in markdown.replace("\r\n", "\n").replace("\r", "\n").split("\n")) {
        let text = line.trimAscii()
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

private func conceptualAddPage(pages: ArrayList<ConceptualPage>, routes: HashSet<String>, page: ConceptualPage): Unit {
    if (!routes.add(page.route)) {
        eprintln("warning[CJDOC4060]: conceptual route collision at ${page.route}")
        return
    }
    if (pages.size >= CONCEPTUAL_MAX_PAGES) {
        throw IllegalArgumentException("conceptual documentation exceeds ${CONCEPTUAL_MAX_PAGES} pages")
    }
    pages.add(page)
}

private func conceptualPages(root: Path, documentation: public_model.DocumentationSet,
    config: ConceptualDocsConfig): ArrayList<ConceptualPage> {
    let pages = ArrayList<ConceptualPage>()
    let routes = HashSet<String>()
    let indexPath = root.join(config.indexSource)
    if (exists(indexPath)) {
        let page = conceptualPageFromSource(root, config.indexSource, "concepts/index.html", "", "project",
            documentation.project.name)
        conceptualAddPage(pages, routes, page)
    } else if (config.enabled) {
        conceptualAddPage(pages, routes,
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
        conceptualAddPage(pages, routes,
            ConceptualPage(source, conceptualRoute("concepts/modules/${conceptualSlug(module.name)}", "concepts/modules/module"),
                conceptualTitle(markdown, module.name), "module", markdown))
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
        conceptualAddPage(pages, routes,
            ConceptualPage(source, conceptualRoute("concepts/packages/${conceptualSlug(pkg.name)}", "concepts/packages/package"),
                conceptualTitle(markdown, pkg.name), "package", markdown))
    }
    for (spec in config.pages) {
        let route = conceptualRoute(spec.route, "concepts/guides/${conceptualSlug(spec.source.removeSuffix(".md"))}")
        let page = conceptualPageFromSource(root, spec.source, route, spec.title, "guide", spec.source)
        conceptualAddPage(pages, routes, page)
    }
    pages
}

internal func conceptualAgentPages(projectRoot: String,
    documentation: public_model.DocumentationSet): Array<public_render.AgentConceptualPage> {
    let config = loadConceptualDocsConfig(projectRoot)
    if (!config.enabled) { return [] }
    let pages = conceptualPages(Path(projectRoot), documentation, config)
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
    conceptualRelativePrefix(route) + "index.html"
}

private func conceptualHtmlPage(page: ConceptualPage, body: String): String {
    let prefix = conceptualRelativePrefix(page.route)
    let out = StringBuilder()
    out.append("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">")
    out.append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">")
    out.append("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'self' file:; style-src 'self' file:; img-src 'self' file:; base-uri 'none'; form-action 'none'\">")
    out.append("<title>${public_render.escapeStandaloneHtml(page.title)}</title><script src=\"${prefix}theme-bootstrap.js\"></script><link rel=\"stylesheet\" href=\"${prefix}style.css\">")
    out.append("<meta name=\"cjdoc-source\" content=\"${public_render.escapeStandaloneHtml(page.source)}\">")
    out.append("<script defer src=\"${prefix}search-index.js\"></script>")
    out.append("<script defer src=\"${prefix}search.js\"></script></head><body>")
    out.append("<header><nav><a href=\"${prefix}index.html\">API reference</a> · ")
    out.append("<a href=\"${conceptualIndexHref(page.route)}\">Concepts</a></nav></header>")
    out.append("<main><h1>${public_render.escapeStandaloneHtml(page.title)}</h1>${body}</main>")
    out.append("<footer>Generated by cjdoc</footer></body></html>\n")
    out.toString()
}

private func conceptualMarkdownPage(page: ConceptualPage, pages: ArrayList<ConceptualPage>): String {
    let prefix = conceptualRelativePrefix(page.route)
    let conceptsHref = conceptualIndexHref(page.route).removeSuffix(".html") + ".md"
    let out = StringBuilder()
    out.append("[API reference](${prefix}index.md) · [Concepts](${conceptsHref})\n\n")
    out.append("<!-- source: ${page.source} -->\n\n")
    out.append(page.markdown)
    if (!page.markdown.endsWith("\n")) { out.append("\n") }
    if (page.kind == "project") { out.append(conceptualProjectMarkdownNavigation(pages)) }
    out.toString()
}

private func conceptualJsonString(value: String): String {
    let out = StringBuilder()
    out.append("\"")
    for (rune in value.runes()) {
        match (rune) {
            case r'\\' => out.append("\\\\")
            case r'"' => out.append("\\\"")
            case r'\n' => out.append("\\n")
            case r'\r' => out.append("\\r")
            case r'\t' => out.append("\\t")
            case _ => out.append(rune)
        }
    }
    out.append("\"")
    out.toString()
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
        out.append("}")
    }
    out.append(suffix)
    out.toString()
}

private func conceptualNavigationHtml(): String {
    "<p class=\"conceptual-navigation\"><a href=\"concepts/index.html\">Conceptual documentation</a></p>\n"
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
            out.append("- [${entry.title}](${path})\n")
        }
    }
    out.toString()
}

internal func renderConceptualDocumentationArtifacts(projectRoot: String,
    documentation: public_model.DocumentationSet, formats: Array<String>): Array<public_render.RenderArtifact> {
    let config = loadConceptualDocsConfig(projectRoot)
    if (!config.enabled) { return [] }
    let root = Path(projectRoot)
    let pages = conceptualPages(root, documentation, config)
    let artifacts = ArrayList<public_render.RenderArtifact>()
    for (format in formats) {
        if (format == "html") {
            for (page in pages) {
                let body = public_render.renderStandaloneMarkdownHtml(parseStandaloneMarkdown(page.markdown))
                let pageBody = if (page.kind == "project") {
                    body + conceptualProjectHtmlNavigation(pages)
                } else {
                    body
                }
                artifacts.add(public_render.RenderArtifact("html/${page.route}", "text/html; charset=utf-8",
                    conceptualHtmlPage(page, pageBody)))
            }
        } else if (format == "markdown") {
            for (page in pages) {
                let path = page.route.removePrefix("concepts/").removeSuffix(".html")
                artifacts.add(public_render.RenderArtifact("markdown/concepts/${path}.md",
                    "text/markdown; charset=utf-8", conceptualMarkdownPage(page, pages)))
            }
        }
    }
    artifacts.toArray()
}

internal func conceptualSearchAugmentation(projectRoot: String, documentation: public_model.DocumentationSet,
    formats: Array<String>, baseSearch: String): String {
    let config = loadConceptualDocsConfig(projectRoot)
    var hasHtml = false
    for (format in formats) { if (format == "html") { hasHtml = true } }
    if (!config.enabled || !hasHtml) { return baseSearch }
    conceptualSearchIndex(baseSearch, conceptualPages(Path(projectRoot), documentation, config))
}
private func injectConceptualNavigation(content: String): String {
    let marker = "</header>"
    match (content.indexOf(marker)) {
        case Some(index) =>
            let end = index + marker.size
            content[..end] + "\n" + conceptualNavigationHtml() + content[end..]
        case None => content + "\n" + conceptualNavigationHtml()
    }
}
internal func conceptualIndexNavigation(projectRoot: String, documentation: public_model.DocumentationSet,
    format: String, content: String): String {
    let config = loadConceptualDocsConfig(projectRoot)
    if (!config.enabled) { return content }
    if (format == "html") { return injectConceptualNavigation(content) }
    if (format == "markdown") { return content + conceptualNavigationMarkdown() }
    content
}

internal func appendConceptualArtifacts(projectRoot: String,
    documentation: public_model.DocumentationSet, formats: Array<String>,
    baseArtifacts: Array<public_render.RenderArtifact>): Array<public_render.RenderArtifact> {
    var search = ""
    for (artifact in baseArtifacts) {
        if (artifact.path == "html/search-index.json") { search = artifact.content }
    }
    let augmentedSearch = conceptualSearchAugmentation(projectRoot, documentation, formats, search)
    let result = ArrayList<public_render.RenderArtifact>()
    for (artifact in baseArtifacts) {
        if (artifact.path == "html/index.html") {
            result.add(public_render.RenderArtifact(artifact.path, artifact.mediaType,
                conceptualIndexNavigation(projectRoot, documentation, "html", artifact.content)))
        } else if (artifact.path == "markdown/index.md") {
            result.add(public_render.RenderArtifact(artifact.path, artifact.mediaType,
                conceptualIndexNavigation(projectRoot, documentation, "markdown", artifact.content)))
        } else if (artifact.path == "html/search-index.json") {
            result.add(public_render.RenderArtifact(artifact.path, artifact.mediaType, augmentedSearch))
        } else if (artifact.path == "html/search-index.js") {
            result.add(public_render.RenderArtifact(artifact.path, artifact.mediaType,
                "globalThis.__CJDOC_SEARCH_INDEX__ = ${augmentedSearch.trimAscii()};\n"))
        } else {
            result.add(artifact)
        }
    }
    result.add(all: renderConceptualDocumentationArtifacts(projectRoot, documentation, formats))
    result.toArray()
}
