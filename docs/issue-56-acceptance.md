# Issue #56 验收映射

本表把 Issue #56 的 RDR 工作项映射到本次实际提交、测试与运行证据。
只记录**实际执行过**的结果；未完成项明确标注，不以计划或旧 issue 勾选代替。

日期：2026-10-09。基线：`d948995`（及后续 rebase 后的 `d7c1e01`）。
证据命令均在本机 Cangjie SDK 1.2.0 + stdx sidecar 下执行；CI 证据取自 GitHub Actions。

## 1. 工作项状态

| 工作项 | 状态 | 实现 / 证据 |
| --- | --- | --- |
| RDR-01.4 关系入口位于默读区域 | 已交付 | 由上游 PR #58 合入（`symbol-relationships` 位于成员浏览器之前、关系名本地化）；本次复核未重复实现 |
| RDR-01.1–.3 签名类型链接与复合类型 | 未完成（架构受限） | 见第 3 节；受项目自身架构决策（Gate C）限制 |
| RDR-02.1 检索语料 | 已交付 | PR #67（`body` 字段，来源 Markdown AST + 标签说明） |
| RDR-02.3 排序可解释 | 已交付 | PR #67（正文命中为第 8 档，低于所有名称/结构化档位） |
| RDR-02.4 命中证据与安全 | 已交付 | PR #67（字段标签 + 真实片段）与 PR #69（内联脚本转义） |
| RDR-02.5 定位到答案 | 部分交付 | PR #70（`sections` + 深链到 `--return` 等稳定锚点）；自动展开经证据判定不适用（见 2.3） |
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

### RDR-01.1–.3 签名类型链接（架构受限）

现状：所有源码 `TypeRef` 为 `state="partial"`、`canonical=null`、`arguments=[]`；渲染层
`HtmlTypeLinkIndex.targetUrl()` 仅接受 `state == "resolved"` 且 canonical 精确匹配的类型。
因此参数/返回/属性类型目前无法解析为链接。

**这不是遗漏，而是项目自身已记录的架构决策**：`docs/research/api-capability-matrix.md`
的 CHIR Gate 结论为 Gate C（G2–G7 未通过），并明确「所有 AST 类型均标为 `partial` 或
`unavailable`，不会伪装为 `resolved`」。把 AST 类型标为 resolved 将直接违反该决策。

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

### 完整 `check.sh`

在本机洁净克隆中执行：`verify_repository_inputs` 与 `cjpm build` 通过，`cjpm test`
出现 5 个 **CHIR 外部依赖**用例失败（`chir_dependency`，worker 非零退出且无输出）。
对照证据：**未改动的 `origin/main`（`d948995`）在本机同样复现**，而同一 SHA 在 CI
三平台均为 `cjdoc acceptance gate passed`。差异来自本机自组装的 stdx sidecar 与
CI 的 `Zxilly/setup-cangjie` 官方 stdx 组件，而非代码改动。

## 4. 边界声明

- 展示层不重算兼容性分类，不把 `potentially-breaking`/`partial` 提升为确定结论；
- 未修改 compiler/std/stdx，未解析 CHIR 文本；
- 所有改动保留离线、确定性、audience/cfg 隔离与既有安全约束；
- 本表不宣称 Issue #56 已满足全部关闭条件：**RDR-01.1–.3 仍未完成**（架构受限，见第 3 节）。
