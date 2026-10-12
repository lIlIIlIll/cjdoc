package cjdoc.model

/**
 * Normalizes an explicit code-language identifier for backend selection.
 *
 * This does not parse a Markdown info string, detect a language, authorize an
 * external program, or change the author's stored metadata. An empty result
 * requests plain text. Unknown languages remain unknown; in particular shell
 * families are not all treated as Bash.
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
