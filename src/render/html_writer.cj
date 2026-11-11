package cjdoc.render

import std.collection.*

/**
 * A link destination that passed one of the renderer's URL safety checks.
 *
 * `href` and `src` attributes only accept this type, so an unchecked author or
 * provider string can never reach a navigable attribute.
 */
internal struct SafeUrl {
    let value: String

    private init(value: String) { this.value = value }

    /** Absolute `http(s)`/`mailto` destinations and same-document fragments. */
    static func external(value: String): ?SafeUrl {
        if (safeLinkDestination(value)) { Some(SafeUrl(value)) } else { None }
    }

    /** Plain relative file paths without traversal, query, or fragment. */
    static func relative(value: String): ?SafeUrl {
        if (safeRelativeLinkDestination(value)) { Some(SafeUrl(value)) } else { None }
    }

    /**
     * Generated site routes: `("../")*` + a safe relative path, optionally
     * followed by `?query` and `#fragment`. Root prefixes are the only allowed
     * parent traversal, and only as a leading run.
     */
    static func site(value: String): ?SafeUrl {
        var rest = value
        while (rest.startsWith("../")) { rest = rest["../".size..] }
        var fragment = ""
        let fragmentParts = rest.split("#", 2)
        if (fragmentParts.size == 2) {
            rest = fragmentParts[0]
            fragment = fragmentParts[1]
            if (!safeUrlComponent(fragment, allowEmpty: false)) { return None }
        }
        let queryParts = rest.split("?", 2)
        if (queryParts.size == 2) {
            rest = queryParts[0]
            if (!safeUrlComponent(queryParts[1], allowEmpty: false)) { return None }
        }
        if (!safeSitePath(rest)) { return None }
        Some(SafeUrl(value))
    }

    /** Generated site route that must be valid by construction. */
    static func siteRoute(value: String): SafeUrl {
        match (SafeUrl.site(value)) {
            case Some(url) => url
            case None => throw IllegalArgumentException("unsafe generated site route")
        }
    }

    /** Same-document fragment for a generated anchor id. */
    static func fragment(id: String): SafeUrl {
        if (!safeUrlComponent(id, allowEmpty: false)) {
            throw IllegalArgumentException("unsafe generated fragment")
        }
        SafeUrl("#" + id)
    }
}

private func safeUrlComponent(value: String, allowEmpty!: Bool): Bool {
    if (value.isEmpty()) { return allowEmpty }
    for (byte in value.toArray()) {
        if (byte <= 0x20 || byte == 0x7F || byte == b'"' || byte == b'\'' || byte == b'<' ||
            byte == b'>' || byte == b'\\' || byte == b'`' || byte == b'#') {
            return false
        }
    }
    true
}

// A relative site path: no scheme, root, backslash, query/fragment delimiter,
// whitespace or markup byte, and no `..` segment (percent-encoded dots
// included). Consecutive dots inside a file name are an ordinary name.
private func safeSitePath(value: String): Bool {
    if (value.isEmpty() || value.startsWith("/") || value.contains(":") ||
        !safeUrlComponent(value, allowEmpty: false) || value.contains("?")) { return false }
    for (segment in value.split("/")) {
        if (segment.replace("%2e", ".").replace("%2E", ".") == "..") { return false }
    }
    true
}

/** One HTML attribute; construct through the `html*` helpers below. */
internal enum HtmlAttr {
    | TextValue(String, String)
    | UrlValue(String, SafeUrl)
    | Flag(String)

    prop name: String {
        get() {
            match (this) {
                case TextValue(attributeName, _) => attributeName
                case UrlValue(attributeName, _) => attributeName
                case Flag(attributeName) => attributeName
            }
        }
    }
}

internal func htmlAttr(name: String, value: String): HtmlAttr { HtmlAttr.TextValue(name, value) }

internal func htmlFlag(name: String): HtmlAttr { HtmlAttr.Flag(name) }

internal func htmlClass(value: String): HtmlAttr { HtmlAttr.TextValue("class", value) }

internal func htmlHref(url: SafeUrl): HtmlAttr { HtmlAttr.UrlValue("href", url) }

internal func htmlSrc(url: SafeUrl): HtmlAttr { HtmlAttr.UrlValue("src", url) }

/**
 * An HTML fragment produced by a balanced `HtmlWriter`. It cannot be built from
 * a plain string, so splicing it never reintroduces unescaped author text.
 */
internal struct TrustedHtml {
    let value: String

    private init(value: String) { this.value = value }

