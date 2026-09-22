package compact_reference

/** An opaque token for signature-link regression tests. */
public class Token {
    /** Create an empty token. */
    public init() {}
}

/** 可在当前页面查看完整成员契约的示例集合。 */
public class CompactBox {
    /** Create an empty collection. */
    public init() {}

    /** 集合名称。该属性不修改对象。 */
    public prop label: String { get() { "compact" } }

    /**
     * 返回供显示使用的集合说明。
     *
     * 此成员关联独立指南。返回内容不包含调用方的私人数据。
     * @return 集合说明文本。
     * @example
     * let box = CompactBox()
     * println(box.describe())
     */
    public func describe(): String { "compact collection" }

    /**
     * 读取缺省位置的值。
     * @return 当前缺省值。
     * @postcondition 不修改集合。
     */
    public func read(): Int64 { 0 }

    /**
     * 读取指定位置的值，保留清楚的边界条件。
     *
     * 本示例只接受非负索引。调用失败时不修改集合。
     * @param index 需要读取的非负位置。
     * @return 所选位置对应的示例值。
     * @throws IllegalArgumentException index 为负数时抛出。
     * @precondition index 必须非负。
     * @postcondition 集合状态保持不变。
     * @performance 本示例为常数时间。
     * @example
     * let box = CompactBox()
     * println(box.read(3))
     */
    public func read(index: Int64): Int64 {
        if (index < 0) { throw IllegalArgumentException("negative index") }
        index
    }

    /**
     * 写入一个值。
     * @param value 待写入值。
     * @return 本示例接收的值。
     */
    public func put(value: Int64): Int64 { value }

    /**
     * 使用命名参数指定位置和值。
     * @param at 目标位置。
     * @param value 待写入值。
     * @return 实际接收的值。
     */
    public func put(at!: Int64, value!: Int64): Int64 { value }

    /**
     * 同名字符串不能被识别成参数类型。
     * @param label 文本标签，可包含 Token 字样。
     * @param item 真正的 Token 类型参数。
     */
    public func accept(label!: String = "Token", item!: Token): Unit {}

    /**
     * 演示嵌套泛型、默认值与较长的命名参数。
     * @param source 原始文本列表。
     * @param fallback 缺少文本时使用的返回值。
     * @return 本示例返回缺省值，不声明实际解析能力。
     */
    public func convert(source: Array<String>, fallback!: String = "not provided"): String { fallback }

    /**
     * 清理操作的示例说明，便于在列表中比较。
     *
     * 这是自有测试夹具，不代表标准库 API；操作保持输入值。
     * @param value 操作的输入值。
     * @return 原始输入值。
     * @postcondition 不修改其他成员的状态。
     */
    public func clear(value: Int64): Int64 { value }

    /**
     * 关闭操作的示例说明，便于在列表中比较。
     *
     * 这是自有测试夹具，不代表标准库 API；操作保持输入值。
     * @param value 操作的输入值。
     * @return 原始输入值。
     * @postcondition 不修改其他成员的状态。
     */
    public func close(value: Int64): Int64 { value }

    /**
     * 查找操作的示例说明，便于在列表中比较。
     *
     * 这是自有测试夹具，不代表标准库 API；操作保持输入值。
     * @param value 操作的输入值。
     * @return 原始输入值。
     * @postcondition 不修改其他成员的状态。
     */
    public func contains(value: Int64): Int64 { value }

    /**
     * 计数操作的示例说明，便于在列表中比较。
     *
     * 这是自有测试夹具，不代表标准库 API；操作保持输入值。
     * @param value 操作的输入值。
     * @return 原始输入值。
     * @postcondition 不修改其他成员的状态。
     */
    public func count(value: Int64): Int64 { value }

    /**
     * 判空操作的示例说明，便于在列表中比较。
     *
     * 这是自有测试夹具，不代表标准库 API；操作保持输入值。
     * @param value 操作的输入值。
     * @return 原始输入值。
     * @postcondition 不修改其他成员的状态。
     */
    public func empty(value: Int64): Int64 { value }

    /**
     * 首项操作的示例说明，便于在列表中比较。
     *
     * 这是自有测试夹具，不代表标准库 API；操作保持输入值。
     * @param value 操作的输入值。
     * @return 原始输入值。
     * @postcondition 不修改其他成员的状态。
     */
    public func first(value: Int64): Int64 { value }

    /**
     * 末项操作的示例说明，便于在列表中比较。
     *
     * 这是自有测试夹具，不代表标准库 API；操作保持输入值。
     * @param value 操作的输入值。
     * @return 原始输入值。
     * @postcondition 不修改其他成员的状态。
     */
    public func last(value: Int64): Int64 { value }

    /**
     * 预留操作的示例说明，便于在列表中比较。
     *
     * 这是自有测试夹具，不代表标准库 API；操作保持输入值。
     * @param value 操作的输入值。
     * @return 原始输入值。
     * @postcondition 不修改其他成员的状态。
     */
    public func reserve(value: Int64): Int64 { value }

    /**
     * 移除操作的示例说明，便于在列表中比较。
     *
     * 这是自有测试夹具，不代表标准库 API；操作保持输入值。
     * @param value 操作的输入值。
     * @return 原始输入值。
     * @postcondition 不修改其他成员的状态。
     */
    public func remove(value: Int64): Int64 { value }

    /**
     * 重置操作的示例说明，便于在列表中比较。
     *
     * 这是自有测试夹具，不代表标准库 API；操作保持输入值。
     * @param value 操作的输入值。
     * @return 原始输入值。
     * @postcondition 不修改其他成员的状态。
     */
    public func reset(value: Int64): Int64 { value }

    /**
     * 快照操作的示例说明，便于在列表中比较。
     *
     * 这是自有测试夹具，不代表标准库 API；操作保持输入值。
     * @param value 操作的输入值。
     * @return 原始输入值。
     * @postcondition 不修改其他成员的状态。
     */
    public func snapshot(value: Int64): Int64 { value }

    /**
     * 转换操作的示例说明，便于在列表中比较。
     *
     * 这是自有测试夹具，不代表标准库 API；操作保持输入值。
     * @param value 操作的输入值。
     * @return 原始输入值。
     * @postcondition 不修改其他成员的状态。
     */
    public func transform(value: Int64): Int64 { value }

    /**
     * 验证操作的示例说明，便于在列表中比较。
     *
     * 这是自有测试夹具，不代表标准库 API；操作保持输入值。
     * @param value 操作的输入值。
     * @return 原始输入值。
     * @postcondition 不修改其他成员的状态。
     */
    public func validate(value: Int64): Int64 { value }

    /**
     * 遍历操作的示例说明，便于在列表中比较。
     *
     * 这是自有测试夹具，不代表标准库 API；操作保持输入值。
     * @param value 操作的输入值。
     * @return 原始输入值。
     * @postcondition 不修改其他成员的状态。
     */
    public func visit(value: Int64): Int64 { value }

    /**
     * 替换操作的示例说明，便于在列表中比较。
     *
     * 这是自有测试夹具，不代表标准库 API；操作保持输入值。
     * @param value 操作的输入值。
     * @return 原始输入值。
     * @postcondition 不修改其他成员的状态。
     */
    public func withValue(value: Int64): Int64 { value }
}

/** 为 CompactBox 提供明确来源的扩展成员。 */
extend CompactBox {
    /**
     * 扩展提供的描述。
     * @return 与扩展关联的文本。
     */
    public func extensionLabel(): String { "extension" }
}

/**
 * 创建一个示例集合；此函数有独立的指南反向入口。
 * @return 新的集合对象。
 */
public func makeBox(): CompactBox { CompactBox() }
