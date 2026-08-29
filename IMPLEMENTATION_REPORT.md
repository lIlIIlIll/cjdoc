# cjdoc implementation report

报告日期：2026-08-30。当前版本：`0.5.0`。Doc IR schema：`cjdoc.doc-ir/6`。

本报告只陈述当前工作区和本次实际运行得到的结果。当前架构选择 Gate C：`std.ast` 是源码语法真值，公开且 provider-neutral 的 `SemanticProvider` 是后续语义扩展点。当前产品不构建、不导入、也不解析 CHIR。

## 1. 实际环境

| 项目 | 实测值 |
|---|---|
| cjc | `1.1.0-alpha.20260829040003 (cjnative)` |
| target | `x86_64-unknown-linux-gnu` |
| cjpm | `1.1.3` |
| SDK root | `/home/elliot/cangjie_sdk/daily/cangjie` |
| `std.ast` | 当前 SDK 自带；compile/run probe 验证 lexer、token、parser、visitor 和 declaration position API |
| `stdx.chir` | 当前 daily dynamic/static stdx 均无可供普通 cjpm 项目导入的构建产物 |
| Markdown | `markdown` commit `3202a82a354a005f5c1e4baa0c9bb800d00c2187` |
| JSON | `yjson` commit `bf65cbecd99ac25e7485f8db60990e94a04e57bc` |

没有修改或构建 compiler、std、stdx。API probe 和逐项证据位于：

- [`docs/research/api-capability-matrix.md`](docs/research/api-capability-matrix.md)
- [`docs/research/std-ast-findings.md`](docs/research/std-ast-findings.md)
- [`docs/research/stdx-chir-findings.md`](docs/research/stdx-chir-findings.md)

## 2. CHIR 结论

**FAIL。CHIR 不能作为当前版本的 authoritative semantic source；Architecture Gate 选择 Gate C。**

| 能力 | 结果 | 证据边界 |
|---|---|---|
| `cjc` 生成 serialized CHIR | PASS | `--emit-chir=raw` 和 `chir-dis` probe 通过 |
| 普通 daily 项目加载 `stdx.chir` | FAIL | import 报 `can not find package 'stdx.chir'` |
| declaration、type 和 owner API | PARTIAL | 只在另一套同版本 local sidecar 验证了部分 API 形态 |
| Function source/debug location | FAIL | 公开 `Function` API 没有足够的只读 location |
| extension method owner | PARTIAL | local probe 中 extension method 的 `declaredParent` 为空 |
| Source 与 CHIR function binding | FAIL | 缺少稳定位置，无法可靠回绑 overload、Unicode 和 multiline declaration |

当前实现不解析 `.chirtxt`，不复制 compiler 内部反序列化器，也不把 source spelling 伪装成 canonical type。未来只有 G1 到 G7 全部重新实测为 PASS，才接入独立 `ChirSemanticProvider`。

## 3. Source 与 semantic binding

### Binding strategy

```text
lexer RawDocComment
        |
        v
std.ast SourceDeclaration
        |
        +---- comment binding
        |
        v
SourceDeclarationView ----> SemanticProviderSession.analyze(...)
        |                              |
        |                              v
        +--------------------- SemanticBatch
                                       |
                                       v
                              DocumentationBinder
```

文档注释先绑定 source declaration。provider 收到 cjdoc 定义的只读 source view，返回 provider-neutral DTO。`std.ast` 和未来 CHIR 类型不会进入 Doc IR 或 renderer。

source key 使用逻辑文件路径、declaration kind、name、起始行列和 owner。signature 用于重载消歧。位置只用于 binding、诊断和 source link，不参与稳定 SymbolId。

### Ambiguity handling

- 零匹配：保留 AST fallback，semantic state 为 `partial` 或 `unavailable`。
- 多匹配：输出稳定 diagnostic，不选择任意候选。
- provider 返回未知 source ID、未知 owner、非法 diagnostic 或异常：输出 `CJDOC2xxx`，保留 AST fallback。
- resolved local relationship 使用 provider 返回的 `targetSourceId` 回绑稳定 `targetSymbolId`。
- provider name、version 和 capabilities 写入 Doc IR。provider relationship 在输出前稳定排序。
- 每次 generation 最多注册一个 provider factory。每个 module session 都执行 `open → analyze → close`。

