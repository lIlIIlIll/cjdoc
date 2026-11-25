# 维护者文档

这里是 cjdoc 的维护者文档，面向修改仓库、同步 Doc IR 与 golden、运行发布与 CI 验收的人。安装和日常使用请看[用户手册](../README.md)。

改代码前先读仓库根目录的 [AGENTS.md](../../AGENTS.md)：它定义项目目标、架构边界、修改规则、代码风格和 Review 要求。本目录的文档补充具体操作；两者冲突时以 AGENTS.md 为准。

## 建议阅读顺序

按你要做的事选一条线：

1. **首次参与开发**：[AGENTS.md](../../AGENTS.md) → [build.md](build.md)（工具链与本地门禁）→ [release-process.md](release-process.md)（证据分层，避免把低层通过当成发布证据）。
2. **修改 Doc IR / schema / golden**：[doc-ir.md](doc-ir.md) → AGENTS.md 的“修改规则”一节 → 相关验收记录。
3. **修改跨文档链接或依赖身份**：[document-links.md](document-links.md) → [doc-ir.md](doc-ir.md) 的导航 wire 部分。
4. **准备发布**：[build.md](build.md) → [release-process.md](release-process.md) → [ci-orchestration.md](ci-orchestration.md)、[ci-wallclock.md](ci-wallclock.md)、[paired-samples-main.md](paired-samples-main.md)。
5. **处理 PR 复审门禁**：[codex-review-gate.md](codex-review-gate.md) → AGENTS.md 的“Codex 复审完成门禁”。
6. **展示站与阅读体验**：[showcase-contract.md](showcase-contract.md) → [showcase-phases.md](showcase-phases.md) → [api-reading-audit.md](api-reading-audit.md) → [reader-scale.md](reader-scale.md)（原生规模语料、成对证据和事前预算）。
7. **机器阅读与 Agent 评测**：[query 与 MCP](../how-to/query-and-mcp.md) → [agent-evaluation.md](agent-evaluation.md)（冻结协议、双路径真实客户端、消费者编译与行为裁决）。

## 文档地图

| 主题 | 入口 | 说明 |
|---|---|---|
| 仓库工作规范 | [AGENTS.md](../../AGENTS.md) | 架构边界、修改规则、代码风格、Review 规则 |
| 构建与本地验收 | [build.md](build.md) | SDK 1.2.0 STS + stdx sidecar、产品 `-O2 --fno-chir-function-inlining -Woff deprecated` / 单测专属 `-O1`、`scripts/check.sh`、可选 CHIR worker |
| Doc IR 与 schema | [doc-ir.md](doc-ir.md) | Doc IR v19、current-only decoder、schema/golden 更新、metadata 捕获、查询与声明 wire 版本 |
| 跨文档链接 | [document-links.md](document-links.md) | `--doc-source`/`--doc-inventory-pin`/`--build-context` 契约、identity、DL05/E2E2、验收脚本 |
| 发布流程 | [release-process.md](release-process.md) | 证据层级、性能基线、三平台 CI、tag release 与 checklist |
| CI/Pages 编排测量 | [ci-orchestration.md](ci-orchestration.md) | issue #82 的配对样本语义、阶段耗时来源与并行决策 |
| CI 墙钟数据 | [ci-wallclock.md](ci-wallclock.md) | 从 GitHub API 读回的 CI/Pages/Release 墙钟样本 |
| 配对样本快照 | [paired-samples-main.md](paired-samples-main.md) | `main` 分支配对样本的时间点快照；用脚本重新生成，不要手改 |
| Codex 复审门禁 | [codex-review-gate.md](codex-review-gate.md) | `codex-review-current-head` 的工作机制、Required Check 启用与语义边界 |
| 展示站契约 | [showcase-contract.md](showcase-contract.md) | PocketKit 展示站、功能清单、发布条件与浏览器验收 |
| 展示站阶段归因 | [showcase-phases.md](showcase-phases.md) | Pages assemble 各阶段墙钟与并行化决策（issue #82/#93） |
| 阅读体验审计 | [api-reading-audit.md](api-reading-audit.md) | 33 项 API 阅读体验修复的实现与验收重点 |
| 大规模阅读基准 | [reader-scale.md](reader-scale.md) | 1k/10k/50k 与真实库语料、原生/浏览器观测、资源边界与固定门槛 |
| Agent 效果评测 | [agent-evaluation.md](agent-evaluation.md) | 固定任务、同条件完整对照、实际读取成本、生成代码验证及证据边界 |
| 验收记录 | [acceptance/](acceptance/) | 按 issue 归档的验收映射与复现入口 |
| 历史实现报告 | [implementation-report-v0.6.md](implementation-report-v0.6.md) | v0.6.0 的历史报告，仅作归档，不是当前证据 |
| 调查记录 | [../research/](../research/) | CHIR、`std.ast`、高亮边界等时间点调查记录 |
| 发布 schema | [../schema/](../schema/) | `scripts/update_schemas.sh` 从构建产物同步；`just schema` 检查当前登记清单及产物字节 |

## 源码入口

根包 `cjdoc` 保留公开入口和应用组装；实现子包不导入根包。先从职责表定位实现：只依赖本包的单测放在实现旁边；覆盖公开类型、wire 或多个模块的契约测试留在对应入口。

