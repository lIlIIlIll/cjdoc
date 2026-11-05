# API 阅读体验审计修复

前次 33 项修复针对 `9923d2732d004622d3db79ae26cacbb03d1ce98c` 演示站审计。
范围包括原生 HTML 阅读界面、版本组合、展示首页、报告阅读和示例指南。
下列 F/U/C 编号保留该次审计的历史背景；当前读者契约与验证入口见文末，不以历史结果代替本次提交的运行证据。

## 功能与导航

| 编号 | 审计问题 | 修改后的行为与实现位置 |
| --- | --- | --- |
| F01 | 侧栏筛选的 `hidden` 被布局样式覆盖 | `html_styles.cj` 为隐藏元素保留明确的隐藏优先级；筛选后的包和成员不会因 flex/grid 规则重新出现。 |
| F02 | 参数布局依赖已经不存在的祖先选择器 | 参数列表自身建立 grid/subgrid，通用描述列表样式排除参数列表；参数名、类型、默认值和说明按实际 DOM 对齐。 |
| F03 | 成员筛选后本页目录仍显示不可见项 | `html_scripts.cj` 在文本和来源筛选后同步桌面、移动端目录以及当前项高亮。 |
| F04 | 页面初始化时侧栏滚到当前包而非成员上下文 | 初始侧栏优先显示当前成员或类型所在位置，再回退到当前包。 |
| F05 | 内联重载切换版本时丢失当前成员 | `version-navigation.js` 根据原生 SymbolId 映射更新真实版本链接，加载、hash 变化和历史恢复时均保留成员身份；不按短名称猜重载。 |
| F06 | 带 hash 的后退导航丢失筛选和展开状态 | 历史恢复优先恢复成员筛选和各项展开状态；首次访问或主动跟随成员链接仍会清除冲突筛选并显示目标。 |
| F07 | 后退后搜索类别的 DOM 与内部状态不一致 | 搜索重新计算结果时读取实际类别选择值，避免浏览器恢复表单后继续使用旧内部值。 |
| F08 | 后退后侧栏筛选文本和结果不同步 | 保存并恢复侧栏输入、包组展开状态和滚动位置，初始化与 `pageshow` 后重新应用筛选。 |
| F09 | 报告切换版本跳回验证总览 | `showcase_build/navigation.py` 在发布时将报告的版本链接映射到同类 `report-*.html`；缺少对应报告时显示明确不可用提示。原生版本脚本保留该默认路由。 |
| F10 | Changes 默认打开机器 JSON | 当可读报告存在时，版本栏默认进入 `report-diff.html`，同时保留单独的原始 JSON 链接；没有可读报告的普通原生目录不生成虚假入口。 |
| F11 | 语言链接在新标签打开或复制时丢失 hash | `publication.js` 在加载和 `hashchange` 时更新真实 href，仅保留目标语言页面确实存在的锚点；不再依赖普通 click 才补锚点。 |
| F12 | 移动端固定页头遮住目标锚点 | 浏览器测量实际导航栏高度并通过 `ResizeObserver` 更新 CSS 变量，正文锚点使用该高度加阅读间距。 |
| F13 | 展示页和原生文档分别保存主题 | 首页、下载页和原生页面共用 `cjdoc-theme`；展示页识别原生主题值和 `theme` URL 回退，主题切换通过一致的持久化接口保存。 |
| F14 | 裸 localhost URL 吞入相邻中文句子 | 两个快照的指南使用显式 Markdown 链接；通用 Markdown 自动链接同步修复中文标点边界。 |

## 阅读界面

