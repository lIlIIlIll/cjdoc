# 为 API 和指南发布中英文

延续 `docdemo`，给相同 API 的字段和相同指南的章节提供作者译文。`--locale` 选择界面标签和已有作者译文，**不会自动翻译**。

## 前提与起点

完成[加入指南](add-guides.md)，在同一个 `docdemo/` 根目录开始。保留该教程的 `cjpm.toml`、`docs/index.md`、`docs/packages/docdemo.md` 和 `docs/images/hello.png`。以下完整替换 `src/api.cj`、`cjdoc.toml`，创建两份语言指南，再删除已被替换的 `docs/start.md`。SDK 1.2.0 和已安装 cjdoc 保持同一终端环境。

## 1. 为同一声明提供译文

完整 `src/api.cj`：

~~~cangjie
package docdemo

/**
 * 为名字生成问候语。
 *
 * name 原样保留，不修剪空白；空字符串返回 `Hello, !`。
 * @summary[lang=en] Creates a greeting for a name.
 * @description[lang=en] Preserves name without trimming; an empty name returns `Hello, !`.
 * @param name 要问候的名字，可以为空。
 * @param[lang=en] name The name to greet; may be empty.
 * @return 格式为 `Hello, <name>!` 的字符串。
 * @return[lang=en] A string in the form `Hello, <name>!`.
 * @example 问候仓颉 {must-pass run}
 * ```cangjie
 * println(greet("Cangjie"))
 * ```
 * ```output
 * Hello, Cangjie!
 * ```
 * @example[lang=en] Greet Cangjie {must-pass run}
 * ```cangjie
 * println(greet("Cangjie"))
 * ```
 * ```output
 * Hello, Cangjie!
 * ```
 */
public func greet(name: String): String {
    return "Hello, ${name}!"
}

private func internalGreeting(): String {
    return "internal"
}
~~~

语言属性紧贴标签，不加空格或引号。摘要、描述、参数、返回与示例各自维护，代码围栏语言与示例指令不翻译。异常要描述真实会抛出的行为；完整 `clamp` 实现、非法边界与显式 throws ID 配对见[注释参考](../reference/doc-comments.md)。不要给仅拼接字符串的 `greet` 编造异常。

## 2. 登记语言和等价章节

完整替换 `cjdoc.toml`：

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

同一 `id` 表示同一逻辑页；同一章节键表示等价章节，值是各自 Markdown 标题的实际锚点，不是原始标题文本。`First greeting` 的锚点是 `first-greeting`，`Name boundaries` 的锚点是 `name-boundaries`；中文标题在本例中保持原样。目录名称本身不建立配对。[docs].index 首页只有一份，两种语言都会看到同一首页，并标注作者来源；本教程不承诺首页翻译。锚点规则和重复标题的后缀见[配置参考](../reference/configuration.md#docspagessections多语言章节锚点)。

## 3. 写两份完整指南

在项目根执行：

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

输出 `Hello, Cangjie!`。

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

Prints `Hello, Cangjie!`.

## Name boundaries

An empty name produces `Hello, !`. Whitespace is preserved.

[Project overview](../index.md).

<!-- cjdoc-bind target="docdemo.greet" -->
~~~

先完成两份文件，再在项目根删除已不使用的旧指南 `docs/start.md`。将共享首页和包概述中的相对链接分别改为 `zh-CN/start.md` 和 `../zh-CN/start.md`；这两份共享内容使用显式中文目标，不冒充语言自适应链接。只修改链接，其他正文保留。

## 4. 生成、切换并观察缺译

在项目根执行：

```bash
cjpm build
cjdoc check --project . --check-examples
cjdoc generate --project . --format html --format coverage --all-languages
xdg-open target/doc/html/zh-CN/index.html
```

两个站点入口分别为 `html/zh-CN/index.html` 和 `html/en/index.html`。进入 `greet`，在页头语言标签内切换，确认参数和返回说明跟随切换；不是独立的“zh-CN”导航项。进入指南“名字的边界”，通过语言标签切换，应落到 `Name boundaries` 等价章节，而不是猜测英文 fragment。两份指南都绑定相同 API，双向关联可用。

`coverage/translations.json` 报告字段状态；共享首页和中文包概述并没有因此获得英文译文。两个 `@example` 没有可证明的跨语言身份，按独立条目保留，可能出现 `CJDOC3107` 和 `unpaired`/缺译警告；标题相似、顺序相同都不构成配对。本教程验证的是参数、返回与指南章节的作者译文，不声称全部内容已完整翻译。只生成英文可用：

```bash
cjdoc generate --project . --format html --locale en --output target/doc-en
```

用副本观察缺译：删掉英文 `@return[lang=en]` 那一行再生成英文，返回说明回退中文并显示来源，报告不再记为已翻译。恢复该行再继续。空译文不是有效译文；同字段重复提供冲突译文会报告冲突，不能把“存在标签”当作完整翻译。`missing-translation = "deny"` 或 `--require-language` 可用于发布门槛，完整语义见[配置](../reference/configuration.md)与[状态参考](../reference/states-and-limits.md)。

## 下一步

- [发布整个站点，而不是只上传一个语言目录](../how-to/generate-and-publish.md)。
- [比较不同源码的版本并合站](../how-to/compare-and-version.md)。
