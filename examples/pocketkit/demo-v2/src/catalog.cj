package pocketkit

import std.collection.*

/**
 * 保存按插入顺序排列的文本条目 / An insertion-ordered text catalogue.
 *
 * TextCatalog 保留重复值和空字符串；索引从零开始。实例不提供内部同步，调用方必须
 * 在并发修改与读取之间安排同步。这是作者提供的契约，不是语义分析器证明。
 * {@link Stamp} 是本库的标签；{@link pocket_support.SourceLabel} 属于独立文档集。
 * 本地优先查找不会把 pocket_support.Stamp 当成本地类型；外部字段
 * {@link pocket_support.SourceLabel.text} 也使用同一个固定版本的本地索引。
 *
 * @example 顺序、重复值和快照
 * ```cangjie
 * let catalog = TextCatalog(["alpha", "beta", "alpha"])
 * assert(catalog.size == 3)
 * assert(catalog.at(0) == "alpha")
 * let saved = catalog.snapshot()
 * catalog.clear()
 * assert(saved.size == 3)
 * ```
 */
public class TextCatalog {
    private let values = ArrayList<String>()

    /** 构造空目录 / Create an empty catalogue. */
    public init() {}

    /**
     * 从数组复制条目，不保留调用方数组的可变视图。
     * @param entries 初始条目，允许重复和空字符串。
     */
    public init(entries: Array<String>) { values.add(all: entries) }

    /** 当前条目个数，不包含隐式终止符。 */
    public prop size: Int64 { get() { values.size } }

    /**
     * 追加一条文本 / Append one string.
     * @param value 原样保存的条目，允许空字符串。
     * @postcondition size 比调用前增加一。
     * @example 追加后按位置读取
     * ```cj
     * let catalog = TextCatalog()
     * catalog.add("hello")
     * assert(catalog.at(0) == "hello")
     * ```
     */
    public func add(value: String): Unit { values.add(value) }

    /**
     * 将整数转换为十进制文本后追加。
     * @param value 要格式化的整数。
     * @param radix 仅支持十进制，默认值是 10。
     * @throws IllegalArgumentException radix 不是 10。
     * @postcondition 新条目与 value.toString() 相同。
     */
    public func add(value: Int64, radix!: Int64 = 10): Unit {
        if (radix != 10) { throw IllegalArgumentException("only decimal radix is supported") }
        values.add(value.toString())
    }

    /**
     * 原样追加一组条目。
     * @param entries 逐项复制的输入数组。
     */
    public func addAll(entries: Array<String>): Unit { values.add(all: entries) }

    /** 删除全部条目；此前返回的快照不受影响。 */
    public func clear(): Unit { values.clear() }

    /** @return 没有条目时返回 true。 */
    public func isEmpty(): Bool { values.isEmpty() }

    /**
     * 判断目录是否包含与输入完全相等的文本。
     * @param value 区分大小写的匹配文本。
     * @return 至少存在一项匹配时返回 true。
     * @performance 最多检查 size 个条目，这是作者说明的复杂度。
     */
    public func contains(value: String): Bool {
        for (entry in values) { if (entry == value) { return true } }
        false
    }

    /**
     * 返回指定索引的条目。
     * @param index 从零开始的索引。
     * @return 保存在该位置的文本。
     * @throws IllegalArgumentException index 小于零或不小于 size。
     * @precondition 0 <= index < size。
     */
    public func at(index: Int64): String {
        if (index < 0 || index >= values.size) { throw IllegalArgumentException("index outside catalogue") }
        values[index]
    }

    /**
     * 可选读取，不用异常表示索引不存在。
     * @param index 任意 Int64 索引。
     * @return 索引有效时为 Some；负索引或越界时为 None。
     */
    public func tryAt(index: Int64): ?String {
        if (index < 0 || index >= values.size) { return None }
        Some(values[index])
    }

    /** @return 首条文本；空目录返回 None。 */
    public func first(): ?String { tryAt(0) }

    /** @return 末条文本；空目录返回 None。 */
    public func last(): ?String { tryAt(values.size - 1) }

    /**
     * 复制当前条目 / Copy the current entries.
     * @return 不共享 ArrayList 容器的数组快照；demo-v2 澄清 String 值本身不可变。
     */
    public func snapshot(): Array<String> { values.toArray() }

    /**
     * 替换指定位置的文本。
     * @param index 从零开始的索引。
     * @param value 替换文本。
     * @throws IllegalArgumentException index 不在有效范围。
     */
    public func replace(index: Int64, value: String): Unit {
        let _ = at(index)
        values[index] = value
    }

    /**
     * 删除指定位置，后续条目依次前移。
     * @param index 从零开始的索引。
     * @return 被移除的文本。
     * @throws IllegalArgumentException index 不在有效范围。
     */
    public func removeAt(index: Int64): String {
        let old = at(index)
        values.remove(at: index)
        old
    }

