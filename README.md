# cjdoc

`cjdoc` 是使用仓颉编写的仓颉 API 文档生成器。当前版本从仓颉源码生成确定性的 `cjdoc.doc-ir/8` JSON，也可以从同一份 Doc IR 生成 Markdown、多页静态 HTML、搜索索引、API surface snapshot 和文档覆盖率报告。严格有效的 v6/v7 输入可只读迁移到 v8；生成器只写 v8。

当前版本使用 `std.ast` 和 lexer 读取源码。CHIR 暂不接入，语义信息明确标为 `partial` 或 `unavailable`，不会把字符串推断伪装成已解析类型。

## 快速开始

### 前置条件

- 已准备仓颉 SDK 环境，`cjc` 和 `cjpm` 位于 `PATH`。
- SDK 包含可由普通 cjpm 项目导入的 `std.ast`。
- 首次构建可以访问 `cjpm.lock` 固定的 `markdown` 与 `yjson` Git 依赖，或本机已有对应 cjpm cache。
- 仓库验收脚本和下方 JSON 检查示例需要 Git、Bash 与 Python 3 标准库；运行 `cjdoc` 本身不需要这些工具。

### 1. 构建 cjdoc

在仓库根目录构建 executable：

```bash
cjpm build
```

成功时最后一行包含：

```text
cjpm build success
```

### 2. 生成 Doc IR

为一个含有 `cjpm.toml` 和 `src/*.cj` 的项目生成 JSON：

```bash
cjpm run -- generate --project tests/fixtures/projects/basic --format json
```

命令创建 `tests/fixtures/projects/basic/target/doc/docs.json`。验证 schema 与声明数量：

```bash
python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); print({"schemaVersion": d["schemaVersion"], "declarations": len(d["declarations"])})' \
  tests/fixtures/projects/basic/target/doc/docs.json
```

当前 fixture 的结果是：

```json
{
  "schemaVersion": "cjdoc.doc-ir/8",
  "declarations": 25
}
```

如果你只需要标准输出，运行：

```bash
cjpm run -- generate --project tests/fixtures/projects/basic --format json --stdout
```

诊断写入 stderr，因此 stdout 保持为单个 JSON document。

### 3. 生成 Markdown 和 HTML

一次生成全部格式：

```bash
cjpm run -- generate \
  --project tests/fixtures/projects/basic \
  --format json \
  --format markdown \
  --format html \
  --output target/example-doc
```

输出包括：

```text
target/example-doc/docs.json
target/example-doc/markdown/index.md
target/example-doc/markdown/packages/*.md
target/example-doc/markdown/symbols/*.md
target/example-doc/html/index.html
target/example-doc/html/packages/*.html
target/example-doc/html/symbols/*.html
target/example-doc/html/search-index.json
target/example-doc/html/search-index.js
target/example-doc/html/search.js
target/example-doc/html/style.css
target/example-doc/html/assets/*
```

HTML 和 Markdown renderer 只消费已清理的 Doc IR `MarkdownNode`，不会重新解释 `rawText`。默认输出是中文结构标题和 package/type/member 多页站点；用 `--locale en` 生成英文站点，用 `--locale en --markdown-layout single` 生成旧式单页 `markdown/docs.md`。站点包含 public import 重导出、交叉链接，以及带 kind/package filter 的浏览器端搜索；`search-index.js` 使搜索在 `file://` 下也可用。POSIX 上，安全的相对本地图片通过逐段 `openat` + `O_NOFOLLOW` 打开，验证普通文件、大小、media type 与 magic bytes 后才会内容寻址并复制到 `assets/`。当前 Windows SDK 没有可表达同等 no-follow/openat 语义的公开能力，因此 Windows **不支持本地 asset embedding**：生成器 fail closed，省略该 asset，发出 `CJDOC4026`，并把文档状态标为 `partial`。缺失、越界、symlink 或签名不匹配的图片同样只产生明确诊断。生成器不会执行文档中的代码或直接插入 raw HTML。

