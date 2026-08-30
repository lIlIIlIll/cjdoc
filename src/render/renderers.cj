package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.sort.*

public class RenderArtifact {
    public let path: String
    public let mediaType: String
    public let content: String
    private let bytesStorage: Array<Byte>

    public init(path: String, mediaType: String, content: String) {
        if (path.isEmpty() || path.startsWith("/") || path.contains("\\") || path.contains("..")) {
            throw IllegalArgumentException("render artifact path must stay within the output directory")
        }
        this.path = path
        this.mediaType = mediaType
        this.content = content
        this.bytesStorage = content.toArray()
    }

    public init(path: String, mediaType: String, bytes: Array<Byte>) {
        if (path.isEmpty() || path.startsWith("/") || path.contains("\\") || path.contains("..")) {
            throw IllegalArgumentException("render artifact path must stay within the output directory")
        }
        this.path = path
        this.mediaType = mediaType
        this.content = ""
        this.bytesStorage = bytes
    }

    public prop bytes: Array<Byte> { get() { bytesStorage.clone() } }
    public prop isBinary: Bool { get() { content.isEmpty() && !bytesStorage.isEmpty() } }
}

public interface DocumentationRenderer {
    prop format: String
    func render(documentation: DocumentationSet): Array<RenderArtifact>
}

public class JsonDocumentationRenderer <: DocumentationRenderer {
    public prop format: String { get() { "json" } }

    public func render(documentation: DocumentationSet): Array<RenderArtifact> {
        validateDocumentationSet(documentation)
        [RenderArtifact("docs.json", "application/json", encodeDocIr(documentation))]
    }
}

private func isVisibleForAudience(declaration: SymbolDoc, audience: String): Bool {
    match (audience) {
        case "external" => declaration.visibility == "public" || declaration.visibility == "protected"
        case "package" => declaration.visibility != "private"
        case "all" => true
        case _ => false
    }
}

private func appendMarkdownPlainText(out: StringBuilder, node: MarkdownNode): Unit {
    match (node.kind) {
        case "text" | "code_span" | "code_block" | "html_inline" | "html_block" =>
            out.append(node.literal)
        case "soft_break" | "hard_break" => out.append("\n")
        case "thematic_break" => out.append("\n")
        case _ =>
            var first = true
            for (child in node.children) {
                if (!first && (node.kind == "paragraph" || node.kind == "heading" ||
                    node.kind == "list_item" || node.kind == "table_cell")) { out.append(" ") }
                first = false
                appendMarkdownPlainText(out, child)
            }
            if (node.kind == "paragraph" || node.kind == "heading" ||
                node.kind == "list_item" || node.kind == "block_quote") { out.append("\n") }
    }
}

private func markdownNodeText(node: MarkdownNode): String {
    let out = StringBuilder()
    appendMarkdownPlainText(out, node)
    out.toString().trimAscii()
}

private func appendEscapedMarkdownText(out: StringBuilder, value: String): Unit {
    for (rune in value.runes()) {
        match (rune) {
            case '\\' | '`' | '*' | '_' | '{' | '}' | '[' | ']' | '<' | '>' | '#' |
                '+' | '-' | '!' | '|' => out.append("\\"); out.append(rune)
            case _ => out.append(rune)
        }
    }
}

private func safeLinkDestination(value: String): Bool {
    if (value.isEmpty() || value.contains("\"") || value.contains("'") ||
        value.contains("\n") || value.contains("\r")) { return false }
    value.startsWith("https://") || value.startsWith("http://") ||
        value.startsWith("mailto:") || value.startsWith("#")
}

private func assetReference(assetLookup: HashMap<String, String>, destination: String): ?String {
    match (assetLookup.get("path:${destination}")) {
        case Some(value) => Some(value)
        case None => match (assetLookup.get("id:${destination}")) {
            case Some(value) => Some(value)
            case None => if (destination.startsWith("./")) {
                assetLookup.get("path:${destination[2..]}")
            } else { None }
        }
    }
}

private func appendMarkdownNodeMarkdown(out: StringBuilder, node: MarkdownNode,
    assetLookup: HashMap<String, String>): Unit {
    match (node.kind) {
        case "document" => for (child in node.children) {
            appendMarkdownNodeMarkdown(out, child, assetLookup)
        }
        case "paragraph" =>
            for (child in node.children) { appendMarkdownNodeMarkdown(out, child, assetLookup) }
            out.append("\n\n")
        case "heading" =>
            out.append("### ")
            for (child in node.children) { appendMarkdownNodeMarkdown(out, child, assetLookup) }
            out.append("\n\n")
        case "text" => appendEscapedMarkdownText(out, node.literal)
        case "soft_break" => out.append("\n")
        case "hard_break" => out.append("  \n")
        case "emphasis" =>
            out.append("*"); for (child in node.children) {
                appendMarkdownNodeMarkdown(out, child, assetLookup)
            }; out.append("*")
        case "strong" =>
            out.append("**"); for (child in node.children) {
                appendMarkdownNodeMarkdown(out, child, assetLookup)
            }; out.append("**")
        case "strikethrough" =>
            out.append("~~"); for (child in node.children) {
                appendMarkdownNodeMarkdown(out, child, assetLookup)
            }; out.append("~~")
        case "code_span" => out.append("`"); out.append(node.literal.replace("`", "\\`")); out.append("`")
        case "code_block" => out.append("```\n"); out.append(node.literal); out.append("\n```\n\n")
        case "thematic_break" => out.append("---\n\n")
        case "block_quote" =>
            out.append("> "); appendEscapedMarkdownText(out, markdownNodeText(node)); out.append("\n\n")
        case "list" => for (child in node.children) {
            appendMarkdownNodeMarkdown(out, child, assetLookup)
        }; out.append("\n")
        case "list_item" =>
            out.append("- "); appendEscapedMarkdownText(out, markdownNodeText(node)); out.append("\n")
        case "link" =>
            out.append("["); for (child in node.children) {
                appendMarkdownNodeMarkdown(out, child, assetLookup)
            }; out.append("]")
            if (safeLinkDestination(node.literal)) { out.append("(${node.literal})") }
        case "image" =>
            let alt = markdownNodeText(node)
            match (assetReference(assetLookup, node.literal)) {
                case Some(path) =>
                    out.append("!["); appendEscapedMarkdownText(out, alt); out.append("](${path})")
                case None => appendEscapedMarkdownText(out, alt)
            }
        case "table" | "table_row" | "table_cell" | "custom_block" | "custom_inline" =>
            appendEscapedMarkdownText(out, markdownNodeText(node)); out.append("\n")
        case "html_block" | "html_inline" => appendEscapedMarkdownText(out, node.literal)
        case _ => appendEscapedMarkdownText(out, markdownNodeText(node))
    }
}

