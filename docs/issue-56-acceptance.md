# Issue #56 验收映射

本表把 Issue #56 的 RDR 工作项映射到本次实际提交、测试与运行证据。
只记录**实际执行过**的结果；未完成项明确标注，不以计划或旧 issue 勾选代替。

日期：2026-10-09。基线：`d948995`（及后续 rebase 后的 `d7c1e01`）。
证据命令均在本机 Cangjie SDK 1.2.0 + stdx sidecar 下执行；CI 证据取自 GitHub Actions。

## 1. 工作项状态

| 工作项 | 状态 | 实现 / 证据 |
| --- | --- | --- |
| RDR-01.4 关系入口位于默读区域 | 已交付 | 由上游 PR #58 合入（`symbol-relationships` 位于成员浏览器之前、关系名本地化）；本次复核未重复实现 |
| RDR-01.1–.3 签名类型链接与复合类型 | 已交付 | PR #81（CHIR 解析身份贯入 Doc IR；复合类型内部类型可链接；默认路径不变） |
| RDR-02.1 检索语料 | 已交付 | PR #67（`body` 字段，来源 Markdown AST + 标签说明） |
| RDR-02.3 排序可解释 | 已交付 | PR #67（正文命中为第 8 档，低于所有名称/结构化档位） |
| RDR-02.4 命中证据与安全 | 已交付 | PR #67（字段标签 + 真实片段）与 PR #69（内联脚本转义） |
| RDR-02.5 定位到答案 | 已交付 | PR #70（`sections` + 深链到 `--return` 等稳定锚点）；自动展开经证据判定不适用（见 2.3） |
| RDR-02.9 输入法/键盘 | 已交付 | PR #73（组合期不驱动结果、Enter 提交组合、Escape 可用） |
| RDR-05.1 标题只展示一次 | 已交付 | PR #65（合入 `f85053b`） |
| RDR-05.2 就近 API 入口 | 已交付 | PR #72（关联卡片渲染在被注解区块旁） |
| RDR-05.4 读者文案与技术信息分离 | 已交付 | PR #72（selector/provenance/state 收进「技术详情」） |
| RDR-05.5 内容拆分 | 已交付 | PR #74（`docs/reproduce.md`，双向入口） |
| RDR-03.1 首屏成员入口 | 已交付 | 上游已满足；本次以实测复核（见 2.1） |
| RDR-03.4 去除次要重复 | 已交付 | 生成器版本/IR schema 仅在页脚次级位置（见 2.1） |
| RDR-04.1 首页单一入口 | 已交付 | PR #76（合并重复的「从指南开始/从这里开始」） |
| RDR-06.2 关键样例补齐 | 已交付 | PR #75（`window` 三个可运行示例，逐例执行 4→7 通过） |
| RDR-06.3 就地逐例证据 | 已交付 | PR #80（成员页逐例状态徽标 + 原始证据入口，5 徽标/4 页面，状态取自原生 runner） |
| RDR-07.2 可读变化说明 | 已交付 | PR #78（native reasons 与字段级 Before/After 文本化，原始 JSON 折叠保留） |
| RDR-08.2 界面本地化 | 已交付 | PR #72、PR #77（外部文档状态徽标 52→0 处原始内部词） |

## 2. 关键实测证据

### 2.1 阅读密度与信息层级（RDR-03.1 / 03.4）

对生成的 `TextCatalog` 类型页实测（`examples/pocketkit/demo-v2`，zh-CN）：

| 指标 | 实测值 |
| --- | --- |
| `<h1>` 偏移 | 561 字节 |
| 成员浏览器容器偏移 | 1523 字节（`<h1>` 之后约 0.96 KB） |
| 成员筛选输入偏移 | 1715 字节 |
| 全部展开按钮偏移 | 2088 字节 |
| 默认阅读路径中的生成器版本/IR schema | 0 处（仅出现在页脚） |

### 2.2 搜索（RDR-02.2 固定查询）

`cjdoc.search-index/7`，60 条条目：

| 查询 | 命中 |
| --- | --- |
| `并发` | `pocketkit.TextCatalog` |
| `读取结束` | `pocketkit.io.TextReader.read` |
| `add` | 2 个重载条目（未退化） |
| 索引体积 | 52.1 KB → 61.8 KB（+18.6%，条目上限 2000 rune） |

### 2.3 深链（RDR-02.5）与「自动展开」判定

- 命中 `读取结束` → 目标页 `pocketkit.io.TextReader.read`，锚点结尾 `--return`；
- 该锚点在目标页为**真实静态元素** `id="…--return"`（非 JS 折叠后才出现）；
- 「自动展开折叠成员行」经证据判定**不适用**：所有可见符号（含成员）都有独立页面，实测 60 条条目对应 60 个不同 href 且**均不带 `#`**，搜索结果不会落到 owner 页的折叠行。

### 2.4 逐例执行（RDR-06.2）

`cjdoc check --check-examples`：`passed=4 → passed=7, failed=0`（新增三个 `window` 示例真实编译并运行通过）。