## CLI reference

```text
cjdoc generate [options]
cjdoc check [options]
cjdoc render --input <docs.json> [options]
cjdoc schema list|doc-ir|doc-ir-v6|doc-ir-v7|doc-ir-v8|diagnostics|cfg-matrix|search-index|api-surface|documentation-coverage
```

构建后可直接运行 `target/release/bin/main`。仓库根目录的 `./cjdoc` launcher 会在缺少 binary 时先执行 `cjpm build`。

### `generate`

常用选项：

| option | value | default | purpose |
|---|---|---|---|
| `--project` | directory | `.` | 包含 `cjpm.toml` 的项目或 workspace |
| `--format` | `json`, `markdown`, `html`, `api-surface`, `coverage` | `json` | 可重复指定 |
| `--output` | directory | `<project>/target/doc` | cjdoc 拥有的输出目录 |
| `--stdout` | flag | off | 只输出单个 JSON artifact |
| `--audience` | `external`, `package`, `all` | `external` | 控制 Markdown、HTML 和 search 可见性 |
| `--lint-profile` | `off`, `standard`, `strict` | `standard` | 文档 lint 强度 |
| `--jobs` | `1..64` | `1` | source frontend worker 数 |
| `--cache-dir` | directory | `<project>/target/cjdoc/cache/source-v8` | 增量 source cache |
| `--no-cache` | flag | off | 禁用增量 source cache |
| `--cfg` | `NAME=VALUE` | none | 可重复的条件编译输入 |
| `--include-path-dependencies` | flag | off | 扫描 manifest 中的 path dependency |
| `--include-cached-dependencies` | flag | off | 扫描可发现的 cjpm cache dependency source |
| `--locale` | `zh-CN`, `en` | `zh-CN` | HTML 和多页 Markdown 的结构语言 |
| `--markdown-layout` | `site`, `single` | `site` | Markdown 多页站点或兼容单页；`single` 需要 `--locale en` |
| `--api-surface-baseline` | JSON file | none | 与 canonical API surface 做 byte-exact 对账，不一致时返回非零 |
| `--min-symbol-coverage` | `0..100` | unset | 显式设置声明文档覆盖率门槛 |
| `--min-parameter-coverage` | `0..100` | unset | 显式设置参数文档覆盖率门槛 |

### 固定和检查公开 API

先生成 canonical snapshot。它记录源码 token signature、稳定 SymbolId 和 public import 暴露关系：

```bash
cjdoc generate --project . --format api-surface --stdout > api/public-api.json
```

在 CI 中对账 snapshot，并按需要启用文档覆盖率门槛：

```bash
cjdoc check --project . \
  --api-surface-baseline api/public-api.json \
  --min-symbol-coverage 80 \
  --min-parameter-coverage 90
```

成功时命令返回 `0`。snapshot 不一致或任一显式门槛未达到时返回非零；未设置门槛时，coverage 不会导致命令失败。单独运行 `--format coverage --stdout` 可读取 `cjdoc.documentation-coverage/1` JSON。
| `--cjpm-cache` | directory | SDK/cjpm 默认位置 | 指定只读 cjpm cache root |
| `--dependency-source` | `NAME=PATH` | none | 显式提供只读 dependency source |
| `--force-owned` | flag | off | 覆盖 manifest 已声明但摘要已改变的 artifact，并显式采用 artifact 所需的既有目录 |

`--stdout` 只能与单个 JSON format 一起使用。`check` 和 generate `--stdout` 虽不写 artifact，仍会在使用 source cache 前按未来默认 output 校验 cache 与事务命名空间不重叠。目录输出在父目录的进程生命周期独占锁下使用唯一 staging/backup 和可恢复 journal。最终 manifest 原子安装并验证成功是 commit point：在此之前的失败会尝试恢复 precommit 输出；到达 commit point 后，新输出已经生效，后续完整性检查或 journal retirement 失败只会报告失败并保留 journal，下一次 writer 会先验证并完成 retirement。进程中断后，下一次 writer 只在最终 owned 文件集合与摘要完整匹配时确认新输出，否则根据 backup 与文件搬移 provenance 回滚；无法证明归属时 fail closed。该协议不承诺目录 reader 的单快照原子性或 `fsync` 级断电持久性。