private func appendDocumentationMarkdown(out: StringBuilder, comment: DocComment,
    assetLookup: HashMap<String, String>): Unit {
    appendMarkdownNodeMarkdown(out, comment.markdown, assetLookup)
    var hasParameters = false
    for (tag in comment.tags) { if (tag.name == "param") { hasParameters = true; break } }
    if (hasParameters) {
        out.append("#### Parameters\n\n")
        for (tag in comment.tags) {
            if (tag.name == "param") {
                out.append("- `${tag.subject}` — "); appendEscapedMarkdownText(out, tag.description); out.append("\n")
            }
        }
        out.append("\n")
    }
    for (tag in comment.tags) {
        if (tag.name == "return") {
            out.append("#### Returns\n\n"); appendEscapedMarkdownText(out, tag.description); out.append("\n\n")
        }
    }
    var hasThrows = false
    for (tag in comment.tags) { if (tag.name == "throws") { hasThrows = true; break } }
    if (hasThrows) {
        out.append("#### Throws\n\n")
        for (tag in comment.tags) {
            if (tag.name == "throws") {
                out.append("- `${tag.subject}` — "); appendEscapedMarkdownText(out, tag.description); out.append("\n")
            }
        }
        out.append("\n")
    }
    var hasSee = false
    for (tag in comment.tags) { if (tag.name == "see") { hasSee = true; break } }
    if (hasSee) {
        out.append("#### See also\n\n")
        for (tag in comment.tags) {
            if (tag.name == "see") { out.append("- `${tag.subject}`")
                if (!tag.description.isEmpty()) {
                    out.append(" — "); appendEscapedMarkdownText(out, tag.description)
                }; out.append("\n") }
        }
        out.append("\n")
    }
}

public class MarkdownDocumentationRenderer <: DocumentationRenderer {
    public prop format: String { get() { "markdown" } }

    public func render(documentation: DocumentationSet): Array<RenderArtifact> {
        validateDocumentationSet(documentation)
        let out = StringBuilder()
        let projection = RenderProjection(documentation)
        let assetLookup = buildAssetLookup(documentation)
        out.append("# "); appendEscapedMarkdownText(out, documentation.project.name); out.append("\n\n")
        out.append("Generated by `cjdoc ${documentation.generator.version}` from `${documentation.schemaVersion}`.\n\n")
        out.append("## API\n\n")
        for (declaration in projection.visibleSymbols) {
            out.append("### `${declaration.qualifiedName}`\n\n")
            out.append("```cj\n${declaration.headerSpelling}\n```\n\n")
            match (declaration.documentation) {
                case Some(comment) => appendDocumentationMarkdown(out, comment, assetLookup)
                case None => ()
            }
            out.append("- Kind: `${declaration.kind}`\n")
            out.append("- Visibility: `${declaration.visibility}`\n")
            out.append("- Semantic state: `${declaration.semantic.state}`\n")
            out.append("- Source: `${declaration.source.path}:${declaration.source.start.line}:${declaration.source.start.column}`\n\n")
            if (!declaration.typeRelationships.isEmpty()) {
                out.append("#### Type relationships\n\n")
                for (relationship in declaration.typeRelationships) {
                    out.append("- `${relationship.kind}` → `${relationship.target.spelling}` ")
                    out.append("(`${relationship.target.semantic.state}`)\n")
                }
                out.append("\n")
            }
            if (!declaration.symbolRelationships.isEmpty()) {
                out.append("#### Symbol relationships\n\n")
                for (relationship in declaration.symbolRelationships) {
                    out.append("- `${relationship.kind}` → `${relationship.targetDisplay}` ")
                    out.append("(`${relationship.state}`)\n")
                }
                out.append("\n")
            }
        }
        let artifacts = ArrayList<RenderArtifact>()
        artifacts.add(RenderArtifact("markdown/docs.md", "text/markdown; charset=utf-8", out.toString()))
        appendAssetArtifacts(artifacts, documentation, "markdown")
        artifacts.toArray()
    }
}

