# AGENTS.md

## 项目目标

`cjdoc` 是纯仓颉实现的仓颉 API 文档生成器。源码声明、注释和位置以 `std.ast` 与 lexer 为真值，输出确定性的 Doc IR v19；decoder 只接受当前版本，不迁移旧 Doc IR 输入。当前 wire contract 见 [Doc IR 维护说明](docs/maintainer/doc-ir.md)。
`generate`、`check` 和 `serve` 默认由配套 `stdx.chir` worker 做结构化语义补充；`--semantic source` 仅使用源码/AST。CHIR 不覆盖源码/注释真值，失败时保留 source/AST fallback。

## 开始工作前

1. 准备仓颉 SDK 环境，确认 `cjc -v` 与 `cjpm -v` 可用。
2. 阅读 `docs/maintainer/README.md`（维护者文档索引）与 `docs/maintainer/build.md`（构建、命令与本地门禁）；`README.md` 面向使用者。
3. 修改精确 std/stdx API 前，先查当前 SDK 或写最小 compile/run probe；不要猜 API。
4. 不要修改 SDK、compiler、std 或 stdx 来迁就本项目。

## 架构边界

- `src/source/`：项目发现、lexer/`std.ast`、源码声明、注释与缓存。
- `src/semantic/`：内部 AST fallback 与保守的 CHIR 结构化补充；不能覆盖源码真值。
- `src/provider/`：公开 provider SPI 与生命周期。`tools/chir-worker/` 调用仓颉编译器并用 `stdx.chir` 读取结构化结果，禁止解析 CHIR 文本。
- `src/binding/`：源码声明与语义模型绑定、SymbolId、重导出。
- `src/dependency/`：依赖身份与跨文档导航。
- `src/model/`：公开 Doc IR；renderer 的唯一输入。`src/render/` 的 codec、发布与呈现实现不得导入 `std.ast` 或 provider 实现。
- `src/main.cj`、`src/public_*.cj`：公开入口、内部/公开模型适配和应用组装。实现子包不反向导入根包。
- `src/cli/` 负责参数、命令及传输；`src/query/` 负责冻结快照与只读查询。
- `src/output/`：输出所有权、锁、spool、事务提交与崩溃恢复。`src/versions/` 负责读取已有发布和多版本合成。
- `src/manifest/`：仓颉项目清单、锁文件和共用 TOML 扫描；`src/filesystem/` 和 `src/digest/` 提供有界读取、安全路径和摘要。

必须保持：注释来自源码；SourceDecl 是 comment 与 semantic provider 的桥；SymbolId 不依赖行号；unavailable/partial/ambiguous 必须显式；可选 CHIR 失败时保留 AST/source fallback；renderer 只读 Doc IR；unsupported source 不得导致整个生成器崩溃。

## 常用命令

先按[构建指南](docs/maintainer/build.md)准备已认证 SDK/stdx，并在当前 shell source
`scripts/with_sts_cjpm.sh`。以下命令使用该入口固定的完整产品旗标与单测专属例外：

```bash
cjpm build
cjpm test
scripts/check.sh
target/release/bin/main generate --project tests/fixtures/projects/basic --format json --stdout
```

安装 `just` 后也可运行 `just doctor`、`just test`、`just check`、`just smoke`。

`scripts/check.sh` 假设 SDK 环境已经准备好，并要求 Bash 和 Python 标准库。它覆盖 build、unit、current v19 goldens、current-only codec round-trip、schema 同步、两次生成确定性、多页 HTML 全站校验、资源限制、安全和外部 provider fixture。当前公开查询/发布契约为 query-request/4、query-result/5、search-index/12、search-contract/3、declaration/3 和 page/2。

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

### 重构评审：何时要求修改

本节适用于独立重构，以及功能或修复 PR 中实际改动的代码。未触及的风格欠账不作为本 PR 的合入条件。

1. **先看哪项维护任务变容易了。** 独立重构只需指出一项可从差异核对的收益，例如改一条规则由两处变为一处。收益已清楚就不要求作者另作说明；少八行、多一个辅助函数，或跨过 80／120 行建议线，本身都不是收益或缺陷。功能 PR 不要求另写重构收益说明。
2. **只集中必须同步修改的规则。** 假设目录和搜索都不得公开私有声明，但公开声明的历史名称只能被搜索。私有性规则应只有一个定义，是否展示历史名称由各入口决定。评审 `isVisible(entry, forSearch)` 时，判断它是否让原本独立的修改互相牵连，不因布尔参数本身要求修改。若两处确实必须随同一规则一起变，就可以集中维护。
3. **用已知需求区分阻塞意见和个人建议。** 即使测试全绿，也可指出：“原来只需理解或修改 A；本 PR 后还必须理解或修改 B；原因是……”只要能从调用关系或差异核对这项新增负担，就可要求解除耦合，无须等到输出出错。仅凭命名偏好、行数、假想需求或本 PR 无关的旧问题，不作阻塞。若作者证明无需连带理解或修改 B，就撤回这条意见。
4. **只补行为缺口所需的证据。** 私有函数原样搬移，调用关系与错误顺序均不变，差异即可作为等价证据，不必加测试。若重排分支可能影响空输入或失败路径，指出一个能区分对错的输入及预期结果。已有用例能区分就引用，否则要求针对性用例或用相同输入对照前后结果。全套 CI 通过不能替代缺失的边界证据。
5. **分清待说明的收益和实际行为变更。** 独立重构说不清收益时，请作者说明具体用途再批准，不把它称为回归。前后输出确实不同时，不能按“行为不变”批准；若新行为符合契约，按修复评审，明确旧、新结果并给出能区分两者的证据。修复和其余搬移可以放在同一 PR，只要能分别核对，不要求拆 PR 或采用特定提交结构。

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
- 门禁脚本及事件触发逻辑见 `docs/maintainer/codex-review-gate.md`；Github Required Check 需在门禁工作流合并并完成验证后由仓库 Ruleset / Branch Protection 启用。不得绕过缺失或 Pending 的门禁直接宣称验收通过。