修复过程中发现并修复了真实缺陷：`collectSnippets` 的 `exampleIndex` 从不递增，同一符号的多个 `@example` 产生重复结果 id，导致展示构建报 `duplicate or orphaned doctest result`（PR #75 内含修复与回归）。

### 2.5 浏览器端到端（TEST-01 / TEST-02 代表性覆盖）

对真实构建的最终展示目录运行仓库自身的 Playwright 验收：

| 门禁 | 结果 |
| --- | --- |
| `showcase_contract.browser` | **324/324** 通过（HTTP 子路径 + `file://`；zh-CN/en；桌面/窄屏/移动） |
| `showcase_contract.browser_reading_regressions` | **12/12** 通过 |
| `showcase_contract verify` | 最终树链接与证据门禁通过 |

### 2.6 单元与脚本测试

| 套件 | 结果 |
| --- | --- |
| `cjpm test` | 331–332 PASSED / 0 FAILED（随分支增减；见各 PR） |
| `python3 -m unittest discover -s scripts` | 118 OK |
| `scripts/validate_html_site.py` | 通过（如 51 pages / 24 entries、90 pages / 46 entries） |
| 确定性 | 两次生成除 doctest 耗时字段外零差异 |

### 2.7 CI

| PR | 说明 |
| --- | --- |
| #69 / #70 / #74 / #77 / #78 | 三平台 + showcase 全绿 |
| #75 / #76 | 栈式 PR（base 为前置分支，非 main）；#75 三平台 + showcase 全绿，#76 的 showcase 已验证通过 |

## 3. 未完成项与阻塞

### RDR-01.1–.3 签名类型链接（已交付，PR #81）

现状：所有源码 `TypeRef` 为 `state="partial"`、`canonical=null`、`arguments=[]`；渲染层
`HtmlTypeLinkIndex.targetUrl()` 仅接受 `state == "resolved"` 且 canonical 精确匹配的类型。
因此参数/返回/属性类型目前无法解析为链接。

**此前记录的「Gate C 架构受限」结论已过期，本轮实测复测如下**（STS 1.2.0 +
stdx release/1.2，`docs/research/api-capability-matrix.md` 的结论基于 20260829
daily 1.1.0-alpha，其 stdx 确实未交付 `stdx.chir`）：

| Gate | 旧结论 | 本轮实测 |
| --- | --- | --- |
| G1 读取 CHIR | PASS | PASS（`--emit-chir=raw` 产出 `.chir`） |
| G2 枚举声明 | FAIL | **PASS**（functions/classes/structs/enums/extends 可枚举） |
| G3 access level | FAIL | **PASS**（`isPublic()` 可区分：public=2 / nonPublic=6） |
| G5 declaration owner | FAIL | **PASS**（`declaredParent.srcCodeName` 可用） |
| G6 source location | FAIL | FAIL（`Function` 仍无公开 location） |
| G7 普通项目依赖 stdx.chir | FAIL | **PASS**（`import stdx.chir.*` 编译运行成功） |

并且 CHIR 能给出 **AST 无法提供的限定类型身份与泛型结构**。实测 `parse` 的
`funcSrcCodeType` 递归展开：

```text
(std.core.String,std.core.String,Bool)->std.core.Array (n=4)
  std.core.String (n=0)
  std.core.String (n=0)
  Bool (n=0)
  std.core.Array (n=1)
    pocketkit.parsing.Token (n=0)
```

即 `Array<Token>` 中的 `Token` 被解析为限定名 `pocketkit.parsing.Token`，可与
`pocketkit.io.Token` 区分——这正是 AST 拼写无法判定的同名歧义。

**结论：阻塞已解除，实现已交付（PR #81）。** 摘要：协议新增携带类型节点树的 `signature=`
记录（协议版本升为 `cjdoc-chir-worker/2`，避免旧解码器把新字段当未知字段而整包失去
CHIR）；worker 发射 pre-order 节点（depth + 限定名）并携带与函数记录一致的 owner 形状
（含 extend 目标）与泛型 arity；provider 按同样的 owner/形状/arity 规则匹配，歧义时拒绝；
每个节点的 `spelling` 保留其**完整源码子树**（去空白），解析身份只进 `canonical`，
因此渲染层按位置对齐后既能链接外层也能链接嵌套实参。
实测：`wrap(items: Array<Token>): Array<Token>` 的两处 `Array<Token>` 内层 `Token`
均渲染为真实链接（`canonical = genprobe.Token`）；`parse` 的 `Array<Token>` 内层
`Token` → `canonical = pocketkit.parsing.Token`（与 `pocketkit.io.Token` 可区分）；
扩展方法 `byteLength` 的返回由 `partial` 变为 `resolved(Int64)`；非泛型自定义类型
（如 `TextReader`）不再产生幻影子实参；默认（无 `--semantic chir`）golden 字节不变；
官方组件下 `cjpm test` 334 PASSED / 0 FAILED。

