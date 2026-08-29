package lint_fixture

/**
 * Deliberately invalid documentation.
 * @param first first value
 * @param first duplicate
 * @param ghost unknown
 * @return one
 * @return two
 * @see
 * @see missing.symbol
 * @see lint_fixture.ambiguous
 */
public func lintTarget(first: String, second: Bool): String { first }

/** @param value string value */
public func ambiguous(value: String): Unit {}

/** @param value integer value */
public func ambiguous(value: Int64): Unit {}