`.cjdoc-output.json` v3 为每个 owned artifact 保存 SHA-256，并记录其 ancestor directory provenance。摘要不匹配或 artifact 需要复用未登记目录时默认视为所有权冲突，只有 `--force-owned` 可以覆盖或显式采用；采用后，空的 stale owned directory 仍会被清理，目录中的未拥有内容不会被递归删除。v2 manifest 继续可读，但嵌套目录 provenance 为 unknown：默认拒绝复用或清理，必须通过一次 `--force-owned` 显式迁移到 v3。manifest 缺失/损坏/版本未知、未拥有文件冲突、内部事务命名空间冲突和 symlink 均继续 fail closed。

输出 parent lock 的进程查询异常同样 fail closed：`std.process` 无法区分 PID 不存在与查询/分配失败，因此 cjdoc 不会按异常消息猜测 owner 已退出，也不会自动移动该 lock。错误会保留固定 lock 供人工核实；确认没有 writer 后才可手动移除。

持锁期间，cjdoc 还会通过已打开的 `owner.json` 句柄写入固定长度的 whitespace challenge，再从当前 lock 路径读回精确字节，以校验 lock 的物理身份。父目录被 rename/recreate 后，即使复制相同 owner 内容也不能重放该 lock。该协议用于协调合作进程并检测竞争替换，不是针对拥有输出父目录写权限的恶意进程的安全边界；这类进程本来就能改写或删除 output、journal 与 lock。

### `check`

运行 frontend、binding、reference resolution 与 lint，不生成 renderer artifact：

```bash
cjpm run -- check --project tests/fixtures/projects/basic --lint-profile strict --deny-warnings
```

exit code 为 `0` 表示没有被拒绝的诊断，`1` 表示 error 或被 `--deny-warnings` 提升的 warning，`2` 表示 CLI 或输入错误。

### `render`

严格读取已有 Doc IR，再生成所选格式：

```bash
cjpm run -- render \
  --input target/example-doc/docs.json \
  --format markdown \
  --format html \
  --output target/rendered-doc
```

decoder 先执行 draft 2020-12 JSON Schema，再执行跨字段领域不变量；它拒绝未知字段、重复 key、错误 schema version、悬空/跨 module SymbolId 和超过有限工作预算的输入。`render` 不读取项目源码。v6/v7 仅作为严格的只读输入迁移到 v8；其中 v6 只有在 package 到 module 一一可判定时才迁移，并会一致重写 owner、package、诊断和关系中的所有 SymbolId 引用。

### `schema`

输出当前 binary 内嵌的 authoritative schema：

```bash
cjpm run -- schema doc-ir > /tmp/doc-ir.schema.json
cmp /tmp/doc-ir.schema.json docs/schema/doc-ir.schema.json
```

仓库保存的 schema 必须与 binary 输出 byte-identical。

## 文档注释

只有 `/** ... */` 被视为 doc comment。普通 `/* ... */` 与 `// ...` 不绑定到声明。

正文使用 GFM profile 解析为 Doc IR 中的 `MarkdownNode` 树。第一段 paragraph 是 summary，其余正文是 description。结构化 parser 支持：

- `@param`
- `@return`
- `@throws`
- `@see`
- `@since`
- `@deprecated`
- `@author`
- `@version`

## 架构

```text
Cangjie source
      |
      v
std.ast + lexer  ---> SourceSnapshot + RawDocComment
      |                         |
      |                         v
      +---------------> Source declaration binding
                                |
                  SemanticProvider SPI
                     |          |
              AST fallback   future CHIR adapter
                     |          |
                     +----+-----+
                          v
                       Doc IR v8
                    /      |       \
               JSON     Markdown    HTML + search
```

