# Doc IR、schema 与 golden

Doc IR 是 renderer 的唯一输入：源码声明、注释和位置先由 frontend 绑定成内部模型，再编码为严格 JSON。使用者不需要直接编辑这个 JSON；本文面向修改产出或消费它的维护者。

## 当前版本与硬约束

- 当前输出版本是 **`cjdoc.doc-ir/16`**（`cjdoc schema doc-ir` 会打印当前版本的 schema）。
- decoder **只接受当前版本**，不迁移旧输入。`render --input docs.json` 会严格验证当前 schema 与引用关系；未知属性、重复 JSON 键和不满足当前约束的输入都会被拒绝。
- 历史 `/6`–`/15` schema 与 golden 已从仓库移除，不保留只读副本；“冻结旧格式 + 迁移 receipt”不是本仓库的路径。wire 变化时提升版本并拒绝旧版本输入。
- 根字段 `apiCollectionState` 取 `resolved`、`partial` 或 `unavailable`，独立于展示用的 `status`。它在 source/provider 绑定后、highlight/lint/i18n/导航处理前采集；呈现错误不会把已采集的 API 改成不完整。
- `generator.toolchain` 自动生成时为空字符串：运行时 `cjc --version`、`--cjc` 或包装器变量都不能认证真正链接的 parser SDK 构建。目标项目的 compiler/std/stdx 身份由构建记录（`--build-context`）单独绑定，见 [document-links.md](document-links.md)。

## 公共 schema 命令

```bash
cjdoc schema list
cjdoc schema doc-ir
cjdoc schema doc-ir-v16
```

`docs/schema/` 保存当前发布的 18 个 schema 文件：`doc-ir`、`doc-ir-v16`、`diagnostics`、`cfg-matrix`、`search-index`、`search-index-v9`、`symbol-index`、`navigation-index`、`api-surface`、`api-surface-v3`、`api-diff`、`api-diff-v2`、`documentation-coverage`、`documentation-quality`、`versions`、`versions-v2`、`translation-coverage`、`site-manifest`。

`scripts/check.sh cli` 会调用 `cjdoc schema <name>` 逐个导出并与 `docs/schema/` 逐字节比较，所以 schema 文件与 binary 必须同步。release 包也包含这组发布 schema 与 `release-manifest.json`；发布校验要求这 18 个 schema 与当前 golden 都被 Git 跟踪。

## 修改 Doc IR 的同步清单

参考 AGENTS.md 的“修改规则”，一次 wire/模型变更至少同时处理：

1. 提升 `cjdoc.doc-ir/N` 版本（破坏性变更必须提升；decoder 保持 current-only）。
2. `src/model/doc_ir.cj` 及相关的 `src/model/doc_ir_*.cj` 类型。
3. JSON encoder/decoder：`src/render/json_encode.cj`、`src/render/json_decode.cj` 及拆分出的 `json_decode_*.cj`；保持严格行为（未知属性、重复键、类型与引用约束都拒绝）。
4. schema source：`src/schema_data/`（当前 v16 定义在 `src/schema_data/schema_v16.cj`，共享 schema 在 `schemas.cj` 等文件）。
5. 重新构建后运行 `bash scripts/update_schemas.sh`，把构建产物同步到 `docs/schema/`。
6. 更新 public-contract tests 与相应单测；不要为了让测试变绿而放宽 strict codec 或手改期望产物。
7. 运行 `bash scripts/update_goldens.sh` 生成 `tests/fixtures/golden-v16/`，再检查 diff。golden 不手改；更新脚本自己生成并校验。
8. 若生成输出的 Doc IR 字节发生变化，还要刷新 `tests/perf/baseline.json` 的 Doc IR identity：CI 每个 push 都跑 `python3 scripts/perf_gate.py identities --binary target/release/bin/main --evidence target/ci-evidence/perf-identities.json`，未刷新的 baseline 会让 CI 失败。性能基线的刷新与冻结规则见 [release-process.md](release-process.md) 的“Performance baseline”。
9. 跑 `bash scripts/check.sh`（至少 `native`、`cli`）确认 current-only codec round-trip、两次生成确定性、HTML 全站校验和 schema 同步。

`self` 性能 profile 也会捕获 `cjdoc.toml` 配置的概念页，因此只修改文档正文或发布页面配置，也可能改变 Doc IR identity。此类变更应实跑生成并核对产物后同步 `referenceDocsSha256`；不要因此重设 elapsed/RSS 测量值、阈值或参考环境。只更新校验值不是性能重新标定，也不是性能回归证据。

### `scripts/update_schemas.sh`

- 从 `target/release/bin/main`（或 `main.exe`）导出一整套发布 schema，先写入 staging 再原子替换。
- 严格解析全部 schema（拒绝重复键与非有限数字），校验 `$id`、draft、版本与根契约，然后更新当前 v16 与共享 schema。
- 不发布冻结的历史 Doc IR schema；它不实现完整的官方 Draft 2020-12 meta-schema，真正的严格验证在构建的 yjson-backed decoder 与 `check.sh` 的 round-trip 中。
- 需要先构建 binary；不要手工 normalize 一个失败的期望产物。

### `scripts/update_goldens.sh`

