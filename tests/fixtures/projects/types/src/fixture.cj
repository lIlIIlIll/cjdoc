package types_fixture

/** Reader API. */
public interface Reader {
    /** Read a value. */
    func read(): Int64
}

/** Point with a primary constructor. */
public class Point {
    /**
     * Create a point.
     * @param x horizontal coordinate
     * @param y vertical coordinate
     */
    public Point(public let x: Int64, public let y: Int64) {}
}

/** Generic box. */
public struct Box<T> {
    /** Stored value. */
    public let value: T

    /**
     * Create a box.
     * @param value stored value
     */
    public init(value: T) {
        this.value = value
    }
}

/** State values. */
public enum State {
    /** Idle state. */
    | Idle
    /** Failure state. */
    | Failed(String)
}

/** Name alias. */
public type Name = String