| 编号 | 审计问题 | 修改后的行为与实现位置 |
| --- | --- | --- |
| U01 | 页面重复提供三套成员导航 | 删除正文标题前的重复同级成员导航，保留紧凑上下文侧栏及正文成员浏览器。 |
| U02 | 类型首屏说明和成员入口被长内容推后 | 类型标题、摘要、完整签名、作者正文说明和结构化契约先出现，避免把正文中的使用约束藏在成员列表之后；示例和反向关联安排在成员浏览之后或折叠区域。 |
| U03 | 展开的成员重复显示签名、类别与摘要 | 内联 summary 保留完整签名；详情不再重复同一签名和摘要，参数、返回值等调用信息优先显示。 |
| U04 | 侧栏中的完整签名过长 | `html_labels.cj` 从现有 Doc IR 生成名字、泛型及参数类型组成的紧凑标签；完整签名保留在 title 和主阅读区。 |
| U05 | 展开标记不清楚，也无法批量展开 | 成员 summary 有明确方向标记，并提供展开全部、收起全部；批量操作只影响当前筛选可见项，空结果或无需操作时按钮禁用。 |
| U06 | 生成器版本、schema 和内部身份抢占正文 | 品牌使用当前项目名，生成器版本/schema 移到页脚，语义状态、SymbolId 和来源等元数据集中在可展开详情中。 |
| U07 | 搜索结果重复显示内部限定名和模块 ID | 默认显示所属类型或包及有区分作用的模块名；完整身份放在 title，区分重载所需的完整签名继续保留。 |
| U08 | `unavailable` 被误解为 API 不可调用 | 异常区使用“暂无文档链接”等明确指向链接解析的措辞；保留原始 `data-state` 和作者给出的异常条件。 |
| U09 | 中文界面夹杂无必要的英文界面标签 | 原生类别、来源、状态和包元信息，以及展示首页、下载页、报告的固定界面文字按 locale 显示。源码名字、作者文档、原始 JSON 和执行输出保持原文。 |
| U10 | 缺少直接跳到正文的键盘入口 | 原生页面第一个可聚焦入口跳到 `main#cjdoc-main`，避免键盘用户逐项穿过导航控件。 |

## 内容、报告与入口

| 编号 | 审计问题 | 修改后的行为与实现位置 |
| --- | --- | --- |
| C01 | Coverage 展开大量 JSON，缺少声明和源码跳转 | `report_views/reports.py` 将诊断呈现为可筛选列表，显示对应 API 与源码位置；API 链接使用原生索引，源码链接复用原生页面已验证的源地址。原始 JSON 默认折叠，输入哈希仍完整保留。诊断条目不再逐项污染本页目录。 |
| C02 | semanticLinks 口径不清，0/0 显示 100% | 界面明确“注释引用解析率”只统计显式注释引用与 `@see`，签名类型链接另列诊断。零分母显示“无适用项”；原始百分比不改写。 |
| C03 | 新用户找不到给自己项目生成文档的路径 | 首页快速开始直达安装入口、实际发布包或源码构建说明、最小 `generate` 命令和 `target/doc/html/index.html` 产物路径；示例复现作为独立入口保留。 |
| C04 | 首页 17 个能力卡片平铺，技术状态压过操作 | 卡片按阅读 API、开始使用、核对结果与版本、集成与能力边界分组，优先显示当前语言的操作说明和动作链接。完整实现状态、17 项 manifest、baseline 和验收场景不删除。 |
| C05 | 示例故意缺注释，却未向读者解释 | 两个快照的项目指南新增“教学文档缺项”说明，解释 `first`、`last`、`isEmpty` 等只有返回说明而没有独立摘要的情况。这是作者保留的教学样例，不把空摘要解释成生成器已证明没有行为。 |
| C06 | 签名和示例缺少语法层次 | `html_signature.cj` 复用已绑定的类型 token，`html_code.cj` 为 cj/cangjie 代码提供只影响显示的词法着色。所有片段仍转义；不能可靠识别的原始字符串回退为原文。类型链接和复制文本保持完整。 |
| C07 | 新增 nonEmpty 没有版本提示 | 示例作者为 `nonEmpty` 添加 `@since 0.2.0`；这是 `demo-v2/cjpm.toml` 中的实际示例包版本，摘要仍明确它属于 demo-v2。没有把教学快照名当作 cjdoc 工具版本。 |
| C08 | 旧版没有成员时只能退回总览 | `versionSymbolTarget` 优先回到目标版本中仍存在的所属类型，并显示该成员在此版本不存在；所属类型也不存在时才回到总览。 |
| C09 | 可读链接和旧稳定路由无法兼顾 | 为声明生成可读别名页，复制链接使用该别名；别名再指向原生稳定 SymbolId 路由，旧路由继续保留，避免破坏已分享的引用。 |