### 已验证 fixture

fixture 覆盖 function overload、class、struct、interface、enum、extend、generic type/function、nested declaration、annotation、visibility、Unicode identifier、中文注释、multiline signature、workspace、path dependency、conditional source 和 unsupported declaration。public contract test 还覆盖 provider lifecycle、版本透传、未知 source ID、type relationship 和 symbol relationship。

### Remaining risks

- macro-generated declaration 没有 compiler origin；
- AST fallback 无法给出 canonical alias/type identity、override target 和 compiler owner；
- 未来 CHIR adapter 必须重新验证 function location、extension owner、版本兼容和 source mapping。

## 4. 最终架构

```text
Cangjie project/workspace
        |
        v
project discovery + bounded source scanning
        |
        v
std.ast lexer/parser/traversal
        |
        +--> RawDocComment collector
        +--> SourceDeclaration collector
        +--> CommentBinder
        |
        v
SourceSnapshot
        |
        +--> AstSemanticFallbackProvider
        +--> SemanticProvider SPI --> future ChirSemanticProvider
        |
        v
DocumentationBinder + reference resolver + lint
        |
        v
Doc IR v6
   |             |                       |
   v             v                       v
docs.json   Markdown renderer   multi-page HTML + search-index.json
```

依赖边界如下：

- `std.ast` 只存在于 source frontend；
- provider API 只暴露 cjdoc DTO；
- renderer 只 import `cjdoc.model`；
- `render` 只读取严格校验后的 Doc IR；
- output writer 使用 ownership manifest、路径检查、symlink 检查和原子替换。

## 5. 已实现功能

### Complete

- Phase 0：`std.ast`、`stdx.chir`、`cjc` CHIR flow 和 Source 与 CHIR binding probe；capability matrix；Gate C 决策。
- Phase 1：project/workspace discovery、path/cached dependency source、bounded source scan、lexer/parser/traversal、declaration/comment collection 和 binding。
- Provider SPI：公开 factory/session、source views、semantic DTO、capabilities、relationship、lifecycle、contract validation 和异常 fallback。
- Doc IR v6：source、semantic state、provider metadata、type/symbol relationship、origin、unsupported declaration、diagnostic、稳定排序和稳定 SymbolId。
- Doc comment：GFM Markdown AST、summary、description 和全部首版 structured tags。
- Lint：unknown/duplicate/missing `@param`、duplicate `@return`、broken `@see`、duplicate SymbolId、ambiguous binding 和 unresolved semantic reference。
- CLI：`generate`、`check`、`render`、`schema`，exit code 0/1/2，stdout JSON 和 source cache 控制。
- JSON：strict decoder、64 MiB input limit、128 层 JSON depth、无绝对本机路径、9 组 v6 golden。
- Markdown：只消费 Doc IR。
- HTML：package/type/member 页面、breadcrumbs、owner/relationship links、浏览器搜索、kind/package filter、CSP、外部 JS/CSS 和安全 Markdown。
- Output hardening：拒绝未管理的非空目录、拒绝 path escape 和 symlink escape、只清理旧 manifest 记录的 artifact、content-equal no-op 和原子写入。
- Source hardening：isolated AST preflight、parse failure recovery、32 MiB 单文件上限、100,000 文件上限、128 层目录上限和并行 parse。
- Linux 本机 acceptance gate；三个真实仓库的 clean build、deterministic generation、HTML 全站校验和资源测量。

### Partial

- AST 类型、inheritance、generic constraint 和 extension target 只保留 source spelling，semantic state 为 `partial`。
- `@see` 使用当前 declaration index 和显式 signature，不实现 compiler overload resolution、alias expansion 或 implicit conversion。
- cfg 由调用者显式传入，不自动读取 compiler target profile。
- cached dependency discovery 只读取本机内容，不下载依赖。
- 大型仓库硬化已覆盖 2,753 symbols；尚未建立 100,000 文件规模的持续性能 gate。

### Not implemented

