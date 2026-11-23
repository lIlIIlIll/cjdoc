protected package cjdoc.source

protected func percentEscapeSymbolPart(value: String): String {
    let builder = StringBuilder()
    for (rune in value.runes()) {
        match (rune) {
            case ':' => builder.append("%3A")
            case '#' => builder.append("%23")
            case '(' => builder.append("%28")
            case ')' => builder.append("%29")
            case ',' => builder.append("%2C")
            case '%' => builder.append("%25")
            case _ => builder.append(rune)
        }
    }
    return builder.toString()
}

protected func moduleId(role: String, name: String, logicalPrefix: String): String {
    if (role == "root") { return "cjdoc:module:v1:root" }
    if (role == "workspace") { return "cjdoc:module:v1:workspace:${logicalPrefix}" }
    if (role == "externalDependency") { return "cjdoc:module:v1:external:${percentEscapeSymbolPart(name)}" }
    "cjdoc:module:v1:path:${percentEscapeSymbolPart(name)}"
}
