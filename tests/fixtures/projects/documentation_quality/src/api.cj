package quality_fixture

/**
 * quality_fixture 公开 API：echo。
 * @param value 参数 value。
 * @return 返回 Int64。
 */
public func echo(value: Int64): Int64 { value }

/**
 * Adds one to the supplied integer. Literal <script>alert(1)</script> is documentation.
 * @param value The integer to increment.
 * @return The successor of value.
 */
public func increment(value: Int64): Int64 { value + 1 }

/** hidden */
private func hidden(): Unit {}
