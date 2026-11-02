package admonitions_fixture

/**
 * Holds serialized cache state.
 *
 * > [!NOTE]
 * > A cache entry is a hint, not a source of truth.
 * > Its contents may be discarded at any time.
 */
public class Cache {
    /**
     * Apply one cache update.
     * @warning[lang=en,id=write-window] Revalidate the source before committing. AdmonitionSearchSentinel
     * Use the same revision that was used during capture.
     * @danger[lang=zh-CN,id=publish-window] Never publish a partial captured result.
     */
    public func commit(): Unit {}
}
