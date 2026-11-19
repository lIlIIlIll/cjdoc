package pocketkit.authoring

import pocketkit.TextCatalog

/**
 * @summary 读取第一条非空文本；仅用于演示文档注释。
 * @description 这个旧式入口把两种缺失情况转换为异常。新代码应直接调用 `catalog.first()`。
 *
 * 它只读取第一项，不会跳过空条目去找下一项。
 *
 * - 空目录没有第一项。
 * - 空字符串是已有条目，但不能作为结果返回。
 *
 * @summary[lang=en] Read the first entry if it is non-empty; a documentation example only.
 * @description[lang=en] This legacy entry point turns two missing-value cases into exceptions. Call `catalog.first()` in new code.
 *
 * It reads only the first entry and never skips a blank entry to look for the next one.
 *
 * - An empty catalogue has no first entry.
 * - An empty string is an entry, but cannot be returned by this function.
 *
 * @param catalog 要读取的文本目录。
 * @param[lang=en] catalog The text catalogue to read.
 * @return 第一条文本，原样返回且不为空。
 * @return[lang=en] The first entry, unchanged and non-empty.
 * @throws[id=empty-catalogue] IllegalStateException 目录中没有条目。
 * @throws[lang=en,id=empty-catalogue] IllegalStateException The catalogue has no entries.
 * @throws[id=blank-entry] IllegalArgumentException 第一条文本是空字符串。
 * @throws[lang=en,id=blank-entry] IllegalArgumentException The first entry is an empty string.
 * @deprecated 改用 `catalog.first()`：`None` 表示空目录，`Some("")` 表示首项为空；按调用方需要分别处理，其他 `Some(text)` 直接取出 `text`。
 * @deprecated[lang=en] Use `catalog.first()`. Handle `None` (empty catalogue) and `Some("")` (empty first entry) separately; unwrap `text` from any other `Some(text)`.
 * @see pocketkit.TextCatalog.first
 * @see pocketkit.TextCatalog.isEmpty
 * @since 0.2.0
 * @author PocketKit
 * @author Documentation team
 * @version example-1
 * @example 首项与两种异常 {run}
 * ```cangjie
 * println(requireFirstText(TextCatalog(["alpha"])))
 * try {
 *     let _ = requireFirstText(TextCatalog())
 *     throw IllegalArgumentException("expected an empty-catalogue exception")
 * } catch (_: IllegalStateException) {
 *     println("empty: IllegalStateException")
 * }
 * try {
 *     let _ = requireFirstText(TextCatalog([""]))
 *     throw IllegalStateException("expected a blank-entry exception")
 * } catch (_: IllegalArgumentException) {
 *     println("blank: IllegalArgumentException")
 * }
 * ```
 *
 * **预期输出 / Expected output**
 *
 * ```output
 * alpha
 * empty: IllegalStateException
 * blank: IllegalArgumentException
 * ```
 * @example 只编译，不运行 {must-pass flags="-O0"}
 * 预期编译通过；不执行这条 `throw`。
 *
 * ```cangjie
 * throw IllegalStateException("compile only")
 * ```
 * @example 不存在的 API {must-fail error="missingApi"}
 * 预期片段编译失败，且诊断包含 `missingApi`。
 *
 * ```cangjie
 * missingApi()
 * ```
 * @example 不打印也可以核对输出 {run}
 * ```cangjie
 * let _ = requireFirstText(TextCatalog(["ok"]))
 * ```
 *
 * **预期输出 / Expected output**
 *
 * 空围栏要求没有标准输出，省略围栏则不比较标准输出。
 *
 * ```output
 * ```
 */
public func requireFirstText(catalog: TextCatalog): String {
    match (catalog.first()) {
        case None => throw IllegalStateException("empty catalogue")
        case Some("") => throw IllegalArgumentException("empty first entry")
        case Some(text) => text
    }
}