    static func capture(body: (HtmlWriter) -> Unit): TrustedHtml {
        let writer = HtmlWriter()
        body(writer)
        TrustedHtml(writer.toString())
    }
}

private let HTML_VOID_ELEMENTS: Array<String> = ["area", "base", "br", "col", "hr", "img",
    "input", "link", "meta", "source", "track", "wbr"]

// Navigable or document-replacing attributes must carry a SafeUrl.
private let HTML_URL_ATTRIBUTES: Array<String> = ["href", "src", "srcset", "action",
    "formaction", "poster", "cite", "data"]

private let HTML_FORBIDDEN_ATTRIBUTES: Array<String> = ["style", "srcdoc"]

private let HTML_FORBIDDEN_ELEMENTS: Array<String> = ["style", "iframe", "object", "embed",
    "frame", "frameset", "base", "form"]

private func htmlLowerAlphanumeric(byte: Byte): Bool {
    (byte >= b'a' && byte <= b'z') || (byte >= b'0' && byte <= b'9')
}

private func validHtmlTagName(tag: String): Bool {
    let bytes = tag.toArray()
    if (bytes.isEmpty() || bytes[0] < b'a' || bytes[0] > b'z') { return false }
    for (byte in bytes) {
        if (!htmlLowerAlphanumeric(byte)) { return false }
    }
    true
}

private func validHtmlAttributeName(name: String): Bool {
    let bytes = name.toArray()
    if (bytes.isEmpty() || bytes[0] < b'a' || bytes[0] > b'z') { return false }
    for (byte in bytes) {
        if (!htmlLowerAlphanumeric(byte) && byte != b'-') { return false }
    }
    !name.startsWith("on") && !HTML_FORBIDDEN_ATTRIBUTES.contains(name)
}

/**
 * Structural HTML builder over the renderer's bounded text buffer.
 *
 * Text and attribute values are always escaped, attribute names are
 * allow-listed, URL attributes require `SafeUrl`, and element nesting is checked
 * so a page cannot end with an unbalanced tag.
 */
internal class HtmlWriter {
    private let out: RenderTextBuffer
    private let openElements = ArrayList<String>()

    init(limit!: Int64 = RENDER_ARTIFACT_LIMIT) {
        out = RenderTextBuffer(limit: limit)
    }

    func doctype(): Unit {
        if (out.size != 0) { throw IllegalStateException("doctype must start the document") }
        out.append("<!doctype html>\n")
    }

    func open(tag: String, attrs!: Array<HtmlAttr> = []): Unit {
        validateElement(tag)
        if (HTML_VOID_ELEMENTS.contains(tag)) {
            throw IllegalArgumentException("void element <${tag}> has no closing tag")
        }
        appendStartTag(tag, attrs)
        openElements.add(tag)
    }

    func close(tag: String): Unit {
        if (openElements.isEmpty() || openElements[openElements.size - 1] != tag) {
            throw IllegalStateException("mismatched closing tag </${tag}>")
        }
        openElements.remove(at: openElements.size - 1)
        out.append("</")
        out.append(tag)
        out.append(">")
    }

    func void(tag: String, attrs!: Array<HtmlAttr> = []): Unit {
        validateElement(tag)
        if (!HTML_VOID_ELEMENTS.contains(tag)) {
            throw IllegalArgumentException("<${tag}> is not a void element")
        }
        appendStartTag(tag, attrs)
    }

    func element(tag: String, attrs: Array<HtmlAttr>, body: (HtmlWriter) -> Unit): Unit {
        open(tag, attrs: attrs)
        body(this)
        close(tag)
    }

    /** A complete element whose whole content is one escaped text value. */
    func textElement(tag: String, value: String, attrs!: Array<HtmlAttr> = []): Unit {
        open(tag, attrs: attrs)
        text(value)
        close(tag)
    }

    func text(value: String): Unit {
        if (!openElements.isEmpty() && openElements[openElements.size - 1] == "script") {
            throw IllegalStateException("script elements only load same-origin files")
        }
        appendHtmlEscapedValue(out, value)
    }

    func trusted(fragment: TrustedHtml): Unit {
        if (!openElements.isEmpty() && openElements[openElements.size - 1] == "script") {
            throw IllegalStateException("script elements only load same-origin files")
        }
        out.append(fragment.value)
    }

    func newline(): Unit { out.append("\n") }

