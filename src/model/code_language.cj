package cjdoc.model

/**
 * Normalizes an explicit code-language identifier for backend selection.
 *
 * Only the author's explicit language metadata is rewritten here: neither a
 * missing language nor an unknown one is inferred or detected. An empty result
 * asks for plain text, and every other unknown value is returned unchanged, so
 * a caller can still report the author's own spelling.
 *
 * Shell families are deliberately NOT unified: Bash, zsh, fish and PowerShell
 * are different grammars, so a `sh` block is not silently highlighted as Bash.
 *
 * This function never authorizes an external program and never changes the
 * language string that a document stores.
 */
public func normalizeCodeLanguage(value: String): String {
    let bytes = value.trimAscii().toArray()
    for (index in 0..bytes.size) {
        if (bytes[index] >= b'A' && bytes[index] <= b'Z') {
            bytes[index] = bytes[index] + (b'a' - b'A')
        }
    }
    let language = String.fromUtf8(bytes)
    match (language) {
        case "cj" => "cangjie"
        case "py" => "python"
        case "yml" => "yaml"
        case "text" | "plaintext" | "plain" | "output" | "console" |
            "nohighlight" | "no-highlight" => ""
        case _ => language
    }
}

/**
 * Selects the highlighting backend for an explicit language.
 *
 * The result is a selection, not an authorization: `"external"` only says that
 * the language is in the supported grammar table, and the caller still decides
 * whether an external adapter may run. Cangjie always stays on the built-in
 * backend and is never handed to an external grammar.
 */
public func codeLanguageBackend(value: String): String {
    match (normalizeCodeLanguage(value)) {
        case "" => "plain"
        case "cangjie" => "builtin"
        case "json" | "bash" | "python" | "toml" | "yaml" => "external"
        case _ => "plain"
    }
}

/**
 * Maps a fixed highlight category to its presentation class.
 *
 * Categories are the only source of a class name, so a backend can never inject
 * an arbitrary CSS class into the generated page. An unrecognized category has
 * no class and is rendered as plain text.
 */
public func codeKindClass(kind: String): String {
    match (kind) {
        case "keyword" => "code-keyword"
        case "type" => "code-type"
        case "string" => "code-string"
        case "number" => "code-number"
        case "literal" => "code-literal"
        case "comment" => "code-comment"
        case "operator" => "code-operator"
        case "punctuation" => "code-punctuation"
        case "function" => "code-function"
        case "property" => "code-property"
        case "meta" => "code-meta"
        case _ => ""
    }
}
