package cjdoc_core

import markdown.Markdown
import std.collection.*

public class HtmlSiteFile {
    public let path: String
    public let content: String

    public init(path: String, content: String) {
        this.path = path
        this.content = content
    }
}

public class HtmlSite {
    public let files = ArrayList<HtmlSiteFile>()
}

// An explicit repository mapping for one dependency source tree. cjdoc never
// infers repositories or revisions from the local checkout.
public class DependencySourceLink {
    public let name: String
    public let urlTemplate: String
    public let revision: ?String

    public init(name: String, urlTemplate: String, revision!: ?String = None) {
        this.name = name
        this.urlTemplate = urlTemplate
        this.revision = revision
    }
}

private let HTML_STYLE = """
:root{color-scheme:light dark;--bg:#fff;--fg:#182026;--muted:#5f6b73;--line:#d8dde3;--panel:#f6f8fa;--link:#0969da} @media(prefers-color-scheme:dark){:root{--bg:#0d1117;--fg:#e6edf3;--muted:#9da7b1;--line:#30363d;--panel:#161b22;--link:#58a6ff}} *{box-sizing:border-box} body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.55 system-ui,sans-serif} main,.site-nav{max-width:72rem;margin:auto;padding:1.25rem} .site-nav{border-bottom:1px solid var(--line)} a{color:var(--link)} h1,h2,h3{line-height:1.25} code,pre{font-family:ui-monospace,monospace} pre{padding:1rem;overflow:auto;background:var(--panel);border:1px solid var(--line);border-radius:.4rem} article,.card{margin:1rem 0;padding:1rem;border:1px solid var(--line);border-radius:.5rem} .meta{color:var(--muted)} .badge{display:inline-block;padding:.1rem .45rem;margin-right:.35rem;background:var(--panel);border:1px solid var(--line);border-radius:999px;font-size:.85rem} .breadcrumbs{color:var(--muted);font-size:.9rem}.breadcrumbs ol{display:flex;flex-wrap:wrap;gap:.35rem;list-style:none;margin:0 0 1rem;padding:0}.breadcrumbs li+li:before{content:"/";margin-right:.35rem;color:var(--muted)} dt{font-weight:600;margin-top:.6rem} footer{max-width:72rem;margin:2rem auto;padding:1.25rem;color:var(--muted);border-top:1px solid var(--line)}
"""

private let HTML_SEARCH_STYLE = """
.site-nav{position:relative;display:flex;gap:1rem;align-items:center;flex-wrap:wrap}.site-search{margin-left:auto;display:grid;grid-template-columns:minmax(14rem,2fr) minmax(7rem,1fr) minmax(7rem,1fr);gap:.35rem;min-width:min(38rem,80vw)}.site-search input,.site-search select{width:100%;padding:.45rem .65rem;border:1px solid var(--line);border-radius:.35rem;background:var(--panel);color:var(--fg)}.search-results{position:absolute;z-index:10;right:1.25rem;top:4.25rem;width:min(38rem,calc(100% - 2.5rem));max-height:24rem;overflow:auto;margin:0;padding:.4rem;list-style:none;background:var(--bg);border:1px solid var(--line);border-radius:.4rem;box-shadow:0 .5rem 1.5rem #0003}.search-results:empty{display:none}.search-results a{display:block;padding:.45rem .55rem;text-decoration:none}.search-results a:hover,.search-results a:focus,.search-results [aria-selected=true] a{background:var(--panel)}.search-kind{color:var(--muted);font-size:.85rem}@media(max-width:48rem){.site-search{margin-left:0;min-width:100%;grid-template-columns:1fr 1fr}.site-search input{grid-column:1/-1}.search-results{top:7.5rem}}
"""

