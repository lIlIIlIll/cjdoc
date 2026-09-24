package pocketkit.parsing

import std.collection.*

/** 解析产生的文本 Token，没有自动做 Unicode 标准化。 */
public struct Token {
    /** 输入中的原样文本。 */
    public let text: String
    /** @param text 原样保存的文本。 */
    public init(text: String) { this.text = text }
}

/**
 * 使用显式分隔符拆分文本 / Split simple delimited text, not full CSV.
 *
 * 返回 {@link pocketkit.parsing.Token}，不是 {@link pocketkit.io.Token}。
 * 不支持引号、转义、区域设置或流式解析。使用完全限定名消除跨包同名歧义。
 *
 * @param text 要拆分的文本。
 * @param separator 非空分隔符，默认为逗号。
 * @param keepEmpty 是否保留空字段，默认为 false。
 * @return 顺序与输入一致的 Token 数组。
 * @throws IllegalArgumentException separator 为空。
 * @example 不保留空字段
 * ```cangjie
 * let tokens = parse("alpha,,beta", keepEmpty: false)
 * assert(tokens.size == 2)
 * assert(tokens[1].text == "beta")
 * ```
 */
public func parse(text: String, separator!: String = ",", keepEmpty!: Bool = false): Array<Token> {
    if (separator.isEmpty()) { throw IllegalArgumentException("separator must not be empty") }
    let tokens = ArrayList<Token>()
    for (part in text.split(separator)) {
        if (keepEmpty || !part.isEmpty()) { tokens.add(Token(part)) }
    }
    tokens.toArray()
}
