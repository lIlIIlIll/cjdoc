package pocketkit.io

/**
 * 示例包自带的条件检查，不是语言内建 assert / An example-owned assertion helper.
 * @param condition 必须成立的条件。
 * @throws IllegalStateException condition 为 false。
 */
public func assert(condition: Bool): Unit {
    if (!condition) { throw IllegalStateException("PocketKit reader assertion failed") }
}
