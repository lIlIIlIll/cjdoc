package source_edges_fixture

/** 中文摘要。 */ public func 解析(文本: String): String { 文本 }

/** Public owner. */
public open class PublicOwner {
    /** Protected API. */
    protected func inherited(): Unit {}

    private func hidden(): Unit {}
}

private class PrivateOwner {
    public func mustNotLeak(): Unit {}
}
