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
