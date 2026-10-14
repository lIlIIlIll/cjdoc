package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func safeDocumentationPageRoute(route: String): Bool {
    if (!safeRelativePath(route) || route.contains(":") || route.contains("#") ||
        route.contains("?") || route.contains("%")) { return false }
    for (byte in route.toArray()) { if (byte < 0x20 || byte == 0x7F) { return false } }
    true
}

internal func validateCapturedPageRoutes(documentation: DocumentationSet): Unit {
    let reserved = HashSet<String>()
    for (route in ["index.html", "validation.html"]) { let _ = reserved.add(route) }
    for (packageDoc in documentation.packages) {
        let _ = reserved.add(packagePagePath(packageDoc.moduleId, packageDoc.name))
    }
    for (symbol in documentation.declarations) {
        let _ = reserved.add(symbolPagePath(symbol))
        let _ = reserved.add(symbolReadablePagePath(symbol))
    }
    for (locale in ["en", "zh-CN"]) {
        let selected = HashSet<String>()
        for (page in selectedDocumentationPages(documentation, locale)) {
            if (reserved.contains(page.route) || !selected.add(page.route)) {
                domainFail("$.pages.route", "reserved or duplicate selected page route for language " + locale)
            }
        }
    }
}
