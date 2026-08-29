# cjdoc

[![CI](https://github.com/lIlIIlIll/cjdoc/actions/workflows/ci.yml/badge.svg?branch=dev)](https://github.com/lIlIIlIll/cjdoc/actions/workflows/ci.yml)

`cjdoc` 是使用仓颉实现的仓颉 API 文档生成器。当前版本以 `std.ast` 作为源码真值，生成稳定的 Doc IR v4，并从同一份 Doc IR 输出 JSON、Markdown 或静态 HTML。

当前版本不依赖 `stdx.chir`。语义层通过 `SemanticProvider` 隔离，默认实现是保守的 `AstSemanticProvider`。类型 spelling 可以输出，但不会被伪装成已经解析的 canonical type。

## 构建并生成文档

在仓颉 SDK 环境中构建项目：

```bash
cjpm build
```

为当前项目生成 JSON：

```bash
cjpm run -- --project . --format json
```

成功后会生成 `target/doc/docs.json`。输出符合 [`cjdoc.doc-ir/4`](docs/schema/doc-ir.schema.json)，不包含本机绝对路径。

也可以使用仓库内的 launcher：

```bash
./cjdoc --project . --format json
```

## 输出格式

JSON 是稳定的中间表示，也是其他 renderer 的唯一输入：

```bash
cjpm run -- \
  --project tests/fixtures/projects/basic \
  --format json \
  --output target/example/docs.json \
  --lint-missing-params \
  --public-only
```

Markdown 默认写入 `target/doc/docs.md`：

```bash
cjpm run -- --project . --format markdown
```

HTML 默认写入 `target/doc/html/`：

```bash
cjpm run -- --project . --format html
```

HTML 站点包含项目首页、package 页面、类型页面、成员锚点、[`cjdoc.search-index/2`](docs/schema/search-index.schema.json)、浏览器端搜索、CSS 和受控的 `search.js`。搜索按精确名称、前缀和全文命中排序，可以按 kind 与 package 过滤，并支持方向键、Enter、Escape 和 Ctrl/Command+K。每页包含 CSP，搜索控件使用 combobox/listbox ARIA 语义。

注释正文通过固定版本的 [`markdown`](https://github.com/lIlIIlIll/markdown) 转换为安全 HTML。raw HTML 会被转义，危险 URL 不会生成链接。

重复生成时，内容未变化的 JSON、Markdown 和 HTML 文件不会被替换。HTML renderer 只清理由 `.cjdoc-files` 记录且已经过期的 cjdoc 文件，不删除输出目录中的用户文件。

## 文档注释

只有 `/** ... */` 被视为文档注释。普通 block comment 和 line comment 默认不会绑定到声明。

支持的结构化标签包括：

- `@param`
- `@return`
- `@throws`
- `@see`
- `@since`
- `@deprecated`
- `@author`
- `@version`

第一段 Markdown paragraph 是 summary，其余 Markdown 是 description。fenced code 中出现的 `@param` 等文本不会被误解析为标签。

`@see` 可以使用 SymbolId、qualified name、simple name，或显式签名：

```text
@see basic.parse(String)
@see basic.parse(Array<UInt8>)
```

显式签名只和 Doc IR 中已有的类型 spelling 精确比较。cjdoc 不实现隐式转换、alias 展开或完整 overload resolution。未解析和歧义引用保留为显式状态并产生 diagnostic。

## 项目、workspace 和依赖源码

`--project` 可以指向普通 cjpm package 或包含 `[workspace].members` 的 workspace。扫描只覆盖 manifest 声明的模块和各模块的 `src/**/*.cj`。

启用本地 path dependency 扫描：

```bash
cjpm run -- \
  --project . \
  --format json \
  --include-path-dependencies
```

cjdoc 递归读取 `[dependencies]` 中的 `{ path = "..." }`，按 canonical path 去重和阻断循环。依赖源码写成 `dependencies/<dependency>/src/...`，不会序列化 checkout 的绝对路径。

对于 registry 或 git dependency，可以显式提供已经存在的离线源码目录：

```bash
cjpm run -- \
  --project . \
  --format json \
  --dependency-source markdown=/opt/src/markdown
```

cjdoc 也可以按 `cjpm.lock` 从已有 cjpm cache 中离线发现 git 和 registry dependency。此行为必须显式启用，不会下载内容：

```bash
cjpm run -- \
  --project . \
  --format json \
  --include-cached-dependencies
```

默认 cache root 是 `$HOME/.cjpm`。使用 `--cjpm-cache <path>` 可以选择其他现有 cache。lock 中的 commit/version 必须精确对应 cache 目录，否则产生 `CJDOC1021` 并跳过该 dependency。发现一个 cache package 后，cjdoc 会继续读取该 package 已有的 `cjpm.lock`，递归建立直接 dependency 边并阻断循环。`--dependency-source` 的显式路径优先于任意层级的同名 cache entry。

cjdoc 不下载依赖。无法访问或不是仓颉源码 package 的依赖产生 warning，其他模块仍会继续生成。

## 条件声明

使用重复的 `--cfg <name>=<value>` 选择简单的 `@When` declaration：

```bash
cjpm run -- \
  --project . \
  --format json \
  --cfg os=Linux \
  --cfg arch=x86_64
```

evaluator 支持布尔键、`!`、`&&`、`||`、括号、`==` 和 `!=`。它使用三值逻辑：已知的 `false && unknown` 可以证明为 false，已知的 `true || unknown` 可以证明为 true。无法证明或格式错误的表达式会被省略并产生 `CJDOC1019`。未指定 cfg profile 且 alternatives 产生相同 SymbolId 时，整组声明会被省略并产生 `CJDOC1013`。

需要比较多个显式配置时，为每个 profile 指定名称和完整 cfg 值：

```bash
cjpm run -- \
  --project . \
  --format json \
  --cfg-matrix-profile linux:os=Linux,arch=x86_64 \
  --cfg-matrix-profile windows:os=Windows,arch=x86_64
```

成功后会生成 `target/doc/docs.matrix.json`。文件符合 [`cjdoc.cfg-matrix/1`](docs/schema/cfg-matrix.schema.json)，每个 profile 内嵌一份完整的 `cjdoc.doc-ir/4`。profile 和 cfg key 按名称排序，因此参数顺序不同不会改变输出。矩阵模式目前只支持 JSON，且不能和单 profile 的 `--cfg` 同时使用。

## 并行扫描

`--jobs` 控制文件级并行解析，范围是 1 到 64。默认值 `auto` 使用处理器数量并限制为最多 8 个 worker：

```bash
cjpm run -- --project . --format json --jobs 4
```

合并顺序始终按逻辑源码路径排序。验收测试要求 `--jobs 1` 与 `--jobs 4` 的 Doc IR 逐字节相同。并行模式可能使用更多内存，也不保证每个项目都更快。

## 缓存和 AST 隔离

CLI 默认把逐源文件 cache 写到 `<project>/target/cjdoc/cache/source-v2/`。cache key 包含 source 内容、逻辑路径、fallback package、cache schema、canonical SDK 路径和真实 `cjc --version`。载荷还会校验完整 key。损坏、碰撞、SDK 变化或 parser schema 变化都会回退到重新解析。

选择其他目录或禁用 cache：

```bash
cjpm run -- --project . --cache-dir /tmp/cjdoc-cache --format json
cjpm run -- --project . --no-cache --format json
```

CLI 对 cache miss 使用内部子进程预检 `parseProgram`。普通 parse error 保留为 `CJDOC1011`；worker 无法启动或异常终止产生 `CJDOC1020`，只跳过对应文件。cache hit 已绑定到相同 source、SDK 和 parser schema，不重复启动预检进程。直接使用 `cjdoc_core` 时，cache 与进程隔离都需要显式配置，默认不会写文件或启动 worker。

## Lint、配置和机器输出

启用 public API 文档覆盖检查和汇总：

```bash
cjpm run -- \
  --project . \
  --lint-missing-params \
  --lint-missing-symbols \
  --coverage \
  --deny-warnings
```

lint 还检查重复 `@throws`、无 value return 的 `@return`、危险 Markdown URL 和失效的 cjdoc symbol anchor。`--deny-warnings` 让任何 warning 导致非零退出码，但仍会生成可检查的输出。

使用 `--config <path>` 读取简单的 `key = value` 配置。支持的 key 与标量 CLI 选项同名，例如 `format`、`jobs`、`no-cache`、`public-only`、lint、coverage 和 dependency discovery。命令行参数在配置之后应用并覆盖标量值。

JSON 或 Markdown 可以写到 stdout。为避免 diagnostic 混入文档内容，stdout 模式要求把 diagnostic 写到单独文件：

```bash
cjpm run -- \
  --project . \
  --format json \
  --stdout \
  --diagnostic-format sarif \
  --diagnostic-output target/doc/cjdoc.sarif \
  > target/doc/docs.json
```

`--diagnostic-format` 支持 `text`、`json` 和 SARIF 2.1.0。

## 源码链接

为根项目配置源码链接：

```bash
cjpm run -- \
  --project . \
  --format html \
  --source-url-template 'https://github.com/example/project/blob/main/{path}#L{line}C{column}'
```

模板必须使用 `http://` 或 `https://` 并包含 `{path}`。还可以使用 `{line}` 和 `{column}`。

每个 dependency 需要独立且显式的仓库与 revision 配置：

```bash
cjpm run -- \
  --project . \
  --format html \
  --include-path-dependencies \
  --dependency-source-url 'markdown=https://github.com/example/markdown/blob/{revision}/{path}#L{line}' \
  --dependency-revision 'markdown=d73eecee4e19fe56a57cd9f150fe0a62bae405c4'
```

`--dependency-revision` 只在对应模板包含 `{revision}` 时有效。没有显式映射的 dependency 只显示逻辑路径，不生成猜测的外链。

## SemanticProvider 边界

当前数据流如下：

```text
Cangjie source
  -> AstSourceProvider
       -> RawDocComment
       -> SourceDeclaration
       -> SourceSnapshot
  -> SemanticProvider
       -> AstSemanticProvider
       -> SemanticResult
  -> DocumentationBinder
  -> DocumentationSet (Doc IR)
  -> JSON / Markdown / HTML
```

`SemanticProvider` 只接收 provider-neutral 的 `SourceSnapshot`，返回 provider-neutral 的 `SemanticResult`。`stdx.chir` 类型不能进入 binder、Doc IR、lint 或 renderer。

Provider 必须声明能力：source binding、owner、visibility、canonical types、canonical signatures 和 symbol relationships。Binder 会验证声明与实际数据是否一致。违反能力契约的数据会降级，并产生 `CJDOC1017`。

默认 AST provider 能稳定提供 declaration、owner、visibility、generic、annotation 和 type spelling。它不声明 canonical type/signature 能力，因此这些字段保持 `partial` 或 `unavailable`。

[`tests/fixtures/projects/provider_plugin`](tests/fixtures/projects/provider_plugin) 是独立 cjpm executable。它通过 `cjdoc_core` 的 public API 提供自定义 `SemanticProvider`，验证 provider 可以在不修改 cjdoc 源码的情况下接入。

## 当前限制

- `ChirSemanticProvider` 尚未实现。当前 daily 没有可导入的 `stdx.chir` 构建产物，公开 `Function` API 也没有足够的 source location。
- AST type spelling 不是 type-checker 结果。canonical type/signature 保持不可用。
- override 会记录为 `state: unavailable`，AST provider 不猜测目标声明。
- macro declaration 会写入 `unsupportedDeclarations`，不会执行宏或收集展开后的声明。
- 深层连续二元表达式仍会在 lexer 阶段用保守阈值跳过并产生 `CJDOC1012`。其他未知 parser native failure 由 CLI 子进程边界隔离。
- manifest adapter 只读取 cjdoc 需要的 cjpm 字段，不是通用 TOML parser。
- cache discovery 递归读取已有的 `cjpm.lock` 和 cache，不访问 registry、registry index 或 git 网络。
- cfg profile 必须显式提供。cjdoc 不读取或推断编译器内建 target profile。
- 本地完整 release gate 已在 Linux x86_64 daily SDK 上运行；GitHub-hosted Windows/macOS 结果以 CI matrix 为准，其他 target 尚未实测。

完整能力证据位于 [`docs/research`](docs/research)，实现结论见 [`IMPLEMENTATION_REPORT.md`](IMPLEMENTATION_REPORT.md)。

## 跨平台 CI

GitHub Actions 使用标准 GitHub-hosted runners 执行完整 acceptance gate：

- `ubuntu-22.04`：Linux x64；
- `windows-2025`：Windows x64；
- `macos-15`：macOS ARM64。

三项任务固定使用仓颉官网公开的 Cangjie 1.1.3 SDK，并在解压前验证官网公布的 SHA256。SDK 按平台和摘要缓存；更换 SDK 时必须同时更新 URL、SHA256 和 cache key。Linux runner 执行性能阈值，Windows/macOS runner 仍运行相同的确定性和性能负载，但只记录共享 runner 上的性能结果。

本地 daily SDK 仍用于 API reality check。CI 使用公开 STS SDK，因此不需要把内部 daily 下载凭据保存到 GitHub。

## 验证

运行核心单元测试：

```bash
cd packages/cjdoc_core
cjpm test
```

运行 build、unit、golden、schema、HTML、安全、provider、安装和性能验收：

```bash
scripts/check.sh
```

成功时最后输出：

```text
cjdoc acceptance checks passed
```

完整 gate 需要 `jq`、Python 3.12、`jsonschema` 和 `referencing`。它会验证 Doc IR、cfg matrix 和 search-index schema、传递 dependency 图、HTML links/anchors/CSP、安全渲染、JSON/Markdown/HTML golden、stdout、JSON/SARIF diagnostics、安装产物、冷/热 cache、峰值内存和真实 parser recovery。首次构建还需要取得 `cjpm.lock` 固定的 Markdown commit，已有 cjpm cache 时可以离线构建。

`scripts/check.sh` 在当前开发机优先使用 Codex 的仓颉环境 helper。其他主机只要已经把 `cjc`、`cjpm` 和 SDK runtime 放入环境，就会直接执行命令。设置 `CJDOC_DISABLE_CODEX_RUNNER=1` 可以强制使用调用者已准备的 SDK 环境；也可以用 `CJDOC_CANGJIE_RUNNER=/path/to/runner` 指定支持 `--cwd <dir> <command...>` 的 runner。Windows 没有 Python `resource` 模块，因此该主机上的 gate 会明确报告 peak RSS unsupported；Linux/macOS 仍执行峰值内存阈值。

## License

[MIT](LICENSE)
