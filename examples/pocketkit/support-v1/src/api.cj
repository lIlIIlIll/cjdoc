package pocket_support

/** 独立依赖中的来源标签 / A label in the independent support documentation. */
public struct SourceLabel {
    /** 原样保存的标签文本。 */
    public let text: String
    /** @param text 标签内容，不执行外部查询。 */
    public init(text: String) { this.text = text }
}

/** 独立依赖中的 Token，不是 pocketkit.io 或 pocketkit.parsing 的 Token。 */
public struct Token {
    /** 标签值。 */
    public let value: String
    /** @param value 标签值。 */
    public init(value: String) { this.value = value }
}

/** 外部 Stamp。与 pocketkit.Stamp 同名，但身份和文档集不同。 */
public struct Stamp {
    /** 标签值。 */
    public let value: String
    /** @param value 标签值。 */
    public init(value: String) { this.value = value }
}
