# cjdoc implementation report

报告日期：2026-08-30。

本报告覆盖当前 v0.3.0 的非 CHIR 实现与 hardening。当前版本采用 Gate C：产品使用 `std.ast` 和可插拔 `SemanticProvider`，暂不接入 CHIR。

## 1. 实际环境

| 项目 | 实测值 |
|---|---|
| cjc | `1.1.0-alpha.20260829040003 (cjnative)` |
| target | `x86_64-unknown-linux-gnu` |
| cjpm | `1.1.3` |
| SDK | `$CANGJIE_HOME=/home/elliot/cangjie_sdk/daily/cangjie`，canonical path 为 `/home/elliot/cangjie_sdk/main/linux_x64/vanilla/20260829/cangjie` |
| std.ast | SDK 内置，实际编译验证 `cangjieLex`、`parseProgram`、`Program.traverse`、`Visitor` 及使用到的 declaration API |
| stdx | 20260829 dynamic/static sidecar 均已检查 |
| stdx.chir | 20260829 sidecar 中没有 `stdx.chir.cjo`，普通项目不能 import |
| Markdown | `markdown` 0.9.0，commit `d73eecee4e19fe56a57cd9f150fe0a62bae405c4` |

当前 `/home/elliot/cangjie_sdk/daily/cangjie` 已解析到上述 20260829 SDK。没有构建或修改 compiler、std、stdx。

详细 API 证据位于：

- [`docs/research/api-capability-matrix.md`](docs/research/api-capability-matrix.md)
- [`docs/research/std-ast-findings.md`](docs/research/std-ast-findings.md)
- [`docs/research/stdx-chir-findings.md`](docs/research/stdx-chir-findings.md)

## 2. CHIR 结论

**FAIL，作为当前版本的 authoritative semantic source。Architecture Gate 选择 Gate C。**

分项结果：

- `cjc --emit-chir=raw` 与 `chir-dis`：PASS。
- current daily 普通项目 import `stdx.chir`：FAIL，构建产物不存在。
- local same-version experiment 的 Package、definition、type、owner、generic 等读取：PARTIAL，只证明部分公开 API 形态。
- `Function` 级 source/debug location：FAIL，公开 API 不足以完成可靠的 source binding。
- extension method owner：PARTIAL，local probe 中 `declaredParent` 为空。

因此当前产品没有 `stdx.chir` import、没有 CHIR 文本解析器，也没有 compiler internal 副本。CHIR 只保留为未来 provider 的接入点。

## 3. Source 与 semantic binding

当前产品的 binding 分为两段。

### Source comment binding

Lexer 收集 `/** ... */` 和真实位置，AST 收集 source declaration。Comment binder 先把 `RawDocComment` 绑定到 `SourceDeclaration`，不直接绑定 semantic declaration。

内部 source key 是：

```text
logical file path + start line + start column + declaration kind + name
```

owner 通过 AST source range containment 单独确定。source key 可以包含位置，但不会序列化，也不会成为 SymbolId。

### Source 与 SemanticProvider binding

`SemanticProvider.analyze(SourceSnapshot)` 返回 provider-neutral `SemanticResult`。Binder 以 source key 做一对一匹配，并记录：

- matched
- missing
- ambiguous
- extraneous
- contract violations

Provider 声明的 capabilities 会被强制检查。没有声明 canonical types/signatures 的 provider 即使返回这些数据，也会被降级并产生 `CJDOC1017`。

已验证 fixture 包括 overload、member declaration、multiline signature、annotation、generic declaration、extend、Unicode identifier、conditional declaration 和 override spelling。仓颉 class declaration 只能位于顶层，因此没有构造不存在的 nested type source fixture。AST provider 的 source binding 为 PASS；CHIR Function binding 仍为 FAIL。

剩余风险：macro-generated declaration 没有展开 origin，override target 没有 semantic identity，未来 CHIR 版本仍需重新验证 location 与 owner。

## 4. 最终架构

