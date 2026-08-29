package basic

/**
 * 从文本解析值。
 *
 * ## Example
 *
 * ```cj
 * let value = parse("42")
 * ```
 *
 * @param text 输入文本。
 * @return 解析结果。
 * @throws IllegalArgumentException 输入非法时抛出。
 * @see basic.parse(String)
 * @see basic.parse(Array<UInt8>) 字节数组重载。
 * @see basic.multiline(String,Bool)
 * @since 0.1.0
 */
public func parse(text: String): Int64 {
    return 42
}

/**
 * Parse bytes.
 * @param data Input bytes.
 * @return Parsed size.
 */
public func parse(data: Array<UInt8>): Int64 {
    return Int64(data.size)
}

/** A readable value. */
public interface Reader {
    func read(): Int64
}

/** Generic parser. */
public class Parser<T> <: Reader {
    /** Stored value. */
    public let value: T

    /**
     * Create a parser.
     * @param value Initial value.
     */
    public init(value: T) {
        this.value = value
    }

    /**
     * Read a number.
     * @return Current number.
     */
    public func read(): Int64 { 0 }

    /** Current size. */
    public prop size: Int64 { get() { 1 } }

    private func hidden(): Unit {}
}

/** Generic box. */
public struct Box<T> {
    public let value: T
    /** @param value Box value. */
    public init(value: T) { this.value = value }
}

/** Result status. */
public enum Status {
    | Ready
    | Failed(String)
}

/** String box helpers. */
extend Box<String> {
    /** Pretty value. */
    public func pretty(): String { value }
}

/** Additional string box helpers. */
extend Box<String> {
    /** Value length. */
    public func length(): Int64 { Int64(value.size) }
}

/**
 * Generic identity.
 * @param value Input value.
 * @return Same value.
 */
public func identity<T>(value: T): T { value }

/** Alias documentation. */
public type Name = String

/**
 * Deprecated API.
 * @param text Input text.
 * @return Parsed value.
 */
@Deprecated[message: "Use parse instead."]
public func oldParse(text: String): Int64 { parse(text) }

/**
 * 中文标识符。
 * @param 文本 文本值。
 * @return 原文本。
 */
public func 解析(文本: String): String { 文本 }

/**
 * Multiline declaration.
 * @param text Text.
 * @param strict Strict mode.
 */
public func multiline(
    text: String,
    strict: Bool
): String {
    if (strict) { text } else { "" }
}
