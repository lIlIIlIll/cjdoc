# 为 API 和指南发布中英文

给同一份 API 注释和同一篇指南分别提供中文、英文正文，读者就能在页头的语言标签里切换语言，并在等价的指南章节之间跳转。`--locale` 只选择界面标签和已存在的作者译文，**不会自动翻译**：要看到英文，必须由你写出英文。

## 前提

- 已完成[加入指南](add-guides.md)，在同一个 `docdemo/` 根目录继续。
- 保留现有的 `cjpm.toml`、`docs/index.md`、`docs/packages/docdemo.md` 和 `docs/images/hello.png`。
- 当前终端里的 `cjdoc` 和仓颉 SDK 环境仍可用。

本页会完整替换 `src/api.cj` 和 `cjdoc.toml`，新增两份分语言指南，并删除已被替换的 `docs/start.md`。

## 1. 为 `greet` 提供两种语言的注释

把 `src/api.cj` 完整替换为：

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

语言属性紧贴标签名，中间不加空格、不加引号；不带语言属性的部分就是默认语言正文。摘要、详细说明、参数、返回和示例各自独立维护，代码围栏里的语言标记和 `{must-pass run}` 之类指令不翻译。

需要为真实的异常行为提供两种语言说明时，见[注释参考的 `clamp` 示例](../reference/doc-comments.md#完整的-clamp-throws-示例)。

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

两份指南通过下一步的稳定章节键关联对应小节，不靠标题文字或排列顺序判断。两种语言都保留 `cjdoc-bind`，这样读者能在指南和 `greet` 之间来回跳转。

共享的首页和包概述只有一份，两种语言的读者都会看到它。把其中指向指南的相对链接改成显式的中文目标：`docs/index.md` 里的 `start.md` 改为 `zh-CN/start.md`，`docs/packages/docdemo.md` 里的 `../start.md` 改为 `../zh-CN/start.md`。只改链接，其余正文保持不变；首页不做翻译，也不自动跟随语言。

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

两条 `[[docs.pages]]` 使用同一个 `id`，表示它们是同一篇逻辑页的不同语言版本，因此共用同一个路由。`[docs.pages.sections]` 两侧语言用同一个章节键，右边填各自标题的实际锚点：英文 `First greeting` 的锚点是 `first-greeting`，`Name boundaries` 的锚点是 `name-boundaries`。章节键是作者维护的稳定名，锚点跟着标题变化；目录名相同本身不建立任何配对。

`missing-translation = "warn"` 会在缺译时给出警告；改成 `"deny"` 会把缺译升级为错误，作为发布门槛。`[i18n]` 的语言列表约束、`[docs.pages.sections]` 的锚点规则和重复标题的后缀见[配置参考](../reference/configuration.md)。

新配置已经指向两份分语言指南，现在可以删除被替换的旧文件：

```bash
rm docs/start.md
```

## 4. 生成双语站点并切换语言

在项目根执行：

```bash
cjpm build
cjdoc check --project . --check-examples
cjdoc generate --project . --format html --format coverage --all-languages
xdg-open target/doc/html/zh-CN/index.html
```

`--all-languages` 按配置里的语言各生成一棵 HTML 文档树，入口分别是 `target/doc/html/zh-CN/index.html` 和 `target/doc/html/en/index.html`。

进入 `greet` 页面，在页头的语言标签上点击展开，再选择另一种语言。切换语言就在这个标签里完成，不会另外出现一个独立的语言导航项。切换后参数、返回和示例说明应随之变成另一种语言；再打开指南的“名字的边界”小节并切换语言，应落到英文的 `Name boundaries`，而不是猜一个英文片段。

`target/doc/coverage/translations.json` 是这次生成的翻译覆盖报告。共享首页和包概述没有英文译文，会在报告里体现出来，这是预期结果。

两个 `@example` 的跨语言关系无法从正文唯一证明，会各自按独立条目保留，可能出现 `unpaired` 或 `CJDOC3107` 一类的提示；标题相似、顺序相同都不构成配对依据。

只发布英文站点时省略 `--all-languages`：

```bash
cjdoc generate --project . --format html --locale en --output target/doc-en
```

入口是 `target/doc-en/html/index.html`，页面里没有语言切换需要的另一份站点，因此只适合单独发布某一种语言。

## 5. 在副本里观察缺译

想在不动主项目的前提下确认缺译报告，复制整个项目再改。先建一个临时父目录：

```bash
mkdir -p "$HOME/cjdoc-practice"
MISSING_ROOT="$(mktemp -d "$HOME/cjdoc-practice/missing-demo.XXXXXX")"
cp -R . "$MISSING_ROOT/docdemo"
cd "$MISSING_ROOT/docdemo"
```

在副本的 `src/api.cj` 中删除 `@return[lang=en] A string in the form ...` 这一行，然后重新生成英文站点与覆盖报告：

```bash
cjdoc generate --project . --format html --format coverage --locale en --output target/doc-en-missing
xdg-open target/doc-en-missing/html/index.html
```

打开 `target/doc-en-missing/html/index.html` 里的 `greet`，返回说明会回退为中文原文，并标注“暂无当前语言翻译，原文：zh-CN”。再看本次生成的 `target/doc-en-missing/coverage/translations.json`：该返回字段的 `state` 不再是 `complete`，对应的回退计数增加。

看报告时注意：

- 只读取这次命令新写出的 `translations.json`，不要拿上一次生成的报告代替。
- 空译文不算有效译文；同一字段在同一语言重复提供了不同内容会报告冲突，不能因为“有语言标签”就当成完整翻译。
- 主项目没有受到影响，确认完可以删除整个副本目录。

## 遇到问题怎么办

- **切换语言后仍是中文**：确认该字段写了 `[lang=en]` 译文，且 `[i18n]` 中 `languages` 包含 `en`。
- **生成后没有英文目录**：检查是否使用了 `--all-languages`；只给 `--locale en` 时不会产生分语言目录。
- **章节切换落到了页首**：目标语言页里没有对应的章节锚点，检查两边 `[docs.pages.sections]` 是否登记了该章节键，以及右侧锚点是否与标题实际生成的一致。
- **生成因缺译失败**：当前配置可能是 `missing-translation = "deny"`，或使用了 `--require-language`。补齐译文，或按发布策略调整门槛，语义见[状态参考](../reference/states-and-limits.md)。

## 下一步

- [发布整个站点，而不是只上传一个语言目录](../how-to/generate-and-publish.md)。
- [比较不同源码的版本并合站](../how-to/compare-and-version.md)。
