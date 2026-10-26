package macro_wrapped

/** A source enum inside nested macro wrappers. */
@Outer
@Derive[Equatable]
public enum State {
    /** No work is pending. */
    Idle |
    /** Work is in progress. */
    Busy(Int64)

    /** Return the source code. */
    public func code(): Int64 { 1 }
}

/** A wrapped class with an original member position. */
@Wrapped
public open class Resource {
    /** The current resource size. */
    protected prop size: Int64 { get() { 1 } }
}

/** This class remains private to its package. */
@Wrapped
private class Hidden {}

@Opaque(1 + 2)
