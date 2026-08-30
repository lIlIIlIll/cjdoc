# cjdoc v0.6.0 implementation report

报告日期：2026-08-30。当前版本：`0.6.0`。当前输出 schema：`cjdoc.doc-ir/7`。

本报告只陈述随报告提交的源码和本次实际运行得到的证据。v0.6.0 已通过 Linux 本机 release gate，但没有创建或推送 tag，也没有发布 release。GitHub-hosted stable、daily 和 tag-release workflow 对当前变更均未运行。

## 1. 结论

- 架构继续采用 Gate C：`std.ast` 与 lexer 是源码语法真值，公开 `SemanticProvider` SPI 是唯一语义扩展入口。当前依赖图不包含 CHIR。
- 生成器只输出 Doc IR v7。严格有效且 package 到 module 映射唯一的 v6 JSON 可以在内存中迁移；歧义输入会被拒绝。
- 输出目录采用进程生命周期独占锁、摘要绑定的 ownership manifest 和可回滚事务。`--force-owned` 只允许覆盖摘要不匹配的已拥有文件。
- public Cangjie API 与 0.5.x 源码不兼容。这是 pre-1.0 的有意破坏性升级，不应描述成兼容修改。
- 本机 `CJDOC_RELEASE_TAG=v0.6.0 scripts/release_check.sh` 通过。该结论不替代其他 SDK、操作系统、GitHub runner 或公开 release 的证据。

## 2. 实测环境与依赖

| 项目 | 实测值 |
|---|---|
| cjc | `1.1.0-alpha.20260829040003 (cjnative)` |
| target | `x86_64-unknown-linux-gnu` |
| cjpm | `1.1.3` |
| SDK root | `/home/elliot/cangjie_sdk/daily/cangjie` |
| host | `Linux-7.2.0-1-mainline-x86_64-with-glibc2.44` |
| Python | `3.14.7` |
| markdown | `db4f9527944b589db8436669f1d255192388cee2` |
| yjson | `bf65cbecd99ac25e7485f8db60990e94a04e57bc` |

`cjpm.toml` 与 `cjpm.lock` 使用相同的 40 位 commit ID，且没有 `branch` 或 `tag`。`vendor/yjson_algorithms/` 保存同一 yjson commit 的 `JsonSchema`、JSON Pointer、JSON Patch 和 work-limit 源码；`UPSTREAM.md` 记录的摘要已逐文件核对。

本次没有修改或构建 compiler、runtime、std 或 stdx，也没有执行 SDK build。

## 3. 架构与数据边界

```text
Cangjie project/workspace
        |
        v
discovery + bounded lexer/std.ast frontend
        |
        +--> SourceDecl + doc comments + explicit gaps
        |
        v
per-module SemanticProvider transaction
        |
        +--> validated provider batch
        +--> AST fallback on module failure
        |
        v
DocumentationBinder + reference resolver + lint
        |
        v
Doc IR v7 --> strict JSON --> Markdown / HTML / search
                          \\-> local content-addressed assets
```

必须保持的边界已经落实：

- 注释只来自源码；`SourceDecl` 是注释与 provider 的桥。
- SymbolId 包含 module identity，不依赖源码行号；file-private 顶层声明使用逻辑文件作用域消歧。
- `unavailable`、`partial` 与 `ambiguous` 保持显式，不把 source spelling 伪装成 canonical type。
- renderer 只依赖公开 Doc IR，不导入 `std.ast` 或 provider 实现。
- unsupported source、无法求值的 cfg、macro 和单文件 parser 失败不会使整个生成器崩溃。
- CHIR dump 文本没有被解析，compiler internal model 没有被复制到项目中。

## 4. 已实现的硬化

### Output transaction

- `.cjdoc-output.json` v2 为每个 owned artifact 保存 SHA-256。
- 输出锁覆盖 directory-mode `generate` 或 `render` 的读取、生成、渲染和提交全过程。锁身份包含 PID 与进程 start time；损坏的锁记录 fail closed。
- 缺失、损坏或未知版本的 manifest 会被拒绝。未拥有路径冲突、symlink 和文件/目录拓扑冲突也会被拒绝。
- 已拥有文件被外部修改时默认视为所有权冲突。`--force-owned` 只跳过该摘要冲突，不覆盖 manifest、未拥有内容或 symlink 检查。
- 每次提交使用唯一 staging 与 backup。故障注入测试证明中途失败会恢复原有 owned bytes，并保留所有未拥有文件。

### Doc IR v7 and validation

