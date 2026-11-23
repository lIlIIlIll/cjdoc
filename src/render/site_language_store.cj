package cjdoc.render

import cjdoc.render.foundation.RenderResourceLimitException
import cjdoc.render.foundation.{validateRenderArtifactPath, RenderArtifactStore, RenderArtifactBudget}
import cjdoc.model.*
import std.collection.*

// Read only the generated body start tag, never a similar attribute in prose
// or an inline declaration. Version composition also uses this identity.
protected func generatedHtmlBodyAttribute(content: String, name: String): ?String {
    let start = content.indexOf("<body ")
    if (start.isNone()) { return None }
    let end = content.indexOf(b'>', start.getOrThrow())
    if (end.isNone()) { return None }
    let tag = content[start.getOrThrow()..end.getOrThrow()]
    let key = " " + name + "=\""
    if (let Some(offset) <- tag.indexOf(key)) {
        let valueStart = offset + key.size
        return tag.indexOf(b'"', valueStart).map({ valueEnd =>
            tag[valueStart..valueEnd].replace("&quot;", "\"").replace("&#39;", "'")
                .replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
        })
    }
    None
}

internal class LanguageHtmlPage {
    let language: String
    let route: String
    let file: String
    let symbolId: ?String
    let pageId: ?String
    let packageAliasFor: ?String
    let entry: Int64
    let anchors: Array<String>
    let anchorMembership = HashSet<String>()
    let needsToggle: Bool

    init(language: String, route: String, file: String, entry: Int64, content: String) {
        this.language = language
        this.route = route
        this.file = file
        symbolId = generatedHtmlBodyAttribute(content, "data-cjdoc-symbol-id")
        pageId = generatedHtmlBodyAttribute(content, "data-cjdoc-page-id")
        packageAliasFor = generatedHtmlBodyAttribute(content, "data-cjdoc-package-alias-for")
        this.entry = entry
        this.anchors = if (packageAliasFor.isSome()) { [] } else { documentationHtmlAnchors(content) }
        this.needsToggle = content.contains("id=\"cjdoc-main\"") &&
            !content.contains("class=\"cj-lang-toggle\"")
        for (anchor in anchors) { let _ = anchorMembership.add(anchor) }
    }
}

internal class LanguageHtmlInventory {
    let pages = ArrayList<LanguageHtmlPage>()
    let files = HashMap<String, LanguageHtmlPage>()
    let routes = HashMap<String, String>()
    let symbolFiles = HashMap<String, LanguageHtmlPage>()
    let generatedPages = HashMap<String, LanguageHtmlPage>()

    func identity(documentation: DocumentationSet, page: LanguageHtmlPage): String {
        if (let Some(id) <- page.symbolId) { return "symbol:" + id }
        if (let Some(id) <- page.pageId) { return id }
        if (let Some(id) <- page.packageAliasFor) { return id }
        languagePageIdentity(documentation, page.route, page.language)
    }

    func capture(documentation: DocumentationSet, language: String, route: String,
        entry: Int64, content: String, mounted!: Bool = false): Unit {
        if (!route.endsWith(".html")) { return }
        let file = if (mounted) { route } else { language + "/" + route }
        let page = LanguageHtmlPage(language, route, file, entry, content)
        pages.add(page)
        if (page.packageAliasFor.isSome()) { return }
        let key = language + ":" + route
        if (!mounted && files.contains(key)) { return }
        files[key] = page
        if (let Some(id) <- page.symbolId) { symbolFiles[language + ":" + id] = page }
        if (let Some(id) <- page.pageId) { generatedPages[language + ":" + id] = page }
        if (page.needsToggle || content.contains("class=\"cj-lang-toggle\"")) {
            routes[language + ":" + identity(documentation, page)] = file
        }
    }
}

private class LanguageStoreEntry {
    let path: String
    let target: ?Int64
    let text: Bool
    var size: Int64

    init(path: String, target: ?Int64, text: Bool, size: Int64) {
        this.path = path
        this.target = target
        this.text = text
        this.size = size
    }
}

// A language has its own budget and local ordinals, even for non-reading formats
// whose later language copies are deliberately not published.
internal class LanguageArtifactStore <: RenderArtifactStore {
    private let target: RenderArtifactStore
    private let documentation: DocumentationSet
    private let language: String
    private let firstLanguage: Bool
    private let inventory: LanguageHtmlInventory
    private let budget = RenderArtifactBudget()
    private let entries = ArrayList<LanguageStoreEntry>()

    init(target: RenderArtifactStore, documentation: DocumentationSet, language: String,
        firstLanguage: Bool, inventory: LanguageHtmlInventory) {
        this.target = target
        this.documentation = documentation
        this.language = language
        this.firstLanguage = firstLanguage
        this.inventory = inventory
    }

    private func publishedPath(path: String): ?String {
        let parts = path.split("/", 2)
        if (parts.size == 2 && ["html", "markdown", "symbol-index"].contains(parts[0])) {
            return Some(parts[0] + "/" + language + "/" + parts[1])
        }
        if (firstLanguage) { Some(path) } else { None }
    }

    public func addText(path: String, mediaType: String, content: String): Int64 {
        budget.checkAdd(path, content.size)
        validateRenderArtifactPath(path)
        let output = publishedPath(path).map({ destination =>
            target.addText(destination, mediaType, content)
        })
        entries.add(LanguageStoreEntry(path, output, true, content.size))
        budget.commitAdd(content.size)
        if (path.startsWith("html/")) {
            if (let Some(ordinal) <- output) {
                inventory.capture(documentation, language, path.removePrefix("html/"), ordinal, content)
            }
        }
        entries.size - 1
    }

    func addMountedApiPage(route: String, content: String): Unit {
        let path = "html/" + route
        budget.checkAdd(path, content.size)
        let entry = target.addText(path, "text/html; charset=utf-8", content)
        budget.commitAdd(content.size)
        inventory.capture(documentation, language, route, entry, content, mounted: true)
    }

    public func addOwnedBytes(path: String, mediaType: String, bytes: Array<Byte>): Int64 {
        budget.checkAdd(path, bytes.size)
        validateRenderArtifactPath(path)
        let output = publishedPath(path).map({ destination =>
            target.addOwnedBytes(destination, mediaType, bytes)
        })
        entries.add(LanguageStoreEntry(path, output, false, bytes.size))
        budget.commitAdd(bytes.size)
        if (path.startsWith("html/")) {
            if (let Some(ordinal) <- output) {
                inventory.capture(documentation, language, path.removePrefix("html/"), ordinal, "")
            }
        }
        entries.size - 1
    }

    private func textEntry(entry: Int64): LanguageStoreEntry {
        if (entry < 0 || entry >= entries.size || !entries[entry].text) {
            throw IllegalArgumentException("language artifact entry ${entry} is not text")
        }
        entries[entry]
    }

    public func readText(entry: Int64, limit: Int64): String {
        let value = textEntry(entry)
        if (limit < 0 || value.size > limit) {
            throw RenderResourceLimitException("language artifact entry ${entry} exceeds ${limit} UTF-8 bytes")
        }
        target.readText(value.target.getOrThrow(), limit)
    }

    public func replaceText(entry: Int64, content: String): Unit {
        let value = textEntry(entry)
        budget.checkReplace(value.path, value.size, content.size)
        target.replaceText(value.target.getOrThrow(), content)
        budget.commitReplace(value.size, content.size)
        value.size = content.size
    }
}