    /**
     * 从第一项开始查找文本。
     * @param value 区分大小写的目标文本。
     * @return 第一个匹配索引；找不到则返回 None。
     */
    public func find(value: String): ?Int64 { find(value, start: 0) }

    /**
     * 从命名参数 start 指定的位置开始查找。
     * @param value 区分大小写的目标文本。
     * @param start 起始位置，允许等于 size。
     * @return 第一个匹配索引；找不到则返回 None。
     * @throws IllegalArgumentException start 小于零或大于 size。
     */
    public func find(value: String, start!: Int64): ?Int64 {
        if (start < 0 || start > values.size) { throw IllegalArgumentException("invalid start") }
        for (index in start..values.size) { if (values[index] == value) { return Some(index) } }
        None
    }

    /**
     * 用显式分隔符连接条目；空目录返回空字符串。
     * @param separator 分隔符，默认是逗号，不进行转义。
     * @return 连接后的文本，不声称这是 CSV 编码。
     */
    public func join(separator!: String = ","): String {
        let output = StringBuilder()
        for (index in 0..values.size) {
            if (index > 0) { output.append(separator) }
            output.append(values[index])
        }
        output.toString()
    }

    /**
     * 按默认分页参数复制一个窗口，保留可选类型信息。
     * @param start 窗口起始位置，默认为零。
     * @param limit 最大条目数，默认为二十。
     * @return 长度不超过 limit 的可选文本数组，数组内实际返回 Some。
     * @throws IllegalArgumentException start 不在 0..=size 或 limit 小于零。
     */
    public func window(start!: Int64 = 0, limit!: Int64 = 20): Array<?String> {
        if (start < 0 || start > values.size || limit < 0) { throw IllegalArgumentException("invalid window") }
        let output = ArrayList<?String>()
        var index = start
        while (index < values.size && output.size < limit) {
            output.add(Some(values[index]))
            index++
        }
        output.toArray()
    }

    /**
     * 把条目分组，展示嵌套泛型返回值。
     * @param width 每组最多的条目数，默认为二。
     * @return 每个内部数组都是独立快照，末组可以短于 width。
     * @throws IllegalArgumentException width 不大于零。
     */
    public func chunks(width!: Int64 = 2): Array<Array<String>> {
        if (width <= 0) { throw IllegalArgumentException("width must be positive") }
        let result = ArrayList<Array<String>>()
        var index: Int64 = 0
        while (index < values.size) {
            let group = ArrayList<String>()
            while (index < values.size && group.size < width) {
                group.add(values[index])
                index++
            }
            result.add(group.toArray())
        }
        result.toArray()
    }

    /**
     * 计算相等条目数，不移除重复值。
     * @param value 要计数的文本。
     * @return 完全相等的条目数。
     */
    public func count(value: String): Int64 {
        var total: Int64 = 0
        for (entry in values) { if (entry == value) { total++ } }
        total
    }

    /**
     * 复制满足前缀条件的条目。
     * @param prefix 区分大小写的前缀。
     * @return 所有匹配条目，保持顺序；空前缀匹配全部。
     */
    public func startingWith(prefix: String): Array<String> {
        let result = ArrayList<String>()
        for (entry in values) { if (entry.startsWith(prefix)) { result.add(entry) } }
        result.toArray()
    }

    /**
     * 判断另一个数组是否与当前目录逐项相等。
     * @param entries 要比较的数组。
     * @return 长度和每一项都相等时返回 true。
     */
    public func equalsEntries(entries: Array<String>): Bool {
        if (entries.size != values.size) { return false }
        for (index in 0..values.size) { if (entries[index] != values[index]) { return false } }
        true
    }

    /**
     * 复制所有非空条目，作为 demo-v2 新增的 API。
     * @return 保持插入顺序的新数组，不修改原目录。
     */
    public func nonEmpty(): Array<String> {
        let result = ArrayList<String>()
        for (entry in values) { if (!entry.isEmpty()) { result.add(entry) } }
        result.toArray()
    }
}

/** 本地标签 / Local stamp，与独立依赖中的 pocket_support.Stamp 身份不同。 */
public struct Stamp {
    /** 标签文字。 */
    public let text: String
    /** @param text 标签文字。 */
    public init(text: String) { this.text = text }
}

/** 按值保存的通用条目，不复制 T 所引用的对象。 */
public class Entry<T> {
    /** 保存的值。 */
    public let value: T
    /** @param value 要保存的值。 */
    public init(value: T) { this.value = value }
}

/** 文本专用扩展；目标约束是 Entry<String>，不推断其他实例也适用。 */
extend Entry<String> {
    /** @return 保存文本的 UTF-8 字节数，而不是 Unicode 标量数。 */
    public func byteLength(): Int64 { value.size }
}
