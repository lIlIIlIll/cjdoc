package html_reference_core

/**
 * A rich reference summary with **bold** text, `inline code`, and a
 * [safe link](https://example.test/reference).
 *
 * The rest of this paragraph stays in the documentation body.
 *
 * ## Details
 *
 * - A documented item.
 * - Another documented item.
 *
 * ```cj
 * let answer = 42
 * ```
 */
/** A type used to verify signature link placement. */
public class Token {}

public class ReferenceBox<T> {
    /** Stored generic value. */
    public let value: T

    /**
     * Create a reference box.
     * @param value Initial value.
     */
    public init(value: T) { this.value = value }

    /**
     * Normalize the stored value.
     * @param value Input value.
     * @return A stable integer for the example.
     * @throws IllegalArgumentException when the value is invalid.
     * @throws HiddenGuideTarget when the hidden target is referenced.
     * @precondition value is a valid numeric input.
     * @postcondition the normalized value is stable.
     * @performance linear in the input size.
     * @example
     * let result = normalize(value: 42)
     */
    public func normalize(value: Int64): Int64 { value }

    /**
     * Exercise named parameters with a default string that matches a type name.
     * @param label Display label.
     * @param item Token value.
     */
    public func use(label!: String = "Token", item!: Token): Unit {}

    /** Compact density member 01. */
    public func member01(): Unit {}

    /** Compact density member 02. */
    public func member02(): Unit {}

    /** Compact density member 03. */
    public func member03(): Unit {}

    /** Compact density member 04. */
    public func member04(): Unit {}

    /** Compact density member 05. */
    public func member05(): Unit {}

    /** Compact density member 06. */
    public func member06(): Unit {}

    /** Compact density member 07. */
    public func member07(): Unit {}

    /** Compact density member 08. */
    public func member08(): Unit {}

    /** Compact density member 09. */
    public func member09(): Unit {}

    /** Compact density member 10. */
    public func member10(): Unit {}

    /** Compact density member 11. */
    public func member11(): Unit {}

    /** Compact density member 12. */
    public func member12(): Unit {}

    /** Compact density member 13. */
    public func member13(): Unit {}

    /** Compact density member 14. */
    public func member14(): Unit {}

    /** Compact density member 15. */
    public func member15(): Unit {}

    /** First overload used for same-page comparison. */
    public func ping(value: Int64): Unit {}

    /** Second overload used for same-page comparison. */
    public func ping(value: String): Unit {}

    /**
     * 将整数转换为文本，验证中文契约在紧凑成员中的可读性。
     *
     * @param value 要转换的整数。
     * @return 转换后的文本。
     */
    public func convert(value: Int64): String { value.toString() }

    /**
     * 直接返回文本，作为第二个重载组的另一个签名。
     *
     * @param value 输入文本。
     * @return 原始文本。
     */
    public func convert(value: String): String { value }

    /** A documented property. */
    public prop label: String { get() { "reference" } }
}

/** A small public enumeration. */
public enum ReferenceState {
    | Ready
    | Failed(String)
}

/** An alias with a stable package index row. */
public type ReferenceName = String
private class HiddenGuideTarget {}

/** Extension container used to verify member-source presentation. */
extend<T> ReferenceBox<T> {
    /** Member supplied by an extension. */
    public func extensionMarker(): String { "extended" }
}