- `ChirSemanticProvider`、CHIR driver/loader 和 compiler canonical type/signature。
- semantic override relation、macro expansion origin 和 compiler-resolved annotation。
- 文档示例编译或执行。默认生成不会执行文档代码。
- 当前 commit 的 GitHub-hosted Linux、Windows 和 macOS 执行证据。

## 6. 关键文件

| 文件 | 职责 |
|---|---|
| `src/main.cj` | executable 入口和 isolated AST preflight 入口 |
| `src/new_cli.cj` | CLI、strict input、output ownership 和原子写入 |
| `src/public_api.cj` | `GenerationRequest`、`DocumentationEngine` 和 public/internal adapter |
| `src/provider/semantic_provider.cj` | provider SPI、source views、semantic DTO 和 capabilities |
| `src/source_frontend.cj` | discovery、cache、bounded scan、lexer/parser 和 source model |
| `src/documentation_binder.cj` | source/semantic binding、relationship target 和 SymbolId |
| `src/model/doc_ir.cj` | 公开 Doc IR v6 model |
| `src/comment_parser.cj` | Markdown AST 和 structured tag parser |
| `src/reference_resolver.cj` | declaration index 和 `@see` resolution |
| `src/lint.cj` | lint diagnostics |
| `src/render/json_encode.cj` | deterministic Doc IR encoder |
| `src/render/json_decode.cj` | strict Doc IR decoder |
| `src/render/renderers.cj` | Markdown、多页 HTML 和 search renderer |
| `src/schema.cj` | binary 内嵌 authoritative schemas |
| `tests/fixtures/golden-v6/` | 9 组 v6 golden |
| `tests/fixtures/projects/provider_plugin/` | 外部 provider contract fixture |
| `scripts/check.sh` | 完整 acceptance gate |
| `scripts/validate_html_site.py` | HTML、link、anchor、search 和安全检查 |
| `scripts/measure_command.py` | wall time 和 best-effort peak RSS 测量 |
| `.github/workflows/ci.yml` | Linux x64、Windows x64、macOS ARM64 runner 配置 |

## 7. 测试结果

### Build、unit、golden 和 integration

| Gate | 结果 |
|---|---|
| `cjpm build` | PASS |
| `cjpm test` | PASS，11/11 |
| 9 组 v6 golden | PASS，两次 byte-identical，strict decoder round-trip byte-identical |
| JSON、Markdown、HTML、search | PASS，两次生成一致 |
| 4 份 binary/schema 文件同步 | PASS，byte-identical |
| HTML fixture | PASS，6 pages、20 search entries |
| HTML security fixture | PASS，2 pages、1 search entry |
| source 32 MiB limit fixture | PASS，输出 `CJDOC1026`，generator 未崩溃 |
| stale output 和 symlink escape | PASS |
| external provider fixture | PASS，输出 `provider plugin ok` |
| `scripts/check.sh` | PASS，输出 `cjdoc acceptance gate passed` |

仓颉构建会显示锁定 `yjson` 依赖的 macro-expansion unused warnings。warnings 不影响 build/test 结果。

### 真实仓库

原仓库保持只读。测试把工作区复制到 `/tmp/cjdoc-real-v05.QYdspa/build`，排除 `.git`、`target` 和 `.cjpm`，再执行 clean build。每个仓库生成一次 JSON 和 HTML，再生成第二份 JSON。`cmp` 验证两份 `docs.json`，全站 validator 检查每个 HTML link、anchor 和 search target。

| repository | clean build | files | symbols | documented | unavailable types | ambiguous | warnings/errors | HTML pages/search | elapsed | peak RSS |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| llm4cj | PASS | 11 | 1,094 | 0 | 0 | 0 | 0/0 | 100/616 | 3,754 ms | 237,364 KiB |
| markdown | PASS | 39 | 2,614 | 53 | 0 | 0 | 0/0 | 232/1,400 | 18,693 ms | 343,572 KiB |
| yjson | PASS | 43 | 2,753 | 10 | 1 | 0 | 0/0 | 82/835 | 10,554 ms | 254,316 KiB |

