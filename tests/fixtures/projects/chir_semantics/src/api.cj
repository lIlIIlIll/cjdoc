package chir_semantics

/** A class with a constructor and member function. */
public class Box {
    public init() {}
    public func value(): Int64 { 1 }
}

/** A value type with a property. */
public struct Point {
    public let x: Int64
    public let y: Int64

    public init(x: Int64, y: Int64) {
        this.x = x
        this.y = y
    }
}

/** An enum with payload and payload-free cases. */
public enum State {
    | Ready
    | Failed(String)
}

/** An overloaded top-level API. */
public func makeBox(): Box { Box() }
public func makeBox(value: Int64): Box { Box() }

/** An extension declaration. */
extend Box {
    public func extra(): Int64 { 2 }
}

public type Alias = Int64
