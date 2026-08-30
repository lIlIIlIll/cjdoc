package frontend_regressions

/** A declaration with no byte gap after its comment. */public func adjacent(): Unit {}

/** Both tuple bindings share this documentation. */
public let (first, second) = (1, 2)

/** Reference target. */
public func target(value: String, enabled: Bool): Unit {}

/** Parameters with source-authored defaults. */
public func defaulted(required: Int64, count!: Int64 = 40 + 2,
    label!: String = "cjdoc"): String {
    label
}

/**
 * Fences retain tag-looking text.
 *
 * ~~~~text
 * @param insideTilde not a tag
 * ~~~
 * ~~~~
 *
 * ````text
 * @throws InsideBacktick not a tag
 * ```
 * ````
 * @see frontend_regressions.target(String, Bool) related overload
 */
public func fenced(): Unit {}

/**
 * Rich Markdown metadata.
 *
 * ## Details
 *
 * 3) first
 * 4) [x] done
 *
 * ~~~~cj {#sample}
 * let value = 1
 * ~~~~
 *
 * | Name | Value |
 * | :--- | ---: |
 * | left | right |
 */
public func richMarkdown(): Unit {}

/** An ordinary enum. */
public enum ClosedStatus {
    /** A compact enum-case comment. */| Closed
}

/** A non-exhaustive enum. */
public enum OpenStatus {
    | Ready
    | ...
}