这些数值是单次 smoke measurement，不是 benchmark。`measure_command.py` 使用 monotonic wall clock；Linux peak RSS 来自 `resource.getrusage(RUSAGE_CHILDREN)`。

### CI evidence boundary

`.github/workflows/ci.yml` 已配置 Linux x64、Windows x64 和 macOS ARM64。workflow 使用 checksum-pinned Cangjie 1.1.3 SDK，并且验收不再安装第三方 Python 包。当前工作区 commit 尚未 push，因此三组 hosted runner 对当前实现均为 **NOT RUN**。

## 8. 当前限制

- macro-generated declarations：不展开，只记录 unsupported source/origin。
- conditional compilation：支持显式 `--cfg`，不能自动取得 compiler target profile。
- extend：target 是 source spelling；semantic owner 和 specialization 不可用。
- generic specialization：不实例化，只记录 declaration 和 generic spelling。
- overload：SymbolId 按参数 type identity 区分；AST fallback 不能判断 alias canonical equivalence。
- source location：AST 行列和 UTF-8 byte offset 可用；CHIR Function location 不可用。
- dependency packages：支持 path、显式 source 和可发现 cache；不下载缺失依赖。
- annotations：保存 source spelling，不执行，也不解析 compiler semantic identity。
- Markdown AST：保存 kind、literal 和 children；node range 尚未映射为项目级 source range。
- portability：当前 commit 只在 Linux x64 daily 本机实际运行。Windows 和 macOS 只有 workflow 配置。

## 9. API 缺口

| 缺失能力 | 为什么需要 | 当前 workaround | 建议最小新增 API |
|---|---|---|---|
| daily 未交付 `stdx.chir` artifact | 普通 cjpm package 无法加载 serialized CHIR | Gate C、AST fallback | 交付与 compiler 版本匹配的公开 package/cjo/library |
| `Function` 只读 source location | overload、multiline 和 Unicode function 回绑 | 不做 CHIR enrichment | 暴露稳定 `location: DebugLocation` 或等价只读字段 |
| extension method declared owner | 稳定 extension member owner/qualified name | AST range owner | `declaredParent` 指向 `ExtendDef`，或暴露 declared extend |
| semantic override target | 正确链接 override | 显式 unavailable | 暴露只读 target declaration identity |
| generated declaration origin | 连接 macro invocation 和 generated symbol | 记录 unsupported/macro source | 暴露 origin kind、invocation identity 和 location |
| AST exact byte range | 免去 line/column/token 换算 | cjdoc 按 UTF-8 source/token 计算 | declaration 暴露 UTF-8 byte start/end |

建议 API 只覆盖 cjdoc 无法可靠自行证明的信息，不要求公开 compiler internal model。

## 10. 下一阶段

- P0：运行并记录当前 commit 的 Linux、Windows 和 macOS hosted CI；增加 provider conformance kit 和跨 SDK matrix。
- P1：建立大型 workspace 的时间与内存回归 gate；继续增加 malformed source、深目录和 future syntax 的 fail-soft fixture。
- P1：增加 package/type 文档、source link 配置和 search ranking，但保持 renderer 只读 Doc IR。
- P2：只有 G1 到 G7 全部重新实测 PASS 后，实现独立 `ChirSemanticProvider`。enrichment 失败仍回退 AST。

## 11. 复现命令

准备 daily SDK 后，运行完整验收：

```bash
cjpm build
cjpm test
scripts/check.sh
```

成功时，最后一行是：

```text
cjdoc acceptance gate passed
```

生成全部 renderer artifact：

```bash
cjpm run -- generate \
  --project tests/fixtures/projects/basic \
  --format json \
  --format markdown \
  --format html \
  --output target/example-doc
```

严格读取 Doc IR 并重新渲染：

```bash
cjpm run -- render \
  --input target/example-doc/docs.json \
  --format markdown \
  --format html \
  --output target/rendered-doc
```

更新并检查 golden：

```bash
bash scripts/update_goldens.sh
scripts/check.sh
```

检查 schema 同步：

```bash
cjpm run -- schema doc-ir > /tmp/doc-ir.schema.json
cmp /tmp/doc-ir.schema.json docs/schema/doc-ir.schema.json
```