private let HTML_SEARCH_SCRIPT = """
(() => {
  const input = document.querySelector("[data-cjdoc-search]");
  const results = document.querySelector("[data-cjdoc-results]");
  if (!input || !results) return;
  let symbols = [];
  let visible = [];
  let selected = -1;
  const root = input.dataset.root || "";
  const kindFilter = document.querySelector("[data-cjdoc-kind]");
  const packageFilter = document.querySelector("[data-cjdoc-package]");
  const score = (entry, query) => {
    const name = entry.name.toLocaleLowerCase();
    const qualified = entry.qualifiedName.toLocaleLowerCase();
    if (name === query) return 0;
    if (qualified === query) return 1;
    if (name.startsWith(query)) return 2;
    if (qualified.startsWith(query)) return 3;
    const tokens = query.split(/\\s+/).filter(Boolean);
    const haystack = (entry.qualifiedName + " " + entry.kind + " " + entry.packageName + " " + entry.summary).toLocaleLowerCase();
    return tokens.every((token) => haystack.includes(token)) ? 4 : -1;
  };
  const select = (next) => {
    if (!visible.length) return;
    selected = (next + visible.length) % visible.length;
    for (let i = 0; i < results.children.length; i += 1) {
      results.children[i].setAttribute("aria-selected", i === selected ? "true" : "false");
    }
    const active = results.children[selected];
    input.setAttribute("aria-activedescendant", active.id);
    active.scrollIntoView({block: "nearest"});
  };
  const render = () => {
    results.replaceChildren();
    visible.length = 0;
    selected = -1;
    input.removeAttribute("aria-activedescendant");
    const query = input.value.trim().toLocaleLowerCase();
    if (!query) { input.setAttribute("aria-expanded", "false"); return; }
    const kind = kindFilter ? kindFilter.value : "";
    const packageName = packageFilter ? packageFilter.value : "";
    visible.push(...symbols.map((entry) => ({entry, rank: score(entry, query)}))
      .filter((item) => item.rank >= 0 && (!kind || item.entry.kind === kind) &&
        (!packageName || item.entry.packageName === packageName))
      .sort((left, right) => left.rank - right.rank ||
        left.entry.qualifiedName.localeCompare(right.entry.qualifiedName) || left.entry.id.localeCompare(right.entry.id))
      .slice(0, 20).map((item) => item.entry));
    for (const symbol of visible) {
      const item = document.createElement("li");
      const link = document.createElement("a");
      const name = document.createElement("span");
      const kind = document.createElement("span");
      link.href = root + symbol.url;
      name.textContent = symbol.qualifiedName;
      kind.className = "search-kind";
      kind.textContent = " — " + symbol.kind;
      item.id = "cjdoc-search-result-" + results.children.length;
      item.setAttribute("role", "option");
      item.setAttribute("aria-selected", "false");
      link.append(name, kind);
      item.append(link);
      results.append(item);
    }
    input.setAttribute("aria-expanded", visible.length ? "true" : "false");
  };
  const addOptions = (selectElement, values) => {
    if (!selectElement) return;
    for (const value of [...new Set(values)].sort((a, b) => a.localeCompare(b))) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = value;
      selectElement.append(option);
    }
  };
  fetch(root + "search-index.json", {credentials: "same-origin"})
    .then((response) => response.ok ? response.json() : Promise.reject(new Error("search index unavailable")))
    .then((index) => {
      symbols = index.schemaVersion === "cjdoc.search-index/2" && Array.isArray(index.symbols) ? index.symbols : [];
      addOptions(kindFilter, symbols.map((entry) => entry.kind));
      addOptions(packageFilter, symbols.map((entry) => entry.packageName));
      render();
    })
    .catch(() => { symbols = []; });
  input.addEventListener("input", render);
  if (kindFilter) kindFilter.addEventListener("change", render);
  if (packageFilter) packageFilter.addEventListener("change", render);
  input.addEventListener("keydown", (event) => {
    if (event.key === "ArrowDown") { event.preventDefault(); select(selected + 1); }
    else if (event.key === "ArrowUp") { event.preventDefault(); select(selected - 1); }
    else if (event.key === "Enter" && selected >= 0) { event.preventDefault(); results.children[selected].querySelector("a").click(); }
    else if (event.key === "Escape") { input.value = ""; render(); }
  });
  document.addEventListener("keydown", (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key.toLocaleLowerCase() === "k") {
      event.preventDefault(); input.focus();
    }
  });
})();
"""

private func htmlEscape(value: String): String {
    let out = StringBuilder()
    for (rune in value.runes()) {
        match (rune) {
            case '&' => out.append("&amp;")
            case '<' => out.append("&lt;")
            case '>' => out.append("&gt;")
            case '"' => out.append("&quot;")
            case '\'' => out.append("&#39;")
            case _ => out.append(rune)
        }
    }
    out.toString()
}

