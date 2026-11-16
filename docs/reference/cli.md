# CLI 参考

`cjdoc` 的命令、选项、取值范围与退出码。命令在项目根执行，除非显式给出输入路径。只有 `cjdoc --help`（或 `-h`）提供帮助，子命令不接受 `--help`：`cjdoc generate --help` 报 `unknown option '--help'` 并以 `2` 退出。`cjdoc --version` 输出 `cjdoc 0.7.8`，只表示产品版本。

需要按步骤完成的任务，见[生成与发布](../how-to/generate-and-publish.md)、[预览](../how-to/preview.md)、[比较与多版本](../how-to/compare-and-version.md)、[离线重放](../how-to/render-snapshots.md)、[查询与 MCP](../how-to/query-and-mcp.md)。

## 命令

| 命令 | 输入 | 行为 | 最小调用 |
|---|---|---|---|
| `generate` | 项目 | 读取项目并生成选定格式 | `cjdoc generate --project . --format html` |
| `check` | 项目 | 读取项目、检查诊断与门槛，不写出站点 | `cjdoc check --project .` |
| `serve` | 项目 | 生成预览站点并监听输入变化 | `cjdoc serve --project . --port 8080` |
| `render` | Doc IR 文件 | 只读 `cjdoc.doc-ir/18`，离线重新渲染 | `cjdoc render --input docs.json --format html --output replay` |
| `diff` | 两个 API 快照 | 比较两个 `cjdoc.api-surface/3` 快照 | `cjdoc diff old.json new.json --format json` |
| `versions compose` | 已生成的版本站点 | 组合版本站点并注入选择器 | `cjdoc versions compose --version v1=old/html --version v2=new/html --latest v2 --output versions` |
| `query` | 冻结快照 | 执行一个 JSON 查询请求 | `cjdoc query --snapshot docs.json --request request.json` |
| `mcp` | 冻结快照 | 提供 stdio MCP 服务 | `cjdoc mcp --snapshot site/agent/manifest.json` |
| `schema` | schema 名 | 输出 schema 文本，或列出名字 | `cjdoc schema list` |

输入参数里的 `docs.json`、`request.json`、版本目录都要先由前面的命令生成。产物路径与 wire 版本见[产物参考](artifacts.md)。

## 选项总表

「适用命令」按解析器实际校验结果列出；命令不在此列时给出该选项会以 `2` 退出。带 `…` 的选项可重复。