| 要改的行为 | 源码入口 |
|---|---|
| 产品入口、生成请求和流水线组装 | [`src/main.cj`](../../src/main.cj)、[`public_request.cj`](../../src/public_request.cj)、[`public_engine.cj`](../../src/public_engine.cj)、[`pipeline.cj`](../../src/pipeline.cj) |
| 命令参数、帮助、配置和传输 | [`src/cli/`](../../src/cli/)；[`cli_runner.cj`](../../src/cli_runner.cj) 连接命令与公开引擎 |
| 清单、lockfile、有界读取与路径检查 | [`src/manifest/`](../../src/manifest/)、[`src/filesystem/`](../../src/filesystem/)；[`src/digest/`](../../src/digest/) 统一实现文件流、契约指纹与发布校验使用的 SHA-256 |
| 输出锁、spool、提交与恢复 | [`src/output/`](../../src/output/)；命令通过 `publication.cj` 的事务入口发布 |
| 源码发现、AST 前端、缓存与源文件来源 | [`src/source/`](../../src/source/) 的 `discovery/`、`frontend/`、`cache/`、`provenance/`；`model/` 持有声明和快照，`lexing/` 持有源码 token 和位置 |
| AST fallback、CHIR 与 provider 生命周期 | [`src/semantic/`](../../src/semantic/) 持有语义事实和 fallback；`semantic/chir/` 负责 worker 和结构化结果；[`src/provider/`](../../src/provider/) 是公开 SPI |
| 声明绑定、SymbolId、重导出 | [`src/binding/`](../../src/binding/)；消费源码与语义事实，持有绑定后的文档模型 |
| 依赖身份、跨文档链接和标准库路由 | [`src/dependency/`](../../src/dependency/) 的 `identity/`、`graph/`、`navigation/`；内置路由在 [`src/stdlib_docs/`](../../src/stdlib_docs/) |
| 注释、国际化、概念页与资源 | [`src/documentation/`](../../src/documentation/) 的 `comments/`、`i18n/`、`pages/`、`markdown/`、`assets/` 和 `metadata/` |
| 示例、代码高亮、质量与 API diff | [`src/examples/`](../../src/examples/)、[`src/highlight/`](../../src/highlight/)、[`src/quality/`](../../src/quality/) |
| 冻结快照、查询执行和结果组装 | [`src/query/`](../../src/query/)；CLI 和 MCP 传输在 `src/cli/`，[`query_api.cj`](../../src/query_api.cj) 保留公开请求与结果契约 |
| 多版本读取、选择、导航和发布合成 | [`src/versions/`](../../src/versions/)；`src/cli/compose_versions.cj` 调用合成和事务入口 |
| Doc IR 与 schema | [`src/model/`](../../src/model/)、[`src/schema_data/`](../../src/schema_data/)、[`src/render/codec/`](../../src/render/codec/) |
| 发布投影、HTML、Markdown、搜索与 Agent | [`src/render/`](../../src/render/) 的 `publication/`、`html/`、`markdown/`、`search/`、`agent/` 和 `browser/`；HTML 负责发布索引，搜索包负责请求、匹配、过滤和排序。`routes/` 和 `reading/` 持有两种呈现共用的路由与阅读规则，`foundation/` 持有有界 buffer 和产物存储契约 |

仓库输入校验（schema、golden、第三方清单）由 `scripts/repository_inputs/` 维护，命令入口是 `scripts/verify_repository_inputs.py`；`scripts/update_schemas.sh` 与 CLI golden 更新共用该目录的契约与校验。浏览器脚本变更用 `scripts/test_validate_html_site.py` 核对发布时的脚本字节。

## 验收记录

[acceptance/](acceptance/) 下的文件按 issue 归档：

- [issue-56-acceptance.md](acceptance/issue-56-acceptance.md)：#56 RDR 工作项与实测证据。
- [issue-64-acceptance.md](acceptance/issue-64-acceptance.md)：#64 中英文作者正文、语言目录与字段投影。
- [issue-100-acceptance.md](acceptance/issue-100-acceptance.md)：#100 静态代码高亮的 CLI、冻结 IR 与浏览器复现。
- [issue-113-acceptance.md](acceptance/issue-113-acceptance.md)：#113 验收包索引中的作者概述。
- [issue-153-acceptance.md](acceptance/issue-153-acceptance.md)：#153 大规模检索、作者契约、重载任务与最终原生视觉证据及资源边界。
- [issue-163-acceptance.md](acceptance/issue-163-acceptance.md)：#163 技术书页的实现与本地验收。

这些记录是各自时间点的证据映射，文中有实测环境、复现命令和边界声明；不要把它们当作当前门禁结果。当前证据要在目标提交上重新运行对应脚本。

## 注意

- 本目录描述维护者流程，包含内部 schema、验收脚本、CI 与发布约束；不要把这些内容搬回使用者文档。
- 历史文档（`implementation-report-v0.6.md`、`paired-samples-main.md`、`ci-wallclock.md`、`showcase-phases.md` 等）是时间点快照，各自标注了日期或运行 ID；引用前先确认它是否仍适用于当前 revision。
- 阅读基准把原生超时记为失败，不当作已观察到的资源拒绝；父进程正常或异常退出后都会清理尚存的子进程组。修正观测协议时要重采同协议的 before/after，不能混用旧 harness 数据或调整事前预算。细节见 [reader-scale.md](reader-scale.md)。
- 文档中的命令要在你的改动范围上重新运行；本目录的说明不代替实际结果。
