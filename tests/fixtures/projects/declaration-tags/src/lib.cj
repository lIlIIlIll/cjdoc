package declaration_tags

/**
 * 流式读取器。
 * @summary[lang=en] Streaming reader.
 * @group 10-query 查询入口
 * @tag stream
 * @tag stable
 */
public class StreamReader {
    /**
     * 读取指定数量。
     * @summary[lang=en] Read a fixed count.
     * @param count 请求数量。
     * @param[lang=en] count Requested count.
     * @return 读取数量。
     * @return[lang=en] The read count.
     * @group 10-query 查询入口
     * @tag stream
     * @tag stable
     * @tag stream
     */
    public func read(count: Int64): Int64 { count }

    /**
     * 读取文本。
     * @summary[lang=en] Read text.
     * @param text 输入文本。
     * @param[lang=en] text Input text.
     * @return 原文本。
     * @return[lang=en] The input text.
     * @group 10-query 查询入口
     * @tag stream
     */
    public func read(text: String): String { text }

    /**
     * 读取字节。
     * @summary[lang=en] Read bytes.
     * @param bytes 输入字节。
     * @param[lang=en] bytes Input bytes.
     * @return 字节数量。
     * @return[lang=en] The byte count.
     * @group 10-query 查询入口
     * @tag Stream
     */
    public func read(bytes: Array<UInt8>): Int64 { Int64(bytes.size) }

    /**
     * 无标签成员不继承所有者标签。
     * @summary[lang=en] An untagged member does not inherit owner tags.
     */
    public func untagged(): Unit {}

    /**
     * 读取器名称。
     * @summary[lang=en] The reader name.
     * @group 20-state 状态
     * @tag stable
     */
    public prop name: String { get() { "reader" } }
}

/**
 * 另一个声明容器。
 * @summary[lang=en] A distinct declaration container.
 * @group 20-state 状态
 */
public class OtherReader {
    /**
     * 独立所有者的同名成员。
     * @summary[lang=en] A same-named member owned by a distinct declaration.
     * @param count 输入数量。
     * @param[lang=en] count Input count.
     * @return 原数量。
     * @return[lang=en] The input count.
     * @group 10-query 查询入口
     * @tag stream
     */
    public func read(count: Int64): Int64 { count }
}

/**
 * 前缀相近但不同的标签。
 * @summary[lang=en] A distinct tag with a similar prefix.
 * @tag streaming
 */
public func streamingOnly(): Unit {}

/**
 * ASCII 大小写是标签身份的一部分。
 * @summary[lang=en] ASCII case is part of tag identity.
 * @tag Stream
 */
public func upperCaseOnly(): Unit {}

/**
 * 不可见的词典成员。
 * @tag secret
 * @tag stream
 */
private func hidden(): Unit {}
