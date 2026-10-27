# 概念页与指南

cjdoc 除了生成 API 参考，还能把项目里的 Markdown 组织成概念文档：项目首页、模块页、包概述和自定义指南页。它们和 API 页面一起发布、一起搜索，并且可以把页面绑定到具体 API。配置键的完整说明见 [配置参考](configuration.md)。

## 概念页从哪里来

只要 `cjdoc.toml` 里出现 `[docs]`、`[[docs.pages]]` 或 `[docs.packages]` 中任意一个，cjdoc 就会生成概念文档。默认页面如下：

| 页面 | 源文件 | 路由 | 说明 |
|---|---|---|---|
| 项目首页 | `[docs].index`，默认 `docs/index.md` | `concepts/index.html` | 文件不存在时自动生成占位首页 |
| 模块页 | `docs/modules/<slug>.md` | `concepts/modules/<slug>.html` | 每个模块一页，包括 workspace 成员和纳入的依赖模块 |
| 包页 | `docs/packages/<slug>.md` | `concepts/packages/<slug>.html` | 每个包一页，可用 `[docs.packages]` 换源文件 |
| 自定义页面 | `[[docs.pages]].source` | 默认 `concepts/guides/<slug>.html` | 指南、说明、教程等 |

自动页面（首页、模块页、包页）的文件不存在时也会保留对应路由。在对应的默认路径放一个同名 Markdown 文件就能补充正文。HTML 不会把自动占位文字推荐为入门指南；缺少作者概述时提供中立说明和完整 API 入口。Doc IR 中的原始占位内容仍保留。

`<slug>` 由名称里的 ASCII 字母和数字组成，其他字符折叠成 `-`。例如包 `pocketkit-core` 对应 `docs/packages/pocketkit-core.md`，包 `std.collection` 对应 `docs/packages/std-collection.md`。跨平台使用时不要依赖其他字符的保真。

## 写项目首页

在 `[docs]` 里指定首页源文件即可，路径是项目内相对 `.md` 路径：

```toml
[docs]
index = "README.md"
```

首页正文就是普通 Markdown。第一个 `# ` 标题会作为概念页标题；API 首页以项目名为标题，并呈现这份正文，不重复显示文章的一级标题。

### 组织读者路径

首页适合按“用途 → 最小例子 → 下一步 → 必要边界”写作。HTML 会在第一个顶层代码块之后放置阅读入口；没有代码块时，入口放在介绍之后。完整包索引仍在首页，按声明种类组织的完整索引可展开查看。没有介绍或指南时直接使用 API 索引，无需添加填充文字。

用 `[[docs.pages]]` 的顺序表达阅读顺序。首页优先呈现首篇实际指南和有 API 绑定的指南，其他未绑定资料收进“其他资料”。模块或包的自动占位页不参与推荐。指南之间的上下篇入口也沿用作者顺序，不根据方法名推测任务。

类型注释应直接说明调用者需要的用途和限制，例如索引边界、允许的输入和同步责任。生成器如何查找外部索引、契约是否经过验证等说明，适合放进单独的教学或维护指南；不要把它们重复写进每个成员的使用说明。cjdoc 不会自动改写第三方作者的契约。

## 写包概述

包概述有两种绑定方式，选一种即可：

```toml
[docs.packages]
pocketkit = "docs/pocketkit.md"
```

```toml
[docs.packages.pocketkit-core]
overview = "docs/pocketkit-core.md"
```

带点的包名用子表写法。包页的第一段正文（最多 240 个字符）会显示在 HTML 包页顶部，并链接到完整的包概述页。要让概述出现在包页上：

- 页面需要有正文，只有标题的页面不参与。
- 页面里的 `<!-- cjdoc-bind ... -->` 必须全部能解析；有未解析的绑定会跳过该概述。
- 同一个 Markdown 文件只保留一个入口，不会重复出现。
- 多个模块有同名包时，需要页面中指向该包可见 API 的显式绑定来证明所属模块；指向其他辅助包的绑定不算归属证据，无法唯一归属时省略概述。

多语言概述按页面的 `id` 和 `language` 配对，沿用正文回退规则。简介段落保留作者文本的实际语言标记，例如中文界面回退到英文概述时，段落仍标为 `en`；没有声明来源语言时不会猜测。

如果希望某个页面成为包的正式概述页，在 `[[docs.pages]]` 里设置 `kind = "package"` 和 `package = "<包名>"`；否则 `kind = "package"` 的页面优先，普通指南作为候选。

## 添加自定义页面

每个 `[[docs.pages]]` 定义一个页面：

```toml
[[docs.pages]]
source = "docs/getting-started.md"
route = "concepts/guides/getting-started"
title = "快速开始"
id = "getting-started"
kind = "guide"
```

`source` 必填，文件必须存在；`route` 省略时按源文件路径生成 slug（例如 `docs/guides/setup.md` 会变成 `concepts/guides/docs-guides-setup`），建议显式写一个短路由。路由必须是安全相对路径：不能以 `/`、`\` 开头，不能含 `..`、`:`、`?`、`#` 或控制字符；同时必须位于 `concepts/` 下（与默认布局一致）。没写 `.html` 时会自动补上。

`kind` 是页面类别标签，默认 `guide`；只有 `kind = "package"` 会改变包概述的归属判断，其他值主要影响导航索引和 agent 产物里的分类展示。

页面正文是普通 Markdown：

```markdown
# 快速开始

先用 `cjpm build` 编译项目。

## 安装

把依赖写进 `cjpm.toml`，然后在项目根目录运行命令。

## 第一个示例

见 [配置说明](configuration.md)。
```

