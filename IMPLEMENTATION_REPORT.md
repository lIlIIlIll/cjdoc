# cjdoc implementation report

报告日期：2026-08-30。当前版本：`0.4.0`。

本报告只陈述当前工作区和本次实际运行得到的结果。当前架构选择 Gate C：以 `std.ast` 作为源码语法真值，以公开、provider-neutral 的 `SemanticProvider` 作为未来语义扩展点；v0.4 不构建、不导入、也不解析 CHIR。

## 1. 实际环境

| 项目 | 实测值 |
|---|---|
| cjc | `1.1.0-alpha.20260829040003 (cjnative)` |
| target | `x86_64-unknown-linux-gnu` |
| cjpm | `1.1.3` |
| SDK executable | `/home/elliot/cangjie_sdk/main/linux_x64/vanilla/20260829/cangjie/bin/cjc` |
| `std.ast` artifact | `modules/linux_x86_64_cjnative/std/std.ast.cjo` |
| `std.ast` API | 实际编译/运行验证 `cangjieLex`、`Token.kind/value/pos`、`TokenKind.COMMENT`、`parseProgram`、`Program.traverse`、`Visitor`、declaration position API |
| `stdx.chir` artifact | 20260829 dynamic/static stdx sidecar 中均不存在 |
| Markdown | `markdown` commit `3202a82a354a005f5c1e4baa0c9bb800d00c2187` |
| JSON | `yjson` commit `bf65cbecd99ac25e7485f8db60990e94a04e57bc` |

没有修改或构建 compiler、std、stdx。API probe 与逐项证据位于：

- [`docs/research/api-capability-matrix.md`](docs/research/api-capability-matrix.md)
- [`docs/research/std-ast-findings.md`](docs/research/std-ast-findings.md)
- [`docs/research/stdx-chir-findings.md`](docs/research/stdx-chir-findings.md)

## 2. CHIR 结论

**FAIL，不能作为当前版本的 authoritative semantic source；Architecture Gate 选择 Gate C。**

| 能力 | 结果 | 原因 |
|---|---|---|
| `cjc` 生成 serialized CHIR | PASS | `--emit-chir=raw` 和 `chir-dis` 实际通过 |
| 普通 daily 项目加载 `stdx.chir` | FAIL | daily stdx 未交付 `stdx.chir.cjo`，import 报 `can not find package 'stdx.chir'` |
| 主要 declaration、type、owner API | PARTIAL | 仅在另一套同版本 local sidecar 上验证了部分 API 形态，不能证明 current daily 可用 |
| Function source/debug location | FAIL | 公开 `Function` API 没有足够的只读 location |
| extension method owner | PARTIAL | local probe 中 extension method 的 `declaredParent` 为空 |
| Source 与 CHIR function binding | FAIL | overload 可由 signature 区分，但没有稳定位置，无法可靠回绑源码 |

因此 v0.4：

- 不 import `stdx.chir`；
- 不解析 `.chirtxt`；
- 不复制 compiler 内部反序列化器；
- 不把 source spelling 猜成 canonical type；
- 仅保留独立 provider SPI，待未来 G1 到 G7 全部 PASS 后接入 CHIR adapter。

## 3. Source 与 semantic binding

### 当前 binding strategy

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

文档注释总是先绑定 source declaration，永远不直接绑定 semantic declaration。provider 收到的是 cjdoc 自己定义的只读 source view，不是 `std.ast` 类型；返回的也是 provider-neutral DTO，不是 CHIR 类型。

source key 使用逻辑文件路径、declaration kind、name、起始行列和 owner；signature 仅用于重载消歧。位置只用于 binding、诊断和 source link，不参与稳定 SymbolId。

### Ambiguity handling

- 零匹配：保留 AST fallback，semantic state 为 `partial` 或 `unavailable`。
- 多匹配：输出稳定的 ambiguous diagnostic，不任意选择候选。
- provider 返回未知 source ID、未知 owner、非法 diagnostic 或抛异常：输出 `CJDOC2xxx` contract diagnostic，并继续生成 AST fallback Doc IR。
- 同一次 generation 最多注册一个 provider factory；session 无论成功或异常都会执行 `close()`。