依赖方向是单向的：renderer 只 import `cjdoc.model`，不读取 AST 或 provider 类型。公开 provider SPI 位于 `cjdoc.provider`，调用生命周期是 `open(module) → analyze(source declarations) → close()`。provider 异常或返回未知 source ID 时，生成器产生 `CJDOC2xxx`，并保留 AST fallback 的声明。

外部 provider 的可运行示例位于 [`tests/fixtures/projects/provider_plugin`](tests/fixtures/projects/provider_plugin)。

## Doc IR contract

[`docs/schema/doc-ir.schema.json`](docs/schema/doc-ir.schema.json) 是当前 v8 alias；[`docs/schema/doc-ir-v6.schema.json`](docs/schema/doc-ir-v6.schema.json) 与 [`docs/schema/doc-ir-v7.schema.json`](docs/schema/doc-ir-v7.schema.json) 是冻结的兼容输入，当前输出由 [`docs/schema/doc-ir-v8.schema.json`](docs/schema/doc-ir-v8.schema.json) 定义。关键属性：

- 当前输出 schema version 固定为 `cjdoc.doc-ir/8`。
- 所有源码路径为 `/` 分隔的相对逻辑路径，不包含本机绝对路径。
- declarations、packages、files、diagnostics 与 renderer artifacts 使用稳定顺序。
- 每个 declaration 都带 lexer token 化的 `sourceApiSignature`；不可获得时显式标记为 `unavailable`。
- package 的 `reExports` 记录 public import 的目标、别名、解析状态和 canonical target SymbolId。搜索索引同时保留 canonical declaration 与消费者 package exposure。
- module identity 是 SymbolId 的组成部分；同名 package 可安全存在于不同 module。file-private 顶层声明额外使用逻辑文件作用域消歧，SymbolId 不使用源码行号。
- semantic state 只能是 `resolved`、`partial`、`unavailable` 或 `ambiguous`。
- type relationship 和 symbol relationship 是显式字段。resolved symbol relationship 必须带稳定 `targetSymbolId`。
- provider 的 name、version、module 和 capabilities 写入 Doc IR。每个 module 独立执行 `open → analyze → validate → close → commit`；任一步失败只丢弃该 module 的 batch，并回退 AST。
- annotation 保留 source/provider provenance；provider 的缺失字段不会删除 source facts。
- renderer 只接受同时满足 JSON Schema 与领域不变量的 Doc IR，并从 `MarkdownNode` 生成正文。
- unsupported source 和无法恢复的 parse 问题生成 partial Doc IR 与明确诊断。

AST fallback 不提供 canonical type，因此当前常见 semantic state 是 `partial`。接入 provider 后，只有 provider 明确返回 canonical information 的字段才能标记为 `resolved`。

## v0.6.0 compatibility

v0.6.0 是 pre-1.0 阶段的有意破坏性升级。Doc IR、公开 facade 和 provider SPI 都加入了 module-aware identity、结构化 annotation 与按 module 的 provider transaction；0.5.x 的 Cangjie 调用方需要重新编译并适配新类型与构造参数。

JSON 兼容边界更窄：严格满足 v6 schema 且 package 到 module 映射唯一的输入可以在内存中迁移到 v7，其他 v6 输入会被拒绝。cjdoc 不再生成 v6，v7 SymbolId 也不应与 v6 SymbolId 做字符串等值比较。

## v0.7.0 compatibility

v0.7.0 只生成 Doc IR v8。冻结的 v6/v7 document 仅作为严格的只读输入迁移到 v8；cjdoc 不会覆盖或重新生成 v6/v7 golden。调用方若持久化 Doc IR，应按 `schemaVersion` 分派，并把迁移后的 v8 document 视为新的输出身份。

