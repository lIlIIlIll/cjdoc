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