    /** Decorative inline SVG from the renderer's fixed icon set. */
    func icon(name: String): Unit {
        out.append("<svg class=\"cj-icon\" width=\"16\" height=\"16\" viewBox=\"0 0 24 24\" ")
        out.append("fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" ")
        out.append("stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\" focusable=\"false\">")
        out.append(htmlIconShape(name))
        out.append("</svg>")
    }

    prop size: Int64 { get() { out.size } }

    func toString(): String {
        if (!openElements.isEmpty()) {
            throw IllegalStateException("unclosed element <${openElements[openElements.size - 1]}>")
        }
        out.toString()
    }

    private func validateElement(tag: String): Unit {
        if (!validHtmlTagName(tag) || HTML_FORBIDDEN_ELEMENTS.contains(tag)) {
            throw IllegalArgumentException("element <${tag}> is not allowed")
        }
        if (!openElements.isEmpty() && openElements[openElements.size - 1] == "script") {
            throw IllegalStateException("script elements only load same-origin files")
        }
    }

    private func appendStartTag(tag: String, attrs: Array<HtmlAttr>): Unit {
        let seen = HashSet<String>()
        out.append("<")
        out.append(tag)
        for (attribute in attrs) {
            let name = attribute.name
            if (!validHtmlAttributeName(name)) {
                throw IllegalArgumentException("attribute '${name}' is not allowed")
            }
            if (!seen.add(name)) {
                throw IllegalArgumentException("duplicate attribute '${name}'")
            }
            out.append(" ")
            out.append(name)
            match (attribute) {
                case HtmlAttr.TextValue(_, value) =>
                    if (HTML_URL_ATTRIBUTES.contains(name)) {
                        throw IllegalArgumentException("attribute '${name}' requires a SafeUrl")
                    }
                    appendQuotedValue(value)
                case HtmlAttr.UrlValue(_, url) =>
                    if (!HTML_URL_ATTRIBUTES.contains(name)) {
                        throw IllegalArgumentException("attribute '${name}' is not a URL attribute")
                    }
                    appendQuotedValue(url.value)
                case HtmlAttr.Flag(_) =>
                    if (HTML_URL_ATTRIBUTES.contains(name)) {
                        throw IllegalArgumentException("attribute '${name}' requires a SafeUrl")
                    }
            }
        }
        out.append(">")
    }

    private func appendQuotedValue(value: String): Unit {
        out.append("=\"")
        appendHtmlEscapedValue(out, value)
        out.append("\"")
    }
}

private func htmlIconShape(name: String): String {
    match (name) {
        case "menu" => "<path d=\"M4 6h16M4 12h16M4 18h16\"/>"
        case "search" => "<circle cx=\"11\" cy=\"11\" r=\"7\"/><path d=\"m20 20-4-4\"/>"
        case "close" => "<path d=\"M6 6l12 12M18 6 6 18\"/>"
        case "settings" =>
            "<path d=\"M4 7h10M18 7h2M4 17h4M12 17h8\"/><circle cx=\"16\" cy=\"7\" r=\"2\"/><circle cx=\"10\" cy=\"17\" r=\"2\"/>"
        case "copy" =>
            "<rect x=\"8\" y=\"8\" width=\"12\" height=\"12\" rx=\"2\"/><path d=\"M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2\"/>"
        case "check" => "<path d=\"m5 12 5 5 9-10\"/>"
        case "standalone" =>
            "<path d=\"M14 4h6v6\"/><path d=\"M20 4l-9 9\"/><path d=\"M20 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h5\"/>"
        case "source" => "<path d=\"m8 9-3 3 3 3\"/><path d=\"m16 9 3 3-3 3\"/><path d=\"m14 5-4 14\"/>"
        case "link" =>
            "<path d=\"M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1\"/><path d=\"M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1\"/>"
        case "more" =>
            "<circle cx=\"5\" cy=\"12\" r=\"1.3\"/><circle cx=\"12\" cy=\"12\" r=\"1.3\"/><circle cx=\"19\" cy=\"12\" r=\"1.3\"/>"
        case "chevron" => "<path d=\"m9 6 6 6-6 6\"/>"
        case "chevron-down" => "<path d=\"m6 9 6 6 6-6\"/>"
        case "note" => "<circle cx=\"12\" cy=\"12\" r=\"9\"/><path d=\"M12 11v6m0-10v.1\"/>"
        case "warning" => "<path d=\"M12 3 22 21H2Z\"/><path d=\"M12 9v5m0 3v.1\"/>"
        case "danger" => "<path d=\"M8 2h8l6 6v8l-6 6H8l-6-6V8Z\"/><path d=\"M12 7v7m0 3v.1\"/>"
        case "language" =>
            "<circle cx=\"12\" cy=\"12\" r=\"9\"/><path d=\"M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18\"/>"
        case _ => throw IllegalArgumentException("unknown icon '${name}'")
    }
}
