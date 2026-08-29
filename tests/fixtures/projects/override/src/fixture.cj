package override_fixture

/** Base API. */
public open class BaseReader {
    /** Read a value. */
    public open func read(): Int64 { 0 }
}

/** Derived API. */
public class DerivedReader <: BaseReader {
    /** Read a specialized value. */
    public override func read(): Int64 { 1 }
}
