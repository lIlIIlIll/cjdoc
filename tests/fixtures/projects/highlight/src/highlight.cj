package highlight

/**
 * Covers the lexical shapes an accurate Cangjie highlighter must colour.
 *
 * Strings, raw strings, runes, numbers in every supported form, nested
 * comments, macros, annotations and identifiers outside ASCII.
 *
 * ```cj
 * let plain = "text with \"escape\" and 中文"
 * let unfinished = "never closed
 * ```
 *
 * @example
 * ```cangjie
 * let raw = #"raw \n text"#
 * let nested = /* outer /* inner */ still */ 1
 * ```
 */
public class LexicalShapes {
    /** A stored value used to keep the declaration non-empty. */
    public let value: Int64

    /**
     * Create the holder.
     * @param value Any value.
     */
    public init(value: Int64) { this.value = value }

    /**
     * Exercise a generic signature with built-in and user types.
     * @param items The items to summarise.
     * @param label A display label that defaults to the type name "Token".
     * @return The number of items.
     */
    public func summarise<T>(items: Array<T>, label!: String = "Token"): Int64 {
        items.size
    }

    /**
     * Return a raw string, a rune and a rounded number.
     * @return A triple of literal shapes.
     */
    public func literals(): (String, Rune, Float64) {
        (##"hash #" inside"##, 'x', 1.5e-3)
    }
}

/** A type named `Token` so a string default of the same spelling can be tested. */
public class Token {}