- v7 增加 module-aware package、file、provider、declaration 与 SymbolId identity，以及带 provenance 的结构化 annotation。
- decoder 先执行 draft 2020-12 JSON Schema，再执行 owner/module/package/file/reference/asset/status 等跨字段领域不变量。
- JSON 解析、schema evaluation、reference resolution、递归深度、输入大小与资源总量均有显式上限。
- generator 对自身编码结果调用同一严格 validator。无效生成结果会硬失败，不能进入 renderer 或输出事务。
- v6 migration 会一致重写 declaration、owner、package membership、diagnostic、doc tag 和 relationship 中的 SymbolId。package 到 module 不唯一时拒绝迁移。
- `schema doc-ir` 是 v7 alias；`doc-ir-v6` 与 `doc-ir-v7` 分别公开兼容输入和当前输出 contract。

### Provider SPI

- 每个 module 独立执行 `open → analyze → validate → close → commit`。任何阶段失败都会丢弃该 module 的 staged batch，生成 `CJDOC2xxx`，并保留 AST fallback；其他 module 继续执行。
- `SourceDeclarationId` 是 session-local capability。未知、跨 session、重复 source ID、owner ID 或 relationship target 会使该 module batch 无效。
- capability 按 module 记录，不做全局 OR。provider 缺失字段不会删除 source facts，annotation overlay 保留 source/provider provenance。
- provider warning 是普通诊断，可由 `--deny-warnings` 提升为失败。
- 当前没有 authoritative provider；AST fallback 仍明确标记非 canonical semantic state。

### Frontend, cache, and parser isolation

- traversal 只收集 declaration container，不把 function body 内局部声明当成 API。
- orphan doc comment、macro invocation、unsupported declaration 与 unresolved cfg 都写入显式 IR/diagnostic surface。
- source cache v4 绑定 SDK/compiler fingerprint、module identity、逻辑路径和 source content。缓存输入按不可信数据解码并做语义校验，写入使用临时文件加原子替换。
- public engine 与 CLI 使用相同的 isolated parser preflight。worker 不可用时 fail closed；单文件失败保留其他文件的 partial 结果。
- 单文件、目录深度、文件数量和 parser/Markdown 输入均有资源上限。

### Renderer and local assets

- `MarkdownNode` 是 Markdown/HTML 正文的唯一语义来源；renderer 不重新解释 `rawText`。
- audience projection 会重新计算 package、owner、relationship、search 与页面集合，不泄漏被过滤符号。
- module/package/symbol 路由和 anchor 使用稳定 identity；生成前执行全局 collision 检查。
- 本地图片只接受项目内、非 symlink、大小受限、media type 与 magic bytes 一致的普通文件。内容按摘要去重并写入 `assets/`。
- HTML 不插入用户 raw HTML，使用 CSP 和外部 JS/CSS。`search-index.js` 允许静态站点在 `file://` 下搜索。

### Release engineering

- stable 和 release workflow 的第三方 Actions 与 stable SDK archive 使用固定摘要；daily workflow 要求 URL 与 SHA-256 成对配置，缺少任一值即失败。
- `verify_release.py` 检查稳定 SemVer、精确 tag、manifest/lock Git source 与 commit、v7 schema alias 和 frozen 性能基线。
- 性能 gate 在一个固定 CPU 上按 cold/warm/warm/cold 顺序测量两个 profile；每次使用新输出目录，并验证 Doc IR SHA-256、wall time 与 peak RSS。
- 发布包固定文件顺序、时间、owner 与权限，并带内部 payload manifest。publish job 只在三个平台的六个精确 asset 全部存在且 sidecar 摘要有效后公开 draft。
- `release_check.sh` 只生成本地证据，不创建 tag、不 push、不创建 PR，也不发布 release。

## 5. 兼容性结论

源码场景分类结果为 `incompatible`。确认的破坏点包括旧 `DocumentationSet`/`SemanticResult` 字段与构造方式被 module-aware model 替代，以及 provider DTO、capability 和 transaction contract 的变化。新公开类型和字段也改变了调用方的编译契约。

该结论符合 v0.6.0 的设计：

- 0.5.x Cangjie 调用方必须重新编译并适配新的 facade、Doc IR model 或 provider SPI。
- v6 JSON 只在严格有效且 module mapping 唯一时获得读取迁移；生成输出始终为 v7。
- v7 SymbolId 与 v6 SymbolId 不保证字符串相等。
- 本次只运行了源码 compatibility scenario 分类，没有执行 old/new SDK ABI 二进制矩阵。因此不能扩展为 ABI 兼容性结论。

## 6. 本次验证结果

### Local acceptance and release gate