private func escapeHtml(value: String): String {
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

internal func assetMediaExtension(mediaType: String): String {
    match (mediaType) {
        case "image/png" => "png"
        case "image/jpeg" => "jpg"
        case "image/gif" => "gif"
        case "image/webp" => "webp"
        case "image/avif" => "avif"
        case _ => throw IllegalArgumentException("unsupported local asset media type '${mediaType}'")
    }
}

private func base64Digit(value: Byte): Int64 {
    if (value >= b'A' && value <= b'Z') { return Int64(value - b'A') }
    if (value >= b'a' && value <= b'z') { return Int64(value - b'a') + 26 }
    if (value >= b'0' && value <= b'9') { return Int64(value - b'0') + 52 }
    if (value == b'+') { return 62 }
    if (value == b'/') { return 63 }
    return -1
}

internal func decodeAssetBase64(value: String): Array<Byte> {
    let encoded = value.toArray()
    if (encoded.isEmpty() || encoded.size % 4 != 0) {
        throw IllegalArgumentException("invalid local asset base64")
    }
    let decoded = ArrayList<Byte>()
    var index: Int64 = 0
    while (index < encoded.size) {
        let last = index + 4 == encoded.size
        let first = base64Digit(encoded[index])
        let second = base64Digit(encoded[index + 1])
        if (first < 0 || second < 0) { throw IllegalArgumentException("invalid local asset base64") }
        let thirdPadding = encoded[index + 2] == b'='
        let fourthPadding = encoded[index + 3] == b'='
        if (thirdPadding) {
            if (!last || !fourthPadding || (second & 15) != 0) {
                throw IllegalArgumentException("invalid local asset base64 padding")
            }
            decoded.add(UInt8((first << 2) | (second >> 4)))
        } else {
            let third = base64Digit(encoded[index + 2])
            if (third < 0) { throw IllegalArgumentException("invalid local asset base64") }
            decoded.add(UInt8((first << 2) | (second >> 4)))
            decoded.add(UInt8(((second & 15) << 4) | (third >> 2)))
            if (fourthPadding) {
                if (!last || (third & 3) != 0) {
                    throw IllegalArgumentException("invalid local asset base64 padding")
                }
            } else {
                let fourth = base64Digit(encoded[index + 3])
                if (fourth < 0) { throw IllegalArgumentException("invalid local asset base64") }
                decoded.add(UInt8(((third & 3) << 6) | fourth))
            }
        }
        index += 4
    }
    decoded.toArray()
}

private func appendStructuredTextHtml(out: StringBuilder, value: String): Unit {
    if (!value.isEmpty()) { out.append("<p>${escapeHtml(value)}</p>\n") }
}

private func appendMarkdownNodeHtml(out: StringBuilder, node: MarkdownNode,
    assetLookup: HashMap<String, String>, rootPrefix: String): Unit {
    match (node.kind) {
        case "document" => for (child in node.children) {
            appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix)
        }
        case "paragraph" =>
            out.append("<p>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix)
            }; out.append("</p>\n")
        case "heading" =>
            out.append("<h3>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix)
            }; out.append("</h3>\n")
        case "text" => out.append(escapeHtml(node.literal))
        case "soft_break" => out.append("\n")
        case "hard_break" => out.append("<br>\n")
        case "emphasis" =>
            out.append("<em>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix)
            }; out.append("</em>")
        case "strong" =>
            out.append("<strong>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix)
            }; out.append("</strong>")
        case "strikethrough" =>
            out.append("<del>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix)
            }; out.append("</del>")
        case "code_span" => out.append("<code>${escapeHtml(node.literal)}</code>")
        case "code_block" => out.append("<pre><code>${escapeHtml(node.literal)}</code></pre>\n")
        case "thematic_break" => out.append("<hr>\n")
        case "block_quote" =>
            out.append("<blockquote>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix)
            }; out.append("</blockquote>\n")
        case "list" =>
            out.append("<ul>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix)
            }; out.append("</ul>\n")
        case "list_item" =>
            out.append("<li>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix)
            }; out.append("</li>")
        case "link" =>
            if (safeLinkDestination(node.literal)) {
                out.append("<a href=\"${escapeHtml(node.literal)}\"")
                if (node.literal.startsWith("http://") || node.literal.startsWith("https://")) {
                    out.append(" rel=\"noopener noreferrer\"")
                }
                out.append(">")
                for (child in node.children) {
                    appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix)
                }
                out.append("</a>")
            } else {
                for (child in node.children) {
                    appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix)
                }
            }
        case "image" =>
            let alt = markdownNodeText(node)
            match (assetReference(assetLookup, node.literal)) {
                case Some(path) => out.append("<img src=\"${rootPrefix}${escapeHtml(path)}\" alt=\"${escapeHtml(alt)}\" loading=\"lazy\">")
                case None => out.append(escapeHtml(alt))
            }
        case "table" =>
            out.append("<table>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix)
            }; out.append("</table>\n")
        case "table_row" =>
            out.append("<tr>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix)
            }; out.append("</tr>")
        case "table_cell" =>
            out.append("<td>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix)
            }; out.append("</td>")
        case "html_block" => out.append("<pre>${escapeHtml(node.literal)}</pre>\n")
        case "html_inline" => out.append(escapeHtml(node.literal))
        case "custom_block" | "custom_inline" => for (child in node.children) {
            appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix)
        }
        case _ => out.append(escapeHtml(markdownNodeText(node)))
    }
}

private let HTML_STYLE = """
:root{color-scheme:light dark;--bg:#fff;--fg:#182026;--muted:#5f6b73;--line:#d8dde3;--panel:#f6f8fa;--link:#0969da}
@media(prefers-color-scheme:dark){:root{--bg:#0d1117;--fg:#e6edf3;--muted:#9da7b1;--line:#30363d;--panel:#161b22;--link:#58a6ff}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.55 system-ui,sans-serif}
main,.site-nav,footer{max-width:76rem;margin:auto;padding:1.25rem}.site-nav{position:relative;display:flex;gap:1rem;align-items:center;flex-wrap:wrap;border-bottom:1px solid var(--line)}
a{color:var(--link)}h1,h2,h3,h4{line-height:1.25}code,pre{font-family:ui-monospace,monospace}pre{padding:1rem;overflow:auto;background:var(--panel);border:1px solid var(--line);border-radius:.4rem}
article,.card{margin:1rem 0;padding:1rem;border:1px solid var(--line);border-radius:.5rem}.meta{color:var(--muted)}.badge{display:inline-block;padding:.1rem .45rem;margin-right:.35rem;background:var(--panel);border:1px solid var(--line);border-radius:999px;font-size:.85rem}
.breadcrumbs{color:var(--muted);font-size:.9rem}.breadcrumbs ol{display:flex;flex-wrap:wrap;gap:.35rem;list-style:none;margin:0 0 1rem;padding:0}.breadcrumbs li+li:before{content:"/";margin-right:.35rem;color:var(--muted)}
dt{font-weight:600;margin-top:.6rem}footer{margin-top:2rem;color:var(--muted);border-top:1px solid var(--line)}
.site-search{margin-left:auto;display:grid;grid-template-columns:minmax(14rem,2fr) minmax(7rem,1fr) minmax(7rem,1fr);gap:.35rem;min-width:min(40rem,80vw)}
.site-search input,.site-search select{width:100%;padding:.45rem .65rem;border:1px solid var(--line);border-radius:.35rem;background:var(--panel);color:var(--fg)}
.search-results{position:absolute;z-index:10;right:1.25rem;top:4.25rem;width:min(40rem,calc(100% - 2.5rem));max-height:24rem;overflow:auto;margin:0;padding:.4rem;list-style:none;background:var(--bg);border:1px solid var(--line);border-radius:.4rem;box-shadow:0 .5rem 1.5rem #0003}
.search-results:empty{display:none}.search-results a{display:block;padding:.45rem .55rem;text-decoration:none}.search-results a:hover,.search-results a:focus,.search-results [aria-selected=true] a{background:var(--panel)}.search-kind{color:var(--muted);font-size:.85rem}
.declaration-list{display:grid;gap:.75rem}.summary>p:first-child,.description>p:first-child{margin-top:0}
@media(max-width:48rem){.site-search{margin-left:0;min-width:100%;grid-template-columns:1fr 1fr}.site-search input{grid-column:1/-1}.search-results{top:7.5rem}}
"""