```text
Cangjie source
  -> content-addressed source cache
  -> isolated std.ast preflight worker on cache miss
  -> std.ast lexer/parser
  -> AstSourceProvider
       -> project/workspace/dependency discovery
       -> RawDocComment collector
       -> SourceDeclaration collector
       -> source comment binder
       -> SourceSnapshot
  -> SemanticProvider
       -> AstSemanticProvider
       -> SemanticResult + capabilities
  -> DocumentationBinder
       -> source/semantic contract validation
       -> stable SymbolId
       -> DocumentationSet (Doc IR)
  -> cfg three-value evaluator
  -> reference resolution + lint + coverage
  -> JSON renderer
  -> Markdown renderer -> markdown parser validation
  -> HTML renderer -> safe HTML + CSP + search index/UI

future serialized CHIR
  -> ChirSemanticProvider package
  -> provider-neutral SemanticResult
```

根 executable 只负责 CLI。可复用产品逻辑位于 `packages/cjdoc_core`。Renderer、comment parser、lint、binder 和 Doc IR 均不依赖 `stdx.chir`。

## 5. 已实现功能

### Complete

- Phase 0 API reality check、可编译 probe、capability matrix 和 Gate C 决策。
- 普通 cjpm package、workspace members、递归 `src/**/*.cj` 扫描。
- 可选 path dependency 扫描，以及显式 `--dependency-source <name>=<path>` 离线源码输入。
- 可选 `cjpm.lock` + 已有 cjpm cache 离线 dependency discovery，递归读取 dependency lock、保留直接边、阻断循环，不下载内容，显式 source 优先。
- `std.ast` lexer/parser/traversal，不用正则解析仓颉 declaration。
- `/** */` collector、source range、source spelling、comment-to-source binding。
- class、struct、interface、enum、enum case、extend、function、constructor、property、variable、type alias、generic 和 member declaration。
- visibility、owner、annotation spelling、parameters、return type spelling、supertype 和 extension target source relationships。
- `SemanticProvider`、`SemanticCapabilities`、`SemanticResult`、`DocumentationBinder` 和 default `AstSemanticProvider`。
- Provider identity/capability enforcement，以及 matched/missing/ambiguous/extraneous/contract-violation statistics。
- Doc IR v4：project/modules、configuration、semanticBinding、packages、symbols、origin、unsupported declarations、diagnostics。
- stable SymbolId，不使用文件名或行号；overload 使用参数类型 identity 区分。
- semantic state 显式表示 `resolved`、`partial`、`unavailable`、`ambiguous`。
- Markdown body、summary/description 和全部首版结构化 tags。
- Doc IR declaration index、跨 package `@see`、显式 signature 消歧和稳定链接。
- lint：unknown/duplicate `@param`、duplicate `@return`/`@throws`、invalid return docs、missing parameter/symbol docs、broken/unresolved/ambiguous `@see`、Markdown URL/anchor、duplicate SymbolId、ambiguous semantic binding。
- public symbol/parameter documentation coverage，以及 `--deny-warnings` CI policy。
- deterministic JSON、Draft 2020-12 schema、无绝对路径、atomic write、内容不变时不替换文件。
- Markdown renderer，只读取 Doc IR，使用 Markdown AST 调整 heading depth。
- HTML renderer，只读取 Doc IR，包含 package/type/member 页面、breadcrumbs、search-index v2、确定性排名、kind/package filters、键盘/ARIA、CSP 和安全 HTML。
- 根项目和每个 dependency 的显式 source URL template；dependency revision 不从 VCS 猜测。
- `--cfg` profile，支持布尔键、`!`、`&&`、`||`、括号、`==`/`!=` 和三值保守选择。
- `--cfg-matrix-profile` 显式多 profile 输出，生成 deterministic、schema-versioned 的 `cjdoc.cfg-matrix/1` JSON；参数顺序不影响结果。
- source macro 以 `unsupportedDeclarations` 和 `origin: source` 记录，不执行 expansion。
- AST override spelling 以 `symbolRelationships` 记录，目标明确为 `unavailable`。
- `--jobs auto|1..64` 文件级并行解析；auto 按处理器数选择并限制为 8，按源码逻辑路径确定性合并。
- 内容寻址的逐文件 source cache，完整 key 校验、SDK/cjc/parser schema invalidation、损坏恢复和显式 stats。
- CLI cache miss 使用独立 AST preflight process；普通 parse error、已知深 BinaryExpr 与未知 worker crash 分别恢复。
- config file、stdout、text/JSON/SARIF diagnostics。
- `cjpm install`、launcher、自定义下游 SemanticProvider fixture。
- host path separator/boundary normalization、`.exe` 选择、portable inode/monotonic timing 和无本机 helper 的 release-runner fallback。

