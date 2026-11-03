# cjdoc 0.7.6 发布记录

`0.7.6` 用于重新准备发行。发布状态及可下载资产以 [Releases](https://github.com/lIlIIlIll/cjdoc/releases) 为准。

本版本包含以下改动：

- 收集 `public macro` 的源码签名、参数、返回类型和文档注释。
  恢复 `@Derive` 等宏包装内的源码声明、成员、可见性和位置；未展开调用继续保留不确定状态，不虚构生成成员。
- 由完整验收链负责产品构建，删除发行工作流前置的重复构建，并在验收成功后核验待打包的同一二进制。
- Windows 发行使用已在 CI 验收的 `windows-2022` runner。工具链、产品优化参数和测试断言保持原值。

Doc IR 仍为 v16。生成器版本改为 `0.7.6`，需要重新生成 current golden 和性能文档身份；此变化不代表新的性能测量结论。

## 保留的 0.7.5 记录

[`v0.7.5`](https://github.com/lIlIIlIll/cjdoc/tree/v0.7.5) 保留在提交
[`a1852d6`](https://github.com/lIlIIlIll/cjdoc/commit/a1852d68ae3ac06dc50f6273eeade8099dee223b)。
其[发行运行](https://github.com/lIlIIlIll/cjdoc/actions/runs/40362242523)在 macOS 和 Windows 的第二次产品构建中失败，未发布 GitHub Release。
`0.7.6` 使用新的发行身份，不移动旧 tag。本次修复调整构建执行图和 runner，编译器崩溃的根因仍未确定。

## 后续查询、分类与分组实现记录

以下记录补充当前源码中的后续功能变化，不表示这些改动属于 `0.7.6` 发行内容，也不报告构建、测试、浏览器或 CI 状态。

- 查询与静态检索采用统一的 search-contract/2：precise/discovery 两种模式，full-ir/bounded-static 两种检索 profile；HTML 使用 discovery + bounded-static。当前协议为 query-request/3、query-result/3、search-index/11 和 declaration/2，Doc IR 升为 17。
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
- 这是 current-only wire cutover：Doc IR/16、旧 query-request/query-result、旧 search-index 与 declaration 版本不会被当前 decoder/消费者迁移。使用旧输入前，须从真实源码重新生成当前 Doc IR 或静态站点。

## 未发布：#173–#177 文档行为与消费者契约

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

- 当前 Doc IR 为 `cjdoc.doc-ir/18`，严格 decoder 只接受 v18。逐文件 `FileDoc.provenance` 及其完整状态/原因/仓库路径/raw digest/normalized digest/receipt identity/evidence kind 字段都是必需的；无值以 `null` 表示，构造默认是 `unavailable/no_registration`。`declaration/3`、`page/2`、`query-result/4` 切换为新 consumer shapes；query-request/3、search-index/11、search-contract/2 保持不变。旧 JSON 必须从保存的源码重新生成，不能迁移或只改版本号。
- `verified` 只表示 caller 独立 pin 的 `cjdoc.source-provenance/1` receipt 与本次捕获文件字节匹配，`evidenceKind` 为 `caller_pinned_receipt`；它不是 Git commit/tree/blob、远端仓库、构建成功或工作树状态的独立认证。旧项目仓库映射仍为 `declared/legacy_project_repository`，没有 pin 或文件 digest。严格登记的缺失/不匹配来源不回退到项目仓库并且没有 source URL。decoder replay 只验证保存的 wire 与状态组合，不重读 source、Git 或 receipt，也不重新认证调用方信任。`ReExportDoc.source` 表示 exposing module 的暴露位置，目标 declaration source 仍表示目标定义位置。
- v18 的提示以 `note`、`warning`、`danger` 的捕获 Markdown AST 表示；只有直接位于 document 下的非空 block admonition 节点有效。`localizationScope` wire 字段必需，模型默认 `all`；`admonitions` scope 要求 `defaultLanguage=null` 且 localized texts 只含提示等级，同时保留普通摘要、正文和其他 tags。`DocTag.entryId/source` 与 `DocumentationText.entryId` wire 字段始终存在，构造默认 `None`。HTML、Markdown、Agent 和 query/search 复用同一捕获内容；full-ir 检索完整 AST/提示 tag 正文，bounded-static 仍限前 2,000 个 Unicode 码点。风险等级是作者文字，不是实现风险验证结论。
- PR #179 首个发布 HEAD `ec5ba7a3b6575f209529490ffbaee2922da749de` 的 [远端 Reader 配对](https://github.com/lIlIIlIll/cjdoc/actions/runs/41505400887)通过全部 248 项严格比较，0 failure；实际 registration digest 与 comparison 绑定已核对，测试合并提交为 `ed765bdc9232951613c37ec61619f37c0d7b9572`。该结果不抹除本地两次全量配对的 13/14 项 timing failures，也不把未确定根因写成环境噪声；后续 HEAD 仍须重新取得对应 CI 证据，原预算与任务集合不变。
- 来源登记索引与查询统一使用 registration 对象已有的规范化 host root，修复 Windows canonical `\` 路径不能匹配 `/` 查询 key、进而错误报告 `no_registration` 的问题；不改变 POSIX 文件名、containment、receipt 信任或资源预算。增加相对/绝对单文件登记去重、精确文件映射与相似前缀 sibling 不捕获的真实生成回归；Linux focused capture 12/12 通过，773 项因 filter 未运行。Windows 是否通过以对应 HEAD 的远端 CI 为准。