## 证据与能力边界

- 展示层只读取原生 Doc IR、coverage、quality、doctest 和 diff，不重新计算兼容性或覆盖率，不制造逐例执行状态。
- `report-provenance.json` 继续保存输入文件的 SHA-256；报告中的原始 JSON、执行输出和来源链接可以继续核对。
- 外置契约合并、扩展适用性推断及逐例原生指令状态的既有 partial 边界没有升级。U08 只修正读者文案，不把 unresolved/unavailable 改成 resolved。
- C05 选择明确解释教学缺项，而非用推测出的说明填满所有字段；C07 只标注已知的示例包版本。
- 语言界面本地化不自动翻译或改写作者 API 契约。代码着色不参与声明解析、语义绑定或类型判断。

## 文档读者契约（当前实现）

| 问题 | 当前行为与边界 | 永久回归入口 |
| --- | --- | --- |
| 独立成员页缺少 owner 的使用约束 | 独立 API 页按可见的真实 owner 链显示摘要、正文与作者契约，附精确来源链接和责任边界说明。nested type 同样适用；extend 仅补充显式 resolved 且可见的目标类型。不复制 owner 示例、参数、返回值或兄弟成员，也不把任意 derived type 的契约套给继承成员。 | `html_introduction_test.cj` |
| 参数或返回说明静默留白 | 缺项和普通作者空说明分别就地提示，保留实际类型及独立参数说明。翻译 missing/empty/conflict/fallback 仍由翻译状态呈现；Unit 没有作者返回说明时不制造模板。 | `html_members_test.cj`、`html_language_test.cj` |
| 正文引用丢失语义状态 | 正文和 tag Markdown 的 `semantic_link` 在内容旁保留 unresolved、ambiguous、unavailable，使用 `data-reference-state`。手工导航可用不代表语义已解析；安全策略拒绝外链也不把已解析语义改成 unresolved。 | `renderer_safety_test.cj`、`dependency_navigation_render_test.cj` |
| 版本切换混淆回退原因 | 完整显式身份配对，不按名字配对重载，不解析不透明 ID 中的分隔符。切换链接区分 exact、missing-language、missing-symbol、missing-section、missing-page；hash 往返恢复初始化时的真实 DOM href、文字和状态，保留发布层路径改写。 | `reading_navigation_test.cj`、`i18n_review_test.cj`、`version_context_members_test.cj`、`i18n.spec.mjs` |
| 表格绑定返回指南首页 | 只接受捕获器准入的 exact sentinel，并核对原始 source/path/line、resolved 绑定和目标身份。`html_block` 与 `html_inline` 均按捕获标题树回到确切章节；代码或 literal 中的伪 marker 不参与关联。 | `conceptual_showcase_test.cj`、`html_reading_test.cj`、`html-reading.spec.mjs` |
| 调用者指南无法独立运行 | demo-v2 的中英文指南针对 PocketKit 0.2.0 教学快照、STS 1.2.0，提供 executable 清单、相对 static dependency、工作目录、四个完整替换程序和成功标记。五个共同 section ID 连接双语阅读路径，API 使用精确 signature 绑定；v1 保留历史教学内容。 | `reader_contract_review.py`、`test_reader_benchmark.py` |
| 语言回退只在 title 中出现且提示残留 | 语言名称仍是标签内的 toggle。缺页面的回首页说明由服务端可见输出；缺章节则提示打开同页开头。映射恢复、空 hash 和历史恢复清除过期的章节提示，但不清除页级回退说明；保留 tag/moduleId 并移除旧 snapshotId。 | `html_language_test.cj`、`i18n.spec.mjs` |