以下为定位该缺口时所依据的详细证据。

已定位到精确的缺口，不再需要猜测：

1. `tools/chir-worker/src/main.cj:105` 目前只把 `funcSrcCodeType.paramTypes.size`
   写进 `ChirWorkerFunctionRecord`；**CHIR 已解析出的限定类型名与泛型结构被丢弃**，
   从未跨越 worker 协议边界。
2. `tools/chir-protocol/src/protocol.cj:245` 的 `function=` 记录只有 9 个字段，
   没有类型字段可承载这些身份。
3. `src/chir_provider.cj:130` 声明 `SemanticCapabilities(..., canonicalTypes: false)`，
   并只用 `partialChirType(view.typeSpelling)` 构造类型——即回到源码拼写，
   因此 renderer 的 `state == "resolved"` 门槛永远不满足。

实现路径（按依赖顺序）：

- 扩展 worker 记录，携带每个参数与返回值的限定类型名及递归 `typeArgs`；
- 扩展协议编解码（字段数、编码、解析）并保持向后兼容的字段计数校验；
- provider 在 worker 提供类型身份时声明 `canonicalTypes: true` 并构造含
  `arguments` 的 `TypeRef`（`state` 严格按证据给，不猜测）；
- 同步 Doc IR/schema/golden，并为「CHIR 不可用时保持 partial/unavailable」补回归。

G6 的缺失（`Function` 无公开 location）不阻塞该路径：绑定 CHIR 记录到源码声明
所用的 package / owner / name / arity 均已可用（G2、G5 实测 PASS），回绑继续沿用
既有「保守绑定 + 诊断」方式。

同时实测表明仅解析**原子类型**收益很低：示例中 42 处类型拼写，35 处为原子类型且多为
`Unit`(11)、`String`(6)、`Bool`(5)、`Int64` 等无本地声明的内建类型，只有 `TextReader`
能获得链接。真正的价值在于复合类型（`Array<Token>`、嵌套泛型）的结构化实参贯通。

可行路径需先做决策：新增不应伪装为「语义解析」的本地类型身份机制（例如独立于
`canonical` 的本地可链接身份字段 + 能力声明），并同步 Doc IR/schema/golden。
属于需要明确范围批准的设计变更，本次未擅自实施。

### RDR-06.3 就地逐例证据（已交付，PR #80）

原生 doctest 结果现已传入 HTML 渲染器：`cli_runner` 构造 `symbolId + 示例标题 → status`
证据表，成员页与内联成员详情在每个 `@example` 旁渲染状态徽标与「原始执行证据」入口。

实测：demo-v2（zh-CN，`doctest.mode=deny`）生成出 **5 个状态徽标、分布在 4 个页面**，
状态全部为 `passed`，与 `doctest/results.json` 的 4 条 `passed` 记录一致。
未匹配的示例不显示任何状态（不推断验证结论）；单测覆盖空证据、标题不匹配、符号不匹配。
状态严格取自原生 runner 记录，未把 compile-only / expected-failure 转换为成功。

### CHIR 复测环境（第 3 节数据的来源）

复测使用 CI 同款官方组件（`Zxilly/setup-cangjie` 缓存中的 STS 1.2.0 与
`stdx release/1.2`），通过 `scripts/with_stdx.py` 认证；probe 以 `cjpm` 构建并运行，
逐项输出即上表数据。旧 Gate C 结论所依据的 20260829 daily 已不适用于当前工具链。

### 完整 `check.sh`（CI 三平台已通过）

`.github/workflows/ci.yml` 第 97 行在 `Run v9 local acceptance gate` 步骤中直接执行
`bash scripts/check.sh`，因此 CI 的整站验收就是该门禁本身。

实测证据（本次改动所在 SHA）：linux-x64、windows-x64、macos-arm64 三个 job 均
`success`，日志中各自输出 `bash scripts/check.sh` 后打印 `cjdoc acceptance gate passed`。
macOS 曾出现一次 runner 卡顿（同一 job 65 分钟未完成），**原样重跑后 12m40s 通过**，
确认为运行器侧抖动而非代码问题。

本机单独执行时 `verify_repository_inputs` 与 `cjpm build` 通过，`cjpm test` 出现 5 个
**CHIR 外部依赖**用例失败（`chir_dependency`，worker 非零退出）。对照：未改动的
`origin/main` 在本机同样复现；差异源于本机自组装的 stdx sidecar 与 CI 的
`Zxilly/setup-cangjie` 官方 stdx 组件。因 CI 已用官方组件完整执行同一脚本，该门禁
以 CI 结果为准。

## 4. 边界声明

- 展示层不重算兼容性分类，不把 `potentially-breaking`/`partial` 提升为确定结论；
- 未修改 compiler/std/stdx，未解析 CHIR 文本；
- 所有改动保留离线、确定性、audience/cfg 隔离与既有安全约束；
- RDR-01～RDR-08 各项均已交付；完整关闭条件仍以 Issue 正文为准，本表不代替关闭判定。
