# Issue #137：逐声明读取、共享查询与真实 Agent 验收

本记录区分原生回归、静态发布、真实客户端、源码判分、消费者编译/行为和远端 CI。协议接通、编译成功、程序退出 0 和模型任务正确不是同一结论。对照中的失败保留在分母内；本机结果不代表 GitHub runner 结果。

## 可审计证据

- [54 条 AF 实现/回归映射](agent-reading-acceptance/implementation-map.json)与 [AI-T01–20 分层实跑映射](agent-reading-acceptance/acceptance-map.json)。
- [原生完整门禁](agent-reading-acceptance/native-gate.json)、[双版本双语发布](agent-reading-acceptance/static-publication.json)、[逐文件字节/hash 清单](agent-reading-acceptance/static-file-manifest.json)。
- [HTTP/断网 file 浏览器记录](agent-reading-acceptance/static-browser.json)、[无 SDK/源码/网络的真实运行回执](agent-reading-acceptance/offline-runtime.json)。
- [固定规模原始协议](agent-reading-acceptance/fixed-input-cost/protocol.json)、[全部 15 次成本观测](agent-reading-acceptance/fixed-input-cost/observations.json)、[汇总与限制](agent-reading-acceptance/fixed-input-cost/summary.json)。
- [证据索引及原始/显示文件 hash](agent-reading-acceptance/evidence-index.json)。复现命令见[评测维护手册](../maintainer/agent-evaluation.md)，产品用法见[机器读取手册](../agent-reading.md)。

## 固定身份

| 对象 | 身份 |
|---|---|
| API 示例源码基线 | `677f36045135ffac967ffebd195b62f1a67b33ff` |
| 已审查 native 实现 revision | `9610eb4fffafb3c6ff73762ae76243767892e25f` |
| native 源码 tree | `d9dbde146e8d8f45ea5495fb8856c90e4b2b2bee` |
| native 主程序 SHA-256 | `57fccf60012c72b3fd36a08262f9a480ba1160d6ab9b3dbcc598dc9024c5e52f` |
| build manifest SHA-256 | `c2159f691f88de55f648bff2e5c4537c26b0751fa0fcb502929ceeca1e3ed399` |
| SDK | Cangjie STS 1.2.0 / stdx 1.2.0.1；`-O1` |
| 产品与 Doc IR | cjdoc 0.7.3 / Doc IR v16 |

build manifest 的临时 checkout commit 只用于构建来源记录；它与上述逻辑 revision 的 tree 相同。任务配对使用相同源码、输入、客户端和协议，不使用临时 checkout commit 作为配对单位。后续文档、验收数据及 Python 发布布局修正不冒充另一份 native 二进制。

## 本机完整门禁

| 层级 | 实测结果 |
|---|---|
| repository-input preflight | 42 项通过 |
| source-bound build | 通过；主程序和 worker 已固定 hash |
| Cangjie unit | 666 通过，0 跳过，0 失败 |
| Python tooling | 共报告 544 项，其中 9 项跳过；未将跳过计为执行通过 |
| showcase contract | 204 项通过 |
| 配置实际 native 的 MCP 集成 | 22 项通过 |
| 外部消费者 API / CLI 对照 | 11 项通过 |
| CLI、golden、schema、HTML、资源、安全及 provider | 完整门禁通过 |

完整门禁耗时 1541.70 秒。该门禁与真实模型实验分别执行；真实实验没有进入日常确定性 CI。54 条 AF 要求逐条映射实现与回归入口；AI-T01–20 的运行证据另行列出，不用文件存在或接口接线代替行为证明。

## 静态发布与离线读取

同一固定源码真实生成 PocketKit API 0.1.0 与 0.2.0，分别发布英文和中文四个文档根。每个根都对实际 producer 产物运行严格 schema、身份、完整表示映射、资源 hash、分页/分片和非法结果拒绝检查。两个 v2 根保留原始 example-check 和 API-diff 报告；聚合报告缺少逐输入绑定时保持 `binding_unavailable`，没有升级为逐示例通过。