### 已验证 fixture

覆盖 function overload、class、struct、interface、enum、extend、generic type/function、member、annotation spelling、visibility、Unicode identifier、中文注释、多行 signature、workspace、path dependency、conditional source 和 unsupported declaration。外部 provider fixture 验证了独立 cjpm 项目只依赖公开 SPI 即可注入 semantic enrichment。

### Remaining risks

- macro-generated declaration 没有 compiler origin；
- AST fallback 无法解析 canonical alias/type identity、override target 和 compiler owner；
- CHIR adapter 将来仍须重新验证 function location、extension owner、版本兼容和 source mapping，不能复用当前 FAIL 结论中的假设。

## 4. 最终架构

```text
Cangjie project/workspace
        |
        v
project discovery + source scanning
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
Doc IR v5
   |             |                 |
   v             v                 v
docs.json   Markdown renderer   HTML renderer + search-index.json
```

依赖边界：

- `std.ast` 只存在于 source frontend；
- provider API 只暴露 cjdoc DTO；
- renderer、codec、comment model 和 lint 不 import `std.ast` 或 `stdx.chir`；
- `render` 子命令只读取严格校验后的 Doc IR，不读取项目源码。

## 5. 已实现功能

### Complete

- Phase 0 reality check、可运行 probe、capability matrix 和 Gate C 决策。
- cjpm project/workspace discovery、递归仓颉源码扫描、path dependency 与显式/cached dependency source 入口。
- `std.ast` lexer/parser/traversal；没有使用正则解析仓颉 declaration。
- `/** ... */` collector、真实源码位置/byte offset、raw header spelling、comment-to-source binding。
- function、constructor、property/variable、type alias、class、struct、interface、enum、enum case、extend、generic、member、visibility 和 annotation spelling 的 source model。
- 公开 `SemanticProviderFactory`/`SemanticProviderSession`、lifecycle、capability/contract validation、异常 fallback 和外部插件 fixture。
- Doc IR v5：source、semantic state、origin、unsupported declaration、diagnostic、稳定排序和稳定 SymbolId。
- `resolved`、`partial`、`unavailable`、`ambiguous` 显式 semantic state；AST spelling 不会标记为 resolved。
- Markdown GFM AST 转换；summary、description，以及 `@param`、`@return`、`@throws`、`@see`、`@since`、`@deprecated`、`@author`、`@version`。
- 首版 lint：参数/返回值重复或缺失、无效 `@see`、duplicate SymbolId、ambiguous binding 和 unresolved semantic reference。
- `generate`、`check`、`render`、`schema` CLI，正确区分 exit code 0/1/2。
- deterministic、schema-versioned JSON；严格 decoder；无绝对本机路径；9 组 v5 golden。
- 从同一 Doc IR 生成 Markdown、HTML 和 `cjdoc.search-index/3`；HTML 转义用户 raw HTML，不执行文档代码。
- Linux 本机 acceptance gate 和三个真实仓库的 deterministic generation。

### Partial

- AST 类型、inheritance、generic constraint 和 extension target 是 source spelling，semantic state 保持 `partial`。
- `@see` 支持当前 declaration index 与显式 signature，但不实现完整 compiler overload resolution、alias 展开或隐式转换。
- cfg 由调用者显式传入；不自动读取 compiler target profile。
- cached dependency discovery 不下载网络内容。
- HTML 是安全的单页 MVP，有稳定 search index，但没有浏览器端搜索 UI、package/type 分页和完整交叉链接。
- Markdown AST 保存 kind/literal/children；节点内部 source range 尚未映射回项目级 source range。

### Not implemented

- `ChirSemanticProvider`、CHIR driver/loader 和 canonical compiler type/signature。
- semantic override relation、macro expansion origin 和 compiler-resolved annotation。
- 文档示例编译/执行；默认且当前实现都不会执行文档代码。
- Phase 6 的大型仓库性能基线、峰值内存 gate、错误恢复/资源上限全面加固。

