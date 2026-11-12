# cjdoc 0.7.8 发布记录

相对公开发行包 v0.7.7，本版本采用 Doc IR v18 和新的查询、静态检索协议。v16/v17 快照需要从源码重新生成；已有 v18 快照仍可离线重渲染。发布状态、可下载资产和校验值以 [Releases](https://github.com/lIlIIlIll/cjdoc/releases) 为准。

## 未发布：重新设计的 HTML 站点

生成的 HTML 站点换成新的界面，URL、页面锚点、搜索索引和所有机器读取产物（Doc IR v18、search-index/11、page/2、declaration/3）不变，已有深链继续可用。已发布站点需要重新生成整站后整体替换，不要把新旧版本的 `style.css`、`search.js` 混用。

- 三栏布局：左侧是包 → 类型 → 成员的导航树，顶部输入框按名称筛选；中间是正文；宽屏右侧是本页目录。窄屏下导航改为抽屉。
- 按 `Ctrl+K`（macOS 为 `⌘K`）或 `/` 打开搜索弹层，`Esc` 关闭。
- 包页面按种类列出声明表格：名称、种类、一行摘要；重载以参数类型区分。完整签名在声明页和成员详情里。
- 右上角“显示设置”可以选择 8 种主题（含跟随系统）、字体（系统 / 衬线 / 等宽）和字号，选择保存在当前浏览器。
- 生成时可用 `--html-font-sans`、`--html-font-mono` 指定站点字体列表，见 [CLI 参考](reference/cli.md#生成和离线渲染的输出选项)。站点不下载字体文件。
- 禁用脚本时页面内容、当前包的导航、完整包索引链接、语言与版本链接和系统主题仍然可用；搜索、筛选、复制和显示设置需要脚本。

## 升级 v16/v17 产物

当前 decoder 只接受 `cjdoc.doc-ir/18`，不迁移 v16/v17 输入。旧数据缺少新增的必需字段与语义，不能只改 `schemaVersion`。

在已有项目根目录重新生成到新输出目录：

```bash
cjdoc generate --project . --format json --format html --output target/doc-0.7.8
```

| 手上已有的旧产物 | 在 0.7.8 的处理方式 |
|---|---|
| Doc IR 16（v0.7.7 发行包生成）或 Doc IR 17 | 重新 `generate`；`render` 只接受 `cjdoc.doc-ir/18` |
| 已发布的 HTML 站点（含 `html/` 下的静态搜索文件） | 重新生成整站后整体替换。0.7.8 的前端要求 search-index/11 与 search-contract/2，混用旧索引会得到 `search_index_version_unsupported` 或 `search_contract_unavailable` |
| `versions compose` 的版本目录 | 各版本重新生成，再重新 compose；compose 只复制既有站点，不重写内容 |
| 旧格式快照，而源码已不可用 | 当前工具没有迁移路径。此限制不影响已有 v18 快照的无源码 `render` |
| agent 产物（`declaration/1`、`page/1`）、查询结果与游标 | 重新生成；旧游标与新请求不再通用 |

升级后先运行 `cjdoc check --project .` 检查注释与配置；需要编译和运行示例时增加 `--check-examples`。确认新站点内容后，再替换已发布目录。

## 这个版本带来什么

### 在注释和指南里写提示

注释中可以用 `@note`、`@warning`、`@danger` 写提示块，属性形式为 `[id=...]`、`[lang=...]` 或两者组合，语言在 ID 前。指南 Markdown 用引用块标记 `> [!NOTE]`、`> [!WARNING]`、`> [!CAUTION]`。等级由作者选择，cjdoc 不推断风险；HTML 输出静态提示区域，正文仍走安全 Markdown renderer，不产生弹窗或 live region。空提示报告 `CJDOC3117`，ID 冲突报告 `CJDOC3118`。写法见[文档注释参考](reference/doc-comments.md#提示标签)。

### 按标签和分组组织声明

`@tag` 为单个声明添加大小写敏感的 ASCII 分类 ID，可重复；查询和 HTML 筛选按 ID 精确匹配、多个 ID 取交集。模块配置可以提供分组和标签的双语标题，并指定分组的展示顺序；既有组、kind 和详情深链保持可达。完整写法与限制见[配置参考](reference/configuration.md)。

### 更明确的阅读页面

- 「使用于 / Used by」按关系 kind 给出反向位置说明：参数、字段/属性、返回类型、父类型、扩展目标、泛型约束，未知 kind 保留为中性转义说明。
- 侧栏只在无 fragment 的路由与当前页精确相等时标为当前页；包和 owner 的上下文链接只作 ancestor。
- 成员工具栏按最终可见成员决定：零或一个成员不生成筛选和批量展开，两个及以上才生成；来源选择器只在实际存在多个来源时出现。
- 嵌套声明页保留所属容器的侧栏上下文；语言切换在没有等价章节时给出说明并打开同一页面开头，不猜测其他章节。

### 查询、静态搜索与 MCP

原生 `query` 和 stdio MCP 共用一套查询核心，静态 HTML 搜索走同一契约的浏览器实现。

- `precise` 以声明身份和限定名为主，最高证据等级并列时返回 `ambiguous`，不按遍历顺序挑重载；`discovery` 按分数返回多个候选。原生默认 `precise` + `full-ir`，HTML 固定 `discovery` + `bounded-static`。
- 结果按 canonical 声明去重并按相关度与 UTF-8 身份稳定排序；`total` 是完整过滤后的去重候选数，不是当前页条数。文本只折叠 ASCII 大小写，不做 Unicode normalization。
- 游标绑定冻结输入、检索 profile 和除 `cursor` 之外的完整请求；换条件、换预算或换输入必须去掉游标从第一页重查，旧游标返回 `stale_cursor`。
- 新增 `tags` 筛选与 `result.facets.tags`；只有 scope、filter、tag 或 overload 选择器而没有文字查询时会枚举候选。静态索引只提供 `search`，请求 `full-ir` 返回 `unavailable/search_profile_unavailable`。

字段、章节预算和错误分层见[查询协议参考](reference/query-protocol.md)，客户端配置与续页示例见[query 与 MCP](how-to/query-and-mcp.md)。

### 来源证据与外部文档链接

Doc IR 为每个源文件记录来源状态，`verified` 表示已登记仓库加调用方独立 pin 的 `cjdoc.source-provenance/1` 回执与捕获字节匹配，`evidenceKind` 为 `caller_pinned_receipt`。它不是 Git commit/tree、远端仓库或构建成功的独立认证。配置任意 `[[source.repositories]]` 后进入严格登记模式：未匹配文件不回退到项目仓库，不匹配时省略源码链接并报告 `CJDOC1032`，API 内容仍保留。旧式项目仓库映射继续标为 `declared`。状态含义见[状态与限制](reference/states-and-limits.md#源码来源-provenance)，操作步骤见[链接外部文档](how-to/link-documentation.md)。

### 手册、入门与命令行帮助

用户手册重组为安装、连续教程、操作专题和参考四组，共 24 篇，按任务组织而不是按功能罗列。八篇旧平铺文档（`usage`、`advanced-usage`、`agent-reading`、`configuration`、`contract-review`、`documentation-quality`、`guides`、`i18n`）由新路径直接替代，不保留重定向。README 的快速开始改为可直接执行的 `docdemo` 静态库流程：写注释、编译、生成 HTML，再打开页面看签名、参数、返回和示例。安装页保留 STS 1.2.0 源码构建主路径，并把 v0.7.7 发行包作为独立替代入口，注明它自己的源码提交和 Doc IR 16。入口见[用户手册](README.md)。

顶层的 `--help` 现在列出 `generate --format symbol-index`，`versions compose --release ID=TEXT` 明确为纯文本元数据，不要求是 URL。这两项是帮助文本与实际行为对齐，参数解析和发布语义未变。

另外，自托管展示站的 API 根首页（`api/index.html`）和概念首页也把手册链接固定到该次构建的源码 revision；其它项目的 API 首页、README badge 和原始 Doc IR 不受影响。

## 协议版本对照

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

旧输入的拒绝是显式的，不是静默降级：Doc IR decoder 要求 `schemaVersion` 精确等于 `cjdoc.doc-ir/18`；HTML 前端发现 search-index 版本不符时返回 `search_index_version_unsupported`，契约不匹配时返回 `search_contract_unavailable`。

## 环境要求与已知限制

- 源码构建需要仓颉 1.2.0 STS 编译器和匹配的静态 stdx 1.2.0。发行包二进制同样需要对应的 SDK 运行时库，按发行清单声明的 SDK/stdx 摘要准备环境，不要用另一套 SDK 的版本字符串代替。
- Windows 当前不提供安全捕获站点本地图片的读取实现：图片被省略、报告 `CJDOC4026`、文档可为 `partial`，Markdown 替代文本仍保留。Linux 和 macOS 支持该路径。
- macOS 当前无法建立示例运行所需的地址空间限制，因此拒绝执行带 `run` 的示例并报告 `CJDOC3074`；这不影响生成 HTML，但示例没有实际运行。
- CHIR 语义补充是可选项，且不是发行包内容：需要同一版本的源码副本自建 worker，并给出匹配的 compiler 与静态 stdx 绝对路径。即使启用，结果也可能只有 `partial` 或 `unavailable`，注释始终是文档真值；`CJDOC2101`–`CJDOC2106` 表示语义没有补上，源码声明仍保留。步骤见[补充类型和签名信息](how-to/chir.md)。
- 资源上限固定，超限时产生诊断、跳过输入或返回资源错误，不应把部分输出当作完整结果。详见[状态与限制](reference/states-and-limits.md#主要资源上限)。

## 历史记录

### 0.7.7（2026-10-30 发布）

tag `v0.7.7` 指向提交 [`8cc8f71`](https://github.com/lIlIIlIll/cjdoc/commit/8cc8f71a296b1c6321e575b56fadbd0c379e242a)，发布内容为 PR #168：按源码注释里的 `@group` 把 API 声明分组，标题为所有语言共用的元数据，非法或冲突标签报告 `CJDOC3130`/`CJDOC3131`。该版本 Doc IR 为 v16，协议为 query-request/1、query-result/1、search-index/9、declaration/1、page/1。发行资产为三个平台的裸可执行文件、压缩包及各自的 `.sha256`。该 tag 内的 `docs/release-notes.md` 仍以 0.7.6 开头，没有单独的 0.7.7 条目。

### 0.7.6（2026-10-28 发布）

tag `v0.7.6` 指向提交 [`653457d`](https://github.com/lIlIIlIll/cjdoc/commit/653457d1aa46ef2939cd10e130d7e1b16fd5d999)，内容来自 PR #165 和 #166。

- 收集 `public macro` 的源码签名、参数、返回类型和文档注释。恢复 `@Derive` 等宏包装内的源码声明、成员、可见性和位置；未展开调用继续保留不确定状态，不虚构生成成员。
- 由完整验收链负责产品构建，删除发行工作流前置的重复构建，并在验收成功后核验待打包的同一二进制。
- Windows 发行使用已在 CI 验收的 `windows-2022` runner。工具链、产品优化参数和测试断言保持原值。

Doc IR 为 v16。生成器版本改为 `0.7.6`，当时需要重新生成 current golden 和性能文档身份；这个版本变化不代表新的性能测量结论。

### 0.7.5（未发布）

[`v0.7.5`](https://github.com/lIlIIlIll/cjdoc/tree/v0.7.5) 保留在提交
[`a1852d6`](https://github.com/lIlIIlIll/cjdoc/commit/a1852d68ae3ac06dc50f6273eeade8099dee223b)。
其[发行运行](https://github.com/lIlIIlIll/cjdoc/actions/runs/40362242523)在 macOS 和 Windows 的第二次产品构建中失败，未发布 GitHub Release。
`0.7.6` 使用新的发行身份，不移动旧 tag。该次修复调整了构建执行图和 runner，编译器崩溃的根因仍未确定。

### 0.7.6 之后至 0.7.8 的实现与验证记录

以下条目记录 0.7.6 发布之后积累的工作，以及当时的验证状态。其中有些描述的是中间状态（例如 Doc IR 曾为 17、query-result 曾为 3），最终版本以本页前面的对照表为准。条目里的 CI、浏览器、性能和无障碍记录都属于当时的提交，不描述 0.7.8 标签的运行结果。这些内容现在属于 0.7.8 的变更范围，但它们的测量与门禁结论只对各自的提交有效。

#### 查询、分类与分组（#178–#179）

- 查询与静态检索采用统一的 search-contract/2：precise/discovery 两种模式，full-ir/bounded-static 两种检索 profile；HTML 使用 discovery + bounded-static。该阶段协议为 query-request/3、query-result/3、search-index/11 和 declaration/2，Doc IR 升为 17，后由 #179 升到 query-result/4、declaration/3、page/2 和 Doc IR 18。
- 查询结果按 canonical 声明去重，按相关度及 UTF-8 稳定身份排序；总数代表完整过滤后的候选数，游标绑定捕获内容与规范化请求。搜索文本只折叠 ASCII 大小写，不做 Unicode normalization；单 token 拼写距离仅支持一次插入、删除或替换，不支持转置。
- 新增声明级 `@tag`，使用大小写敏感的 ASCII ID，精确 AND 筛选，不从类型、包或扩展继承，也不作为行为契约。可选 module-local `cjdoc.toml` 元数据为标签提供标题、为包或 owner scope 定义可排序分组。
  metadata 根键不能通过多行字符串绕过严格表语法；无关字符串内的示例文本仍不作为配置解析。
- Doc IR/17 捕获实际用于发布声明的 metadata，支持 source-free render；HTML 与 Markdown 采用相同的分组/kind 层级规则，按 module/package/原始 owner 区分同 ID 组，并保留既有组、kind、声明和详情深链。Markdown 中超过 H6 的作者标题降为低权重文字并保留可达片段；分组中的容器标题仍链接到成员页。
  包页与成员页的声明行以捕获的 canonical ID 参与共享筛选；未设置筛选时保留全部声明。
  摘要与正文共享作者片段导航；参数、返回值与重复出现的异常章节各用独立命名空间，避免完整参考中的锚点冲突。
- 修正 workspace/依赖 metadata 绑定诊断的配置归属；facet 切换同步输入与有效标签条件。顶层声明名称选择器不命中 concept，discovery 保留纯标点标题的名称证据；摘要与签名预览按 Unicode 码点上限处理，并同步实际 renderer 的静态脚本校验身份。
- 静态索引的模块目录来自捕获的 Doc IR 模块清单，包含没有可见搜索条目的模块；module、document-set 与 dependency identity 按同一模块记录校验。`packageName` 仅收窄候选声明；已捕获 module scope 中，完整收集但没有候选时返回 `not_found/no_match_in_scope`，收集不完整时保留 `source_incomplete`，不会把 packageName 当作捕获证明。
- Windows 源外 metadata 回放保留原生运行时路径，只隔离编译器工具和 SDK 定位入口。Reader CI 固定基线经显式批准刷新到 `67faf0b244544a750543f049370c59479769eff4`，保留相同 payload 与原任务/资源门禁；其结论只覆盖后续修复。Showcase 经显式批准仅将站点/离线包上限更新为 130,000,000/20,000,000 bytes，其他约束不变。
- 静态搜索的 ASCII 折叠不再逐码点累积拼接字符串，保留非 ASCII 文本与不规范化规则。Reader 浏览器回归按当前 UTF-8 canonical identity 顺序校验续页，保留 package 的 canonical-or-exposure 匹配；历史恢复用显式名称过滤验证目标成员，不把 discovery 的模糊匹配误当作唯一结果。
- 可选高亮宿主构建失败时，公开证据仅增加有界、白名单化的 STS 包装器调用状态；不发布原始编译输出、路径或参数，不增加超时，也不把诊断记录视为构建成功。
- 这一阶段已经确立 current-only wire cutover 的做法：旧 Doc IR、旧 query-request/query-result、旧 search-index 与 declaration 版本不由当前 decoder/消费者迁移；使用旧输入前须从真实源码重新生成 Doc IR 或静态站点。

#### 阅读界面与消费者契约（#173–#177）

- HTML「使用于 / Used by」按关系 kind 标示反向使用位置；正向关系、去重、计数和目标链接不变。内置双语文案如下：

| kind | English | 简体中文 |
|---|---|---|
| `parameter` | Uses this type in a parameter | 在参数类型中使用此类型 |
| `field` | Uses this type in a field or property | 在字段或属性类型中使用此类型 |
| `return` | Uses this type in a return type | 在返回类型中使用此类型 |
| `superType` | Uses this type in a parent-type clause | 在父类型声明中使用此类型 |
| `extensionTarget` | Uses this type in an extension target | 在扩展目标中使用此类型 |
| `genericConstraint` | Uses this type in a generic constraint | 在泛型约束中使用此类型 |

未知 provider kind 保留为安全转义的中性关系说明，文案形如 `References this type (relationship: ${kind})` / `引用此类型（关系：${kind}）`。

- 本地 STS 1.2.0 产品构建及中英文 reference fixture 生成已运行；实际 Chromium 中展开 Token 的反向使用区域，显示成员链接和参数使用位置。此记录不代表正式 source-bound 门禁或远端 CI 通过。
- 侧栏仅对无 fragment 的 HTML 路由与实际 `currentPagePath` 精确相等时设置 `aria-current="page"`。只有真实 `index.html` 路由让 Overview 成为当前页；`#packages` 等片段只影响章节高亮，API Reference 不冒充当前页。包页、声明页只在实际链接指向当前文档时为 current，包/owner 的上下文链接仅作 ancestor；侧栏没有对应成员链接时可没有 current 项。
- 已运行双语各 94 页静态路由检查、Chromium 的 file 及 HTTP 子路径代表场景、4 项导航脚本测试和 14 项 HTML validator 测试。后续完整 canonical 浏览器回归通过 56/56，Admonition 专项矩阵通过 63/63，均未重试或跳过。
- 实际使用 Orca 51.1 与 Chromium 153 检验固定双仓库 yjson 的中英文 backend 类型、`parseFloat64` 独立成员、包页和首页，以及双语 extension fixture：精确页面链接产生 current-page 语音，成员页的 owner 只读作链接、不产生 current-page 语音。证据来自真实 Orca 生成并交给 Speech Dispatcher/eSpeak 合成的输出，不仅是 ARIA tree；不将其表述为真人听测、完整人类可用性实验或 Windows/NVDA 验收。
- 嵌套 owner 链沿同模块、同包的可见容器解析到既有顶层侧栏祖先，不把祖先冒充当前页。严格合法的公开 Doc IR `Outer → Inner → render` fixture 通过双语、启用/禁用 JavaScript 的 8 项真实浏览器检查与 byte-identical JSON round-trip；4 项实际 Orca 场景确认两种嵌套页面只播报 Outer 链接、不播报 current page。该 fixture 检验公开模型的 renderer 契约，不声称当前 SDK 支持源码嵌套 class。
- 成员工具栏以最终投影后的 `HtmlMemberBrowser.entries` 数量为准：零或一个成员不生成筛选、来源选择和批量展开/收起；两个及以上成员显示筛选与展开/收起。来源选择器只在实际成员含两个及以上来源时出现，选项只列实际存在的 declared、inherited、extension 来源。单成员仍保留原生 `details`、签名、契约、操作和深链。
- 本批产品重建通过；HTML 原生测试实际选中并通过 61 项、跳过 94 项。Chromium 实测单成员原生展开、单来源多成员无来源选择器、混合来源筛选、名称查询及批量展开；已失效的 session 来源值恢复为 All。实际 94 页站点及 48 条搜索条目通过 HTML validator。
- Showcase reading 消费者按真实投影来源集合断言 Origin 控件有无及选项，不再对已省略的单来源控件调用选择。使用首次失败 CI 的同一 sealed site、Playwright 1.57.0 与 Chromium 143.0.7499.4 完成双语 × root/subpath/file × desktop/mobile 的 12 项实际回归，站点 digest 前后相等；205 项 Showcase tooling tests 通过，未加重试或超时。

#### 提示、来源与参考导航（#179）

- Doc IR 升为 `cjdoc.doc-ir/18`，严格 decoder 只接受 v18。逐文件 `FileDoc.provenance` 及其完整状态/原因/仓库路径/raw digest/normalized digest/receipt identity/evidence kind 字段都是必需的；无值以 `null` 表示，构造默认是 `unavailable/no_registration`。`declaration/3`、`page/2`、`query-result/4` 切换为新 consumer shapes；query-request/3、search-index/11、search-contract/2 保持不变。旧 JSON 必须从保存的源码重新生成，不能迁移或只改版本号。
- `verified` 只表示 caller 独立 pin 的 `cjdoc.source-provenance/1` receipt 与本次捕获文件字节匹配，`evidenceKind` 为 `caller_pinned_receipt`；它不是 Git commit/tree/blob、远端仓库、构建成功或工作树状态的独立认证。旧项目仓库映射仍为 `declared/legacy_project_repository`，没有 pin 或文件 digest。严格登记的缺失/不匹配来源不回退到项目仓库并且没有 source URL。decoder replay 只验证保存的 wire 与状态组合，不重读 source、Git 或 receipt，也不重新认证调用方信任。`ReExportDoc.source` 表示 exposing module 的暴露位置，目标 declaration source 仍表示目标定义位置。
- v18 的提示以 `note`、`warning`、`danger` 的捕获 Markdown AST 表示；只有直接位于 document 下的非空 block admonition 节点有效。`localizationScope` wire 字段必需，模型默认 `all`；`admonitions` scope 要求 `defaultLanguage=null` 且 localized texts 只含提示等级，同时保留普通摘要、正文和其他 tags。`DocTag.entryId/source` 与 `DocumentationText.entryId` wire 字段始终存在，构造默认 `None`。HTML、Markdown、Agent 和 query/search 复用同一捕获内容；full-ir 检索完整 AST/提示 tag 正文，bounded-static 仍限前 2,000 个 Unicode 码点。风险等级是作者文字，不是实现风险验证结论。
- PR #179 首个发布 HEAD `ec5ba7a3b6575f209529490ffbaee2922da749de` 的 [远端 Reader 配对](https://github.com/lIlIIlIll/cjdoc/actions/runs/41505400887)通过全部 248 项严格比较，0 failure；实际 registration digest 与 comparison 绑定已核对，测试合并提交为 `ed765bdc9232951613c37ec61619f37c0d7b9572`。该结果不抹除本地两次全量配对的 13/14 项 timing failures，也不把未确定根因写成环境噪声；后续 HEAD 仍须重新取得对应 CI 证据，原预算与任务集合不变。
- 来源登记索引与查询统一使用 registration 对象已有的规范化 host root，修复 Windows canonical `\` 路径不能匹配 `/` 查询 key、进而错误报告 `no_registration` 的问题；不改变 POSIX 文件名、containment、receipt 信任或资源预算。增加相对/绝对单文件登记去重、精确文件映射与相似前缀 sibling 不捕获的真实生成回归；Linux focused capture 12/12 通过，773 项因 filter 未运行。Windows 是否通过以对应 HEAD 的远端 CI 为准。
- `@example` 后的受支持顶层 `@deprecated`、`@author`、`@version` 元数据不再被吞入示例正文；围栏中的同名文字仍保留为示例内容。
- 提示正文只有 Markdown 引用定义、解析后没有正文节点时，使用既有 `CJDOC3117` 空提示诊断并保留作者原文，不构造违反严格 Doc IR 契约的空提示框。已配对空译保留身份并使用原回退规则，冲突条目不重新配对。指南中的无正文 marker 保留普通引用，诊断绑定源文件而不写入空的符号 ID。
- 提示专用范围中的普通示例继续捕获 Markdown AST、代码高亮及语义链接；普通正文和示例仍执行语义链接诊断。增加有/无提示的对照回归，覆盖格式化正文、已解析/未解析链接、双语投影与严格 JSON 回放。
- Reader 合成 search script fixture 用显式 UTF-8 字节写入生产者的 LF wrapper，避免 Windows 文本写入将其改成 CRLF 后被严格身份校验拒绝。只修正 fixture，保留实际 script grammar、digest、注入拒绝和性能预算。
- 提示专用范围中的容器按普通正文结构判断 Overview，保留已有描述的 `#overview` 深链；仅摘要的容器继续省略该区域。有/无提示及仅摘要的双语严格回放回归覆盖这个边界。

#### 阅读上下文与精确导航回退（#180）

- 本地化 introduction 链接和版本切换在目标语言缺章节时打开同一页面开头，并显示本地化说明，不再指向无效 fragment。
- 声明字段锚点按 namespace 区分，参数、返回值与重复异常章节不再互相覆盖；字段 Markdown 没有可渲染正文而作者原文非空时按结构化文本输出，不产生空块。
- 版本导航增加显式状态（命中、缺符号、缺语言、缺章节、缺页面），只把校验过的 symbol-index 路由写入 HTML 属性，复制链接、中键和键盘导航与页面内跳转一致。
- 阅读器上下文标记受 DOM 预算约束，描述容器在预算内复用；extension 的来源跟随捕获的 owner 身份，而不是按名称猜测。

#### 手册与源码安装入口（#181–#182）

- 用户手册重组为安装、连续教程、操作专题和参考四组，共 24 篇正文；八篇旧平铺手册由新路径直接替代，不保留重定向。发布树复制完整的新目录、README 品牌素材与预览素材，并拒绝复制链中的符号链接。
- 首次成功使用无外部依赖的 `docdemo` 静态库，随后在同一项目加入指南和作者维护的中英文内容。章节映射使用生成页的实际标题锚点，不将原始英文标题、标题相似或条目顺序当作配对证明。
- 安装主路径从与手册匹配的源码构建，保留 STS 1.2.0 runtime 前提；公开发行包 v0.7.7 单独说明其真实源码和 Doc IR v16，不能代替当前 v18 工具验证。
- 顶层帮助补齐 `generate --format symbol-index`，并把 `versions compose --release ID=TEXT` 明确为纯文本元数据；不改变参数解析或发布语义。自文档 checksum 按真实生成结果刷新，性能 profile、声明门槛和资源预算不变。
- 真实展示站预算验证发现显式 `ZipInfo` 不继承 ZIP 容器的压缩级别；离线包和源码示例包改为对每个成员显式应用既定 level 9。压缩调整不改变同一输入的成员、内容字节、顺序或安全提取规则；README PNG 另作无损重编码，逐像素不变。站点与离线包预算保持原值。
- 保留展示首页的既有样式表，使新增 favicon 不影响中英文首页的布局、主题和移动端品牌尺寸。文档负例工作流限定在 Bash 子 shell 中，在代码块返回交互终端前恢复临时源码与覆盖率配置。
- 补充父目录锁的失败关闭边界：进程查询不确定时保留旧锁，不能把外部确认 PID 消失当作自动恢复证明；需要继续生成时使用独立且互不重叠的父目录，不接管或删除旧事务。
- 自托管展示站的 API 根首页与概念首页均将手册链接固定到该次发布的源码 revision；其它项目的 API 首页、README badge 与原始 Doc IR 保持不变。