| 选项 | 取值 | 默认 | 适用命令 |
|---|---|---|---|
| `--project DIR` | 目录 | `.`；未写时视为 project 根 | generate、check、serve |
| `--format NAME` | `json`、`markdown`、`html`、`api-surface`、`coverage`、`symbol-index` | `json`；可重复、去重 | generate、render、serve；`diff` 只接受 `text`、`json` |
| `--output DIR` | 目录 | generate/serve 为 `<project>/target/doc`，render 为 `target/doc` | generate、render、serve；compose 必填 |
| `--stdout` | 标志 | 关闭 | generate、render |
| `--input FILE` | Doc IR JSON | 无 | render（必填） |
| `--force-owned` | 标志 | 关闭 | generate、render、compose |
| `--jobs N` | 整数 `1..64` | `1` | generate、check、serve |
| `--audience LEVEL` | `external`、`package`、`all` | `external` | generate、check、serve |
| `--lint-profile LEVEL` | `off`、`standard`、`strict` | `standard` | generate、check、serve |
| `--check-examples` | 标志 | 关闭 | generate、check、serve |
| `--deny-warnings` | 标志 | 关闭 | generate、check、serve |
| `--min-symbol-coverage N` | 整数 `0..100` | 无门槛 | generate、check、serve |
| `--min-parameter-coverage N` | 整数 `0..100` | 无门槛 | generate、check、serve |
| `--api-surface-baseline FILE` | 文件 | 无 | generate、check、serve |
| `--max-doc-ir-mib N` | 整数 `1..64` | `64`，可被 `[limits]` 覆盖 | generate、check、serve、render |
| `--semantic MODE` | `source`、`chir` | `source` | generate、check |
| `--cjc PATH` | 可执行文件 | `cjc` | generate、check（要求 `--semantic chir`） |
| `--chir-worker PATH` | 可执行文件 | 无 | generate、check（要求 `--semantic chir`） |
| `--chir-import-path DIR`… | 目录 | 无 | generate、check（要求 `--semantic chir`） |
| `--highlight-adapter PATH` | 绝对路径 | 无 | generate、check（与 `--highlight-node` 成对） |
| `--highlight-node PATH` | 绝对路径 | 无 | generate、check（与 `--highlight-adapter` 成对） |
| `--cfg NAME=VALUE`… | 条件编译键值 | 无 | generate、check、serve |
| `--include-path-dependencies` | 标志 | 关闭 | generate、check、serve |
| `--include-cached-dependencies` | 标志 | 关闭 | generate、check、serve |
| `--cjpm-cache DIR` | 目录 | `$HOME/.cjpm` | generate、check、serve（要求 `--include-cached-dependencies`） |
| `--dependency-source NAME=PATH`… | 依赖源码 | 无 | generate、check、serve |
| `--cache-dir DIR` | 目录 | `<project>/target/cjdoc/cache/source-v11` | generate、check、serve |
| `--no-cache` | 标志 | 关闭 | generate、check、serve |
| `--repository-url URL` | `https://github.com/<owner>/<repo>` | 无 | generate、serve（与 revision 成对） |
| `--repository-revision REV` | 文本 | 无 | generate、serve（与 URL 成对） |
| `--repository-root DIR` | 目录 | 项目根 | generate、serve（要求 URL 与 revision） |
| `--build-context FILE` | JSON | 无 | generate、check |
| `--doc-source PATH`… | catalog 文件或目录 | 无 | generate、check |
| `--doc-inventory-pin PATH=SHA256`… | 库存字节摘要 | 无 | generate、check |
| `--link-language LANG` | `zh-CN`、`en` | 未指定 | generate、check |
| `--link-language-fallback` | 标志 | 关闭 | generate、check |
| `--link-compatible` | 标志 | 关闭 | generate、check |
| `--stdlib-doc-version VERSION` | 内置目录版本或安全路径段 | 内置目录选择 | generate |
| `--stdlib-doc-base-url URL` | HTTPS 且以 `/libs/std` 结尾 | 无 | generate |
| `--locale LANG` | `zh-CN`、`en` | `zh-CN` | generate、render、serve |
| `--all-languages` | 标志 | 关闭 | generate、render |
| `--require-language LANG`… | `zh-CN`、`en` | 无 | generate、check、serve |
| `--doc-version TEXT` | 文本 | 无 | generate、render（要求 `--format html`） |
| `--agent-full` | 标志 | 关闭 | generate、render、serve |
| `--html-font-sans LIST` | 字体族列表 | 无 | generate、render、serve |
| `--html-font-mono LIST` | 字体族列表 | 无 | generate、render、serve |
| `--validation-report FILE` | JSON 报告 | 无 | generate、render |
| `--api-diff-report FILE` | JSON 报告 | 无 | generate、render |
| `--deny-breaking-api` | 标志 | 关闭 | diff |
| `--deny-potentially-breaking-api` | 标志 | 关闭 | diff |
| `--baseline FILE` / `--current FILE` | API 快照 | 无 | diff |
| `--port N` | 端口整数 | `8080` | serve |
| `--open` | 标志 | 关闭 | serve |
| `--snapshot PATH`… | `docs.json`、`agent/manifest.json`、`versions.json` | 无 | query、mcp（1–64 个） |
| `--request FILE\|-` | 请求 JSON，`-` 为 stdin | 无 | query（恰好一个） |
| `--version ID=PATH`… | 版本 ID 与站点目录 | 无 | versions compose（必填） |
| `--label ID=TEXT`、`--channel ID=TEXT`、`--status ID=TEXT`、`--base-path ID=PATH`、`--release ID=TEXT`、`--diff ID=PATH` | 版本元数据 | 见 `versions compose` 一节 | versions compose |
| `--latest ID` | 版本 ID | 首个 `--version` 的 ID | versions compose |