- 先把已提交的 fixture 树归档成不可变快照，只从该快照生成，生成后再核对摘要与 Git identity，最后发布完整的 current v16 golden 集合。
- 拒绝脏的或混合来源的 fixture 输入；不保留 legacy Doc IR golden。
- `source_edges` 使用干净的外部 checkout 时，三个变量必须同时提供，且 expected commit/subtree 在生成前后都要匹配该 Git worktree：

```bash
CJDOC_SOURCE_EDGES_PROJECT=/clean/checkout/tests/fixtures/projects/source_edges \
CJDOC_SOURCE_EDGES_COMMIT=<40-hex-commit> \
CJDOC_SOURCE_EDGES_TREE=<40-hex-subtree> \
bash scripts/update_goldens.sh
```

当前 golden 覆盖 `basic`、`functions`、`types`、`extend_visibility`、`source_edges`、`unsupported`、`workspace`、`conditional-linux`、`path-dependencies` 等 fixture，由 `scripts/check.sh cli` 逐个两次生成、比较并与 golden 字节对齐。

## 导航 wire

`navigation` 与 `TypeRef.semantic` 描述的是不同事实：前者是文档链接决策，后者是语义证据。找到文档链接不会把 `unavailable`/`partial` 语义升级为 resolved，导航的 `exact`/`manual` 也不把 `semanticState` 提升为 resolved。

### TypeRef 的平展语义字段

Doc IR `/16` 把三项类型语义事实命名平铺为必需的 `semanticState`、`semanticCanonical`、`semanticProvider`；后两项允许 `null`。公开的 `TypeRef.semantic: SemanticType` 模型完整保留，转换在 codec 内完成，不改变语义或导航。这样每个 TypeRef 少一个真实 JSON 对象，不增加数组条目，也不丢 canonical/provider。

### 紧凑失败记录

非 resolved、`matchLevel=none` 且 dependency/document-set/index/symbol/URL/API/language 七项上下文全空的失败，在 wire 上以恰好两项的 `[state, reason]` 保存。`state` 只能是 `unresolved`、`ambiguous`、`unavailable`，`reason` 保留完整原文。任何有上下文的失败和全部 resolved 记录仍保存完整的十字段对象；公开 `TypeNavigation` 模型始终保留十个字段。

- decoder 拒绝 resolved 的 tuple、元素数量不对的 tuple、非字符串项，以及本应使用 tuple 却写成无上下文对象的情况。
- tuple 不是成功链接、依赖版本或兼容性证据。
- `scripts/document_navigation.py` 在 wire 与完整模型之间转换（`decode_document_navigation` / `encode_document_navigation`），只做表示转换，不扫描类型名、不改变任何决定。
- `navigation: null` 只表示没有记录独立导航决策：新生成的结构 wrapper、AST 确认的 intrinsic primitive、作用域确认的泛型形参在没有独立可解析目标时不重复发布失败对象。实际 named/generic 引用（缺版本、歧义、未知依赖、隐藏目标等）的失败决策保持非空。质量报告仍统计全部结构节点、原子与非目标位置。

### 其它产物的版本

`symbol-index` 当前是 `cjdoc.symbol-index/2`；HTML 内嵌 `html/symbol-index.json` 与独立 `symbol-index/symbol-index.json` 共用生产逻辑，但路由根不同：独立索引的路由根是整个输出目录（自动加 `html/` 前缀），HTML 内嵌索引不带该前缀。`navigation-index.json` 是 `cjdoc.navigation-index/1`；API snapshot 与 diff 分别是 `cjdoc.api-surface/3` 与 `cjdoc.api-diff/2`。这些格式各自版本化，不随 Doc IR 版本一起迁移。

## 资源预算与回退

- Doc IR 的对象数量上限为 **65,536**，完整文档默认上限 **64 MiB**；可通过 `[limits].max-doc-ir-mib` 或 `--max-doc-ir-mib` 收紧到 `1..64` MiB，配置规则见 [配置参考](../configuration.md)。数组/字符串预算保持不变。
- 导航诊断最多 **4096** 条；导航绑定/解析的累计工作预算为 **262144 步与 32 MiB**，不逐索引或递归子图重置（该预算与依赖文档解析共用，细节见 [document-links.md](document-links.md)）。
- 超限时按既有有界回退编码：保留仍可按 codec 边界编码的部分，并记录 `CJDOC3027`（文档产物超过资源限制）或 `CJDOC3026`（Markdown/概念页解析退化）等诊断。
- 渲染器只读 Doc IR；普通 `render` 不读取原项目、receipt、索引、SDK 或网络，也不重新选版本。

公开 API 的 `GenerationRequest(..., maxDocIrMiB: 32)` 使用同一配置规则。`encodeDocIr`、`decodeDocIr` 和 `validateDocumentationSet` 接受可选的 `maxDocumentBytes` 字节预算，范围为 `1..67108864`。配置属于运行策略，不写入 Doc IR，schema/wire 格式不变。

## 验证

```bash
bash scripts/check.sh cli --repo . --worker-binary target/release/bin/chir-worker-main
```

`check.sh cli` 覆盖：逐 schema 与 `docs/schema/` 比较、current v16 golden 双次生成与 round-trip、多格式 HTML 全站校验、输出所有权/安全、i18n 门禁、外部快照门禁。完整门禁与各阶段见 [build.md](build.md)。
