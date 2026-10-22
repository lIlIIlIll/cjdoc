# 维护者文档

这里是 cjdoc 的维护者/开发者文档：面向修改仓库、同步 Doc IR 与 golden、运行发布与 CI 验收的人。安装和日常使用请看[使用者文档索引](../README.md)（README、usage、advanced-usage、configuration、guides、i18n、documentation-quality）。

改代码前先读仓库根目录的 [AGENTS.md](../../AGENTS.md)：它定义项目目标、架构边界、修改规则、代码风格和 Review 要求。本目录的文档补充具体操作；两者冲突时以 AGENTS.md 为准。

## 建议阅读顺序

按你要做的事选一条线：

1. **首次参与开发**：[AGENTS.md](../../AGENTS.md) → [build.md](build.md)（工具链与本地门禁）→ [release-process.md](release-process.md)（证据分层，避免把低层通过当成发布证据）。
2. **修改 Doc IR / schema / golden**：[doc-ir.md](doc-ir.md) → AGENTS.md 的“修改规则”一节 → 相关验收记录。
3. **修改跨文档链接或依赖身份**：[document-links.md](document-links.md) → [doc-ir.md](doc-ir.md) 的导航 wire 部分。
4. **准备发布**：[build.md](build.md) → [release-process.md](release-process.md) → [ci-orchestration.md](ci-orchestration.md)、[ci-wallclock.md](ci-wallclock.md)、[paired-samples-main.md](paired-samples-main.md)。
5. **处理 PR 复审门禁**：[codex-review-gate.md](codex-review-gate.md) → AGENTS.md 的“Codex 复审完成门禁”。
6. **展示站与阅读体验**：[showcase-contract.md](showcase-contract.md) → [showcase-phases.md](showcase-phases.md) → [api-reading-audit.md](api-reading-audit.md)。

## 文档地图

| 主题 | 入口 | 说明 |
|---|---|---|
| 仓库工作规范 | [AGENTS.md](../../AGENTS.md) | 架构边界、修改规则、代码风格、Review 规则 |
| 构建与本地验收 | [build.md](build.md) | SDK 1.2.0 STS + stdx sidecar、`-O1` 覆盖、`scripts/check.sh`、可选 CHIR worker |
| Doc IR 与 schema | [doc-ir.md](doc-ir.md) | Doc IR v16、current-only decoder、schema/golden 更新、导航 wire 与预算 |
| 跨文档链接 | [document-links.md](document-links.md) | `--doc-source`/`--doc-inventory-pin`/`--build-context` 契约、identity、DL05/E2E2、验收脚本 |
| 发布流程 | [release-process.md](release-process.md) | 证据层级、性能基线、三平台 CI、tag release 与 checklist |
| CI/Pages 编排测量 | [ci-orchestration.md](ci-orchestration.md) | issue #82 的配对样本语义、阶段耗时来源与并行决策 |
| CI 墙钟数据 | [ci-wallclock.md](ci-wallclock.md) | 从 GitHub API 读回的 CI/Pages/Release 墙钟样本 |
| 配对样本快照 | [paired-samples-main.md](paired-samples-main.md) | `main` 分支配对样本的时间点快照；用脚本重新生成，不要手改 |
| Codex 复审门禁 | [codex-review-gate.md](codex-review-gate.md) | `codex-review-current-head` 的工作机制、Required Check 启用与语义边界 |
| 展示站契约 | [showcase-contract.md](showcase-contract.md) | PocketKit 展示站、功能清单、发布条件与浏览器验收 |
| 展示站阶段归因 | [showcase-phases.md](showcase-phases.md) | Pages assemble 各阶段墙钟与并行化决策（issue #82/#93） |
| 阅读体验审计 | [api-reading-audit.md](api-reading-audit.md) | 33 项 API 阅读体验修复的实现与验收重点 |
| 验收记录 | [acceptance/](acceptance/) | 按 issue 归档的验收映射与复现入口 |
| 历史实现报告 | [implementation-report-v0.6.md](implementation-report-v0.6.md) | v0.6.0 的历史报告，仅作归档，不是当前证据 |
| 调查记录 | [../research/](../research/) | CHIR、`std.ast`、高亮边界等时间点调查记录 |
| 发布 schema | [../schema/](../schema/) | 当前发布的 18 个 schema 文件，由 `scripts/update_schemas.sh` 从构建产物同步 |

## 验收记录

[acceptance/](acceptance/) 下的文件按 issue 归档：

- [issue-56-acceptance.md](acceptance/issue-56-acceptance.md)：#56 RDR 工作项与实测证据。
- [issue-64-acceptance.md](acceptance/issue-64-acceptance.md)：#64 中英文作者正文、语言目录与字段投影。
- [issue-100-acceptance.md](acceptance/issue-100-acceptance.md)：#100 静态代码高亮的 CLI、冻结 IR 与浏览器复现。
- [issue-113-acceptance.md](acceptance/issue-113-acceptance.md)：#113 验收包索引中的作者概述。

这些记录是各自时间点的证据映射，文中有实测环境、复现命令和边界声明；不要把它们当作当前门禁结果。当前证据要在目标提交上重新运行对应脚本。

## 注意

- 本目录描述维护者流程，包含内部 schema、验收脚本、CI 与发布约束；不要把这些内容搬回使用者文档。
- 历史文档（`implementation-report-v0.6.md`、`paired-samples-main.md`、`ci-wallclock.md`、`showcase-phases.md` 等）是时间点快照，各自标注了日期或运行 ID；引用前先确认它是否仍适用于当前 revision。
- 文档中的命令要在你的改动范围上重新运行；本目录的说明不代替实际结果。