本版本补充 public import re-export/package API surface、基于源码 token stream 的 canonical API snapshot、声明/参数文档覆盖率门槛，以及默认中文的 package/type/member 多页 Markdown/HTML 输出。新的 `api-surface` 与 `coverage` artifact 都有独立、可查询的 published schema；解析不完整或冲突的 re-export 保持显式 `partial`/`ambiguous`/`unavailable`，不会伪装成已解析 API。

GitHub release 同时发布 Linux x64、macOS arm64 和 Windows x64 的校验过 archive，以及可直接下载的单 executable 和对应 `.sha256` 文件。Windows executable 使用 `.exe` 后缀。

## 验证修改

运行完整本地验收：

```bash
scripts/check.sh
```

它执行 exact repository-input preflight、build、Cangjie tests、Python tooling/fixture-contract tests、9 个 v8 golden、全部 18 个冻结 v6/v7 golden 的严格只读迁移、schema 同步、两次生成 byte comparison、strict codec round-trip、HTML 全站校验、安全/资源限制、输出事务与 provider fixture。preflight 不依赖 `git status` 的可见性：它拒绝 `assume-unchanged`/`skip-worktree`、index mode/blob 漂移、tracked bytes 漂移，以及构建输入中的 ignored/untracked 文件；所有 tooling JSON 输入也拒绝重复 key 与 `NaN`/`Infinity`。脚本要求仓颉工具链、Git、Bash 和 Python 标准库。

如果安装了 `just`，`just doctor` 会检查 Git、SDK 和 Python 标准库；`just check` 运行同一验收入口。

发布验收是更高层级的独立入口：

```bash
CJDOC_RELEASE_TAG=v0.7.0 scripts/release_check.sh
```

它在本地验收之上验证稳定 SemVer、tag/HEAD/commit/tree/exact-worktree identity、tracked schema/golden、commit-pinned Git 依赖、完整 vendor inventory/provenance、frozen hard-ceiling 性能预算，以及仓库自身两次 JSON+HTML 确定性生成。只有 ceiling 实际通过后才写入 `verdict: passed`；candidate calibration 不能进入 release receipt。证据先写入 canonical `target/` 下的同文件系统 staging directory；任何 `target` 路径分量是 symlink/特殊文件都会在删除或创建输出前 fail closed，所有门通过后才整体发布到 `target/release-evidence/`。[`docs/release-process.md`](docs/release-process.md) 说明 authenticated SDK archive cache、TAR/ZIP 预检、强制 stable 平台矩阵、仅在 checksum-pinned 仓库变量齐全时运行的可选 daily SDK 验收、package manifest 与 tag 发布边界。

## 当前限制

- CHIR 暂未接入，canonical types、compiler owner/override relation 和 compiler-resolved annotations 不可用。
- macro invocation 和无法求值的 cfg 会记录为 unsupported source，不展开生成声明。
- 条件编译需要显式 `--cfg`，不会读取 compiler target profile。
- extension target、generic constraints 与 inheritance 目前保留 source spelling。
- cache dependency discovery 不下载网络依赖。
- 浏览器搜索是预加载的静态前端筛选，不实现 compiler overload resolution。
- 单个 source 文件上限为 32 MiB；单次扫描上限为 100,000 个文件和 128 层目录。超限会生成诊断并保留 partial Doc IR。
- Markdown AST 的 node kind、literal 与 children 已保留；节点相对 doc-comment 的 source range 尚未映射到项目 source range。

真实环境与 API probe 结果见 [`docs/research/api-capability-matrix.md`](docs/research/api-capability-matrix.md)。[`IMPLEMENTATION_REPORT.md`](IMPLEMENTATION_REPORT.md) 是基线提交 `2e8c8ecc849ba77d5209f4546cdbb2129b7b17fb` 中归档的 v0.6.0 历史报告，不是当前 v0.7.0 的验收或发布证据；当前证据必须在目标提交上重新运行并按 [`docs/release-process.md`](docs/release-process.md) 分层记录。
