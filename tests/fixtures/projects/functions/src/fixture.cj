package functions_fixture

/**
 * Parse text.
 * @param text input text
 * @return length
 */
public func parse(text: String): Int64 { Int64(text.size) }

/**
 * Parse bytes.
 * @param data input bytes
 * @return length
 */
public func parse(data: Array<UInt8>): Int64 { Int64(data.size) }

/**
 * Identity.
 * @param value input
 * @return input
 */
public func identity<T>(value: T): T { value }

/**
 * 中文函数。
 * @param 文本 输入文本。
 * @return 输入文本。
 */
public func 解析(文本: String): String { 文本 }

/**
 * Multiline signature.
 * @param text input
 * @param strict mode
 * @return text
 */
public func multiline(
    text: String,
    strict: Bool
): String {
    if (strict) { text } else { "" }
}

