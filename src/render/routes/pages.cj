protected package cjdoc.render.routes

import cjdoc.model.*
import std.collection.*

protected func selectedDocumentationPages(value: DocumentationSet, locale: String): Array<DocumentationPage> {
    let ids = ArrayList<String>()
    for (page in value.pages) { if (!ids.contains(page.id)) { ids.add(page.id) } }
    let result = ArrayList<DocumentationPage>()
    for (id in ids) {
        var exact: ?DocumentationPage = None
        var original: ?DocumentationPage = None
        var unknown: ?DocumentationPage = None
        for (page in value.pages where page.id == id) {
            if (page.language == Some(locale)) { exact = Some(page) }
            if (page.language == page.defaultLanguage) { original = Some(page) }
            if (page.language.isNone()) { unknown = Some(page) }
        }
        let selected = if (exact.isSome()) { exact } else if (original.isSome()) { original } else { unknown }
        if (let Some(page) <- selected) { result.add(page) }
    }
    result.toArray()
}

// Stable page identity for a generated package page, shared by the published
// language inventory and the HTML package page.
protected func packagePageIdentity(pkg: PackageDoc): String {
    "package:${pkg.moduleId}:${pkg.name}"
}

protected func pageRootPrefix(route: String): String {
    var prefix = ""
    for (_ in 1..route.split("/").size) { prefix += "../" }
    prefix
}
