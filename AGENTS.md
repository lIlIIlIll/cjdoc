# AGENTS.md

## 项目目标

`cjdoc` 是纯仓颉实现的仓颉 API 文档生成器。源码声明、注释和位置以 `std.ast` 与 lexer 为真值，输出 schema-versioned、确定性的 Doc IR v16；decoder 只接受当前版本，不迁移旧 Doc IR 输入。
`--semantic chir` 可选择内置 `stdx.chir` provider 做结构化语义补充；CHIR 不覆盖源码/注释真值，也不替代 source/AST fallback。

## 开始工作前

1. 准备仓颉 SDK 环境，确认 `cjc -v` 与 `cjpm -v` 可用。
2. 阅读 `README.md` 的架构与命令部分。
3. 修改精确 std/stdx API 前，先查当前 SDK 或写最小 compile/run probe；不要猜 API。
4. 不要修改 SDK、compiler、std 或 stdx 来迁就本项目。

## 架构边界

- `src/source_frontend.cj`：项目发现、lexer/`std.ast`、源码声明和 doc comment 收集。
- `src/semantic_provider.cj`：内部 AST fallback semantic model。
- `src/provider/`：公开 provider SPI；定义内置与外部 provider 的生命周期和语义契约。
- `src/chir_provider.cj`：可选内置 CHIR provider；把结构化语义结果保守地绑定回源码声明。
- `src/chir_worker.cj`：通过配置的 Cangjie compiler 生成 raw CHIR，并用 `stdx.chir` 结构化读取；禁止解析 CHIR 文本。
- `src/documentation_binder.cj`：SourceDecl 与 semantic declaration 绑定、SymbolId。
- `src/model/`：公开 Doc IR；renderer 的唯一输入。
- `src/render/`：严格 JSON codec、Markdown/HTML/search renderer；禁止 import `std.ast` 或 provider 实现。
- `src/public_api.cj`：公开 facade 与 internal/public model adapter。
- `src/new_cli.cj`：CLI 与命令编排。
- `src/output_transaction.cj`：输出所有权、锁、事务与崩溃恢复。

必须保持：注释来自源码；SourceDecl 是 comment 与 semantic provider 的桥；SymbolId 不依赖行号；unavailable/partial/ambiguous 必须显式；可选 CHIR 失败时保留 AST/source fallback；renderer 只读 Doc IR；unsupported source 不得导致整个生成器崩溃。

## 常用命令

```bash
cjpm build
cjpm test
scripts/check.sh
target/release/bin/main generate --project tests/fixtures/projects/basic --format json --stdout
```

安装 `just` 后也可运行 `just doctor`、`just test`、`just check`、`just smoke`。

`scripts/check.sh` 假设 SDK 环境已经准备好，并要求 Bash 和 Python 标准库。它覆盖 build、unit、current v16 goldens、current-only codec round-trip、schema 同步、两次生成确定性、多页 HTML 全站校验、资源限制、安全和外部 provider fixture。

## 修改规则

- 不用正则解析仓颉声明，不实现 type checker，不解析 CHIR dump 文本。
- 新增不确定仓颉 API 时，先增加最小 probe，记录真实编译/运行结果。
- 改 Doc IR 时同时修改：`src/model/doc_ir.cj`、JSON encoder/decoder、`src/schema_data/` 中的 schema source、生成的 `docs/schema/`、public-contract tests 和 current-version golden。decoder 与分发库存保持 current-only；破坏性 schema 变更必须提升 schema version。
- Doc IR decoder 只接受当前 schema；不得保留旧版迁移、冻结 schema/golden 或 migration receipt 路径。wire 变更时提升版本并拒绝旧版本输入。
- 改 provider SPI 时保持 provider session 的 `open → analyze → close` 生命周期；失败必须保留 AST fallback 并产生 `CJDOC2xxx`。
- 改 renderer 时增加安全测试；用户注释不得未经清理进入 HTML。
- 不手改 golden 来迎合实现。运行 `bash scripts/update_goldens.sh`，再检查 diff。
- 诊断码一旦发布即稳定：新增类别使用 `CJDOC1xxx` source、`2xxx` semantic/binding、`3xxx` docs/lint、`4xxx` render/output。

## 代码风格

优先遵循仓库现有代码风格；以下指标作为默认约束，超过时应考虑重构。

### 代码规模

* 单个函数建议不超过 **80 行**。
* 超过 **120 行** 的函数应优先拆分。
* 单个源文件建议不超过 **500 行**。
* 超过 **800 行** 的文件应考虑按职责拆分。
* 单个类型建议不超过 **300 行**。
* 单个函数参数建议不超过 **5 个**；参数过多时考虑配置对象或结构体。
* 单个表达式或语句不要过长，优先保证可读性。
* 嵌套深度建议不超过 **5 层**，优先使用早返回减少嵌套。

这些限制不是机械的硬性指标。若拆分会降低可读性、破坏局部性或引入无意义抽象，可以保留较长实现，但应保证结构清晰。

### 函数设计

* 一个函数尽量只完成一个明确职责。
* 避免同时处理解析、验证、状态修改和输出等多个阶段。
* 优先使用早返回处理错误和边界条件。
* 避免大量布尔参数控制完全不同的行为。
* 重复逻辑出现多次时应考虑抽取，但不要为了几行简单代码制造无意义抽象。

### 命名

* 类型、函数、变量名称应能直接表达用途。
* 避免 `tmp`、`data1`、`obj`、`helper` 等含义模糊的命名。
* 除行业通用缩写外，避免自行创造缩写。
* 同类 API 保持一致的动词、参数顺序和命名规则。
* 布尔值应使用能够表达真假语义的名称。

### 控制流

优先：