## 6. 关键文件

| 文件 | 职责 |
|---|---|
| `src/main.cj` | executable 入口 |
| `src/new_cli.cj` | `generate/check/render/schema` 参数、exit code 与输出调度 |
| `src/public_api.cj` | `GenerationRequest`、`DocumentationEngine` 和公开 facade |
| `src/provider/semantic_provider.cj` | provider SPI、source views、semantic DTO 与 capabilities |
| `src/source_frontend.cj` | project discovery、source scanning、lexer/parser、declaration/comment collection |
| `src/documentation_binder.cj` | source/semantic binding、provider contract、SymbolId 与 Doc IR 组装 |
| `src/model/doc_ir.cj` | 公开 Doc IR v5 model |
| `src/comment_parser.cj` | Markdown AST 和结构化 tag parser |
| `src/reference_resolver.cj` | declaration index 与 `@see` resolution |
| `src/lint.cj` | 稳定 lint diagnostics |
| `src/render/json_encode.cj` | deterministic Doc IR encoder |
| `src/render/json_decode.cj` | strict Doc IR decoder |
| `src/render/renderers.cj` | Markdown、HTML 与 search renderer |
| `src/schema.cj` | binary 内嵌 authoritative schemas |
| `docs/schema/*.schema.json` | Doc IR、diagnostic、cfg matrix、search index schemas |
| `tests/fixtures/golden-v5/` | 9 组 v5 golden |
| `tests/fixtures/projects/provider_plugin/` | 外部 provider contract fixture |
| `scripts/check.sh` | 完整 acceptance gate |
| `scripts/validate_html_site.py` | HTML link、anchor 和安全检查 |
| `.github/workflows/ci.yml` | Linux x64、Windows x64、macOS ARM64 runner 配置 |
| `AGENTS.md` | 仓库边界、验证入口和 agent 工作约定 |

## 7. 测试结果

### Build、unit 和 public contract

| Gate | 当前结果 |
|---|---|
| `cjpm build` | PASS |
| `cjpm test` | PASS，11/11 |
| public Doc IR/codec/provider contract | PASS |
| external provider fixture | PASS，输出 `provider plugin ok` |
| README `cjpm run -- generate ... --stdout` | PASS |

构建会显示锁定 `yjson` 依赖宏展开产生的 unused warnings；未影响 build/test 结果。

### Golden 和 integration

- 9 个 v5 golden 全部通过 Draft 2020-12 schema validation。
- basic、functions、types、extend、source edges、unsupported、workspace、conditional Linux、path dependencies 均两次 byte-identical。
- JSON、Markdown、HTML、search index 两次生成一致。
- strict `render` round-trip 后 JSON 字节一致，Markdown/HTML 目录一致。
- Doc IR、diagnostics、cfg matrix、search index 四份仓库 schema 与 binary 内嵌 schema 字节一致。
- HTML security fixture 通过 parser-based validator：禁止 script/iframe/object/embed、事件属性和危险 URL；转义后的示例文本保留。
- `check --deny-warnings` 和无效 CLI 的 exit code contract 通过。
- 完整入口最终输出 `cjdoc acceptance gate passed`。

### 真实仓库

三个原仓库只读；clean build 在 `/tmp/cjdoc-real-build` 隔离副本执行，生成输出在 `/tmp/cjdoc-real-smoke`。每个仓库的隔离 clean build 均通过，并分别生成两次、用 `cmp` 验证 `docs.json`。

| repository | clean build | source files | declarations | documented | unresolved types | ambiguous bindings | warnings/errors | first generation |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| llm4cj | PASS | 10 | 1068 | 0 | 0 | 0 | 0/0 | 2 s |
| markdown | PASS | 39 | 2614 | 53 | 0 | 0 | 0/0 | 13 s |
| yjson | PASS | 43 | 2753 | 10 | 1 | 0 | 0/0 | 7 s |

