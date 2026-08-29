package extend_visibility_fixture

/** Public box. */
public class Box<T> {
    /** Public value. */
    public let value: T

    /**
     * Create a box.
     * @param value stored value
     */
    public init(value: T) {
        this.value = value
    }

    private func hiddenMember(): Unit {}
}

/** First extension. */
extend Box<String> {
    /** Length. */
    public func length(): Int64 { Int64(value.size) }
}

/** Second extension. */
extend Box<String> {
    /** Pretty value. */
    public func pretty(): String { value }
    private func hiddenExtensionMember(): Unit {}
}

/** Annotated API. */
@Deprecated[message: "Use Box instead."]
public func oldApi(): Unit {}

internal func packageOnly(): Unit {}
private func fileOnly(): Unit {}