### Partial

- AST 类型和签名是 source spelling，不是 type-checker 结果，统一保持 `partial`/`canonical: null`。
- `@see` 不做 alias 展开、import resolution、隐式转换或完整 overload resolution。
- cfg evaluator 不读取编译器内建 target profile；单 profile 和矩阵 profile 都必须由调用者显式提供 key/value。
- macro origin 只覆盖源码 macro declaration，不包含 expansion-generated declaration。
- override 关系可以识别 modifier，但 AST provider 不能解析目标 SymbolId。
- manifest/lock adapter 只提取 cjdoc 使用的字段，不是通用 TOML parser。
- cache discovery 不解析 registry index，也不联网补全缺失 dependency。
- 并行扫描已经确定性验证，但不保证加速；大型 Markdown 仓库的本次 `--jobs 4` 略慢且内存更高。

### Not implemented

- `ChirSemanticProvider`。
- canonical semantic type/signature、semantic extension owner、semantic override target。
- macro expansion 执行。文档生成默认不会执行用户文档代码或 macro。
- Windows、macOS 和非 x86_64 target 的 release gate 尚未运行。

## 6. 关键文件

| 文件 | 职责 |
|---|---|
| `src/main.cj` | executable 入口，只调用 core CLI |
| `packages/cjdoc_core/src/cli.cj` | CLI、输出路径、atomic/incremental write、HTML managed files |
| `packages/cjdoc_core/src/model.cj` | Source/Semantic/Doc IR DTO 和 provider boundary |
| `packages/cjdoc_core/src/manifest_adapter.cj` | 受限 cjpm manifest/lock view |
| `packages/cjdoc_core/src/source_frontend.cj` | project/dependency discovery、cache、AST worker、lexer/parser、comments、并行 source collection |
| `packages/cjdoc_core/src/semantic_provider.cj` | default AST semantic provider |
| `packages/cjdoc_core/src/documentation_binder.cj` | provider contract、binding、SymbolId、Doc IR |
| `packages/cjdoc_core/src/cfg_profile.cj` | 保守 cfg profile selection |
| `packages/cjdoc_core/src/comment_parser.cj` | Markdown body 和结构化 tags |
| `packages/cjdoc_core/src/reference_resolver.cj` | declaration index 和 `@see` resolution |
| `packages/cjdoc_core/src/lint.cj` | 稳定 diagnostic codes |
| `packages/cjdoc_core/src/diagnostic_renderer.cj` | JSON diagnostics 和 SARIF 2.1.0 |
| `packages/cjdoc_core/src/json_renderer.cj` | Doc IR v4 JSON |
| `packages/cjdoc_core/src/markdown_renderer.cj` | Doc IR 到 Markdown |
| `packages/cjdoc_core/src/html_renderer.cj` | 安全 HTML、search、source links |
| `packages/cjdoc_core/src/lib_test.cj` | public behavior unit tests |
| `docs/schema/doc-ir.schema.json` | `cjdoc.doc-ir/4` schema |
| `docs/schema/cfg-matrix.schema.json` | `cjdoc.cfg-matrix/1` schema |
| `docs/schema/search-index.schema.json` | `cjdoc.search-index/2` schema |
| `scripts/check.sh` | 完整 acceptance gate |
| `scripts/cangjie_env_runner.sh` | 本机 helper 或已有 SDK 环境的 portable command adapter |
| `scripts/portable_probe.py` | 跨平台 inode 和 monotonic time probe |
| `scripts/validate_schema.py` | JSON Schema validator |
| `scripts/validate_html_site.py` | HTML links、anchors、search 和安全 validator |
| `scripts/perf_gate.sh` | 2000-symbol deterministic performance gate |
| `scripts/run_with_peak_memory.py` | 无轮询的 child peak RSS 测量 glue |
| `probes/` | std.ast 和 CHIR reality-check probes |

