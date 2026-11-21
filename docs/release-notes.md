# cjdoc 发布记录

每个版本对使用者的变化和升级步骤。可下载的资产与校验值见 [Releases](https://github.com/lIlIIlIll/cjdoc/releases)。

## 未发布

- 从首页的「API 参考」展开包和类型，浏览当前版本公开给你的每条声明；关闭 JavaScript 仍可打开各声明详情。左栏可直接显示当前分支的全部条目，包页的「本页目录」可跳到单条声明。
- 已弃用声明的详情显示作者说明，或可读取的源码注解消息。只有作者明确指定且可用的替代项才显示为独立的「改用」链接；原名称仍打开原声明。
- 包使用可读地址，例如 `packages/pocketkit/authoring/`。双语站的包页留在当前语言目录中，默认语言的声明地址不变。旧包链接及其片段仍可打开；发布时复制完整 `html/` 目录。
- 新 HTML 机器包使用 `cjdoc.machine-manifest/3` + `cjdoc.read/3`。CLI 仍按原地址验证和查询已发布的 `/1` 和 `/2` 包；Doc IR v18 不变。

## 0.7.9

### 项目配置与默认 CHIR

- 常用输出与分析设置可以保存在项目根的 `cjdoc.toml`，普通命令行选项覆盖对应配置默认值；未知配置键和不支持的多行字符串会报错，避免设置被静默忽略。已有覆盖率配置与 CLI 门槛仍各自检查。
- 既有分组与标签表继续支持带引号的路径分量和点号两侧的空白，例如 `[["metadata"."groups"]]` 与 `[[metadata . groups]]`；标题、翻译和重复定义检查规则不变。
- `generate`、`check`、`serve` 默认尝试 CHIR 语义补充。匹配版本的 worker 随主程序安装，按 `cjdoc` 的真实可执行文件位置自动定位，不需要配置 worker 路径。
- `--semantic source` 可关闭本次 CHIR 分析；`--chir-worker` 保留为开发或特殊部署的显式覆盖。worker 缺失、版本或协议不匹配时产生诊断，并保留源码/AST 信息。
- CHIR 整模块不可用时保留模块级失败诊断，不再把每条源码声明都误报为独立绑定缺失，避免大项目的源码回退被重复诊断耗尽。
- 默认 CHIR 与失败回退都保留源码可唯一确定的本地继承和扩展导航，公开扩展成员不会因语义补充不支持关系查询而从发布文档中消失；不确定目标仍保持不可用或歧义。
- 子命令支持独立帮助，例如 `cjdoc generate --help`。离线 `render` 不读取项目配置，不启动 worker。

从 0.7.8 升级时，把 `cjdoc` 与配套 `chir-worker-main`（Windows 为 `.exe`）安装到同一目录。推荐下载归档包，它同时包含两个文件；单独下载主程序不包含 worker。现有 Doc IR v18 快照仍可离线重放，无需迁移。大型项目在 STS 1.2.0 上仍可能遇到 [Linux GC 崩溃](https://github.com/lIlIIlIll/cjdoc/issues/184)，此版本未修复该崩溃。

### HTML 参考页

- 参数列表在类型和默认值之间显示 ` = `。宽屏时参数和异常的声明与说明对齐，窄屏时说明显示在声明下方。返回值类型与说明之间不再留出多余空白。
- 带预期输出的示例默认在同一框内显示代码和输出，分别复制。长输出可展开；支持[正文式和宽屏并排布局](reference/doc-comments.md#html-示例布局)，窄屏始终上下排列。
- 示例可整体折叠；在「显示设置 → 示例默认状态」选择默认展开或折叠。
- 「显示设置」新增代码长行软换行、长输出默认展开和「恢复默认设置」。预期输出和复制内容保留原样。
- 类型和成员改用可读的目录地址，例如 `pocketkit/TextCatalog/` 与 `pocketkit/TextCatalog/join/`。`pocketkit/TextCatalog/find/` 列出重载，具体签名各有可分享的链接。页首和成员操作区的**复制链接**指向相应声明；离线复制保留 `index.html`。
- 在包表、成员、侧栏和搜索结果里可直接辨认已弃用 API。[`@replacement`](reference/doc-comments.md#弃用与迁移) 指定的有效目标显示为独立的「改用」链接；点击原名称或在搜索中按 Enter 仍打开原声明。
- 双语站的默认语言 API 不加前缀；若默认语言是中文，英文使用 `en/`。静态托管需发布完整 `html/`，并让目录地址读取其中的 `index.html`。旧的两种 `symbols/` 链接继续指向原声明。
- 新 HTML 机器包使用 `cjdoc.machine-manifest/2` + `cjdoc.read/2`。CLI 仍能验证和查询既有的 v1 包，Doc IR v18 不变。

### PocketKit 示例

- demo-v2 首页加入[双语文档注释指南](../examples/pocketkit/demo-v2/docs/doc-comments.md)，可从可复制的注释、示例与排错写法跳到实际生成的 API。

## 0.7.8（2026-11-16 发布）

tag `v0.7.8` 指向提交 [`5c065af`](https://github.com/lIlIIlIll/cjdoc/commit/5c065affd2c45f61549c06808537731ce46b436b)。这个版本换了新的 HTML 站点界面，并采用 Doc IR v18 和新的查询、静态搜索协议。升级前请注意：

- 0.7.7 及更早版本生成的 JSON 快照（Doc IR v16/v17）不能直接使用，需要从源码重新生成。
- 已发布的 HTML 站点需要重新生成后整体替换。

具体做法见[从 0.7.7 升级](#从-077-升级)。

### 重新设计的 HTML 站点

新界面没有改变页面 URL、页面内锚点和机器读取产物的格式（Doc IR v18、search-index/11、page/2、declaration/3），指向旧页面的深链继续可用。

- 三栏布局：左侧是包 → 类型 → 成员的导航树，顶部输入框按名称筛选；中间是正文；宽屏右侧是本页目录。窄屏下导航改为抽屉。
- 按 `Ctrl+K`（macOS 为 `⌘K`）或 `/` 打开搜索弹层，`Esc` 关闭。
- 包页面按种类列出声明表格：名称、种类、一行摘要；重载以参数类型区分。完整签名在声明页和成员详情里。
- 右上角“显示设置”可以选择 8 种主题（含跟随系统）、字体（系统 / 衬线 / 等宽）和字号，选择保存在当前浏览器。
- 生成时可用 `--html-font-sans`、`--html-font-mono` 指定站点字体列表，见 [CLI 参考](reference/cli.md#生成和离线渲染的输出选项)。站点不下载字体文件。
- 禁用脚本时页面内容、当前包的导航、完整包索引链接、语言与版本链接和系统主题仍然可用；搜索、筛选、复制和显示设置需要脚本。

### 从 0.7.7 升级

cjdoc 0.7.8 只读取 `cjdoc.doc-ir/18`，没有旧格式的迁移工具，也不能通过修改 `schemaVersion` 让旧文件通过。

在项目根目录重新生成到一个新的输出目录：

```bash
cjdoc generate --project . --format json --format html --output target/doc-0.7.8
```

| 你手上的旧产物 | 在 0.7.8 怎么处理 |
|---|---|
| Doc IR v16（0.7.7 生成）或 v17 的 `docs.json` | 重新 `generate`；`render` 只接受 `cjdoc.doc-ir/18` |
| 已发布的 HTML 站点 | 重新生成整站后整体替换。不要混用新旧版本的 `style.css`、`search.js` 或搜索索引，否则搜索会报告 `search_index_version_unsupported` 或 `search_contract_unavailable` |
| `versions compose` 组合出的多版本站点 | 每个版本重新生成，再重新 compose；compose 只复制已有站点，不改写内容 |
| 旧格式快照，而对应源码已经拿不到 | 无法升级。已有的 v18 快照不受影响，仍可离线 `render` |
| agent 产物（`declaration/1`、`page/1`）、查询结果和游标 | 重新生成；旧游标不能用于新请求 |

升级后先运行 `cjdoc check --project .` 检查注释与配置，需要编译和运行示例时加 `--check-examples`。确认新站点内容无误后，再替换已发布的目录。

### 在注释和指南里写提示

注释中可以用 `@note`、`@warning`、`@danger` 写提示块，属性形式为 `[id=...]`、`[lang=...]` 或两者组合，语言在 ID 前。指南 Markdown 用引用块标记 `> [!NOTE]`、`> [!WARNING]`、`> [!CAUTION]`。等级由作者选择，cjdoc 不推断风险；HTML 输出静态提示区域，正文仍走安全 Markdown renderer，不产生弹窗或 live region。空提示报告 `CJDOC3117`，ID 冲突报告 `CJDOC3118`。写法见[文档注释参考](reference/doc-comments.md#提示标签)。

### 按标签和分组组织声明

`@tag` 为单个声明添加大小写敏感的 ASCII 分类 ID，可重复；查询和 HTML 筛选按 ID 精确匹配、多个 ID 取交集。模块配置可以提供分组和标签的双语标题，并指定分组的展示顺序；既有组、kind 和详情深链保持可达。完整写法与限制见[配置参考](reference/configuration.md)。

### 更清楚的阅读页面

- 「使用于 / Used by」说明每个引用出现的位置：参数、字段或属性、返回类型、父类型、扩展目标、泛型约束。
- 侧栏只把与当前页面完全对应的条目标为当前页；所属的包和容器类型只显示为上级。
- 类型只有零个或一个成员时，不再显示成员筛选和“全部展开”；来源选择器只在成员确实有多个来源（自身声明、继承、扩展）时出现。
- 嵌套声明的页面保留所属容器的侧栏位置。
- 切换语言或版本时，如果目标里没有对应章节，会打开同一页面的开头并给出说明，不再跳到无效位置。

### 查询、静态搜索与 MCP

命令行 `query`、本地 MCP 服务和 HTML 站点内的搜索现在遵循同一套查询规则。

- 两种匹配模式：`precise` 按声明身份和限定名匹配，多个候选同样匹配时返回 `ambiguous`，不替你挑一个重载；`discovery` 按相关度返回多个候选。`query` 和 MCP 默认 `precise`，HTML 搜索固定为 `discovery`。
- 结果按声明去重，排序稳定。`total` 是过滤后的候选总数，不是当前页的条数。文本匹配只忽略 ASCII 字母大小写，不做 Unicode 规范化。
- 游标只对同一份输入和同一个请求有效。换了条件、预算或输入后，去掉游标从第一页重新查询；继续使用旧游标会返回 `stale_cursor`。
- 可以按 `tags` 筛选，结果里的 `result.facets.tags` 给出标签分布。只给范围、筛选条件或标签而不给查询文字时，返回该范围内的全部候选。
- 已发布站点的静态索引只支持 `search`；对它请求 `full-ir` 返回 `unavailable/search_profile_unavailable`。

字段和错误码见[查询协议参考](reference/query-protocol.md)，客户端配置和翻页示例见 [query 与 MCP](how-to/query-and-mcp.md)。

### 源码来源状态与外部文档链接

每个源文件现在带有来源状态。`verified` 表示你登记的仓库加上你独立提供的 `cjdoc.source-provenance/1` 回执与读取到的文件内容一致；它不证明 Git 提交、远端仓库或构建结果。只要配置了任何一个 `[[source.repositories]]`，没有匹配登记的文件就不再回退到项目仓库：页面省略它的源码链接并报告 `CJDOC1032`，API 内容照常保留。沿用旧式项目仓库映射的文件标为 `declared`。状态含义见[状态与限制](reference/states-and-limits.md#源码来源-provenance)，操作步骤见[链接外部文档](how-to/link-documentation.md)。

### 手册与命令行帮助

- 用户手册按任务重新组织为安装、连续教程、操作指南和参考四组，入口是[用户手册](README.md)。旧的平铺文档（`usage`、`advanced-usage`、`agent-reading`、`configuration`、`contract-review`、`documentation-quality`、`guides`、`i18n`）已由新路径取代，没有重定向。
- `cjdoc --help` 现在列出 `generate --format symbol-index`，并说明 `versions compose --release ID=TEXT` 的值是纯文本，不要求是 URL。两项都只是帮助文本的修正，命令行为没有变化。

### 协议版本对照

| 协议 | 0.7.7 | 0.7.8 |
|---|---|---|
| Doc IR | `cjdoc.doc-ir/16` | `cjdoc.doc-ir/18` |
| query-request | `cjdoc.query-request/1` | `cjdoc.query-request/3` |
| query-result | `cjdoc.query-result/1` | `cjdoc.query-result/4` |
| search-index | `cjdoc.search-index/9` | `cjdoc.search-index/11` |
| search-contract | 无 | `cjdoc.search-contract/2` |
| declaration | `cjdoc.declaration/1` | `cjdoc.declaration/3` |
| page | `cjdoc.page/1` | `cjdoc.page/2` |
| cursor / cursor-binding | `cjdoc.cursor/1`、`cjdoc.cursor-binding/1` | `cjdoc.cursor/2`、`cjdoc.cursor-binding/2` |
| source-provenance | 无 | `cjdoc.source-provenance/1` |

未列出的产物版本不变：`api-surface/3`、`api-diff/2`、`versions/2`、`site-manifest/1`、`machine-manifest/1`、`symbol-index/2`、`navigation-index/2`、`documentation-coverage/2`、`documentation-quality/1`、`doc-sources/1`、`build-context/1`。完整清单见[产物参考](reference/artifacts.md)。

格式不匹配时会明确报错：读取 Doc IR 要求 `schemaVersion` 恰好是 `cjdoc.doc-ir/18`；HTML 搜索遇到版本不符的索引返回 `search_index_version_unsupported`，搜索规则不匹配时返回 `search_contract_unavailable`。

### 环境要求与已知限制

- 运行 cjdoc 需要仓颉 1.2.0 STS SDK 的运行时环境，发行包也一样。从源码构建另需匹配的静态 stdx 1.2.0。见[安装 cjdoc](getting-started/install.md)。
- Windows 当前不提供安全捕获站点本地图片的读取实现：图片被省略、报告 `CJDOC4026`、文档可为 `partial`，Markdown 替代文本仍保留。Linux 和 macOS 支持该路径。
- macOS 上不能运行带 `run` 的注释示例，会报告 `CJDOC3074`。HTML 仍然正常生成，但示例没有实际执行。
- CHIR 语义补充是可选能力，不随发行包提供：需要用同一版本的源码自行构建 worker，并提供匹配的编译器和静态 stdx。启用后结果仍可能是 `partial` 或 `unavailable`，`CJDOC2101`–`CJDOC2106` 表示语义信息没有补上；注释内容和源码声明不受影响。步骤见[使用 CHIR](how-to/chir.md)。
- 资源上限是固定的。超限时会报告诊断、跳过输入或返回资源错误，这时的输出不是完整结果。见[状态与限制](reference/states-and-limits.md#主要资源上限)。

## 更早的版本

### 0.7.7（2026-10-30 发布）

tag `v0.7.7` 指向提交 [`8cc8f71`](https://github.com/lIlIIlIll/cjdoc/commit/8cc8f71a296b1c6321e575b56fadbd0c379e242a)。

- 可以用注释里的 `@group` 把 API 声明分组。分组标题对所有语言相同；非法或冲突的分组标签报告 `CJDOC3130`、`CJDOC3131`。
- Doc IR 为 v16，其余协议版本见上面的对照表。

### 0.7.6（2026-10-28 发布）

tag `v0.7.6` 指向提交 [`653457d`](https://github.com/lIlIIlIll/cjdoc/commit/653457d1aa46ef2939cd10e130d7e1b16fd5d999)。

- 文档包含 `public macro` 的签名、参数、返回类型和注释。
- 包在 `@Derive` 等宏调用里的声明保留其成员、可见性和源码位置。宏展开后才产生的成员不会出现在文档里，相关声明标为不确定。
- Doc IR 为 v16。

### 0.7.5（未发布）

tag [`v0.7.5`](https://github.com/lIlIIlIll/cjdoc/tree/v0.7.5) 的发行流程在 macOS 和 Windows 上构建失败，没有发布 GitHub Release。0.7.6 以新的版本号发布，旧 tag 保持不动。
