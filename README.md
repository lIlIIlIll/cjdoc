# cjdoc

`cjdoc` 是使用仓颉编写的仓颉 API 文档生成器。当前 MVP 从仓颉源码生成确定性的 `cjdoc.doc-ir/5` JSON，也可以从同一份 Doc IR 生成 Markdown、静态 HTML 和搜索索引。

当前版本使用 `std.ast` 和 lexer 读取源码。CHIR 暂不接入，语义信息明确标为 `partial` 或 `unavailable`，不会把字符串推断伪装成已解析类型。

## 快速开始

### 前置条件

- 已准备仓颉 SDK 环境，`cjc` 和 `cjpm` 位于 `PATH`。
- SDK 包含可由普通 cjpm 项目导入的 `std.ast`。
- 首次构建可以访问 `cjpm.lock` 固定的 `markdown` 与 `yjson` Git 依赖，或本机已有对应 cjpm cache。

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
jq '{schemaVersion, declarations: (.declarations | length)}' \
  tests/fixtures/projects/basic/target/doc/docs.json
```

当前 fixture 的结果是：

```json
{
  "schemaVersion": "cjdoc.doc-ir/5",
  "declarations": 25
}
```

如果你只需要标准输出，运行：

```bash
cjpm run -- generate --project tests/fixtures/projects/basic --format json --stdout | jq .
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
target/example-doc/markdown/docs.md
target/example-doc/html/index.html
target/example-doc/html/search-index.json
```

HTML 正文使用固定版本的 `markdown` 库进行安全渲染。生成器不会执行文档中的代码或直接插入 raw HTML。

## CLI reference

```text
cjdoc generate [options]
cjdoc check [options]
cjdoc render --input <docs.json> [options]
cjdoc schema list|doc-ir|diagnostics|cfg-matrix|search-index
```

构建后可直接运行 `target/release/bin/main`。仓库根目录的 `./cjdoc` launcher 会在缺少 binary 时先执行 `cjpm build`。

### `generate`

常用选项：

| option | value | default | purpose |
|---|---|---|---|
| `--project` | directory | `.` | 包含 `cjpm.toml` 的项目或 workspace |
| `--format` | `json`, `markdown`, `html` | `json` | 可重复指定 |
| `--output` | directory | `<project>/target/doc` | cjdoc 拥有的输出目录 |
| `--stdout` | flag | off | 只输出单个 JSON artifact |
| `--audience` | `external`, `package`, `all` | `external` | 控制 Markdown、HTML 和 search 可见性 |
| `--lint-profile` | `off`, `standard`, `strict` | `standard` | 文档 lint 强度 |
| `--jobs` | `1..64` | `1` | source frontend worker 数 |
| `--cfg` | `NAME=VALUE` | none | 可重复的条件编译输入 |
| `--include-path-dependencies` | flag | off | 扫描 manifest 中的 path dependency |
| `--include-cached-dependencies` | flag | off | 扫描可发现的 cjpm cache dependency source |
| `--dependency-source` | `NAME=PATH` | none | 显式提供只读 dependency source |

`--stdout` 只能与单个 JSON format 一起使用。`--output` 指向非空目录时，该目录必须已经包含 cjdoc 的 `.cjdoc-output.json` ownership manifest，否则命令会拒绝覆盖。

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

decoder 拒绝未知字段、重复 key、错误 schema version 和超过限制的嵌套结构。`render` 不读取项目源码。

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
                       Doc IR v5
                    /      |       \
               JSON     Markdown    HTML + search
```

依赖方向是单向的：renderer 只 import `cjdoc.model`，不读取 AST 或 provider 类型。公开 provider SPI 位于 `cjdoc.provider`，调用生命周期是 `open(module) → analyze(source declarations) → close()`。provider 异常或返回未知 source ID 时，生成器产生 `CJDOC2xxx`，并保留 AST fallback 的声明。

外部 provider 的可运行示例位于 [`tests/fixtures/projects/provider_plugin`](tests/fixtures/projects/provider_plugin)。

## Doc IR contract

[`docs/schema/doc-ir.schema.json`](docs/schema/doc-ir.schema.json) 定义完整 v5 contract。关键属性：

- schema version 固定为 `cjdoc.doc-ir/5`。
- 所有源码路径为 `/` 分隔的相对逻辑路径，不包含本机绝对路径。
- declarations、packages、files、diagnostics 与 renderer artifacts 使用稳定顺序。
- SymbolId 由 package、owner、kind、name、generic arity 与参数 type spelling/canonical type 构造，不使用源码行号。
- semantic state 只能是 `resolved`、`partial`、`unavailable` 或 `ambiguous`。
- unsupported source 和无法恢复的 parse 问题生成 partial Doc IR 与明确诊断。

AST fallback 不提供 canonical type，因此当前常见 semantic state 是 `partial`。接入 provider 后，只有 provider 明确返回 canonical information 的字段才能标记为 `resolved`。

## 验证修改

先安装 Python schema validator 依赖：

```bash
python3 -m pip install -r requirements-ci.txt
```

运行完整本地验收：

```bash
scripts/check.sh
```

它执行 build、11 个 unit/public-contract tests、9 个 v5 golden、schema validation、两次生成 byte comparison、strict codec round-trip、HTML security 和 provider fixture。

如果安装了 `just`，`just doctor` 会先检查 SDK、Python schema 包与 jq；`just check` 运行同一验收入口。

## 当前限制

- CHIR 暂未接入，canonical types、compiler owner/override relation 和 compiler-resolved annotations 不可用。
- macro invocation 会记录为 unsupported source，不展开生成声明。
- 条件编译需要显式 `--cfg`，不会读取 compiler target profile。
- extension target、generic constraints 与 inheritance 目前保留 source spelling。
- cache dependency discovery 不下载网络依赖。
- HTML 当前是单页 MVP，包含确定性 search index，但没有浏览器端搜索 UI 或按 package/type 拆页。
- Markdown AST 的 node kind、literal 与 children 已保留；节点相对 doc-comment 的 source range 尚未映射到项目 source range。

真实环境与 API probe 结果见 [`docs/research/api-capability-matrix.md`](docs/research/api-capability-matrix.md)，实现和测试证据见 [`IMPLEMENTATION_REPORT.md`](IMPLEMENTATION_REPORT.md)。