## 7. 测试结果

### Build 和 unit

- `cjpm build`：PASS。
- 根目录 `cjpm test`：PASS，root executable 本身没有测试用例（TOTAL 0）。
- `packages/cjdoc_core` 的 `cjpm test`：38/38 PASS。
- provider plugin executable：PASS，输出 `provider plugin ok`。
- `cjpm install --path .`：PASS，安装后的 `cjdoc --version` 为 `0.3.0`。

### Golden 和 integration

- Doc IR JSON golden：16 个输出，全部 schema-valid、两次 byte-identical、无绝对路径。
- cfg matrix golden：1 个 `cjdoc.cfg-matrix/1` 输出，profile 与 cfg 参数换序后 byte-identical，嵌套 Doc IR 全部 schema-valid。
- Markdown golden：5 个输出，两次 byte-identical。
- HTML golden：站点目录两次一致，links/anchors/CSP/search validator 与 search-index schema PASS。
- cfg Linux profile、显式 cfg matrix、override、path dependency、offline dependency source、root/dependency source URL、HTML security、stale cleanup：PASS。
- `--jobs 1`、`--jobs 4` 与 `--jobs auto` 的 fixture/large gate 输出保持确定顺序。
- cache cold/hot、SDK fingerprint invalidation、corrupt-entry recovery、worker failure isolation：PASS。
- config、stdout、JSON diagnostics、SARIF、coverage、deny warnings、transitive cached dependency discovery：PASS。
- self generation 使用 `--include-path-dependencies`：2 modules、2 packages、674 symbols、59 HTML pages、0 diagnostics；两次 JSON byte-identical，Doc IR/search schema 和 HTML validator PASS。
- 深 BinaryExpr 在 jobs 1/4 下均产生同一 `CJDOC1012` 部分 Doc IR：PASS。
- JSON 和 HTML 内容不变时 inode 保持不变：PASS。
- invalid schema、duplicate SymbolId、invalid workspace：fail-closed PASS。

### 性能门禁

2000 个函数分布在 40 个 source files：cold 703 ms、hot 320 ms、peak RSS 339300 KiB。cold 门限 15000 ms、hot 门限 7000 ms、peak 门限 524288 KiB；两次 JSON byte-identical，cache entry 数为 40。

### 真实仓库

所有命令使用当前构建的 cjdoc。被测仓库保持只读，输出和 cache 写入 `/tmp/cjdoc-real-20260830/`。

| repo | source files | packages | symbols | documented | non-resolved type refs | diagnostics | cold | hot | cold peak RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| sse4cj | 16 | 1 | 603 | 0 | 702 | 0 | 0.51 s | 0.16 s | 339192 KiB |
| llm4cj | 8 | 1 | 787 | 0 | 1099 | 0 | 1.17 s | 0.18 s | 339284 KiB |
| markdown | 39 | 9 | 2571 | 52 | 3980 | 0 | 12.06 s | 0.42 s | 371436 KiB |

三者 cold/hot JSON 均 `cmp` PASS，ambiguous binding 为 0。时间来自执行工具 wall clock，peak RSS 来自 `resource.getrusage(RUSAGE_CHILDREN)`；均为单次观测，不是稳定 benchmark。

## 8. 当前限制

