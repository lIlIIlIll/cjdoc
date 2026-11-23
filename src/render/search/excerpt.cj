protected package cjdoc.render.search

import cjdoc.render.foundation.RenderTextBuffer

/**
 * Bound a search preview by Unicode scalar count, including a final ellipsis
 * only when truncated. Native and static search share this display policy;
 * byte-limited response and contract budgets are enforced separately.
 */
public func searchTextExcerpt(value: String, maximum!: Int64): String {
    if (maximum <= 0) { return "" }
    if (value.size <= maximum) { return value }
    let out = RenderTextBuffer()
    var count: Int64 = 0
    var pending: ?Rune = None
    for (rune in value.runes()) {
        if (count < maximum - 1) {
            out.append(rune)
            count++
        } else if (count == maximum - 1) {
            pending = Some(rune)
            count++
        } else {
            out.append("…")
            return out.toString()
        }
    }
    if (let Some(last) <- pending) { out.append(last) }
    out.toString()
}