`--locale` 选择界面语言与已有作者译文，不翻译正文；它不改写 `zh-Hans`、`en-US` 之类的区域别名，非法值报 `--locale must be zh-CN or en`。

`--port` 与 `--open` 只影响 serve；其他命令接受这两个选项但不使用它们，退出码与不带时相同。

## 生成和离线渲染的输出选项

`--format` 可重复，重复值去重；默认只输出 `json`。`--output` 指定发布根，而不是 HTML 内层目录。多种格式共享一次源码捕获；只给 `--output` 而不给 `html` 时不会生成网页。

`--stdout` 要求恰好一种 JSON 类格式（`json`、`api-surface`、`coverage`、`symbol-index`），且与 `--output`、`--force-owned`、`--all-languages` 互斥；`--format markdown --stdout` 或两种格式同用都报 `--stdout requires exactly one JSON-producing format`。结构化数据写 stdout，诊断写 stderr。目录输出属于 `--force-owned` 描述的所有权契约，不只是「覆盖已有文件」。

`--max-doc-ir-mib` 的 CLI 值覆盖 `[limits].max-doc-ir-mib`；`render` 不读项目配置，用默认值或自己的选项。

`--html-font-sans`、`--html-font-mono` 接受逗号分隔的字体族列表：

- 每个字体族由字母、数字、空格、`_`、`-` 组成，可整体加双引号，如 `'"Source Han Sans SC", system-ui, sans-serif'`。
- 只允许以空格分隔列表项；制表符、换行、`;`、`{}`、`url(`、空项、长度超过 256 字节都报 `invalid --html-font-sans value`（mono 同理），不写出站点。
- 站点只引用字体名，不下载或打包字体文件；阅读者设备缺失时按列表顺序回退。站点「显示设置」里的字体选择优先于这两个选项。
- 非 serve 命令要求同时请求 `html` 格式。

`--validation-report`、`--api-diff-report` 附加已存在的报告文件，不执行验证或重新比较；两者都要求 generate/render 的 HTML 目录输出，`--stdout` 下不可用。

## 可选语义和高亮后端

以下选项只对 `generate`、`check` 有效，用于 serve 时报 `semantic options are only valid for generate and check` 或 `highlight host options are only valid for generate and check`。

| 选项 | 取值与约束 | 默认 |
|---|---|---|
| `--semantic source\|chir` | 其他值报 `--semantic must be source or chir` | `source` |
| `--cjc EXECUTABLE` | 显式给出时要求 `--semantic chir`，否则报 `--cjc, --chir-worker, and --chir-import-path require --semantic chir` | `cjc` |
| `--chir-worker EXECUTABLE` | 要求 `--semantic chir`；缺失或失败时保留源码信息并报诊断 | 无 |
| `--chir-import-path DIR` | 可重复；要求 `--semantic chir` | 无 |
| `--highlight-adapter PATH` | 必须与 `--highlight-node` 同时给出，否则报 `--highlight-adapter and --highlight-node must be supplied together` | 无 |
| `--highlight-node PATH` | 同上；与 adapter 一样必须是绝对路径（`--highlight-adapter requires an absolute path`），且不得含 shell 元字符 | 无 |

两个高亮路径是 argv 值，不是 shell 命令；`;`、`|`、`&`、`$`、`` ` ``、引号、括号、通配符、`~`、控制字符都报 `requires a path without shell metacharacters`。CHIR 是显式的可选语义补充，失败不会升级为权威类型检查，也不替代注释真值：worker 缺失时报 `CJDOC2101` 并回退到源码信息。构建真实 worker 见[CHIR 语义补充](../how-to/chir.md)；适配器准备与失败策略见[代码高亮](../how-to/highlighting.md)。

## serve

`cjdoc serve --project . --port 8080` 先做一次完整生成，然后在本机监听并监视输入。`--port` 默认 `8080`；`--open` 请求浏览器打开 `http://127.0.0.1:<port>/`，命令本身不等待页面。

