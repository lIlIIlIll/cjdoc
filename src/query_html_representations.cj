package cjdoc

import std.collection.*
import std.fs.*
import yjson.*

// Agent payload bytes have manifest digests. HTML chrome belongs to the
// existing site/version transaction, so record its actual in-bundle availability
// without parsing HTML or pretending those bytes are part of the Doc IR hash.
internal func validateQueryHtmlRepresentations(root: Path, manifest: JsonObject): Unit {
    let canonicalRoot = canonicalize(root).toString()
    let paths = HashSet<String>()
    let representations = manifest.get("representations").getOrThrow().asArray()
    for (index in 0..representations.size()) {
        let relative = queryString(representations[index].asObject(), "html")
        if (!paths.add(relative)) { continue }
        queryResourcePath(relative)
        let path = root.join(relative)
        ensureNoSymbolicLinkAncestors(path, "packaged HTML representation")
        ensureRegularNonSymlink(path, "packaged HTML representation")
        if (!hostPathIsWithin(canonicalRoot, canonicalize(path).toString())) {
            throw DocumentationQueryException("unavailable", "html_representation_outside_bundle",
                "A packaged HTML representation is outside its captured document root.")
        }
    }
}
