protected package cjdoc.render.codec

protected func domainFail(path: String, message: String): Nothing {
    throw IllegalArgumentException("invalid Doc IR domain at ${path}: ${message}")
}