- 服务根固定为输出目录下的 `html/`，即使还请求了其他格式。`--format`、`--output`、`--locale`、`--force-owned`、`--jobs`、`--audience`、`--lint-profile`、`--cfg`、依赖与缓存选项、`--repository-*`、`--require-language`、`--deny-warnings`、`--check-examples`、两个覆盖率门槛、`--api-surface-baseline`、`--max-doc-ir-mib`、`--agent-full`、字体选项可用。
- `--semantic`、`--cjc`、`--chir-*`、`--highlight-*`、`--build-context`、`--doc-source`、`--doc-inventory-pin`、`--link-language*`、`--link-compatible` 只对 generate/check 有效，用于 serve 报 `semantic options are only valid for generate and check` 或 `dependency documentation options are only valid for generate and check`。
- `--doc-version`、`--all-languages`、`--validation-report`、`--api-diff-report` 不适用于 serve。`--stdout` 会被接受但不改变行为：serve 始终是站点预览，`--stdout` 与 `--format html` 同用仍报错。
- 监视范围是项目内的 `.cj`、`.md`、`cjpm.toml`、`cjpm.lock`、`cjdoc.toml`；跳过隐藏项、`target/`、`.git/`、输出目录与缓存目录。保存后重建，浏览器需手动刷新。
- 重建失败时服务继续提供上一份成功站点；进程因输入错误退出后，修正输入再重启。`Ctrl+C` 停止。

状态接口 `http://127.0.0.1:<port>/__cjdoc/status.json` 返回 `cjdoc.serve-status/1`：

| 字段 | 含义 |
|---|---|
| `schemaVersion` | 固定 `cjdoc.serve-status/1` |
| `status` | 最近一次构建成功为 `ok`，否则 `error` |
| `port` | 当前监听端口 |
| `builds` | 初次生成与重建的累计尝试次数，含失败 |
| `successfulBuilds` | 其中成功的累计次数 |
| `lastError` | 最近一次失败的提示，下一次成功后重置为 `""`；具体诊断看服务终端 |

## diff

```text
cjdoc diff OLD NEW [--format text|json] [--deny-breaking-api|--deny-potentially-breaking-api]
cjdoc diff --baseline OLD --current NEW [--format text|json] [--deny-breaking-api|--deny-potentially-breaking-api]
```

两个输入都必需，两种写法只能选一种；多余的位置参数报 `unknown option '...'`。`--format` 只接受 `text`（默认）与 `json`。`--deny-breaking-api` 使 `breaking` 条目失败，`--deny-potentially-breaking-api` 使 `potentially-breaking` 条目失败；两类都要拒绝时同时给出。输入必须是 `cjdoc.api-surface/3` 快照，传入 Doc IR 报 `unsupported API surface schema 'cjdoc.doc-ir/18'`。严格基线是另一个接口：`check --api-surface-baseline` 连新增也拒绝。流程见[比较与多版本](../how-to/compare-and-version.md)。

## versions compose

| 选项 | 约束 |
|---|---|
| `--version ID=PATH` | 必填、可重复；ID 不可重复；PATH 是已生成的站点根（含 `index.html`） |
| `--output DIR` | 必填；组合站点输出，不能与任一输入目录重叠 |
| `--latest ID` | 默认首个 `--version` 的 ID，不按版本号排序；显式值必须属于版本集合 |
| `--label ID=TEXT` | 默认 ID；显示标签 |
| `--channel ID=TEXT` | 默认 `unspecified` |
| `--status ID=TEXT` | 默认 `published` |
| `--base-path ID=PATH` | 默认 ID；受安全相对路由约束，不能与其他版本重叠或占用 `index.html`、`versions.json`、`version-navigation.js`、`latest` |
| `--release ID=TEXT` | 发布说明文本，不要求 URL |
| `--diff ID=PATH` | 关联已存在的 diff 文件 |
| `--force-owned` | 输出所有权规则与 generate 相同 |