| Gate | 结果 |
|---|---|
| `cjpm build` | PASS |
| `cjpm test` | PASS，30/30，0 skipped，0 failed |
| Python release-tool tests | PASS，9/9 |
| 9 组 v7 golden | PASS；双次输出 byte-identical，strict codec round-trip 一致 |
| v6 migration | PASS；严格 basic fixture 迁移，歧义映射 rejection 有 public contract test |
| schema sync | PASS；binary 与 `docs/schema/` byte-identical |
| HTML validation | PASS；普通 fixture 6 pages/20 search entries，security fixture 2 pages/1 entry |
| output/provider/resource checks | PASS；rollback、lock、ownership、symlink、32 MiB source limit 与外部 provider fixture 均通过 |
| `scripts/check.sh` | PASS，`cjdoc acceptance gate passed` |
| `CJDOC_RELEASE_TAG=v0.6.0 scripts/release_check.sh` | PASS，`cjdoc release gate passed` |

构建与测试期间 yjson macro expansion 产生 generated unused warnings；门禁退出码仍为 0。没有把 warning 隐藏或描述成无 warning 构建。

### Real-repository smoke

release gate 对当前 cjdoc 仓库执行两次完整 JSON+HTML 生成，并逐文件比较 SHA-256：

| status | declarations | diagnostics | artifacts | docs SHA-256 | elapsed |
|---|---:|---:|---:|---|---:|
| `complete` | 1236 | 0 | 64 | `5257e35a354a134f86c3129a6bdb6ba4d8aee0955d8fec25bd0281c7e8d180f6` | 18,803 ms |

这证明当前仓库在本机的完整生成是确定的；它不替代其他真实仓库或其他平台的 smoke。

### Frozen performance gate

二进制 SHA-256：`996e11477e1d55ee179a9eff658a08a704b09fc2a907c97d2372bff0b630cff3`。每个 variant 有两个 ABBA sample。

| profile | variant | max elapsed / budget | max RSS / budget | Doc IR identity |
|---|---|---:|---:|---|
| basic | cold | 262 / 1,056 ms | 96,932 / 189,688 KiB | `a0d17a…3300d` |
| basic | warm | 418 / 1,116 ms | 339,104 / 678,184 KiB | `a0d17a…3300d` |
| self | cold | 11,532 / 30,267 ms | 227,640 / 484,280 KiB | `5257e3…180f6` |
| self | warm | 7,417 / 16,683 ms | 339,036 / 678,096 KiB | `5257e3…180f6` |

这些是当前机器上的本地 budget evidence，不是 GitHub runner、Server 或正式跨平台性能认证。

### Release package

Linux x64 archive 使用当前 binary 独立构建两次，两个文件的 SHA-256 都是：

```text
1e103438785b568db1129aaf2d4dd850fc16def4696af9351e4b9be3a177b2de
```

这验证了当前 Linux archive 的字节可复现性。Windows 与 macOS archive 尚未在对应平台构建；现有 Python fixture 只覆盖 Linux tar archive 的可复现构造。

### Evidence boundary

| Evidence | 状态 |
|---|---|
| Linux 本机 daily SDK build/test/check | PASS |
| Linux 本机 v0.6.0 release gate | PASS |
| Linux 本机真实仓库与性能 gate | PASS |
| Workflow YAML parser | PASS |
| GitHub stable Linux/Windows/macOS matrix | NOT RUN |
| GitHub configured daily workflow | NOT RUN |
| GitHub tag release/publish | NOT RUN |
| push、PR、tag、release | NOT PERFORMED |

## 7. 当前限制与后续门禁

- CHIR G1–G7 尚未全部实测 PASS，因此不能实现或宣称 authoritative `ChirSemanticProvider`。
- AST fallback 不提供 canonical alias/type identity、override target、compiler owner 或 generated declaration origin。
- macro 不展开；无法求值的 cfg 记录为 unsupported source。cfg profile 仍需调用者显式提供。
- cached dependency discovery 不下载缺失依赖。
- 文档示例不会编译或执行。
- Markdown node range 尚未映射成完整项目 source range。
- 正式发布前仍需在精确提交上完成 GitHub stable 三平台、configured daily 与 tag-release workflow，并验证公开 release 的六个下载 asset 和 checksum。

CHIR capability 细节见 [`docs/research/api-capability-matrix.md`](docs/research/api-capability-matrix.md)。发布证据层级与 checklist 见 [`docs/release-process.md`](docs/release-process.md)。

## 8. 复现命令

准备 SDK 环境后：

```bash
cjpm build
cjpm test
scripts/check.sh
python3 scripts/real_repository_smoke.py --project .
python3 scripts/perf_gate.py check
CJDOC_RELEASE_TAG=v0.6.0 scripts/release_check.sh
```

本机 release receipt 写入 `target/release-evidence/`。该目录是运行产物，不属于源码提交。