时间来自 zsh `SECONDS` 的单次墙钟测量，只用于冒烟记录，不是 benchmark。当前环境缺少 `/usr/bin/time`，因此 peak memory 为 **NOT COLLECTED**。

### CI evidence boundary

`.github/workflows/ci.yml` 已配置 Linux x64、Windows x64 和 macOS ARM64 runner，但本次工作区 SHA 尚未 push，因此这些 hosted runner 对当前实现是 **NOT RUN**。本报告不把 workflow 配置当作远端通过证据。

## 8. 当前限制

- macro-generated declarations：不展开；只能记录 unsupported source/origin。
- conditional compilation：支持显式 cfg 输入，不能自动取得 compiler 内建 target profile。
- extend：target 是 source spelling；semantic owner 和 specialization 不可用。
- generic specialization：不实例化，只记录 declaration/generic spelling。
- overload：SymbolId 能按参数 type identity 区分；AST fallback 不能判断 alias canonical equivalence。
- source location：AST 行列和 byte offset 可用；CHIR Function location 不可用。
- dependency packages：支持 path、显式 source 和可发现 cache；不下载缺失依赖。
- annotations：保存源码 spelling，不执行、不解析 compiler semantic identity。
- unsupported declaration：产生 partial Doc IR 或稳定 diagnostic，不使整个 generator crash；尚未覆盖所有 future language construct。
- HTML：单页、安全、确定性，但尚非完整浏览体验。
- portability：当前 SHA 只在 Linux x64 daily 本机实际运行；Windows/macOS 仅有 workflow 配置。

## 9. API 缺口

| 缺失能力 | 为什么需要 | 当前 workaround | 建议最小新增 API |
|---|---|---|---|
| daily 未交付 `stdx.chir` artifact | 普通 cjpm package 无法加载 serialized CHIR | Gate C、AST fallback | 交付与 compiler 版本匹配的公开 package/cjo/library |
| `Function` 只读 source location | overload、多行、Unicode function 回绑 | 不做 CHIR enrichment | 暴露稳定 `location: DebugLocation` 或等价只读字段 |
| extension method declared owner | 稳定 extension member owner/qualified name | AST range owner | `declaredParent` 指向 `ExtendDef`，或暴露只读 declared extend |
| semantic override target | 正确链接 override，而不是猜名字 | 显式 unavailable | 暴露只读 target declaration identity |
| generated declaration origin | macro source comment 与 generated symbol 对应 | 记录 unsupported/macro source | 暴露 origin kind、source invocation identity/location |
| AST exact byte range | 无需从 line/column/token 重算 spelling | cjdoc 按 UTF-8 source/token 计算 | declaration 暴露只读 UTF-8 byte start/end |

这些建议只覆盖 cjdoc 无法可靠自行证明的最小信息，不要求扩大为完整 compiler internal API。

## 10. 下一阶段

- P0：补充 parser failure/资源限制 fixture、真实大型 workspace 性能与 peak-memory 基线；继续扩大 unsupported construct 的 fail-soft 覆盖。
- P1：把 HTML 从单页升级为 package/type/member 页面和浏览器端搜索 UI，同时仍只消费 Doc IR。
- P1：增加 provider conformance kit 与跨 SDK contract matrix，供未来第三方 semantic provider 使用。
- P2：仅当 G1 到 G7 重新验证全部 PASS 后，实现独立 `ChirSemanticProvider`；任何 enrichment 失败仍必须回退 AST。
- P2：在当前提交 push 后运行 Linux/Windows/macOS GitHub-hosted acceptance，并记录 target SHA 证据。

## 11. 复现命令

准备 daily SDK 后：

```bash
cjpm build
cjpm test
python3 -m pip install -r requirements-ci.txt
scripts/check.sh
```

生成 Doc IR：

```bash
cjpm run -- generate \
  --project tests/fixtures/projects/basic \
  --format json
```

一次生成全部当前 renderer artifact：

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

检查 schema 同步：

```bash
cjpm run -- schema doc-ir > /tmp/doc-ir.schema.json
cmp /tmp/doc-ir.schema.json docs/schema/doc-ir.schema.json
```
