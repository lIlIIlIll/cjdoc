package pocketkit.io

/** 内存行阅读接口 / A finite, explicitly closed sequence of text lines. */
public interface Readable {
    /** @return 下一行；没有更多数据时返回 None。 */
    func read(): ?String
    /** 释放会话状态。此接口不规定系统文件描述符的所有权。 */
    func close(): Unit
}

/**
 * 按换行符读取内存文本，显式展示资源责任。
 *
 * 构造时复制拆分后的行数组；调用方拥有此阅读会话。close 可重复调用，关闭后
 * read 和 rewind 抛出异常。没有文件描述符、网络连接或后台线程需要销毁。
 * 不提供内部同步，调用方不得在多个线程间无同步地共享可变读取位置。
 *
 * @state 读到末尾时 `read()` 返回 `None`，会话仍然打开。
 * @state[lang=en] At EOF, `read()` returns `None` and the session stays open.
 * @invariant 会话一旦关闭就不会重新打开。
 * @invariant[lang=en] Once closed, the session never reopens.
 * @concurrency 多个线程共享读取位置时，调用方必须同步访问。
 * @concurrency[lang=en] Callers must synchronize access when sharing the cursor across threads.
 * @platform 只读内存文本，不打开文件句柄。
 * @platform[lang=en] Reads in-memory text without opening a file handle.
 * @see pocketkit.io.Readable
 * @example 读取并关闭会话 {run}
 * ```cangjie
 * let reader = openText("first\nsecond")
 * println(reader.read().getOrThrow())
 * println(reader.read().getOrThrow())
 * println("eof: ${reader.read().isNone()}")
 * reader.close()
 * reader.close()
 * println("closed: ${reader.closed}")
 * ```
 *
 * **预期输出 / Expected output**
 *
 * ```output
 * first
 * second
 * eof: true
 * closed: true
 * ```
 */
public class TextReader <: Readable {
    private let lines: Array<String>
    private var position: Int64 = 0
    private var isClosed: Bool = false

    /**
     * 创建内存阅读会话。
     * @param text 以换行分隔的文本；空文本表示没有行。
     */
    public init(text: String) {
        lines = if (text.isEmpty()) { Array<String>() } else { text.split("\n") }
    }

    /** 会话是否已经显式关闭。 */
    public prop closed: Bool { get() { isClosed } }

    /**
     * 读取并前进一行 / Read and advance one line.
     * @return 下一行，读取结束时返回 None。
     * @throws IllegalStateException 会话已经关闭。
     * @postcondition 成功读取时 position 增加一；结束时不再前进。
     * @group 10-cursor 读取位置
     * @tag cursor
     * @tag reading
     * @tag cursor
     */
    public func read(): ?String {
        if (isClosed) { throw IllegalStateException("reader is closed") }
        if (position >= lines.size) { return None }
        let line = lines[position]
        position++
        Some(line)
    }

    /**
     * 回到第一行。
     * @throws IllegalStateException 会话已经关闭。
     * @group 10-cursor
     * @tag cursor
     */
    public func rewind(): Unit {
        if (isClosed) { throw IllegalStateException("reader is closed") }
        position = 0
    }

    /**
     * 幂等关闭内存阅读会话；不会关闭操作系统资源。
     * @postcondition closed 为 true；再次 close 不抛异常。
     */
    public func close(): Unit { isClosed = true }
}

/**
 * 创建一个必须由调用方关闭的内存阅读会话。
 * 返回类型 {@link pocketkit.io.TextReader} 实现 {@link pocketkit.io.Readable}。
 * @param text 输入文本，不打开磁盘文件。
 * @return 调用方拥有的 TextReader。
 */
public func openText(text: String): TextReader { TextReader(text) }

/** IO 标签，与 pocketkit.parsing.Token 同名但作用域不同。 */
public struct Token {
    /** IO 标签正文。 */
    public let label: String
    /** @param label 标签正文。 */
    public init(label: String) { this.label = label }
}
