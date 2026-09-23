# AGENTS.md

## 项目目标

`cjdoc` 是纯仓颉实现的仓颉 API 文档生成器。当前里程碑以 `std.ast` 和 lexer 为源码真值，输出 schema-versioned、确定性的 Doc IR v9，并严格迁移受支持的 v6/v7/v8 输入。CHIR 不在当前依赖图中，只能通过公开 `SemanticProvider` SPI 在后续独立接入。

## 开始工作前

1. 准备仓颉 SDK 环境，确认 `cjc -v` 与 `cjpm -v` 可用。
2. 阅读 `README.md` 的架构与命令部分。
3. 修改精确 std/stdx API 前，先查当前 SDK 或写最小 compile/run probe；不要猜 API。
4. 不要修改 SDK、compiler、std 或 stdx 来迁就本项目。

## 架构边界

- `src/source_frontend.cj`：项目发现、lexer/AST、源码声明和 doc comment 收集。
- `src/semantic_provider.cj`：内部 AST fallback semantic model。
- `src/provider/`：公开 provider SPI；这是未来 CHIR adapter 的唯一入口。
- `src/documentation_binder.cj`：SourceDecl 与 semantic declaration 绑定、SymbolId。
- `src/model/`：公开 Doc IR；renderer 的唯一输入。
- `src/render/`：严格 JSON codec、Markdown/HTML/search renderer；禁止 import `std.ast` 或 provider 实现。
- `src/public_api.cj`：公开 facade 与 internal/public model adapter。
- `src/new_cli.cj`：CLI 与命令编排。
- `src/output_transaction.cj`：输出所有权、锁、事务与崩溃恢复。

必须保持：注释来自源码；SourceDecl 是 comment 与 semantic provider 的桥；SymbolId 不依赖行号；unavailable/partial/ambiguous 必须显式；renderer 只读 Doc IR；unsupported source 不得导致整个生成器崩溃。

## 常用命令

```bash
cjpm build
cjpm test
scripts/check.sh
target/release/bin/main generate --project tests/fixtures/projects/basic --format json --stdout
```

安装 `just` 后也可运行 `just doctor`、`just test`、`just check`、`just smoke`。

`scripts/check.sh` 假设 SDK 环境已经准备好，并要求 Bash 和 Python 标准库。它覆盖 build、unit、v9 golden、v6/v7/v8 严格迁移、schema 同步、两次生成确定性、strict codec round-trip、多页 HTML 全站校验、资源限制、安全和外部 provider fixture。

## 修改规则

- 不用正则解析仓颉声明，不实现 type checker，不解析 CHIR dump 文本。
- 新增不确定仓颉 API 时，先增加最小 probe，记录真实编译/运行结果。
- 改 Doc IR 时同时修改：`src/model/doc_ir.cj`、JSON encoder/decoder、`src/schema_data/` 中的 schema source、生成的 `docs/schema/`、public-contract tests 和 current-version golden。已发布的 legacy schema/golden 只读冻结；破坏性 schema 变更必须提升 schema version。
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

CHIR capability Gate 只有 G1–G7 全部实测 PASS 才能升级为 authoritative provider；当前结论和证据位于 `docs/research/`。