这些修复保留生成器与作者内容的责任边界：没有 owner 文档或说明缺项，不等于没有使用责任。
生成器没有增加资源 requiredness schema，也不从实现推测释放义务。
指南中的四项是教程练习，不是全库核心任务清单；`TextReader` 的关闭责任来自原作者文档，指内存会话而非 OS 文件描述符。

Owner 上下文保留完整来源身份和精确链接，但标题使用页面内入口及来源身份的 SHA-256 命名空间，
不把当前声明和来源声明的完整十六进制身份重复放进每个标题。
版本回退消息由同一服务端本地化函数生成，整站共享一份脚本词典；页面初始可见说明不依赖 JavaScript。
完整发布目录仍受原有体积预算约束，不通过删减指南、出处或离线内容满足预算。
参数和返回值的普通缺项提示直接使用已有说明容器，不为每条缺项增加包装节点；
作者显式空 tag 及翻译状态仍分别保留，不放宽 Reader 的 DOM 增长门槛。

## 验证入口

`tests/showcase_contract/test_reader_ui.py` 覆盖报告筛选、指标口径、原始证据保留、当前语言任务入口、安装路径、主题共享、语言 href 同步，以及发布层报告路由与原生版本脚本的兼容性。
`scripts/showcase_contract/browser_reading_regressions.py` 与 `scripts/test_html_search.py` 覆盖浏览器状态、键盘和阅读交互；原生 renderer/versioning 的对应测试覆盖稳定路由、别名、签名及转义。
`scripts/reader_contract_review.py` 把两份指南、配置、清单与代码的实际复制字节绑定到回执，
按共同 section ID 执行八个完整指南程序，并与原十三个 C/R 消费者用例分项记录。
每个程序使用独立的完整 caller/sibling-library 目录，避免短间隔替换同一源文件时复用旧增量产物；
成功标记校验不放宽，回执的程序路径指向该次真实编译输入。
非零退出、超时、缺少或额外成功标记均拒绝；结束时复核原始输入没有变化。
普通 Markdown 围栏不是 `@example` 产品语义，指南运行证据不能冒充源码 doctest 报告。
调用该脚本前按 [build.md](build.md) 准备认证环境，并指定实际完整源码 SHA 的 `--revision` 与任务独占的 `--output`。

浏览器套件需使用同次原生产物。`i18n.spec.mjs` 同时要求 `CJDOC_I18N_SITE` 指向
`i18n_gate.py` 的 `multi` 根、`CJDOC_I18N_COMPOSED_SITE` 指向同次 `composed` 根；
PocketKit 阅读 fixture 保留 HTML 根旁的 `site-manifest.json`，用于核对 API 回链的确切任务章节。
两语言指南末尾的项目介绍链接也须命中同语言 manifest 中捕获的 `concepts/index.html`，
并实际导航到可读正文；作者链接按各自 Markdown 源文件的位置解析，不能把输出目录当作源目录。
`search.js` 的安全摘要必须从实际原生 emitted bytes 更新，继续保留严格资产 allowlist 与负例。


```sh
python3 -m unittest discover -s tests/showcase_contract -v
python3 scripts/test_html_search.py
python3 scripts/test_validate_html_site.py
cjpm test
```

完整验收仍需针对本次原生生成的最终目录运行现有根路径、项目子路径、离线解压目录、语言与视口矩阵，并独立报告 build、unit、golden/integration、真实仓库和远端 CI 的实际结果。
旧原生数据的展示层预览只用于检查阅读界面，不能替代新源码生成、示例执行或远端 CI 的证据。
