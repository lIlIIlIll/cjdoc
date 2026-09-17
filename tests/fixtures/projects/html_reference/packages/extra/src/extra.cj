package html_reference_extra

/**
 * Extra package API with a long generic signature.
 *
 * This second paragraph verifies that the header summary is not the whole
 * documentation body.
 *
 * @param values Values to count.
 * @param strict Whether validation is strict.
 * @return The number of values.
 * @throws IllegalArgumentException for invalid input.
 */
public func count<T>(values: Array<T>, strict: Bool): Int64 {
    if (strict && values.isEmpty()) { throw IllegalArgumentException("empty") }
    Int64(values.size)
}

/** A public interface for the package index. */
public interface ExtraReader {
    /** Read the current count. */
    func read(): Int64
}

/** A public implementation with a member row. */
public struct ExtraBox {
    /** The stored count. */
    public let count: Int64

    /** Create an extra box. */
    public init(count: Int64) { this.count = count }

    /** Read the stored count. */
    public func read(): Int64 { count }
}