private let HTML_SEARCH_SCRIPT = """
(() => {
  const input = document.querySelector("[data-cjdoc-search]");
  const results = document.querySelector("[data-cjdoc-results]");
  if (!input || !results) return;
  const root = input.dataset.root || "";
  const kindFilter = document.querySelector("[data-cjdoc-kind]");
  const packageFilter = document.querySelector("[data-cjdoc-package]");
  let entries = [];
  let visible = [];
  let selected = -1;
  const rank = (entry, query) => {
    const name = entry.name.toLocaleLowerCase();
    const qualified = entry.qualifiedName.toLocaleLowerCase();
    if (name === query) return 0;
    if (qualified === query) return 1;
    if (name.startsWith(query)) return 2;
    if (qualified.startsWith(query)) return 3;
    const haystack = (entry.qualifiedName + " " + entry.kind + " " + entry.packageName + " " + entry.summary).toLocaleLowerCase();
    return query.split(/\\s+/).filter(Boolean).every((token) => haystack.includes(token)) ? 4 : -1;
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
    visible = [];
    selected = -1;
    input.removeAttribute("aria-activedescendant");
    const query = input.value.trim().toLocaleLowerCase();
    if (!query) { input.setAttribute("aria-expanded", "false"); return; }
    const selectedKind = kindFilter ? kindFilter.value : "";
    const selectedPackage = packageFilter ? packageFilter.value : "";
    visible = entries.map((entry) => ({entry, rank: rank(entry, query)}))
      .filter((item) => item.rank >= 0 && (!selectedKind || item.entry.kind === selectedKind) &&
        (!selectedPackage || item.entry.packageName === selectedPackage))
      .sort((left, right) => left.rank - right.rank ||
        left.entry.qualifiedName.localeCompare(right.entry.qualifiedName) || left.entry.id.localeCompare(right.entry.id))
      .slice(0, 20).map((item) => item.entry);
    for (const entry of visible) {
      const item = document.createElement("li");
      const link = document.createElement("a");
      const name = document.createElement("span");
      const kind = document.createElement("span");
      item.id = "cjdoc-search-result-" + results.children.length;
      item.setAttribute("role", "option");
      item.setAttribute("aria-selected", "false");
      link.href = root + entry.href;
      name.textContent = entry.qualifiedName;
      kind.className = "search-kind";
      kind.textContent = " — " + entry.kind;
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
  const index = globalThis.__CJDOC_SEARCH_INDEX__;
  entries = index && index.schemaVersion === "cjdoc.search-index/3" && Array.isArray(index.entries)
    ? index.entries : [];
  addOptions(kindFilter, entries.map((entry) => entry.kind));
  addOptions(packageFilter, entries.map((entry) => entry.packageName));
  render();
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

private func appendSlugByte(out: StringBuilder, byte: Byte): Unit {
    let digits = "0123456789abcdef"
    let high = Int64((byte >> 4) & 0x0F)
    let low = Int64(byte & 0x0F)
    out.append(digits[high..high + 1])
    out.append(digits[low..low + 1])
}

private func htmlStableSlug(value: String): String {
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

private func boundedHtmlSlug(value: String): String {
    let slug = htmlStableSlug(value)
    if (slug.size <= 160) { return slug }
    slug[..120] + "--" + stableFileHash(value)
}

private func routeKey(moduleId: String, packageName: String): String {
    "${moduleId.size}:${moduleId}${packageName}"
}

private func packagePagePath(moduleId: String, name: String): String {
    "packages/package-${boundedHtmlSlug(routeKey(moduleId, name))}.html"
}

private func symbolPagePath(symbol: SymbolDoc): String {
    "symbols/symbol-${boundedHtmlSlug(symbol.id)}.html"
}

private func symbolAnchor(symbol: SymbolDoc): String {
    "symbol-${htmlStableSlug(symbol.id)}"
}

private func assetOutputPath(asset: AssetDoc): String {
    "assets/asset-${boundedHtmlSlug(asset.id)}.${assetMediaExtension(asset.mediaType)}"
}

private func isContainerDeclaration(symbol: SymbolDoc): Bool {
    symbol.kind == "class" || symbol.kind == "struct" || symbol.kind == "interface" ||
        symbol.kind == "enum" || symbol.kind == "extend"
}

private func indexSymbols(documentation: DocumentationSet): HashMap<String, SymbolDoc> {
    let index = HashMap<String, SymbolDoc>()
    for (symbol in documentation.declarations) { index[symbol.id] = symbol }
    index
}

private class ProjectedPackage {
    let source: PackageDoc
    let sourceFiles = ArrayList<String>()
    let symbols = ArrayList<SymbolDoc>()

    init(source: PackageDoc) { this.source = source }
}

private class ProjectedModule {
    let source: ModuleDoc
    let packages = ArrayList<ProjectedPackage>()

    init(source: ModuleDoc) { this.source = source }
}

private class RenderProjection {
    let allIndex: HashMap<String, SymbolDoc>
    let visibleIndex = HashMap<String, SymbolDoc>()
    let visibleSymbols = ArrayList<SymbolDoc>()
    let packages = ArrayList<ProjectedPackage>()
    let modules = ArrayList<ProjectedModule>()

    init(documentation: DocumentationSet) {
        allIndex = indexSymbols(documentation)
        for (symbol in documentation.declarations) {
            if (isRenderable(documentation, allIndex, symbol)) {
                visibleSymbols.add(symbol)
                visibleIndex[symbol.id] = symbol
            }
        }
        for (pkg in documentation.packages) {
            let projected = ProjectedPackage(pkg)
            let files = HashSet<String>()
            for (symbol in visibleSymbols) {
                if (symbol.moduleId != pkg.moduleId || symbol.packageName != pkg.name) { continue }
                projected.symbols.add(symbol)
                if (files.add(symbol.source.path)) { projected.sourceFiles.add(symbol.source.path) }
            }
            if (!projected.symbols.isEmpty()) {
                sort(projected.sourceFiles)
                packages.add(projected)
            }
        }
        for (module in documentation.modules) {
            let projected = ProjectedModule(module)
            for (pkg in packages) {
                if (pkg.source.moduleId == module.id) { projected.packages.add(pkg) }
            }
            if (!projected.packages.isEmpty()) { modules.add(projected) }
        }
    }
}

private func groupTopLevelByPackage(projection: RenderProjection):
    HashMap<String, ArrayList<SymbolDoc>> {
    let groups = HashMap<String, ArrayList<SymbolDoc>>()
    for (symbol in projection.visibleSymbols where symbol.ownerId.isNone()) {
        let key = routeKey(symbol.moduleId, symbol.packageName)
        match (groups.get(key)) {
            case Some(values) => values.add(symbol)
            case None => groups[key] = ArrayList<SymbolDoc>([symbol])
        }
    }
    groups
}

private func groupMembersByOwner(projection: RenderProjection):
    HashMap<String, ArrayList<SymbolDoc>> {
    let groups = HashMap<String, ArrayList<SymbolDoc>>()
    for (symbol in projection.visibleSymbols) {
        match (symbol.ownerId) {
            case Some(ownerId) => match (groups.get(ownerId)) {
                case Some(values) => values.add(symbol)
                case None => groups[ownerId] = ArrayList<SymbolDoc>([symbol])
            }
            case None => ()
        }
    }
    groups
}

private func findSymbol(index: HashMap<String, SymbolDoc>, id: String): ?SymbolDoc {
    index.get(id)
}

private func isRenderable(documentation: DocumentationSet,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc): Bool {
    if (!isVisibleForAudience(symbol, documentation.configuration.audience)) { return false }
    var current = symbol
    var remaining = documentation.declarations.size + 1
    while (remaining > 0) {
        match (current.ownerId) {
            case Some(ownerId) =>
                match (findSymbol(index, ownerId)) {
                    case Some(owner) =>
                        if (!isVisibleForAudience(owner, documentation.configuration.audience)) { return false }
                        current = owner
                    case None => return true
                }
            case None => return true
        }
        remaining--
    }
    false
}

private func containingPageSymbol(documentation: DocumentationSet,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc): ?SymbolDoc {
    if (isContainerDeclaration(symbol)) { return Some(symbol) }
    var current = symbol
    var remaining = documentation.declarations.size + 1
    while (remaining > 0) {
        match (current.ownerId) {
            case Some(ownerId) =>
                match (findSymbol(index, ownerId)) {
                    case Some(owner) =>
                        if (isContainerDeclaration(owner)) { return Some(owner) }
                        current = owner
                    case None => return None
                }
            case None => return None
        }
        remaining--
    }
    None
}

private func symbolUrl(documentation: DocumentationSet, index: HashMap<String, SymbolDoc>,
    symbol: SymbolDoc): String {
    match (containingPageSymbol(documentation, index, symbol)) {
        case Some(container) =>
            let page = symbolPagePath(container)
            if (container.id == symbol.id) { page } else { page + "#" + symbolAnchor(symbol) }
        case None => packagePagePath(symbol.moduleId, symbol.packageName) + "#" + symbolAnchor(symbol)
    }
}

private func buildAssetLookup(documentation: DocumentationSet): HashMap<String, String> {
    let lookup = HashMap<String, String>()
    for (asset in documentation.assets) {
        let path = assetOutputPath(asset)
        lookup["id:${asset.id}"] = path
        lookup["path:${asset.sourcePath}"] = path
    }
    lookup
}

private func appendAssetArtifacts(artifacts: ArrayList<RenderArtifact>,
    documentation: DocumentationSet, formatRoot: String): Unit {
    for (asset in documentation.assets) {
        artifacts.add(RenderArtifact("${formatRoot}/${assetOutputPath(asset)}",
            asset.mediaType, decodeAssetBase64(asset.base64)))
    }
}

private func validateHtmlRouting(documentation: DocumentationSet,
    projection: RenderProjection): Unit {
    let paths = HashSet<String>()
    for (path in ["index.html", "search-index.json", "search-index.js", "search.js", "style.css"]) {
        let _ = paths.add(path)
    }
    for (pkg in projection.packages) {
        let path = packagePagePath(pkg.source.moduleId, pkg.source.name)
        if (!paths.add(path)) {
            throw IllegalArgumentException("HTML route collision for package '${pkg.source.name}'")
        }
    }
    for (symbol in projection.visibleSymbols where isContainerDeclaration(symbol)) {
        let path = symbolPagePath(symbol)
        if (!paths.add(path)) {
            throw IllegalArgumentException("HTML route collision for SymbolId '${symbol.id}'")
        }
    }
    for (asset in documentation.assets) {
        let path = assetOutputPath(asset)
        if (!paths.add(path)) {
            throw IllegalArgumentException("HTML route collision for asset '${asset.id}'")
        }
    }
    let urls = HashSet<String>()
    for (symbol in projection.visibleSymbols) {
        let url = symbolUrl(documentation, projection.visibleIndex, symbol)
        if (!urls.add(url)) {
            throw IllegalArgumentException("non-injective HTML URL for SymbolId '${symbol.id}'")
        }
    }
}

private func appendPageStart(out: StringBuilder, title: String, rootPrefix: String): Unit {
    out.append("<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">")
    out.append("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
    out.append("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'\">")
    out.append("<title>${escapeHtml(title)}</title><link rel=\"stylesheet\" href=\"${rootPrefix}style.css\">")
    out.append("<script defer src=\"${rootPrefix}search-index.js\"></script>")
    out.append("<script defer src=\"${rootPrefix}search.js\"></script></head><body>\n")
    out.append("<nav class=\"site-nav\"><a href=\"${rootPrefix}index.html\">cjdoc</a>")
    out.append("<div class=\"site-search\"><label><span hidden>Search API</span>")
    out.append("<input type=\"search\" placeholder=\"Search API (Ctrl+K)\" autocomplete=\"off\" role=\"combobox\" aria-autocomplete=\"list\" aria-controls=\"cjdoc-search-results\" aria-expanded=\"false\" data-cjdoc-search data-root=\"${rootPrefix}\"></label>")
    out.append("<label><span hidden>Filter by kind</span><select data-cjdoc-kind><option value=\"\">All kinds</option></select></label>")
    out.append("<label><span hidden>Filter by package</span><select data-cjdoc-package><option value=\"\">All packages</option></select></label></div>")
    out.append("<ul id=\"cjdoc-search-results\" class=\"search-results\" role=\"listbox\" data-cjdoc-results aria-live=\"polite\"></ul></nav>\n<main>\n")
}

private func appendPageEnd(out: StringBuilder, documentation: DocumentationSet): Unit {
    out.append("</main><footer>Generated by cjdoc ${escapeHtml(documentation.generator.version)} from ${escapeHtml(documentation.schemaVersion)}.</footer></body></html>\n")
}

private func findTag(comment: DocComment, name: String, subject!: ?String = None): ?DocTag {
    for (tag in comment.tags) {
        if (tag.name == name && (subject.isNone() || tag.subject == subject.getOrThrow())) { return Some(tag) }
    }
    None
}

private func tagHeading(name: String): String {
    match (name) {
        case "since" => "Since"
        case "author" => "Authors"
        case "version" => "Version"
        case _ => name
    }
}

private func appendDocumentationHtml(out: StringBuilder, documentation: DocumentationSet,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String,
    assetLookup: HashMap<String, String>): Unit {
    match (symbol.documentation) {
        case Some(comment) =>
            match (findTag(comment, "deprecated")) {
                case Some(tag) =>
                    out.append("<aside class=\"card\"><strong>Deprecated.</strong> ")
                    appendStructuredTextHtml(out, tag.description)
                    out.append("</aside>\n")
                case None => ()
            }
            out.append("<div class=\"description\">")
            appendMarkdownNodeHtml(out, comment.markdown, assetLookup, rootPrefix)
            out.append("</div>\n")
            if (!symbol.parameters.isEmpty()) {
                out.append("<h3>Parameters</h3><dl>\n")
                for (parameter in symbol.parameters) {
                    out.append("<dt><code>${escapeHtml(parameter.name)}</code>: <code>${escapeHtml(parameter.typeRef.spelling)}</code></dt><dd>")
                    match (parameter.documentation) {
                        case Some(value) => appendStructuredTextHtml(out, value)
                        case None => match (findTag(comment, "param", subject: Some(parameter.name))) {
                            case Some(tag) => appendStructuredTextHtml(out, tag.description)
                            case None => ()
                        }
                    }
                    out.append("</dd>\n")
                }
                out.append("</dl>\n")
            }
            match (symbol.returnType) {
                case Some(returnType) =>
                    out.append("<h3>Returns</h3><p><code>${escapeHtml(returnType.spelling)}</code></p>\n")
                    match (findTag(comment, "return")) {
                        case Some(tag) => appendStructuredTextHtml(out, tag.description)
                        case None => ()
                    }
                case None => ()
            }
            var hasThrows = false
            for (tag in comment.tags) { if (tag.name == "throws") { hasThrows = true; break } }
            if (hasThrows) {
                out.append("<h3>Throws</h3><dl>\n")
                for (tag in comment.tags) {
                    if (tag.name == "throws") {
                        out.append("<dt><code>${escapeHtml(tag.subject)}</code></dt><dd>")
                        appendStructuredTextHtml(out, tag.description)
                        out.append("</dd>\n")
                    }
                }
                out.append("</dl>\n")
            }
            var hasSee = false
            for (tag in comment.tags) { if (tag.name == "see") { hasSee = true; break } }
            if (hasSee) {
                out.append("<h3>See also</h3><ul>\n")
                for (tag in comment.tags) {
                    if (tag.name != "see") { continue }
                    out.append("<li>")
                    match (tag.targetSymbolId) {
                        case Some(targetId) => match (findSymbol(index, targetId)) {
                            case Some(target) =>
                                out.append("<a href=\"${rootPrefix}${escapeHtml(symbolUrl(documentation, index, target))}\"><code>${escapeHtml(tag.subject)}</code></a>")
                            case None => out.append("<code>${escapeHtml(tag.subject)}</code>")
                        }
                        case None => out.append("<code>${escapeHtml(tag.subject)}</code>")
                    }
                    if (!tag.description.isEmpty()) {
                        out.append(" "); appendStructuredTextHtml(out, tag.description)
                    }
                    out.append("</li>\n")
                }
                out.append("</ul>\n")
            }
            for (name in ["since", "author", "version"]) {
                var opened = false
                for (tag in comment.tags) {
                    if (tag.name != name) { continue }
                    if (!opened) { out.append("<h3>${escapeHtml(tagHeading(name))}</h3><ul>\n"); opened = true }
                    out.append("<li>"); appendStructuredTextHtml(out, tag.description); out.append("</li>\n")
                }
                if (opened) { out.append("</ul>\n") }
            }
        case None =>
            if (!symbol.parameters.isEmpty()) {
                out.append("<h3>Parameters</h3><dl>\n")
                for (parameter in symbol.parameters) {
                    out.append("<dt><code>${escapeHtml(parameter.name)}</code>: <code>${escapeHtml(parameter.typeRef.spelling)}</code></dt><dd></dd>\n")
                }
                out.append("</dl>\n")
            }
            match (symbol.returnType) {
                case Some(returnType) => out.append("<h3>Returns</h3><p><code>${escapeHtml(returnType.spelling)}</code></p>\n")
                case None => ()
            }
    }
}

private func appendSymbolMetadata(out: StringBuilder, documentation: DocumentationSet,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String): Unit {
    out.append("<p class=\"meta\"><span class=\"badge\">${escapeHtml(symbol.kind)}</span>")
    out.append("<span class=\"badge\">${escapeHtml(symbol.visibility)}</span>")
    out.append("<span class=\"badge\">semantic: ${escapeHtml(symbol.semantic.state)}</span>")
    match (symbol.ownerId) {
        case Some(ownerId) => match (findSymbol(index, ownerId)) {
            case Some(owner) => out.append(" Owner: <a href=\"${rootPrefix}${escapeHtml(symbolUrl(documentation, index, owner))}\"><code>${escapeHtml(owner.qualifiedName)}</code></a> ·")
            case None => out.append(" Owner: <code>${escapeHtml(ownerId)}</code> ·")
        }
        case None => ()
    }
    out.append(" <code>${escapeHtml(symbol.source.path)}:${symbol.source.start.line}:${symbol.source.start.column}</code></p>\n")
    if (!symbol.genericParameters.isEmpty()) {
        out.append("<p class=\"meta\">Generic parameters: ")
        var first = true
        for (parameter in symbol.genericParameters) {
            if (!first) { out.append(", ") }; first = false
            out.append("<code>${escapeHtml(parameter)}</code>")
        }
        out.append("</p>\n")
    }
    if (!symbol.annotations.isEmpty()) {
        out.append("<p class=\"meta\">Annotations: ")
        var first = true
        for (annotation in symbol.annotations) {
            if (!first) { out.append(" ") }; first = false
            out.append("<code>${escapeHtml(annotation.spelling)}</code>")
        }
        out.append("</p>\n")
    }
    if (!symbol.typeRelationships.isEmpty() || !symbol.symbolRelationships.isEmpty()) {
        out.append("<dl class=\"relationships\">")
        for (relationship in symbol.typeRelationships) {
            out.append("<dt>${escapeHtml(relationship.kind)}</dt><dd><code>${escapeHtml(relationship.target.spelling)}</code> <span class=\"badge\">${escapeHtml(relationship.target.semantic.state)}</span></dd>")
        }
        for (relationship in symbol.symbolRelationships) {
            out.append("<dt>${escapeHtml(relationship.kind)}</dt><dd>")
            match (relationship.targetSymbolId) {
                case Some(targetId) => match (findSymbol(index, targetId)) {
                    case Some(target) =>
                        out.append("<a href=\"${rootPrefix}${escapeHtml(symbolUrl(documentation, index, target))}\"><code>${escapeHtml(relationship.targetDisplay)}</code></a>")
                    case None => out.append("<code>${escapeHtml(relationship.targetDisplay)}</code>")
                }
                case None => out.append("<code>${escapeHtml(relationship.targetDisplay)}</code>")
            }
            out.append(" <span class=\"badge\">${escapeHtml(relationship.state)}</span></dd>")
        }
        out.append("</dl>\n")
    }
    out.append("<pre><code>${escapeHtml(symbol.headerSpelling)}</code></pre>\n")
}

private func appendSymbolArticle(out: StringBuilder, documentation: DocumentationSet,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String,
    assetLookup: HashMap<String, String>, linkTitle!: Bool = false): Unit {
    out.append("<article id=\"${symbolAnchor(symbol)}\"><h2>")
    if (linkTitle) {
        out.append("<a href=\"${rootPrefix}${escapeHtml(symbolUrl(documentation, index, symbol))}\"><code>${escapeHtml(symbol.qualifiedName)}</code></a>")
    } else { out.append("<code>${escapeHtml(symbol.qualifiedName)}</code>") }
    out.append("</h2>\n")
    appendSymbolMetadata(out, documentation, index, symbol, rootPrefix)
    appendDocumentationHtml(out, documentation, index, symbol, rootPrefix, assetLookup)
    out.append("</article>\n")
}

private func renderHtmlIndex(documentation: DocumentationSet, projection: RenderProjection): String {
    let out = StringBuilder()
    appendPageStart(out, "${documentation.project.name} API documentation", "")
    out.append("<h1>${escapeHtml(documentation.project.name)} API documentation</h1>\n")
    out.append("<p class=\"meta\">${projection.modules.size} modules, ${projection.packages.size} packages, ${projection.visibleSymbols.size} visible declarations</p>\n")
    if (!projection.modules.isEmpty()) {
        out.append("<h2>Modules</h2><div class=\"declaration-list\">\n")
        for (projected in projection.modules) {
            let module = projected.source
            out.append("<section class=\"card\"><h3><code>${escapeHtml(module.name)}</code> <span class=\"badge\">${escapeHtml(module.role)}</span></h3>")
            let prefix = if (module.sourcePrefix.isEmpty()) { "." } else { module.sourcePrefix }
            out.append("<p class=\"meta\">Source prefix: <code>${escapeHtml(prefix)}</code></p><ul>\n")
            for (pkg in projected.packages) {
                out.append("<li><a href=\"${escapeHtml(packagePagePath(module.id, pkg.source.name))}\"><code>${escapeHtml(pkg.source.name)}</code></a></li>\n")
            }
            out.append("</ul></section>\n")
        }
        out.append("</div>\n")
    }
    out.append("<h2>Packages</h2><ul>\n")
    for (pkg in projection.packages) {
        out.append("<li><a href=\"${escapeHtml(packagePagePath(pkg.source.moduleId, pkg.source.name))}\"><code>${escapeHtml(pkg.source.name)}</code></a></li>\n")
    }
    out.append("</ul>\n")
    if (!documentation.diagnostics.isEmpty()) {
        out.append("<h2>Diagnostics</h2><ul>\n")
        for (diagnostic in documentation.diagnostics) {
            if (let Some(symbolId) <- diagnostic.symbolId) {
                if (!projection.visibleIndex.contains(symbolId)) { continue }
            }
            out.append("<li><strong>${escapeHtml(diagnostic.severity)}[${escapeHtml(diagnostic.code)}]</strong>: ${escapeHtml(diagnostic.message)}")
            match (diagnostic.source) {
                case Some(source) => out.append(" <code>${escapeHtml(source.path)}:${source.start.line}:${source.start.column}</code>")
                case None => ()
            }
            out.append("</li>\n")
        }
        out.append("</ul>\n")
    }
    appendPageEnd(out, documentation)
    out.toString()
}

private func renderPackagePage(documentation: DocumentationSet,
    index: HashMap<String, SymbolDoc>, topLevelByPackage: HashMap<String, ArrayList<SymbolDoc>>,
    pkg: ProjectedPackage, assetLookup: HashMap<String, String>): String {
    let packageDoc = pkg.source
    let out = StringBuilder()
    appendPageStart(out, "Package ${packageDoc.name}", "../")
    out.append("<nav class=\"breadcrumbs\" aria-label=\"Breadcrumb\"><ol><li><a href=\"../index.html\">Home</a></li><li aria-current=\"page\">Package <code>${escapeHtml(packageDoc.name)}</code></li></ol></nav>\n")
    out.append("<h1>Package <code>${escapeHtml(packageDoc.name)}</code></h1>\n")
    if (!pkg.sourceFiles.isEmpty()) {
        out.append("<h2>Sources</h2><ul>\n")
        for (path in pkg.sourceFiles) { out.append("<li><code>${escapeHtml(path)}</code></li>\n") }
        out.append("</ul>\n")
    }
    out.append("<h2>Declarations</h2>\n")
    var wroteDeclaration = false
    match (topLevelByPackage.get(routeKey(packageDoc.moduleId, packageDoc.name))) {
        case Some(symbols) => for (symbol in symbols) {
            wroteDeclaration = true
            if (isContainerDeclaration(symbol)) {
                out.append("<section class=\"card\"><h3><a href=\"../${escapeHtml(symbolPagePath(symbol))}\"><code>${escapeHtml(symbol.qualifiedName)}</code></a> <span class=\"badge\">${escapeHtml(symbol.kind)}</span></h3>")
                match (symbol.documentation) {
                    case Some(comment) => out.append("<p>${escapeHtml(markdownNodeText(comment.markdown))}</p>")
                    case None => ()
                }
                out.append("</section>\n")
            } else {
                appendSymbolArticle(out, documentation, index, symbol, "../", assetLookup)
            }
        }
        case None => ()
    }
    if (!wroteDeclaration) { out.append("<p>No declarations are visible for this audience.</p>\n") }
    appendPageEnd(out, documentation)
    out.toString()
}

private func memberSectionTitle(symbol: SymbolDoc): String {
    match (symbol.kind) {
        case "constructor" => "Constructors"
        case "property" => "Properties"
        case "variable" => "Variables"
        case "function" => "Functions"
        case "enumCase" => "Enum cases"
        case "class" => "Nested classes"
        case "struct" => "Nested structs"
        case "interface" => "Nested interfaces"
        case "enum" => "Nested enums"
        case "extend" => "Nested extensions"
        case _ => "Other members"
    }
}

private func appendMemberSection(out: StringBuilder, documentation: DocumentationSet,
    index: HashMap<String, SymbolDoc>, membersByOwner: HashMap<String, ArrayList<SymbolDoc>>,
    owner: SymbolDoc, title: String, assetLookup: HashMap<String, String>): Unit {
    var opened = false
    match (membersByOwner.get(owner.id)) {
        case Some(members) => for (member in members) {
            if (memberSectionTitle(member) != title) { continue }
            if (!opened) { out.append("<h2>${escapeHtml(title)}</h2>\n"); opened = true }
            appendSymbolArticle(out, documentation, index, member, "../", assetLookup,
                linkTitle: isContainerDeclaration(member))
        }
        case None => ()
    }
}

private func renderSymbolPage(documentation: DocumentationSet,
    index: HashMap<String, SymbolDoc>, membersByOwner: HashMap<String, ArrayList<SymbolDoc>>,
    symbol: SymbolDoc, assetLookup: HashMap<String, String>): String {
    let out = StringBuilder()
    appendPageStart(out, symbol.qualifiedName, "../")
    out.append("<nav class=\"breadcrumbs\" aria-label=\"Breadcrumb\"><ol><li><a href=\"../index.html\">Home</a></li>")
    out.append("<li><a href=\"../${escapeHtml(packagePagePath(symbol.moduleId, symbol.packageName))}\">Package <code>${escapeHtml(symbol.packageName)}</code></a></li>")
    out.append("<li aria-current=\"page\"><code>${escapeHtml(symbol.name)}</code></li></ol></nav>\n")
    out.append("<h1><code>${escapeHtml(symbol.qualifiedName)}</code></h1>\n")
    appendSymbolMetadata(out, documentation, index, symbol, "../")
    appendDocumentationHtml(out, documentation, index, symbol, "../", assetLookup)
    for (title in ["Constructors", "Properties", "Variables", "Functions", "Enum cases",
        "Nested classes", "Nested structs", "Nested interfaces", "Nested enums", "Nested extensions",
        "Other members"]) {
        appendMemberSection(out, documentation, index, membersByOwner, symbol, title, assetLookup)
    }
    appendPageEnd(out, documentation)
    out.toString()
}

private func renderSearchIndex(documentation: DocumentationSet,
    projection: RenderProjection): String {
    let out = StringBuilder()
    out.append("{\n  \"schemaVersion\": \"cjdoc.search-index/3\",\n  \"entries\": [")
    var first = true
    let visible = ArrayList<SymbolDoc>(projection.visibleSymbols.toArray())
    sort(visible, lessThan: { left, right => left.id < right.id }, stable: true)
    for (declaration in visible) {
        if (!first) { out.append(",") }
        first = false
        out.append("\n    {\"id\": ${escapeJsonString(declaration.id)}, \"name\": ${escapeJsonString(declaration.name)}, ")
        out.append("\"qualifiedName\": ${escapeJsonString(declaration.qualifiedName)}, ")
        out.append("\"kind\": ${escapeJsonString(declaration.kind)}, \"packageName\": ${escapeJsonString(declaration.packageName)}, ")
        let summary = match (declaration.documentation) {
            case Some(comment) => markdownNodeText(comment.markdown)
            case None => ""
        }
        out.append("\"summary\": ${escapeJsonString(summary)}, \"href\": ${escapeJsonString(symbolUrl(documentation, projection.visibleIndex, declaration))}}")
    }
    if (!first) { out.append("\n  ") }
    out.append("]\n}\n")
    out.toString()
}

private func renderSearchIndexScript(searchIndex: String): String {
    "globalThis.__CJDOC_SEARCH_INDEX__ = ${searchIndex.trimAscii()};\n"
}

public class HtmlDocumentationRenderer <: DocumentationRenderer {
    public prop format: String { get() { "html" } }

    public func render(documentation: DocumentationSet): Array<RenderArtifact> {
        validateDocumentationSet(documentation)
        let artifacts = ArrayList<RenderArtifact>()
        let projection = RenderProjection(documentation)
        let index = projection.visibleIndex
        let assetLookup = buildAssetLookup(documentation)
        validateHtmlRouting(documentation, projection)
        let topLevelByPackage = groupTopLevelByPackage(projection)
        let membersByOwner = groupMembersByOwner(projection)
        let searchIndex = renderSearchIndex(documentation, projection)
        artifacts.add(RenderArtifact("html/index.html", "text/html; charset=utf-8",
            renderHtmlIndex(documentation, projection)))
        artifacts.add(RenderArtifact("html/search-index.json", "application/json", searchIndex))
        artifacts.add(RenderArtifact("html/search-index.js", "text/javascript; charset=utf-8",
            renderSearchIndexScript(searchIndex)))
        artifacts.add(RenderArtifact("html/search.js", "text/javascript; charset=utf-8", HTML_SEARCH_SCRIPT))
        artifacts.add(RenderArtifact("html/style.css", "text/css; charset=utf-8", HTML_STYLE))
        for (pkg in projection.packages) {
            artifacts.add(RenderArtifact("html/${packagePagePath(pkg.source.moduleId, pkg.source.name)}",
                "text/html; charset=utf-8",
                renderPackagePage(documentation, index, topLevelByPackage, pkg, assetLookup)))
        }
        for (symbol in projection.visibleSymbols) {
            if (isContainerDeclaration(symbol)) {
                artifacts.add(RenderArtifact("html/${symbolPagePath(symbol)}", "text/html; charset=utf-8",
                    renderSymbolPage(documentation, index, membersByOwner, symbol, assetLookup)))
            }
        }
        appendAssetArtifacts(artifacts, documentation, "html")
        artifacts.toArray()
    }
}

public func rendererFor(format: String): DocumentationRenderer {
    match (format) {
        case "json" => JsonDocumentationRenderer()
        case "markdown" => MarkdownDocumentationRenderer()
        case "html" => HtmlDocumentationRenderer()
        case _ => throw IllegalArgumentException("unsupported documentation format '${format}'")
    }
}
