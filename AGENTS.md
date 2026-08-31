# AGENTS.md

## 项目目标

`cjdoc` 是纯仓颉实现的仓颉 API 文档生成器。当前里程碑以 `std.ast` 和 lexer 为源码真值，输出 schema-versioned、确定性的 Doc IR v8，并严格迁移受支持的 v6/v7 输入。CHIR 不在当前依赖图中，只能通过公开 `SemanticProvider` SPI 在后续独立接入。

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

`scripts/check.sh` 假设 SDK 环境已经准备好，并要求 Bash 和 Python 标准库。它覆盖 build、unit、v8 golden、v6/v7 严格迁移、schema 同步、两次生成确定性、strict codec round-trip、多页 HTML 全站校验、资源限制、安全和外部 provider fixture。

## 修改规则

- 不用正则解析仓颉声明，不实现 type checker，不解析 CHIR dump 文本。
- 新增不确定仓颉 API 时，先增加最小 probe，记录真实编译/运行结果。
- 改 Doc IR 时同时修改：`src/model/doc_ir.cj`、JSON encoder/decoder、`src/schema_data/` 中的 schema source、生成的 `docs/schema/`、public-contract tests 和 current-version golden。已发布的 legacy schema/golden 只读冻结；破坏性 schema 变更必须提升 schema version。
- 改 provider SPI 时保持 provider session 的 `open → analyze → close` 生命周期；失败必须保留 AST fallback 并产生 `CJDOC2xxx`。
- 改 renderer 时增加安全测试；用户注释不得未经清理进入 HTML。
- 不手改 golden 来迎合实现。运行 `bash scripts/update_goldens.sh`，再检查 diff。
- 诊断码一旦发布即稳定；新增类别使用：`CJDOC1xxx` source、`2xxx` semantic/binding、`3xxx` docs/lint、`4xxx` render/output。

## 验证与证据

在报告或 PR 中分别说明 build、unit、golden/integration、real-repository 与远端 CI 是否实际运行。不要用较低层级的通过替代更高层级证据，也不要把本机通过描述成 GitHub runner 已通过。

CHIR capability Gate 只有 G1–G7 全部实测 PASS 才能升级为 authoritative provider；当前结论和证据位于 `docs/research/`。