受控 native 离线包包含 1419 个文件，展开后 27,717,949 字节；ZIP 为 4,541,167 字节，SHA-256 为 `b68a302b834414b0976b52ab955314f23bfe6f46b944debf2c20461d68f11115`。每个解压文件都与打包前的实际字节和 hash 相同；包内没有编译器、SDK、源码或二进制归档。它是受控四文档根实验，不与正式 showcase 下载包混用大小或身份。

真实 Chromium 已检查：HTTP 子路径中搜索 `window`、进入精确声明、读取完整命名默认参数签名和三个完整示例、发现 manifest/Markdown/source 链接；语言切换保留当前声明，版本切换保留语言及存在的声明路径。解压后的 `file://` 页面在初次导航前启用断网，搜索和完整正文仍可用，实际 12 个请求均为成功的本地文件请求。HTML 的严格 CSP 阻止页面脚本任意 `fetch`；独立 HTTP 读取器仍实际取得 JSON manifest 和完整 Markdown，不把 CSP 拒绝说成资源不存在。

部署须保留完整 HTML 文档根及其中的 `agent/`，不能仅搬运 `agent/` 而丢失 manifest 指向的 HTML。正式展示站由既有 Pages 流程发布[完整离线 ZIP](https://liliilill.github.io/cjdoc/downloads/showcase-offline.zip)；应核对对应 main 部署 revision，不与受控实验包混用身份或大小。

同一最终 native 在真实隔离命名空间中，仅挂载最小运行库与捕获文档；清空环境，不挂载 SDK、源码、项目或 home，并隔离网络。实际探针观察到 `cjc`、`cjpm` 和 SDK 环境变量均不存在，只有 `lo` 网络接口；随后 CLI 与 stdio MCP 对同请求返回完整相等的核心 JSON 和正文。运行库依赖不被误称为 SDK。

## 固定规模成本：没有声称整体加速

固定同一 54 声明、API 0.2.0、v16 输入，以相同发布参数交替运行三对 native 进程。新路径增加逐声明表示，因此不是相同输出量的速度对比；这些是本机描述性测量，不是跨硬件保证。

| 发布指标 | 基线 | 最终 native |
|---|---:|---:|
| 耗时中位数，秒 | 12.506743 | 20.530903 |
| peak RSS 中位数，KiB | 181940 | 203412 |
| peak RSS 最大值，KiB | 191820 | 203660 |
| 文件数 | 132 | 266 |
| 产物字节 | 2137745 | 4538349 |

| 最终 native 新进程查询 | 三次耗时中位数，秒 | peak RSS 最大值，KiB | 单次结果 UTF-8 字节 | 状态 |
|---|---:|---:|---:|---|
| resolve_docs | 9.399081 | 201884 | 4866 | ok |
| search | 9.419709 | 202860 | 4531 | ambiguous；两个真实重载 |
| get_symbol(window) | 9.406881 | 203508 | 70235 | ok |

每种查询的三次原始响应 hash 一致。这里的“新进程”不表示冷 OS 缓存；旧版本没有等价 native 查询操作，因此不伪造旧查询时间。发布耗时与字节均增加，不能从较少工具调用推出总耗时改善。RSS 包含运行库及 native 映射，不等同于所设 512MB Cangjie heap 上限。

资源约束沿用已公布值：查询输入 1–64 个，规范 Doc IR 合计 64 MiB，读文件累计 512 MiB；请求 1 MiB/深度 64；内容预算默认 64 KiB，可请求 1 KiB–64 MiB；核心 JSON wire 64 MiB；静态 navigation/full 每片 16 MiB、单产物 64 MiB、总产物 512 MiB、条目 65536。单位是字节，不是假设的 token 保证。

既有 `tests/perf/baseline.json` 的耗时/RSS ceiling 与内容身份门禁独立于上述新实验，不根据新测量放宽。历史大输入实验另有二进制 pin：1104 个可见声明、37,478,935 字节输入，实际跨两片 navigation 与两片全文遍历；它不是本次 54 声明成本对比，也不是最终 native 的重新测量。

## schema 与证据边界

18 个既有发布 schema 和 9 个 v16 golden 保持原字节；新增 declaration、page、machine-manifest、query-request、query-result、navigation-index-v2 与 agent-full-index schema，合计 25 个发布 schema。旧 navigation v1 冻结，当前 alias 明确导出 v2；没有用当前数据重写 legacy schema/golden。

真实模型报告、原始消费者程序、逐事实/引用判定、编译与运行回执、完整轨迹归一化副本分别附带 hash。显示副本去除本机根路径、客户端线程标识、会话时钟起点及示例 loopback 地址；原始 hash 和读字节仍指向私有原始捕获。消费者原程序不被归一化或修复；其公开字节与实际编译的原始回答完全一致。模型实验的作用是观察正确性与成本，不保证每道任务都成功，也不能替代正常回归或远端 CI。

## 三次完整真实客户端观测，分别保留

原题、48 个事实、评分表、模型请求、推理强度、任务顺序、每题 24 次工具调用／262144 字节／180 秒预算均未因结果改变。客户端为 Codex 0.163.0，请求模型 `gpt-6.1-sol`、medium；两路径均禁用非文档工具。每次完整实验都是 12 题 × 2 路径，不筛题、不重试择优，不跨配置合并分数。

| 完整观测 | 记录数 | native hash 前缀 | 解释 | 报告与完整轨迹 |
|---|---:|---|---|---|
| 首轮 | 24 | `1bbb438b` | MCP host/运行库接入失败；不是有效模型效果对比。 | [报告](agent-reading-acceptance/observations/initial-infrastructure-failure/report.json) · [轨迹](agent-reading-acceptance/observations/initial-infrastructure-failure/traces.jsonl.gz) |
| transport v2 | 24 | `1bbb438b` | 保留全部有效接入后的结果；当时 native 工具说明尚未修正。 | [报告](agent-reading-acceptance/observations/pre-description-review/report.json) · [轨迹](agent-reading-acceptance/observations/pre-description-review/traces.jsonl.gz) |
| 最终接口 | 24 | `57fccf60` | 对已修正说明的最终 native 完整观测，不挑选三轮中的最好值。 | [报告](agent-reading-acceptance/observations/final-reviewed-interface/report.json) · [轨迹](agent-reading-acceptance/observations/final-reviewed-interface/traces.jsonl.gz) |

transport v2 仅修复真实客户端接入，并按 digest 引用原事实协议。`resolve_docs` 的说明曾错误承诺按符号解析，而共享核心实际选择库/模块/依赖文档集；[审查决策](agent-reading-acceptance/resolver-review-decision.json)要求保留当时正在运行的完整实验，之后只修正说明、重新绑定 native，并完整观察最终接口。没有把解析器改为符号查找，也没有借结果调整题目或预算。

### 最终接口的同条件结果

| 指标 | 旧 HTML/索引消费 | 新共享查询 |
|---|---:|---:|
| 正确 API 选择／适用任务 | 9/10 | 10/10 |
| 错选版本/范围 | 0 | 0 |
| 签名/命名默认参数错误或遗漏 | 1 | 0 |
| 固定事实遗漏／48 | 4 | 3 |
| 引用身份、出处与路由核对 | 52/52 | 34/34 |
| 不确定性保留／12 | 12/12 | 12/12 |
| 实际工具结果 UTF-8 字节 | 2336437 | 2080214 |
| 实际工具调用 | 134 | 104 |
| 全客户端耗时合计，毫秒 | 648925.216 | 856910.924 |
| 客户端正常完成／12 | 6 | 7 |
| 因预算拒绝而失败／12 | 6 | 5 |
| 所有非空消费者实际编译通过／提供数 | 6/7 | 4/6 |
| 行为验证通过／要求行为的消费者 | 4/6 | 2/6 |

API 选择的两个 not-applicable 任务是正确拒绝不可用 API，不是 API 成功；它们仍留在 12 题的其他分母内。基线额外提供了 AG-12 的非行为消费者，已按原字节编译，不用它抬高 6 个行为任务的通过率。两边预算失败全部保留；客户端完成也不等同于任务正确。

这次观测显示读取字节和工具调用减少，但新路径耗时更长，编译/行为通过更少；不能宣称整体、稳定或因果改进。中间观测的全部数字在其单独报告中，未用来替换最终结果。

逐事实判分保留：两边都未把拒绝调用后的状态检查升级为已读到源码内部“先失败再追加”的时序保证；基线还缺少确切 since 契约、组织限定导入及完整 window 重试，新路径缺少关闭异常的确切子类型和 owner 的无内部同步契约。缺失、保守拒绝和错误调用没有被改写为已验证。

### 原始消费者与实际行为

最终 13 段非空原程序全部只尝试一次编译，10 段通过、3 段失败。失败分别为基线 AG-03 的未绑定 `pocketkit` 名称，以及新路径 AG-03、AG-07 的未导入 `assert`；原程序和诊断完整保留，没有增加 import、package 或修好后重算。

实际执行 9 段，均退出 0，但只有 6 段经完整控制流审查覆盖要求：基线 AG-01/04/05/07，新路径 AG-01/05。两边 AG-02 都只调用而未读取/检查已存值；新路径 AG-04 仅捕获通用 `Exception`，没有验证所需 `IllegalStateException`。这些程序不因退出 0 获得行为通过。两边 AG-05 的 stdout `3` 来自真实 `Entry<String>("汉").byteLength()` 计算，不是硬编码成功标记。

### 实际客户端正文与 CLI 同任务

[真实客户端正文证据](agent-reading-acceptance/real-client-body.json)逐一比较最终 AG-01 的 8 次实际 MCP 完成结果：完整可读 `content[].text` 与结构化结果均与真实客户端事件相同，最终回答复制了精确 snapshot ID、symbol ID、完整签名和一行作者正文。不根据前缀命中或协议初始化推断模型看到了全文，也不声称知道隐藏模型状态。

[CLI 复放](agent-reading-acceptance/real-client-cli.json)使用同一有序五快照，原样重放上述全部实际请求，完整核心 JSON 均相等。其中 3 次模型传入未声明的 `includeRelations`，MCP 与 CLI 都返回 `invalid_request`；CLI 退出 2 是正确领域错误，而不是要求所有调用退出 0。错误同样保留并计入成本。任务的原始消费者随后真实编译并通过状态/异常验证。

## 最终发布布局修正

原 Python showcase 发布器在完整 `api/` 文档根之外，另复制孤立的 `artifacts/agent`。对实际 native 产物的检查发现它有 65 个 HTML 映射在该副本文档根中不存在。[真实消费者负例](agent-reading-acceptance/publisher-layout-negative.json)中，隔离副本被 native 输入读取与严格图校验拒绝，而完整文档根成功。

修正删除这个尚未发布的无调用者副本，不增加别名或另一套 manifest。完整 `api/` 保持原路径；[实际生产函数 smoke](agent-reading-acceptance/publisher-cutover.json)使用真实 native 的全部生产格式生成，再调用修改后的 `publish_compatibility`，校验完整表示闭包，并用 native 从发布后的 manifest 读取真实声明。没有用 mock 文件存在检查代替消费证明。

## 自身文档门禁的测试文件角色修正

既有 `perf_gate.py identities` 还实际发现自身文档的默认生成触发了空声明资源回退。对固定 native 的异常断点确认拒绝原因是 `$.diagnostics` 处的 JSON 数组项总预算，而不是缺 SDK 或编译失败。未用空结果刷新基线，也未放宽 100000 数组项、65536 对象、64 MiB Doc IR、512MB heap 或既有耗时/RSS ceiling。

[失败前／修正后回执](agent-reading-acceptance/self-source-role.json)记录：26 个仅供测试的 suite、fixture 和 helper 文件原来缺少 `_test.cj` 后缀，错误进入自身文档的生产源码输入。修正只将这些文件归入既有测试文件命名规则，完整保留文件内容和测试；不改解析器规则，不按项目名称特殊处理。

同一 native 在修正后以原默认 `standard` lint 和相同 heap 实际生成 4924 个声明、212 个源文件、94997 个数组项和 1209 条诊断；无错误诊断，也无资源回退。852 个实际可见 API 的 SymbolId、源码 header 和全部 signature tokens 与修正前的诊断控制运行完全相同；移除的是 276 个测试输入声明，不是真实可见 API。诊断控制运行的 lint-off 仅用于确定旧输入和可见 API 集，未成为验收配置。

这次测试文件角色修正会改变后续编译输入，因而不重标前述固定 native、静态包或模型轨迹。其最终构建、完整单元测试及内容身份结果分别读取最新 revision 的门禁；本回执仅证明实际源码输入切换和默认生成行为。

内容身份检查单次生成时禁用 source cache，避免在受严格身份保护的 fixture 中留下 `target/cjdoc/cache`。这不改变正式性能门禁的显式 cold/warm 缓存测量，也不改变其 ceiling。

实际内容身份检查中，`basic` 保持原 hash；`self` 在新增 API 和测试输入角色修正后产生新的真实 Doc IR hash `d095bb0efaad0db1dd404a9368a1a05c9f2a26d1589844196f22a74d1a2246f6`。只刷新这一项内容身份，不重测或放宽既有时间/RSS ceiling，不将当前机器耗时冒充固定参考环境的性能结论。

## PR #161 的真实查询边界回归

[原生 CLI 回执](agent-reading-acceptance/review-query-bounds.json)使用相同冻结 Doc IR 重放两条真实 review 重现。修复 native 绑定 `c00cfc7ff6075c636e07fc58b4ffafa28cb78914` 的 source tree；不是把历史模型观测改标为新构建，也不是远端 CI 结论。

| 重现 | 实际修复前 | 实际修复后 |
|---|---|---|
| 关系深度 1 | 发出深度 2 的边 | 最深 1；逐条续取 5 页，与有效深度内原有边完全相同 |
| 关系深度 4 | 发出深度 5 的边 | 最深 4；逐条续取 16 页，与有效深度内原有边完全相同 |
| 歧义候选、`maxBytes=1024` | 仍返回两个候选，仅候选 JSON 已有 4473 字节 | `budget_exceeded`、退出 3，给出完整候选所需字节 |

关系遍历结束不冒充正文完整：最后一页保留 `relation_depth` 或 `resource_limit` 省略原因。歧义候选按完整 JSON 加对应可读行计费；固定协议封装和诊断前缀不在这个内容预算内。按真实字节提示重新开始后，两页候选逐字段与冻结旧响应相等；改变预算却沿用旧 cursor 的负例仍明确返回 `stale_cursor`。

发布体积修正保持所有声明及正文：机器 manifest 复用文档根唯一的 `symbol-index.json`；自包含 Doc IR 仅去除 JSON 结构空白；侧栏导航元数据通过静态 `sidebar-index.js` 共享。完整声明 HTML、Markdown、JSON、包及成员索引不被抽样或截断。既有全站与 ZIP 字节 ceiling 保持不变；最终发布结论仍以最新 revision 的实际门禁及下载包为准。

## 远端密封发布体积与入口迁移

[下载后实测回执](agent-reading-acceptance/publication-size-review.json)记录两次真实 PR 密封产物，并重新计算修正后目录的 seal。后者的触发 HEAD 为 `38a7d1557c1f08597722d820d0bd6257a5bb3fbc`，实际构建 source revision 为 `ce2611fa5f7634362b7d18f30c77938256563c7b`；不把 PR HEAD 和 runner checkout commit 混为一谈。

| 字节指标 | 原密封产物 | 去重后密封产物 | 既有 ceiling |
|---|---:|---:|---:|
| 全站 | 122785840 | 97088160 | 100000000 |
| 离线 ZIP | 16774105 | 14515040 | 16000000 |

11 个文档根的全部 1205 条表示映射逐字段相同，包含 kind、身份及 HTML/Markdown/JSON 路径。该次运行仍因陈旧的资源 schema/库存校验和 machine journey 文档根查找失败，不能标为 CI 或发布成功。入口迁移修正保留严格的逻辑快照重算、物理文件 hash、资源完整闭包及非法根资源负例，不通过移除校验来过门禁。

后续跨快照 context 修正的 10 项公开查询契约实测通过，包括消费者快照恢复和目标候选仍被固定；其余 660 项未被本次 filter 选中，不计为完整单元测试通过。更正后的自身源码预提交捕获仍有 4931 个声明、95134 个数组项、1209 条诊断和零错误，852 个可见 API 的身份、header 与源码签名完全相同；实测内容 hash 为 `1de1d2f4ec32e864d378ce27b3c7ae702d0bdf6d56d47840b59d624635013f5c`。只同步内容身份，不改变时间/RSS ceiling；干净 HEAD 内容身份与跨平台 CLI/MCP 仍分别读取最新门禁结果。

## Review 的上下文隔离与概念链接

[固定输入与原生消费者回执](agent-reading-acceptance/review-scope-links.json)保留同一请求在修正前后的实际结果。相同 API identity/key、不同 target、cfg 或捕获依赖图的相关快照，不再获得错误的 resolved 目标；原始导航逐字段保留。真正匹配的对照响应完整不变，包括仅保留依赖图、没有发布依赖 `ModuleDoc` 的消费者。公开关系测试同时覆盖 exact、compatible、manual 及不完整图，不把过滤掉的其他测试计为通过。

概念页输入复制真实本地与依赖导航到受控 Markdown AST：原来本地目标只有文字，外部链接误指 `../html/`；修正后逐页 Markdown、JSON 正文和文档根查询分别使用各自实际路径，仍保留原始导航等级。实际 stdio MCP 逐字段及完整正文与相同 CLI 请求比较，不用 mock 返回值证明转发。

实际浏览器进一步读取上述原生逐页 Markdown，发现本地 `pocketkit.TextCatalog.add` 文件存在，但附加的聚合 Markdown `symbol-…` fragment 在该独立 HTML 页上不存在。规范 HTML 路由不再虚构此 fragment；回归改为验证真实目标 HTML 产物及可选 id，删除仅固定 `#symbol-` 展示的断言。当前完整原生测试实测 674/674、零跳过/错误/失败，包含此链接闭包、关系上下文和相对文件读取边界；不把它改标为较早固定 CLI 或远端 CI 结果。

machine journey 的发布身份改由结构化 manifest/全文索引配对，并遍历实际全文分片；不重新固定旧的展示文案。生产构建所得 11 个文档根、1118 个声明的完整源码 header、限定名、hash、范围和续取均实测；真实浏览器点击 JSON、导航、Markdown、全文四种入口并返回原页面。该静态观测绑定其原构建，不改标为后续查询 native 或最新 CI。

macOS 的真实失败日志已定位为普通 `agent/docs.json` 在 FD regular-file 验证处被拒绝。Darwin 改为对打开的描述符调用 `fgetattrlist` 查询 vnode 类型，不借助 `/dev/fd` 路径反查，不重新打开文件，也不猜 `stat` 结构布局。相同相对读取正反例扩展到 macOS；Linux 的定长数组 native ABI probe 仅证明本机调用模式，不冒充 Darwin syscall 或远端门禁通过。

本轮默认 self 生成也实际触发 `CJDOC3027`：临时诊断定位为 `$.diagnostics[1206].source.start` 超过既有 65536 个 JSON object 上限，不是新页面或 API 被允许省略。原完整输入已有 65508 个 object。移除新查询/JSON 编码切换后无调用的内部序列化函数，以及不再用于生产读取的无 captured-size 相对入口；读取测试改走真实 `readFileBoundedWithinExpected`。预提交默认 JSON 捕获恢复为完整的 4931 个声明、65499 个 object、95118 个数组项、1209 条诊断和零错误，独立库存恰有原来的全部 852 个可见身份，header 与源码签名完全相同。其 hash 为 `3c312e5f052c01ee616da96e60f83bedbe2d23d63e7b9e60f8a34b12814c4744`；未改变任何 codec、时间或 RSS ceiling，临时诊断代码已撤回。该捕获使用较早固定原生程序读取当前源码，不冒充后续链接行为修正；干净 HEAD 的正式身份门禁仍单独核验。

本轮功能 smoke 使用预提交的固定 Linux 可执行文件；不声称它完成了干净 HEAD 的完整受保护构建。完整构建、完整单元、跨平台 CLI/MCP 与两片浏览器门禁继续以最新 HEAD 的实际运行结果为准。

## 原生构建与 CI 发现的发布入口

`f8eb25d429f18d48df7777967ca9478ae22f60fa` 的受保护原生构建已实跑通过；固定应用 SHA-256 为 `1eb6f2bdb3f9f42a36ed17b8ad8cb098e035e69af6df7f622efa6e4dbbfd236f`。同一固定输入的五项真实 CLI 与五项 stdio MCP 均通过，MCP 的结构化结果及完整正文逐字段等于 CLI。匹配对照的结构化查询内容不变，正文只发生移除不存在的独立 HTML fragment 这一预期变化。真实浏览器从概念 Markdown 跳到本地声明，落点具有完整源码 header，且没有虚构 fragment。

[该 HEAD 的远端 CI](https://github.com/lIlIIlIll/cjdoc/actions/runs/40207271463) 中，Windows job 已通过，macOS 的五项相对 FD 读取正反例均通过。macOS 原生单元仍有两项失败：程序实际产出安全图片，测试却把能力限定为 Linux。测试能力条件现与生产的非 Windows 描述符相对读取一致；Linux 两个精确 `Class.method` 用例各实跑一项通过，不把未选中的 673 项算作通过，也不冒充后续 macOS MCP 成功。

同一 HEAD 的 Linux 正式身份门禁实际生成 `880bb2e4cb601507fadb7b6e9551b7ba61d0dfa249837e0c295ef5bc979f7fc9`，与本机停止 fixture 活动后的捕获一致，但与较早 `3c312e…` 基线不同。完整模型比较仅有根项目依赖的 `identity` 与 `instanceId` 两处差异。源码依赖指纹包含测试目录内的 `.cj`、`cjpm.toml` 和 `cjpm.lock`，不能与会改写这些文件的测试并发捕获。上述测试条件修正完成后，重新捕获的完整模型 hash 为 `8d782d44d140a205e6cf1b4b676ef15c8e66868ad4711e93a600458a456a9982`，仍只有这两个身份字段变化；声明、公开 API、诊断数量和资源限额不变。这里只同步已观测内容身份，干净新 HEAD 的正式门禁另行核验。

[Pages 两个浏览器分片](https://github.com/lIlIIlIll/cjdoc/actions/runs/40207271453) 揭示另一真实生产问题：可见 Markdown 操作仍由旧聚合 Markdown 的标题反查，目标与原生表示 manifest 不同。Showcase 改按原生 HTML 路径查找 manifest 的 Markdown 表示，移除标题解析器；未发布表示的报告页不再提供无关聚合内容。原始严格浏览器比较保持不变。回归覆盖任意原生路径、概念页、重复旧标题及无表示页面；该模块 20 项实跑通过。

更新后的挂载器直接处理上述固定原生 HTML，真实浏览器分别在 HTTP 和 `file://` 点击 class 与 concept 的可见 Markdown 操作并返回原页面，四项落点均精确等于原生 manifest。HTTP 的完整 UTF-8 文件内容与原生产物相同。离线浏览器识别 UTF-8；本机普通 HTTP 测试宿主未声明 charset，浏览器按 windows-1252 显示，不能用这次点击记录声称 HTTP Unicode 显示已验证。完整双分片矩阵及部署宿主仍以新 HEAD 的实际结果为准。

## 发布与复算

每轮 `traces.jsonl.gz` 是 UTF-8 JSONL 的 gzip：首行描述归一化口径，后续每行包含相对文件名、原始/显示字节数与 SHA-256、完整显示文本。包含全部 24 条 record、客户端事件、真实 stdio、答案、逐项判分，以及每段非空原程序和实际编译/运行日志；不包括 SDK、库产物或 ELF。对应 `traces-receipt.json` 列出完整文件清单。显示文本不是可冒充原始运行目录的副本；消费者输入字节保持原样，原始消息读字节独立记录。

公开资料保留所有 72 条完整观测和所有失败，历史 smoke 的二进制 pin 不会改成最终 native。静态下载包由 `.github/workflows/pages.yml` 的最终树生成并密封；PR 的 sealed-site artifact 与最终 main 的部署/CI 结果由 GitHub 实际运行记录提供，不由本机 PASS 推导。
