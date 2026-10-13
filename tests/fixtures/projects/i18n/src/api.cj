package language_fixture

/**
 * 计算两个整数的和。
 * @summary[lang=en] Adds two integers.
 * @param left 左侧数值。
 * @param[lang=en] left The left operand.
 * @param right 右侧数值。
 * @return 两数之和。
 * @return[lang=en] The sum of the two operands.
 */
public func add(left: Int64, right: Int64): Int64 {
    left + right
}

/**
 * 保存一个整数的运算器。
 * @summary[lang=en] Stores an integer for arithmetic.
 */
public class Calculator {
    /**
     * 增加一个整数。
     * @summary[lang=en] Increment by an integer. Sapphire arithmetic marker.
     * @param value 增量。
     * @param[lang=en] value The increment.
     * @return 增量的整数值。
     * @return[lang=en] The integer increment.
     */
    public func increment(value: Int64): Int64 { value }

    /**
     * 读取文本长度。
     * @summary[lang=en] Read the text length.
     * @param value 文本。
     * @param[lang=en] value The text.
     * @return 字节数。
     * @return[lang=en] The number of bytes.
     */
    public func increment(value: String): Int64 { value.size }

    /**
     * 私有中文标记，不能进入公开索引。
     * @summary[lang=en] HiddenArithmeticalKeyword.
     */
    private func hidden(): Int64 { 0 }
}