private func appendSlugByte(out: StringBuilder, byte: Byte): Unit {
    let digits = "0123456789abcdef"
    if ((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
        (byte >= b'0' && byte <= b'9') || byte == b'-' || byte == b'_' || byte == b'.') {
        out.append(String.fromUtf8([byte]))
    } else {
        out.append("_")
        let high = Int64((byte >> 4) & 0x0F)
        let low = Int64(byte & 0x0F)
        out.append(digits[high..high + 1])
        out.append(digits[low..low + 1])
    }
}

private func appendUrlPathByte(out: StringBuilder, byte: Byte): Unit {
    let digits = "0123456789ABCDEF"
    if ((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
        (byte >= b'0' && byte <= b'9') || byte == b'-' || byte == b'_' || byte == b'.' ||
        byte == b'~' || byte == b'/') {
        out.append(String.fromUtf8([byte]))
    } else {
        out.append("%")
        let high = Int64((byte >> 4) & 0x0F)
        let low = Int64(byte & 0x0F)
        out.append(digits[high..high + 1])
        out.append(digits[low..low + 1])
    }
}

private func encodeSourcePath(value: String): String {
    let out = StringBuilder()
    for (byte in value.toArray()) { appendUrlPathByte(out, byte) }
    out.toString()
}

private func sourceUrlTemplateValidFor(value: String, allowRevision: Bool): Bool {
    if (!(value.startsWith("https://") || value.startsWith("http://")) || !value.contains("{path}")) {
        return false
    }
    let authorityStart: Int64 = if (value.startsWith("https://")) { 8 } else { 7 }
    var index = authorityStart
    while (index < value.size && value[index] != b'/' && value[index] != b'?' && value[index] != b'#') {
        if (value[index] == b'{' || value[index] == b'}') { return false }
        index++
    }
    if (index == authorityStart) { return false }
    var remaining = value.replace("{path}", "").replace("{line}", "").replace("{column}", "")
    if (allowRevision) { remaining = remaining.replace("{revision}", "") }
    !remaining.contains("{") && !remaining.contains("}")
}

public func sourceUrlTemplateValid(value: String): Bool {
    sourceUrlTemplateValidFor(value, false)
}

public func dependencySourceUrlTemplateValid(value: String): Bool {
    sourceUrlTemplateValidFor(value, true)
}

private func dependencySourceUrl(links: Array<DependencySourceLink>, source: SourceLocation): ?String {
    if (!source.path.startsWith("dependencies/")) { return None }
    for (link in links) {
        let prefix = dependencyPrefix(link.name) + "/"
        if (!source.path.startsWith(prefix)) { continue }
        if (!dependencySourceUrlTemplateValid(link.urlTemplate)) { return None }
        if (link.urlTemplate.contains("{revision}") && link.revision.isNone()) { return None }
        var value = link.urlTemplate.replace("{path}", encodeSourcePath(source.path[prefix.size..]))
            .replace("{line}", source.startLine.toString())
            .replace("{column}", source.startColumn.toString())
        if (let Some(revision) <- link.revision) {
            value = value.replace("{revision}", encodeSourcePath(revision))
        }
        return Some(value)
    }
    None
}

private func sourceUrl(template: ?String, dependencyLinks: Array<DependencySourceLink>,
    source: SourceLocation): ?String {
    if (source.path.startsWith("dependencies/")) {
        return dependencySourceUrl(dependencyLinks, source)
    }
    if (let Some(value) <- template) {
        if (!sourceUrlTemplateValid(value)) { return None }
        return Some(value.replace("{path}", encodeSourcePath(source.path))
            .replace("{line}", source.startLine.toString())
            .replace("{column}", source.startColumn.toString()))
    }
    None
}

public func htmlStableSlug(value: String): String {
    if (value.isEmpty()) { return "root" }
    let out = StringBuilder()
    for (byte in value.toArray()) { appendSlugByte(out, byte) }
    out.toString()
}

private func stableFileHash(value: String): String {
    var first: Int64 = 0
    var second: Int64 = 0
    for (byte in value.toArray()) {
        first = (first * 131 + Int64(byte)) % 2147483647
        second = (second * 257 + Int64(byte)) % 2147483629
    }
    "${first}-${second}"
}

private func boundedFileSlug(value: String): String {
    let slug = htmlStableSlug(value)
    if (slug.size <= 160) { return slug }
    slug[..120] + "--" + stableFileHash(value)
}

private func packagePagePath(name: String): String {
    "packages/package-${boundedFileSlug(name)}.html"
}

private func moduleAnchor(module: ModuleDoc): String {
    "module-${htmlStableSlug(module.id)}"
}

private func findModule(documentation: DocumentationSet, id: String): ?ModuleDoc {
    for (module in documentation.modules) {
        if (module.id == id) { return Some(module) }
    }
    None
}

private func packageExists(documentation: DocumentationSet, name: String): Bool {
    for (pkg in documentation.packages) {
        if (pkg.name == name) { return true }
    }
    false
}

private func symbolPagePath(symbol: SymbolDoc): String {
    "symbols/symbol-${boundedFileSlug(symbol.id)}.html"
}

private func symbolAnchor(symbol: SymbolDoc): String {
    "symbol-${htmlStableSlug(symbol.id)}"
}

private func findSymbol(documentation: DocumentationSet, id: String): ?SymbolDoc {
    for (symbol in documentation.symbols) {
        if (symbol.id == id) { return Some(symbol) }
    }
    None
}

private func containingPageSymbol(documentation: DocumentationSet, symbol: SymbolDoc): ?SymbolDoc {
    if (symbol.isContainer) { return Some(symbol) }
    var current = symbol
    var remaining = documentation.symbols.size + 1
    while (remaining > 0) {
        if (current.ownerId.isNone()) { return None }
        if (let Some(ownerId) <- current.ownerId) {
            if (let Some(owner) <- findSymbol(documentation, ownerId)) {
                if (owner.isContainer) { return Some(owner) }
                current = owner
            } else {
                return None
            }
        }
        remaining--
    }
    None
}

private func symbolUrl(documentation: DocumentationSet, symbol: SymbolDoc): String {
    if (let Some(container) <- containingPageSymbol(documentation, symbol)) {
        let page = symbolPagePath(container)
        if (container.id == symbol.id) { return page }
        return page + "#" + symbolAnchor(symbol)
    }
    packagePagePath(symbol.packageName) + "#" + symbolAnchor(symbol)
}

private func relativeFromSubpage(path: String): String { "../" + path }

private func safeMarkdownHtml(value: String, headingDepth!: Int64 = 3): String {
    let prepared = prepareDocumentationMarkdown(value, headingDepth: headingDepth)
    if (prepared.isEmpty()) { return "" }
    try {
        Markdown.toSafeHtml(prepared)
    } catch (_: Exception) {
        "<p>${htmlEscape(prepared)}</p>\n"
    }
}

private func markdownPlainText(value: String): String {
    if (value.isEmpty()) { return "" }
    try {
        Markdown.toText(value).trimAscii()
    } catch (_: Exception) {
        value.trimAscii()
    }
}

private func appendPageStart(out: StringBuilder, title: String, rootPrefix: String): Unit {
    out.append("<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">")
    out.append("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
    out.append("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data: https:; connect-src 'self'; base-uri 'none'; form-action 'none'\">")
    out.append("<title>${htmlEscape(title)}</title><link rel=\"stylesheet\" href=\"")
    out.append(rootPrefix)
    out.append("style.css\"><script defer src=\"")
    out.append(rootPrefix)
    out.append("search.js\"></script></head><body>\n<nav class=\"site-nav\"><a href=\"")
    out.append(rootPrefix)
    out.append("index.html\">cjdoc</a><div class=\"site-search\"><label><span hidden>Search API</span>")
    out.append("<input type=\"search\" placeholder=\"Search API (Ctrl+K)\" autocomplete=\"off\" role=\"combobox\" aria-autocomplete=\"list\" aria-controls=\"cjdoc-search-results\" aria-expanded=\"false\" data-cjdoc-search data-root=\"")
    out.append(rootPrefix)
    out.append("\"></label><label><span hidden>Filter by kind</span><select data-cjdoc-kind><option value=\"\">All kinds</option></select></label>")
    out.append("<label><span hidden>Filter by package</span><select data-cjdoc-package><option value=\"\">All packages</option></select></label></div>")
    out.append("<ul id=\"cjdoc-search-results\" class=\"search-results\" role=\"listbox\" data-cjdoc-results aria-live=\"polite\"></ul></nav>\n<main>\n")
}

private func appendPageEnd(out: StringBuilder): Unit {
    out.append("</main>\n<footer>Generated by cjdoc 0.3.0.</footer>\n</body></html>\n")
}

private func appendPackageBreadcrumb(out: StringBuilder, packageName: String): Unit {
    out.append("<nav class=\"breadcrumbs\" aria-label=\"Breadcrumb\"><ol>")
    out.append("<li><a href=\"../index.html\">Home</a></li>")
    out.append("<li aria-current=\"page\">Package <code>${htmlEscape(packageName)}</code></li>")
    out.append("</ol></nav>\n")
}

private func appendSymbolBreadcrumb(out: StringBuilder, documentation: DocumentationSet,
    symbol: SymbolDoc): Unit {
    out.append("<nav class=\"breadcrumbs\" aria-label=\"Breadcrumb\"><ol>")
    out.append("<li><a href=\"../index.html\">Home</a></li>")
    out.append("<li><a href=\"${htmlEscape(relativeFromSubpage(packagePagePath(symbol.packageName)))}\">")
    out.append("Package <code>${htmlEscape(symbol.packageName)}</code></a></li>")
    let owners = ArrayList<SymbolDoc>()
    var current = symbol
    var remaining = documentation.symbols.size + 1
    while (remaining > 0) {
        if (let Some(ownerId) <- current.ownerId) {
            if (let Some(owner) <- findSymbol(documentation, ownerId)) {
                owners.add(owner)
                current = owner
            } else {
                break
            }
        } else {
            break
        }
        remaining--
    }
    var index = owners.size - 1
    while (index >= 0) {
        let owner = owners[index]
        out.append("<li><a href=\"${htmlEscape(relativeFromSubpage(symbolUrl(documentation, owner)))}\"><code>")
        out.append(htmlEscape(owner.name))
        out.append("</code></a></li>")
        index--
    }
    out.append("<li aria-current=\"page\"><code>${htmlEscape(symbol.name)}</code></li>")
    out.append("</ol></nav>\n")
}

private func appendMetadata(out: StringBuilder, documentation: DocumentationSet, symbol: SymbolDoc,
    sourceUrlTemplate: ?String, dependencySourceLinks: Array<DependencySourceLink>): Unit {
    out.append("<p class=\"meta\"><span class=\"badge\">")
    out.append(htmlEscape(symbol.kind))
    out.append("</span><span class=\"badge\">")
    out.append(htmlEscape(symbol.visibility))
    out.append("</span> ")
    if (let Some(ownerId) <- symbol.ownerId) {
        out.append("Owner: ")
        if (let Some(owner) <- findSymbol(documentation, ownerId)) {
            out.append("<a class=\"owner-link\" href=\"${htmlEscape(relativeFromSubpage(symbolUrl(documentation, owner)))}\"><code>")
            out.append(htmlEscape(owner.qualifiedName))
            out.append("</code></a> · ")
        } else {
            out.append("<code>${htmlEscape(ownerId)}</code> · ")
        }
    }
    let sourceLabel = htmlEscape("${symbol.source.path}:${symbol.source.startLine}:${symbol.source.startColumn}")
    if (let Some(url) <- sourceUrl(sourceUrlTemplate, dependencySourceLinks, symbol.source)) {
        out.append("<a class=\"source-link\" href=\"${htmlEscape(url)}\"><code>${sourceLabel}</code></a>")
    } else {
        out.append("<code>${sourceLabel}</code>")
    }
    out.append("</p>\n")
    out.append("<pre><code>")
    out.append(htmlEscape(symbol.sourceSignature))
    out.append("</code></pre>\n")
}

private func appendMarkdownSection(out: StringBuilder, title: String, value: String, depth!: Int64 = 3): Unit {
    if (value.trimAscii().isEmpty()) { return }
    out.append("<h3>${htmlEscape(title)}</h3>\n")
    out.append(safeMarkdownHtml(value, headingDepth: depth))
}

private func htmlRelationshipLabel(kind: String): String {
    match (kind) {
        case "extensionTarget" => "Extension target"
        case "superType" => "Supertype"
        case _ => kind
    }
}

private func appendRelationships(out: StringBuilder, symbol: SymbolDoc): Unit {
    if (symbol.relationships.isEmpty() && symbol.symbolRelationships.isEmpty()) { return }
    out.append("<h3>Relationships</h3><dl class=\"relationships\">\n")
    for (relationship in symbol.relationships) {
        out.append("<dt>${htmlEscape(htmlRelationshipLabel(relationship.kind))}</dt><dd><code>")
        out.append(htmlEscape(relationship.target.display))
        out.append("</code> <span class=\"badge\">${htmlEscape(relationship.target.state)}</span></dd>\n")
    }
    for (relationship in symbol.symbolRelationships) {
        let label = if (relationship.kind == "override") { "Override target" } else { relationship.kind }
        out.append("<dt>${htmlEscape(label)}</dt><dd><code>")
        out.append(htmlEscape(relationship.targetDisplay))
        out.append("</code> <span class=\"badge\">${htmlEscape(relationship.state)}</span></dd>\n")
    }
    out.append("</dl>\n")
}

private func appendDocumentation(out: StringBuilder, documentation: DocumentationSet, symbol: SymbolDoc): Unit {
    appendRelationships(out, symbol)
    if (let Some(comment) <- symbol.documentation) {
        if (let Some(value) <- comment.deprecated) {
            appendMarkdownSection(out, "Deprecated", value, depth: 4)
        }
        if (!comment.summaryMarkdown.isEmpty()) {
            out.append("<div class=\"summary\">")
            out.append(safeMarkdownHtml(comment.summaryMarkdown))
            out.append("</div>\n")
        }
        if (!comment.descriptionMarkdown.isEmpty()) {
            out.append("<div class=\"description\">")
            out.append(safeMarkdownHtml(comment.descriptionMarkdown))
            out.append("</div>\n")
        }
        if (!symbol.parameters.isEmpty()) {
            out.append("<h3>Parameters</h3><dl>\n")
            for (parameter in symbol.parameters) {
                out.append("<dt><code>${htmlEscape(parameter.name)}</code>: <code>")
                out.append(htmlEscape(parameter.typeRef.display))
                out.append("</code></dt><dd>")
                if (let Some(value) <- parameter.documentation) { out.append(safeMarkdownHtml(value, headingDepth: 4)) }
                out.append("</dd>\n")
            }
            out.append("</dl>\n")
        }
        if (let Some(returnType) <- symbol.returnType) {
            out.append("<h3>Returns</h3><p><code>${htmlEscape(returnType.display)}</code></p>\n")
            if (let Some(tag) <- comment.returns) { out.append(safeMarkdownHtml(tag.description, headingDepth: 4)) }
        }
        if (!comment.throwsTags.isEmpty()) {
            out.append("<h3>Throws</h3><dl>\n")
            for (tag in comment.throwsTags) {
                out.append("<dt><code>${htmlEscape(tag.subject)}</code></dt><dd>")
                out.append(safeMarkdownHtml(tag.description, headingDepth: 4))
                out.append("</dd>\n")
            }
            out.append("</dl>\n")
        }
        if (!comment.see.isEmpty()) {
            out.append("<h3>See also</h3><ul>\n")
            for (tag in comment.see) {
                out.append("<li>")
                if (let Some(target) <- resolvedReferenceTarget(documentation, tag)) {
                    out.append("<a href=\"${htmlEscape(relativeFromSubpage(symbolUrl(documentation, target)))}\"><code>")
                    out.append(htmlEscape(tag.subject))
                    out.append("</code></a>")
                } else {
                    out.append("<code>${htmlEscape(tag.subject)}</code>")
                }
                if (!tag.description.isEmpty()) {
                    out.append(" ")
                    out.append(safeMarkdownHtml(tag.description, headingDepth: 4))
                }
                out.append("</li>\n")
            }
            out.append("</ul>\n")
        }
        if (let Some(value) <- comment.since) { appendMarkdownSection(out, "Since", value, depth: 4) }
        if (!comment.authors.isEmpty()) {
            out.append("<h3>Authors</h3><ul>\n")
            for (author in comment.authors) { out.append("<li>${safeMarkdownHtml(author, headingDepth: 4)}</li>\n") }
            out.append("</ul>\n")
        }
        if (let Some(value) <- comment.version) { appendMarkdownSection(out, "Version", value, depth: 4) }
    } else {
        if (!symbol.parameters.isEmpty()) {
            out.append("<h3>Parameters</h3><dl>\n")
            for (parameter in symbol.parameters) {
                out.append("<dt><code>${htmlEscape(parameter.name)}</code>: <code>${htmlEscape(parameter.typeRef.display)}</code></dt><dd></dd>\n")
            }
            out.append("</dl>\n")
        }
        if (let Some(returnType) <- symbol.returnType) {
            out.append("<h3>Returns</h3><p><code>${htmlEscape(returnType.display)}</code></p>\n")
        }
    }
}

private func appendSymbolArticle(out: StringBuilder, documentation: DocumentationSet, symbol: SymbolDoc,
    sourceUrlTemplate: ?String, dependencySourceLinks: Array<DependencySourceLink>,
    linkTitle!: Bool = false): Unit {
    out.append("<article id=\"${symbolAnchor(symbol)}\">\n<h2>")
    if (linkTitle) {
        out.append("<a href=\"${htmlEscape(relativeFromSubpage(symbolUrl(documentation, symbol)))}\">")
        out.append(htmlEscape(symbol.qualifiedName))
        out.append("</a>")
    } else {
        out.append(htmlEscape(symbol.qualifiedName))
    }
    out.append("</h2>\n")
    appendMetadata(out, documentation, symbol, sourceUrlTemplate, dependencySourceLinks)
    appendDocumentation(out, documentation, symbol)
    out.append("</article>\n")
}

private func renderIndex(documentation: DocumentationSet): String {
    let out = StringBuilder()
    appendPageStart(out, "${documentation.projectName} API documentation", "")
    out.append("<h1>${htmlEscape(documentation.projectName)} API documentation</h1>\n")
    out.append("<p class=\"meta\">${documentation.modules.size} modules, ${documentation.packages.size} packages, ${documentation.symbols.size} symbols</p>\n")
    if (!documentation.modules.isEmpty()) {
        out.append("<h2>Modules</h2>\n")
        for (module in documentation.modules) {
            out.append("<section class=\"card\" id=\"${moduleAnchor(module)}\"><h3><code>")
            out.append(htmlEscape(module.name))
            out.append("</code> <span class=\"badge\">${htmlEscape(module.role)}</span></h3>\n")
            let prefix = if (module.sourcePrefix.isEmpty()) { "." } else { module.sourcePrefix }
            out.append("<p class=\"meta\">Source prefix: <code>${htmlEscape(prefix)}</code></p>\n")
            out.append("<h4>Packages</h4><ul>\n")
            if (module.packageNames.isEmpty()) {
                out.append("<li>None</li>\n")
            } else {
                for (packageName in module.packageNames) {
                    out.append("<li>")
                    if (packageExists(documentation, packageName)) {
                        out.append("<a href=\"${htmlEscape(packagePagePath(packageName))}\"><code>")
                        out.append(htmlEscape(packageName))
                        out.append("</code></a>")
                    } else {
                        out.append("<code>${htmlEscape(packageName)}</code>")
                    }
                    out.append("</li>\n")
                }
            }
            out.append("</ul><h4>Direct dependencies</h4><ul>\n")
            if (module.dependencyIds.isEmpty()) {
                out.append("<li>None</li>\n")
            } else {
                for (dependencyId in module.dependencyIds) {
                    out.append("<li>")
                    if (let Some(dependency) <- findModule(documentation, dependencyId)) {
                        out.append("<a href=\"#${moduleAnchor(dependency)}\"><code>")
                        out.append(htmlEscape(dependency.name))
                        out.append("</code></a>")
                    } else {
                        out.append("<code>${htmlEscape(dependencyId)}</code>")
                    }
                    out.append("</li>\n")
                }
            }
            out.append("</ul></section>\n")
        }
    }
    out.append("<h2>Packages</h2><ul>\n")
    for (pkg in documentation.packages) {
        out.append("<li><a href=\"${htmlEscape(packagePagePath(pkg.name))}\"><code>${htmlEscape(pkg.name)}</code></a></li>\n")
    }
    out.append("</ul>\n")
    if (!documentation.diagnostics.isEmpty()) {
        out.append("<h2>Diagnostics</h2><ul>\n")
        for (diagnostic in documentation.diagnostics) {
            out.append("<li><strong>${htmlEscape(diagnostic.severity)}[${htmlEscape(diagnostic.code)}]</strong>: ")
            out.append(htmlEscape(diagnostic.message))
            if (let Some(source) <- diagnostic.source) {
                out.append(" <code>${htmlEscape("${source.path}:${source.startLine}:${source.startColumn}")}</code>")
            }
            out.append("</li>\n")
        }
        out.append("</ul>\n")
    }
    appendPageEnd(out)
    out.toString()
}

private func renderPackagePage(documentation: DocumentationSet, pkg: PackageDoc,
    sourceUrlTemplate: ?String, dependencySourceLinks: Array<DependencySourceLink>): String {
    let out = StringBuilder()
    appendPageStart(out, "Package ${pkg.name}", "../")
    appendPackageBreadcrumb(out, pkg.name)
    out.append("<h1>Package <code>${htmlEscape(pkg.name)}</code></h1>\n")
    if (!pkg.sourceFiles.isEmpty()) {
        out.append("<h2>Sources</h2><ul>\n")
        for (path in pkg.sourceFiles) { out.append("<li><code>${htmlEscape(path)}</code></li>\n") }
        out.append("</ul>\n")
    }
    out.append("<h2>Declarations</h2>\n")
    for (symbol in documentation.symbols) {
        if (symbol.packageName == pkg.name && symbol.ownerId.isNone()) {
            if (symbol.isContainer) {
                out.append("<div class=\"card\"><a href=\"${htmlEscape(relativeFromSubpage(symbolPagePath(symbol)))}\"><code>")
                out.append(htmlEscape(symbol.qualifiedName))
                out.append("</code></a> <span class=\"badge\">${htmlEscape(symbol.kind)}</span>")
                if (let Some(comment) <- symbol.documentation) {
                    out.append(safeMarkdownHtml(comment.summaryMarkdown))
                }
                out.append("</div>\n")
            } else {
                appendSymbolArticle(out, documentation, symbol, sourceUrlTemplate, dependencySourceLinks)
            }
        }
    }
    appendPageEnd(out)
    out.toString()
}

private func renderSymbolPage(documentation: DocumentationSet, symbol: SymbolDoc,
    sourceUrlTemplate: ?String, dependencySourceLinks: Array<DependencySourceLink>): String {
    let out = StringBuilder()
    appendPageStart(out, symbol.qualifiedName, "../")
    appendSymbolBreadcrumb(out, documentation, symbol)
    out.append("<h1>${htmlEscape(symbol.qualifiedName)}</h1>\n")
    appendMetadata(out, documentation, symbol, sourceUrlTemplate, dependencySourceLinks)
    appendDocumentation(out, documentation, symbol)
    var wroteMembers = false
    for (member in documentation.symbols) {
        if (member.ownerId == Some(symbol.id)) {
            if (!wroteMembers) {
                out.append("<h2>Members</h2>\n")
                wroteMembers = true
            }
            appendSymbolArticle(out, documentation, member, sourceUrlTemplate, dependencySourceLinks,
                linkTitle: member.isContainer)
        }
    }
    appendPageEnd(out)
    out.toString()
}

private func renderSearchIndex(documentation: DocumentationSet): String {
    let out = StringBuilder()
    out.append("{\"schemaVersion\":\"cjdoc.search-index/2\",\"projectName\":")
    out.append(jsonEscape(documentation.projectName))
    out.append(",\"symbols\":[")
    var first = true
    for (symbol in documentation.symbols) {
        if (!first) { out.append(",") }
        first = false
        let summary = match (symbol.documentation) {
            case Some(comment) => markdownPlainText(comment.summaryMarkdown)
            case None => ""
        }
        out.append("{\"id\":${jsonEscape(symbol.id)},\"kind\":${jsonEscape(symbol.kind)},")
        out.append("\"name\":${jsonEscape(symbol.name)},\"qualifiedName\":${jsonEscape(symbol.qualifiedName)},")
        out.append("\"packageName\":${jsonEscape(symbol.packageName)},\"visibility\":${jsonEscape(symbol.visibility)},\"summary\":${jsonEscape(summary)},")
        out.append("\"url\":${jsonEscape(symbolUrl(documentation, symbol))}}")
    }
    out.append("]}\n")
    out.toString()
}

public func renderDocumentationHtml(documentation: DocumentationSet,
    sourceUrlTemplate!: ?String = None,
    dependencySourceLinks!: Array<DependencySourceLink> = []): HtmlSite {
    sortDocumentationDeterministically(documentation)
    let site = HtmlSite()
    site.files.add(HtmlSiteFile("index.html", renderIndex(documentation)))
    site.files.add(HtmlSiteFile("search-index.json", renderSearchIndex(documentation)))
    site.files.add(HtmlSiteFile("search.js", HTML_SEARCH_SCRIPT))
    site.files.add(HtmlSiteFile("style.css", HTML_STYLE + HTML_SEARCH_STYLE))
    for (pkg in documentation.packages) {
        site.files.add(HtmlSiteFile(packagePagePath(pkg.name),
            renderPackagePage(documentation, pkg, sourceUrlTemplate, dependencySourceLinks)))
    }
    for (symbol in documentation.symbols) {
        if (symbol.isContainer) {
            site.files.add(HtmlSiteFile(symbolPagePath(symbol),
                renderSymbolPage(documentation, symbol, sourceUrlTemplate, dependencySourceLinks)))
        }
    }
    site
}
