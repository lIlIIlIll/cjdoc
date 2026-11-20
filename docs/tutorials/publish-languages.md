# 为 API 和指南发布中英文

为 `greet` 和「开始使用」指南提供中英文内容。读者切换语言时，仍能留在同一个 API 或指南小节。`--locale` 只选择界面和作者提供的译文，不会自动翻译。

## 前提条件

在[加入首页和指南](add-guides.md)做完的 `docdemo/` 继续，当前终端须能运行 `cjdoc` 和仓颉 SDK。下面会替换 `src/api.cj` 和 `cjdoc.toml`，并新增两份指南。首页、包概述和图片沿用原文件。

## 1. 为 `greet` 提供两种语言的注释

把 `src/api.cj` 完整替换为：

~~~cangjie
package docdemo

/**
 * 为名字生成问候语。
 *
 * 名字中的空白原样保留。
 * @summary[lang=en] Creates a greeting for a name.
 * @description[lang=en] Preserves whitespace in the name.
 * @param name 要问候的名字，可以为空。
 * @param[lang=en] name The name to greet; may be empty.
 * @return 格式为 `Hello, <name>!` 的字符串。
 * @return[lang=en] A string in the form `Hello, <name>!`.
 * @example 问候仓颉 {must-pass run}
 * ```cangjie
 * println(greet("Cangjie"))
 * println(greet(""))
 * ```
 * ```output
 * Hello, Cangjie!
 * Hello, !
 * ```
 * @example[lang=en] Greet Cangjie {must-pass run}
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

private func internalGreeting(): String {
    return "internal"
}
~~~

`[lang=en]` 紧贴标签名，不加引号。没有语言属性的正文属于默认语言。摘要和详细说明是不同字段：只写 `@summary[lang=en]` 不会翻译详细说明。代码和 `{must-pass run}` 指令保持原样。要翻译异常说明，可参照[`clamp` 示例](../reference/doc-comments.md#完整的-clamp-throws-示例)。

## 2. 写出两份等价的指南

中文和英文各要一份正文。先建目录：

```bash
mkdir -p docs/zh-CN docs/en
```

完整 `docs/zh-CN/start.md`：

~~~markdown
# 开始使用

## 第一次问候

```cangjie
println(greet("Cangjie"))
```

```output
Hello, Cangjie!
```

## 名字的边界

空字符串得到 `Hello, !`；空白原样保留。

[返回项目首页](../index.md)。

<!-- cjdoc-bind target="docdemo.greet" -->
~~~

完整 `docs/en/start.md`：

~~~markdown
# Get started

## First greeting

```cangjie
println(greet("Cangjie"))
```

```output
Hello, Cangjie!
```

## Name boundaries

An empty name produces `Hello, !`. Whitespace is preserved.

[Project overview](../index.md).

<!-- cjdoc-bind target="docdemo.greet" -->
~~~

两份指南都保留 `cjdoc-bind`，让读者能在指南和 `greet` 之间来回跳转。首页和包概述共用一份原文：把 `docs/index.md` 的 `start.md` 链接改成 `zh-CN/start.md`，把 `docs/packages/docdemo.md` 的 `../start.md` 改成 `../zh-CN/start.md`。旧 `docs/start.md` 不再登记，无需删除。

## 3. 登记语言和等价章节

把 `cjdoc.toml` 完整替换为：

```toml
[i18n]
default-language = "zh-CN"
languages = ["zh-CN", "en"]
missing-translation = "warn"

[docs]
index = "docs/index.md"

[docs.packages]
docdemo = "docs/packages/docdemo.md"

[[docs.pages]]
id = "start"
language = "zh-CN"
source = "docs/zh-CN/start.md"
route = "concepts/guides/start.html"
kind = "guide"
[docs.pages.sections]
usage = "第一次问候"
boundaries = "名字的边界"

[[docs.pages]]
id = "start"
language = "en"
source = "docs/en/start.md"
route = "concepts/guides/start.html"
kind = "guide"
[docs.pages.sections]
usage = "first-greeting"
boundaries = "name-boundaries"
```

两份指南共用 `id` 和 `route`。`usage` 与 `boundaries` 在两边各出现一次，右边填写各自标题的短锚点。即使英文改了标题或移动了小节，只要页面标识和章节键相同，并更新对应锚点，语言切换仍能找到目标。详见[配置参考](../reference/configuration.md)。

## 4. 生成双语站点并切换语言

从项目根生成 HTML 和翻译覆盖报告：

```bash
cjdoc generate --project . --format html --format coverage --all-languages
```

打开 `target/doc/html/zh-CN/index.html`，进入 `greet`，再在页头语言标签上切换到 English。参数和返回值应显示英文。打开指南的「名字的边界」小节再切换，英文页面应落到 `Name boundaries`，而不是页首。

这个练习没有翻译首页和包概述，英文站点会回退到原文。两条 `@example` 各自保留，可能报告 `CJDOC3107`：语言属性、标题和顺序并不构成示例一一配对的依据。用 `cjdoc check --project . --check-examples` 可检查两条示例。

打开 `target/doc/coverage/translations.json` 检查 `state`：`complete` 表示有当前语言的内容，`fallback` 表示显示原文，`unpaired` 表示不能配对；文件顶部的 `translated`、`fallback`、`unpaired` 等计数是该语言的汇总。设置 `missing-translation = "deny"` 可把缺译设为失败；以退出码为准，即使失败也可能写出站点。

通过 HTTP 发布时，中文是本例的默认语言，`greet` 的公开地址是 `<站点根>/docdemo/greet/`，英文地址是 `<站点根>/en/docdemo/greet/`。离线打开或复制链接时，地址保留尾部的 `index.html`。发布时复制共同的 `html/` 目录，不要分别发布两个语言目录。

### 只发布英文

```bash
cjdoc generate --project . --format html --locale en --output target/doc-en
```

入口为 `target/doc-en/html/index.html`。这次没有生成另一种语言，页头不提供语言切换。

## 5. 在副本里观察缺译

复制练习项目，在副本的 `src/api.cj` 删除 `@return[lang=en]` 一行。从副本根目录生成：

```bash
cjdoc generate --project . --format html --format coverage --locale en --output target/doc-en-missing
```

打开 `target/doc-en-missing/html/index.html` 中的 `greet`。返回值说明应回退到中文，并标记 `Translation missing. Original text: zh-CN`；同一次生成的 `coverage/translations.json` 中该字段应为 `fallback`。空译文不算已翻译，同一字段同一语言的不同内容会报告冲突。

## 失败时怎么办

| 看到什么 | 怎么处理 |
|---|---|
| 切换后某段仍是中文 | 补该字段的 `[lang=en]` 内容，并确认 `languages` 包含 `en` |
| 没有 `en/` | 用 `--all-languages` 生成目录；它要求显式配置 `[i18n].languages`。只用 `--locale en` 时入口在 `html/` 下 |
| 切换后落到页首，或有 `CJDOC3110` | 检查两份指南的 `id`、章节键和实际标题锚点 |
| `CJDOC3108` 或 `CJDOC3111` 使生成失败 | 补齐缺译，或检查 `missing-translation` 和 `--require-language` 的发布要求；不要只凭文件存在判断通过 |

发布时上传共同的 `target/doc/html/` 根目录，不能只上传其中一种语言。见[生成与发布](../how-to/generate-and-publish.md)。
