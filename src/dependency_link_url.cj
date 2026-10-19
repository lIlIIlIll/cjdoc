package cjdoc

import cjdoc.model.*

internal func safeDependencyExternalBase(value: String): Bool {
    safeLocalExternalBaseUrl(value) || isSafeAbsoluteDocumentationUrl(value, allowFragment: false, allowQuery: false)
}

internal func safeDependencyExternalHref(baseUrl: String, href: String): ?String {
    if (!safeDependencyExternalBase(baseUrl)) { return None }
    if (href.startsWith("https://") || href.startsWith("http://")) {
        return if (isSafeAbsoluteDocumentationUrl(href)) { Some(href) } else { None }
    }
    if (!isSafeDocumentationRoute(href)) { return None }
    let base = if (baseUrl.endsWith("/")) { baseUrl[..baseUrl.size - 1] } else { baseUrl }
    Some(base + "/" + href)
}