- macro-generated declaration：不会展开，只记录 source macro unsupported entry。
- conditional compilation：支持组合表达式和显式 cfg matrix，但不读取 compiler target profile。
- extend：target 和附加 supertype 是 AST spelling，semantic owner/canonical type 不可用。
- generic specialization：只记录声明 spelling，不实例化。
- overload：AST spelling 可以稳定区分，alias 等价性不能 canonicalize。
- source location：AST 位置可用，column 按 UTF-8 byte；CHIR Function location 不可用。
- dependency packages：支持 path package、显式离线 source，以及递归的 lock-pinned cache source graph；不下载 registry/git dependency。
- annotations：保存 source spelling，不执行或做 semantic resolution。
- deep expressions：保留预扫描阈值；其他 parser crash 在 CLI worker process 中隔离。
- parallelism：确定性成立，性能收益依项目而异，内存通常增加。
- portability：host path、shell gate、`.exe` 和无本机 runner fallback 已做静态/本机回归；完整 release/installation gate 仍只在当前 Linux x86_64 target 实际运行。Windows 的标准 Python 不提供 `resource`，该平台明确跳过 peak RSS 阈值而不伪造测量。

## 9. API 缺口

| 缺失能力 | 为什么需要 | 当前 workaround | 建议最小新增 API |
|---|---|---|---|
| daily 未交付 `stdx.chir` | 普通 cjpm package 无法加载 serialized CHIR | Gate C，AST provider | 在 compiler-compatible stdx sidecar 交付已有 package/artifacts |
| `Function.location` | overload、nested、multiline source binding | 不做 CHIR enrichment | 暴露只读 `location: DebugLocation` |
| extension method owner | 稳定 extension member owner | AST range owner | 让 `declaredParent` 指向 ExtendDef，或提供只读 declaredExtend |
| source exact byte range | 直接切出 source spelling | 由 line/UTF-8 byte column 和 lexer token 重算 | 为 AST node 暴露只读 source byte range |
| generated-node origin | macro-generated declaration 与 source doc 对应 | source macro warning，不声明 resolved | 暴露只读 origin kind/location |
| `parseProgram` 深 BinaryExpr native crash | unsupported source 不应终止生成器 | lexer guard + CLI subprocess isolation + `CJDOC1012`/`CJDOC1020` | 返回结构化 parse error，并使 parser traversal 栈安全 |

没有提出扩大完整 compiler API surface 的要求。每项建议只覆盖 cjdoc 无法自行可靠证明的最小信息。

## 10. 下一阶段

- P0：在公开 CHIR artifact、Function location 和 extension owner 全部可用后，重新运行 G1 到 G7，再实现独立 `ChirSemanticProvider` package。
- P1：在 Windows/macOS daily 上运行 build、install、worker process、path、HTML 和 cache release matrix。
- P2：如果 compiler 后续提供稳定的只读 target cfg API，增加显式 opt-in 的 compiler profile adapter；现阶段继续要求用户提供可复现的 cfg 值。

## 11. 复现命令

准备当前 daily 后运行：

```bash
/home/elliot/.codex/scripts/codex_cangjie_env --cwd . cjpm build
/home/elliot/.codex/scripts/codex_cangjie_env --cwd . cjpm test
/home/elliot/.codex/scripts/codex_cangjie_env \
  --cwd packages/cjdoc_core cjpm test
scripts/check.sh
```

生成三种输出：

```bash
cjpm run -- --project . --format json --output target/doc/docs.json
cjpm run -- --project . --format markdown --output target/doc/docs.md
cjpm run -- --project . --format html --output target/doc/html --jobs 4
```

生成显式 cfg matrix：

```bash
cjpm run -- --project tests/fixtures/projects/conditional --format json \
  --cfg-matrix-profile linux:os=Linux,arch=x86_64 \
  --cfg-matrix-profile windows:os=Windows,arch=x86_64 \
  --output target/doc/docs.matrix.json
```

验证串并行确定性：

```bash
./cjdoc --project /home/elliot/playground/markdown \
  --format json --jobs 1 --output /tmp/markdown-jobs1.json
./cjdoc --project /home/elliot/playground/markdown \
  --format json --jobs 4 --output /tmp/markdown-jobs4.json
cmp /tmp/markdown-jobs1.json /tmp/markdown-jobs4.json
```

完整验收成功时最后输出：

```text
cjdoc acceptance checks passed
```
