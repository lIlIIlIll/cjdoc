package reexport_dep

/** A visible widget. */
public struct Widget {}

/** Creates a value. */
public func make(): Int64 { 1 }

public func overload(value: Int64): Int64 { value }
public func overload(value: String): String { value }
public let renamed = 1
public func alias_target(): Unit {}
private let hidden = 2
