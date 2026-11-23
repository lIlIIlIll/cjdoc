protected package cjdoc.source

import std.collection.ArrayList

protected func joinedImportPath(parts: ArrayList<String>, tail!: ?String = None): String {
    let out = StringBuilder()
    var first = true
    for (part in parts) {
        if (!first) { out.append(".") }
        out.append(part)
        first = false
    }
    if (let Some(value) <- tail) {
        if (!first) { out.append(".") }
        out.append(value)
    }
    out.toString()
}