每个元数据选项对同一 ID 只能赋值一次，引用的 ID 必须出现在 `--version` 中。最多 64 个站点。产物结构见[产物参考](artifacts.md#版本站点)。

## query、mcp 与 schema

`query` 和 `mcp` 接受 1–64 个 `--snapshot`，值可以是当前 `docs.json`、`agent/manifest.json` 或版本目录的 `versions.json`；它们不发现项目、不写输出、不联网。`query` 另需恰好一个 `--request`，`-` 表示从 stdin 读一个 UTF-8 JSON 对象；`mcp` 不接受 `--request`。请求、分页与域状态见[查询协议](query-protocol.md)。

`cjdoc schema list` 列出全部可导出名字，`cjdoc schema <name>` 输出该名字对应的内容；未知名字报 `unknown schema '...'`（`2`）。各名字对应的 wire 版本见[产物参考](artifacts.md#schema-与-wire-版本)。

## 环境变量

| 变量 | 用途 | 未设置时 |
|---|---|---|
| `CJDOC_TOOLCHAIN_VERSION` | 记录到源码缓存指纹的编译器版本 | 运行 `<cjc> --version` 并从 `Cangjie Compiler:` 行提取 |
| `CJDOC_TOOLCHAIN_TARGET` | 缓存指纹中的目标平台 | `unknown-target` |
| `CJDOC_TOOLCHAIN_FINGERPRINT` | 缓存指纹中的工具链指纹 | `unknown-toolchain` |
| `CJDOC_STDX_DIGEST` | 缓存指纹中的 stdx 摘要 | `unknown-stdx` |
| `CJDOC_STDX_DEPENDENCY_DIGEST` | stdx 依赖摘要 | 沿用 `CJDOC_STDX_DIGEST` |
| `CJDOC_STDX_VARIANT` | stdx 变体 | `unknown-variant` |
| `CANGJIE_HOME` | 缓存指纹里的 SDK 路径 | 回退到 `CANGJIE_SDK_ROOT`，再回退到 `unknown-sdk` |
| `HOME` | 未给 `--cjpm-cache` 时的 cjpm 缓存根 `$HOME/.cjpm` | 缓存依赖发现报 `CJDOC1021` 并跳过 |

`CJDOC_TOOLCHAIN_*` 与 `CJDOC_STDX_*` 只作为缓存键提示，不认证实际编译器、标准库或 stdx 构建。外部高亮进程只继承 `PATH`、`SystemRoot`、`WINDIR`、`TEMP`、`TMP`、`TMPDIR`、`LANG`，不继承 `NODE_OPTIONS`、`NODE_PATH` 或其他项目环境。

## 默认值与优先级

- 显式 CLI 值优先于项目配置；未指定时按项目配置与内置默认值。
- `--max-doc-ir-mib` 覆盖配置；`--min-symbol-coverage`、`--min-parameter-coverage` 不覆盖 `[coverage]`，而是在配置门槛之外再加一套检查，两者都执行。
- `--format` 重复去重；`--cache-dir` 与 `--no-cache` 按最后出现的那个生效。
- `--validation-report`、`--api-diff-report`、`--doc-source`、`--doc-inventory-pin`、`--require-language`、`--cfg`、`--dependency-source`、`--chir-import-path` 可重复，其含义是并列而不是覆盖。
- 不要靠重复其他参数表达组合语义；除上述选项外重复给出不会产生新行为。

## 退出码

| 范围 | 退出码 | 含义 |
|---|---|---|
| generate、check、diff、versions compose、schema | 0 | 完成且所选策略未失败 |
| 同上 | 1 | 文档 error、`--deny-warnings` 遇到的 warning、覆盖率或 API 门槛失败、示例检查失败 |
| 同上 | 2 | 用法、配置或输入错误（含选项互斥、取值范围、配置文件语法） |
| render | 同上三条 | 输入不是 `cjdoc.doc-ir/18`、无法读取或超出 `--max-doc-ir-mib` 时为 `2` |
| query | 0 | `ok`、`ambiguous`、`not_found`、`source_incomplete` |
| query | 2 | `invalid_request`、`scope_mismatch`、`stale_cursor` |
| query | 3 | `budget_exceeded`、`resource_limit`、`unavailable` |
| mcp 启动 | 2 / 3 | 无效参数或输入 / 输入不可用；启动后按 JSON-RPC 与 tool 结果判断 |

`query` 的 `0` 不代表唯一匹配：必须读结果里的 `status`。`generate` 在诊断失败时仍可能写出输出（有界回退产物），是否可用要看诊断与 `apiCollectionState`。
