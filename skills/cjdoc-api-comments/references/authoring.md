# cjdoc 注释写法

<!-- 由 scripts/sync_api_comment_skill.py 同步，请勿手改。 -->

## 1. 为一个 API 写注释

~~~cangjie
package demo

/**
 * 为名字生成问候语。
 *
 * 名字里的空白原样保留，允许空字符串。
 *
 * @param name 要问候的名字。
 * @return 格式为 `Hello, <name>!` 的字符串。
 * @example 问候普通名字和空名字 {must-pass run}
 * ```cangjie
 * println(greet("Cangjie"))
 * println(greet(""))
 * ```
 * ```output
 * Hello, Cangjie!
 * Hello, !
 * ```
 */
public func greet(name: String): String {
    return "Hello, ${name}!"
}
~~~

## 行为契约

| 写法 | 显示的约定 | PocketKit 示例 |
|---|---|---|
| `@precondition 0 <= index < size。` | 调用前的必要条件 | `TextCatalog.at` |
| `@postcondition size 比调用前增加一。` | 成功调用后成立的条件 | `TextCatalog.add(String)` |
| `@invariant 会话一旦关闭就不会重新打开。` | 始终成立的约束 | `TextReader` |
| `@performance 最多检查 size 个条目。` | 时间、空间或工作量边界 | `TextCatalog.contains` |
| `@state 读到末尾时 read() 返回 None，会话仍然打开。` | 状态或状态转换 | `TextReader` |
| `@concurrency 多个线程共享读取位置时，调用方必须同步访问。` | 并发使用责任 | `TextReader` |
| `@platform 只读内存文本，不打开文件句柄。` | 平台或环境条件 | `TextReader` |
| `@compatibility 旧的单参数调用仍有效，使用默认的十进制。` | 旧用法与兼容条件 | `TextCatalog.add(Int64, radix:)` |
| `@error radix 不是 10 时，不追加任何条目。` | 失败时的可见行为；具体异常用 `@throws` | `TextCatalog.add(Int64, radix:)` |

## 在同一声明里写多个提示

```text
@note 连接结果保留条目的插入顺序。
@note 分隔符可以包含多个字符。
@warning 连接时不会转义条目内容，不能代替 CSV 编码器。
@danger 不要用连接结果覆盖原始条目；不同条目可能产生相同结果。
```

## 多语言注释

```cangjie
/**
 * @summary 将 value 限制在区间内。
 * @summary[lang=en] Clamp value to an interval.
 * @param value 待限制的值。
 * @param[lang=en] value The value to clamp.
 * @return 限制后的值。
 * @return[lang=en] The clamped value.
 */
```

## 参数与返回值

```text
@param index 从零开始的索引。
@param[lang=en] index The zero-based index.
@return 保存在该位置的文本。
@return[lang=en] The text stored at that position.
@throws[id=index-range] IllegalArgumentException `index` 小于 0 或大于等于 `size`。
@throws[lang=en,id=index-range] IllegalArgumentException `index` is negative or is not smaller than `size`.
```

## 示例与输出

~~~text
@example 按位置与上限取窗口 {run}
```cangjie
let catalog = TextCatalog(["a", "b", "c", "d"])
```
```cangjie
let page = catalog.window(start: 1, limit: 2)
for (entry in page) {
    println(entry.getOrThrow())
}
```

**预期输出 / Expected output**

```output
b
c
```
~~~

## 弃用与版本

```text
@summary 读取首项；目录为空或首项为空字符串时抛出异常。
@description 这个旧式入口把两种缺失情况转换为异常。

它只读取第一项，不会跳过空条目去找下一项。

- 空目录没有第一项。
- 空字符串是已有条目，但不能作为结果返回。

@param catalog 要读取的文本目录。
@return 第一条文本，原样返回且不为空。
@throws[id=empty-catalogue] IllegalStateException 目录中没有条目。
@throws[id=blank-entry] IllegalArgumentException 第一条文本是空字符串。
@replacement pocketkit.TextCatalog.first
@deprecated 调用 `catalog.first()` 后分别处理三种结果：

- `None`：目录没有条目。
- `Some("")`：首项存在，但内容为空。
- `Some(text)`：首项非空，取出 `text`。

@see pocketkit.TextCatalog.first
@see pocketkit.TextCatalog.isEmpty
@since 0.2.0
@author PocketKit
@author Documentation team
@version example-1
```

## 分组与分类

```text
@group 10-cursor 读取位置
@tag cursor
@tag reading
@tag cursor
```

## 提供译文

```toml
[i18n]
default-language = "zh-CN"
languages = ["zh-CN", "en"]
missing-translation = "warn"
```