- 支持标题、段落、列表、表格、引用、代码块、行内代码、强调、链接和本地图片。
- 原始 HTML 不会作为 HTML 注入，会按文本显示；只有 `<!-- cjdoc-bind ... -->` 标记有特殊含义（见下文）。
- 指向另一个概念页源文件的相对链接，会自动替换成生成后的页面路由；同一个页面里的 `#标题` 锚点也会映射到实际锚点。指向非概念页的相对链接保持原样。
- 本地图片支持 PNG、JPEG、GIF、WebP、AVIF。目前仅 Linux 会嵌入页面；macOS 和 Windows 上不会嵌入，只保留替代文本并输出 warning（`CJDOC4026`），页面标记为不完整（partial）。远程图片 URL 不会渲染成图片。

需要把同一页面发布成多种语言时，给两个 `[[docs.pages]]` 写相同的 `id`、不同的 `language`，见 [多语言文档](i18n.md)。

### 映射章节

`[docs.pages.sections]` 把逻辑章节 ID 映射到页面里的真实标题，写在对应页面配置的后面（同一个文件里可以按页面重复出现）：

```toml
[[docs.pages]]
source = "docs/getting-started.md"
route = "concepts/guides/getting-started"
id = "getting-started"

[docs.pages.sections]
install = "安装"
first-example = "第一个示例"
```

多语言站点里，各语言版本用相同的章节 ID 指向各自的标题，切换语言时就能落到等价章节。标题在页面里找不到或匹配不唯一时，该映射被忽略并输出 warning（`CJDOC3110`）。

## 绑定 API

在 Markdown 里用一行注释把页面关联到 API 声明：

```markdown
<!-- cjdoc-bind target="pocketkit.Client" -->
```

| 写法 | 匹配方式 | 用途 |
|---|---|---|
| `target="pocketkit.Client"` | 限定名完全相等 | 常见写法，写声明在文档里的完整限定名 |
| `target="id:<稳定 ID>"` | 与符号 ID 完全相等 | 限定名会随重导出变化、或需要精确指向时使用；ID 可从 `html/navigation-index.json` 的 `symbolId` 复制 |
| `selector="signature:public func send(body: String): Unit"` | 签名文本完全相等 | 同名重载时区分具体声明；冒号后是源码里的完整声明头 |
| `language="cangjie"` | 仅记录 | 可选属性，记录绑定所在语言，默认 `markdown` |

标记要单独占一行，不要放进代码块或缩进的代码里。一个页面可以写多个标记；重复的同一个目标会被标记为冲突并输出 warning（`CJDOC2053`）。

页面生成后：

- 成功的 `<!-- cjdoc-bind ... -->` 在原位置显示“相关 API”及短签名，指向准确声明或重载；版本、来源和绑定状态可在次级详情查看。
- 页面底部可展开“API 关联”查看全部绑定。
- 被绑定 API 的页面会出现“相关指南”列表，反向链接到包含标记的实际章节；缺少可证明的章节时链接到文章。
- 生成 `markdown` 格式时，关联信息以 Markdown 列表形式附在页面末尾。

绑定结果和读者看到的状态：

| 结果 | 页面上的显示 | 构建输出 |
|---|---|---|
| 找到唯一且当前 audience 可见的声明 | 链接到 API 页 | 无诊断 |
| 找不到目标 | “未找到目标” | warning（`CJDOC2051`） |
| 匹配到多个声明 | “目标不明确” | warning（`CJDOC2052`） |
| 目标存在但被当前 audience 排除 | “当前受众不可见” | warning（`CJDOC2055`） |
| 重复标记 | “标记冲突” | warning（`CJDOC2053`） |

绑定失败不会中断生成，页面照常发布。换 `--audience` 重新生成可以验证某个绑定是否对目标读者可见。

## 自动模块页

cjdoc 为每个模块生成一页，源文件是 `docs/modules/<slug>.md`，路由是 `concepts/modules/<slug>.html`。没有对应文件时使用占位内容，列出模块名、角色和包含的包。想补充模块说明时，在默认路径放一个同名 Markdown 文件即可：

```text
docs/modules/pocketkit.md
```

模块页通常只写模块职责、包列表和阅读顺序；具体 API 交给包页和声明页。

## 路由与搜索

- 生成的 HTML 里，概念页统一放在 `html/concepts/` 下；生成 Markdown 时在 `markdown/concepts/` 下有对应页面。
- 所有概念页都会进入站点搜索索引，可以按标题和有界正文摘录搜索；不是完整全文检索。结果分页与 2,000-rune 边界见[使用指南](usage.md#在静态页面中查找-api)。
- 项目首页会列出其他概念页；API 页会列出绑定到它的指南。
- 同一个语言内路由不能重复。配置的两页撞到同一路由时，cjdoc 会保留可读前缀并追加稳定后缀，同时输出 warning（`CJDOC4060`）；此时以 `html/navigation-index.json` 里的实际路由为准。
- 自动生成的页面路由由名称决定，不能直接配置；需要固定 URL 的页面请用 `[[docs.pages]]` 显式写 `route`。

## 多语言页面配对

启用 `[i18n]` 后，用相同 `id`、不同 `language` 声明同一逻辑页的不同语言版本；章节通过 `[docs.pages.sections]` 对齐。带 `language` 的页面必须显式写 `id`，同一语言内 `id` 不能重复，否则页面被跳过并报错（`CJDOC3110`）。完整规则见 [多语言文档](i18n.md)。