```text
if invalid {
    return error
}

doWork()
```

避免：

```text
if valid {
    if ready {
        if enabled {
            doWork()
        }
    }
}
```

复杂条件应拆成具有明确名称的中间判断。

### 注释

* 注释重点说明“为什么”，而不是逐行解释“做了什么”。
* 不保留注释掉的旧代码。
* TODO 必须说明待解决的问题，不要使用模糊的 `TODO: fix later`。
* public API 应按仓库现有规范提供必要文档。

### 抽象

遵循：

```text
可读性 > 技巧
简单 > 过度抽象
明确 > 隐式
一致性 > 个人偏好
```

不要为了减少几行代码而：

* 引入复杂继承层级
* 创建只有一个调用者的通用框架
* 增加无实际需求的扩展点
* 使用难以理解的元编程技巧

### 文件组织

* 一个文件应围绕一个明确模块或职责。
* 不要把不相关类型集中到同一个大文件。
* 小型、强相关的辅助类型可以与主要实现放在一起。
* 不要为了满足文件行数限制机械地创建大量只有几十行的小文件。

### 格式化

* 使用仓库已有 formatter / linter。
* 不手工建立另一套格式规则。
* 不在功能修改中顺带格式化无关代码。
* 提交前确保没有调试代码、临时日志和无用 import。


## 验证与证据

在报告或 PR 中分别说明 build、unit、golden/integration、real-repository 与远端 CI 是否实际运行。不要用较低层级的通过替代更高层级证据，也不要把本机通过描述成 GitHub runner 已通过。

CHIR capability Gate 只有 G1–G7 全部实测 PASS 才能升级为 authoritative provider；当前内置 provider 只提供保守的结构化语义补充，不替代源码/AST fallback。结论和证据位于 `docs/research/`。

## Code Review Rules

仅在变更触及相应契约时应用以下检查，不要为了套用规则扩展无关 PR 的审查范围；仍需正常报告真实的安全、正确性与回归问题。

### Doc IR 与跨文档导航

- 变更涉及 Doc IR、跨文档链接或冻结文档重放（replay）时，对照实际 producer 的创建、选择与绑定路径，核对 decoder、validator、renderer 接受的状态是否可由 producer 生成，同时不得拒绝合法产物。区分 `exact`、`compatible`、`unavailable`、`partial`、`ambiguous` 的语义。
- 发现契约不一致时，一次性检查同一不变量的正反、对称及相关边界情形：空值与缺失字段、document set 的 language/library、owner/module、dependency instance、component、symbol key、组织限定名与别名、重复或歧义选取。无需穷举无关组合。
- 外部 `exact` / `compatible` 证据必须关联到 producer 实际选中的目标。若 Doc IR 未保留消费端证明关系所需的信息，应指出契约缺口并建议补充证据或安全降级；不得臆造映射，也不得将无法验证的链接标为确定匹配。

### 身份与观测快照

- 修改 source identity、manifest、build context 或 receipt 时，检查 identity、version、digest、size 等数据是否绑定到同一稳定观测快照，避免散落的二次读取造成时间竞态。不得通过重复计入预算、放宽资源限制、破坏事务隔离或把未验证状态标为 `verified` 来修复问题。

### 审查意见质量

- 缺陷意见应明确触发条件、违反的契约、实际影响和关键代码路径；区分可从代码证明的错误与未经验证的推测，不把纯风格建议当作正确性缺陷。
- 同根因的边界或对称反例尽可能合并到同一条意见；可访问历史 Review Thread 时，先检查是否已报告或已修复。新发现的真实缺陷仍必须指出，不能为了减少线程数而隐瞒问题。
- 区分本 PR 引入或加重的问题与独立的范围外改进；后者可建议单独建 Issue，不能将当前 PR 的真实阻塞缺陷仅因发现较晚就降级。

## Review 反馈处理与收敛

- 处理 Review Thread 前先核实实际 producer/consumer 代码及其契约，按不变量和共同根因归类，不机械地将每条评论视为独立的修复任务。
- 同根因问题集中修复，补充覆盖合法/非法、正反与相关边界情形的回归或参数化测试，避免只修一个反例而遗漏对称情形。
- 优先完成一组相关修复与受影响的测试后再推送；复审重点检查本轮修复及受影响的调用链，而不是主动对每次小提交重新启动无界的全量审计。
- 记录各组意见的处理状态及证据：已修复、附反证不采纳、仍阻塞、范围外跟进。不得因 Review 轮次较多而忽略可证实的阻塞缺陷。
- PR 的技术合并条件是原 Issue/PR 验收标准、真实阻塞问题和必要测试/CI 均满足；不要把 Review Thread 全部清零或固定审查轮数作为唯一条件。

## Codex 复审完成门禁

- 每次向 PR 推送批量修复后，核对最新 HEAD 对应的 `codex-review-current-head` 状态：只有官方 Codex 的 `code_review` 明确在该完整 SHA 上 `completed` 才算本轮复审完成。旧 SHA、仅有 Review Thread/表情、等待中或未收到审查结果，均不能代替完成证据。
- `codex-review-current-head` 应发布到校验过当前 base/head 的 PR 测试合并提交，而非可能被多个 PR 共用的原始 HEAD；官方摘要删除或证据失效时不得保留成功状态。
- 复审完成状态不等于“无缺陷”或自动批准；对未解决的真实阻塞缺陷继续按根因处理，并独立核对 Issue 验收标准和 CI。
- 门禁脚本及事件触发逻辑见 `docs/codex-review-gate.md`；Github Required Check 需在门禁工作流合并并完成验证后由仓库 Ruleset / Branch Protection 启用。不得绕过缺失或 Pending 的门禁直接宣称验收通过。
