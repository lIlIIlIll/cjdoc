# CLI 参考

当前源码的命令行契约。先按[安装页](../getting-started/install.md)构建并安装同提交工具；命令在目标项目根运行，除非显式给出输入路径。只有 `cjdoc --help` / `cjdoc -h` 提供帮助，子命令不支持独立 `--help`。`cjdoc --version` 显示产品版本，不代替完整 source commit 身份。

## 命令

| 命令 | 输入与行为 | 最小调用 |
|---|---|---|
| `generate` | 读取项目，生成选定格式 | `cjdoc generate --project . --format html` |
| `check` | 读取项目，检查诊断和门槛，不发布站点 | `cjdoc check --project .` |
| `serve` | 生成预览并监听输入变化 | `cjdoc serve --project . --port 8080` |
| `render` | 只读当前 Doc IR v18，离线重新渲染 | `cjdoc render --input docs.json --format html --output replay` |
| `diff` | 比较两个 API snapshot 或 Doc IR | `cjdoc diff old.json new.json --format json` |
| `versions compose` | 组合已生成版本站点 | `cjdoc versions compose --version v1=old/html --version v2=new/html --latest v2 --output versions` |
| `query` | 对显式冻结快照执行单个 JSON 请求 | `cjdoc query --snapshot docs.json --request request.json` |
| `mcp` | 对显式冻结快照提供 stdio MCP | `cjdoc mcp --snapshot site/agent/manifest.json` |
| `schema` | 输出指定 schema，或列出名字 | `cjdoc schema list` |

表中的 `old.json`、`new.json`、`docs.json`、`request.json`、版本目录均是需要先准备的输入，不是安装后自带的文件。[版本操作](../how-to/compare-and-version.md)、[离线重放](../how-to/render-snapshots.md)、[query/MCP](../how-to/query-and-mcp.md)提供完整流程。

## 生成和离线渲染的输出选项

| 选项 | 默认值与约束 | 适用命令 |
|---|---|---|
| `--format NAME` | 默认 `json`；可重复，去重；`json`、`markdown`、`html`、`api-surface`、`coverage`、`symbol-index` | generate、render；diff 单独只支持 text/json |
| `--output DIR` | generate/serve 默认 `<project>/target/doc`，render 默认当前目录下 `target/doc`；指定发布根，而非 HTML 内层目录 | generate、render、serve；compose 必填 |
| `--stdout` | 默认关闭；恰好一个 JSON 类格式：json/api-surface/coverage/symbol-index；与 output、force-owned、all-languages 互斥 | generate、render |
| `--force-owned` | 默认关闭；只在所有权契约允许时替换输出，不等于任意覆盖 | generate、render、compose |
| `--max-doc-ir-mib N` | 1–64，默认 64；generate/check/serve 可受配置影响；render 不重新读项目配置 | generate、check、serve、render |
| `--locale zh-CN\|en` | 默认 zh-CN；选择界面和已有作者译文，不自动翻译 | generate、render；不是 check 选项 |
| `--all-languages` | 关闭；按配置语言生成目录，与显式 locale/stdout 互斥 | generate、render |
| `--doc-version TEXT` | 无；必须生成 HTML，写入站点版本元数据，不改变源码 | generate、render |
| `--agent-full` | 关闭；HTML 聚合全文/分片；非 serve 时要求 format html | generate、render、serve |
| `--validation-report FILE` | 无；附加已存在的报告，不执行验证；要求 HTML 目录输出 | generate、render |
| `--api-diff-report FILE` | 无；附加已有 diff，不重新比较；要求 HTML 目录输出 | generate、render |

实际目录与 wire 版本见[产物参考](artifacts.md)。stdout 的结构化数据写 stdout，生成诊断写 stderr。多种输出一次扫描生成；没有 format html 时，不会因为给了 output 就自动生成网页。

## 项目、依赖、可见性与缓存

以下用于项目生成/检查；`serve` 复用项目输入并强制加入 HTML 格式，不能用 render/query 代替项目发现。`render` 拒绝项目、依赖、受众、lint、cfg、缓存和 jobs 选项。serve 的生成/输出细节见下方专节。

| 选项 | 默认值、约束与用途 |
|---|---|
| `--project DIR` | `.`；指向含 cjpm.toml 的根，workspace 自动发现成员 |
| `--audience external\|package\|all` | external：public/protected；package：除 private；all：全部。不是隐私删源保证 |
| `--lint-profile off\|standard\|strict` | standard；控制文档诊断，不检查行为真实性 |
| `--jobs N` | 1，范围 1–64 |
| `--cfg NAME=VALUE` | 无；可重复，显式条件编译值，不猜 compiler profile |
| `--include-path-dependencies` | 关闭；加入本地 path 依赖 |
| `--include-cached-dependencies` | 关闭；只读已经准备的 cjpm 缓存，不下载 |
| `--cjpm-cache DIR` | 无显式覆盖；必须同时 include-cached-dependencies |
| `--dependency-source NAME=PATH` | 可重复；显式依赖源码，身份与清单绑定规则见输入专题 |
| `--cache-dir DIR` | 默认 `<project>/target/cjdoc/cache/source-v11`；出现时启用缓存 |
| `--no-cache` | 关闭缓存；与 cache-dir 按最后出现的选项选择 |

完整流程：[选择输入](../how-to/select-inputs.md)、[输出与缓存](../how-to/manage-outputs.md)。

## 质量与示例

| 选项 | 用途与约束 | 适用命令 |
|---|---|---|
| `--check-examples` | 默认关闭；实际编译，带 run 才执行；使用注释中的指令与固定资源限制 | generate、check |
| `--deny-warnings` | 默认关闭；warning 也导致失败 | check；项目生成解析器也接受，但不是覆盖率配置替代 |
| `--min-symbol-coverage N` | 无，0–100；使用 CLI 计数口径，与配置门槛并行检查 | check |
| `--min-parameter-coverage N` | 无，0–100；不是覆盖 `[coverage].parameters` | check |
| `--api-surface-baseline FILE` | 无；所有差异均失败，包含新增，不是仅阻断 breaking | check |
| `--require-language zh-CN\|en` | 无；可重复；要求配置内语言及有效翻译覆盖 | generate、check |

目前通用项目解析器也会接受部分门槛用于 generate；推荐按表中检查任务使用 `check`，不要把某个选项被解析视为其他子命令提供相同承诺。精确计数与两个门槛体系见[质量专题](../how-to/check-quality.md)，示例指令见[检查示例](../how-to/check-examples.md)。

## 源码与外部文档链接

| 选项 | 默认值与约束 | 命令 |
|---|---|---|
| `--repository-url URL` | 无；GitHub 仓库根，与 revision 成对 | generate；serve 的项目解析也接受 |
| `--repository-revision REV` | 无；与 URL 成对，固定源码身份 | 同上 |
| `--repository-root DIR` | 无；需要 URL/revision | 同上 |
| `--stdlib-doc-version VERSION` | 内置目录选择；非内置版本需提供 base URL | generate |
| `--stdlib-doc-base-url HTTPS_URL` | 必须是 HTTPS 且以 `/libs/std` 结尾 | generate |
| `--build-context FILE` | 无；捕获实际依赖选择的记录 | generate、check |
| `--doc-source PATH` | 可重复；文档 catalog 文件或含 `cjdoc-documents.json` 的目录，不是随便的 HTML 根；相对路径以项目根为基准 | generate、check |
| `--doc-inventory-pin PATH=SHA256` | 可重复；对实际库存字节固定 SHA-256；相对路径以项目根为基准 | generate、check |
| `--link-language LANG` | 默认未指定；规范化文档语言 | generate、check |
| `--link-language-fallback` | 默认关闭；允许显式语言回退 | generate、check |
| `--link-compatible` | 默认关闭；允许契约所定义的兼容匹配，不把它标成 exact | generate、check |

多仓源码也可配置登记，唯一完整配置见[configuration](configuration.md)。完整外部库、消费方与 pin 流程见[链接文档](../how-to/link-documentation.md)。

## 可选语义和高亮后端

| 选项 | 默认值与约束 |
|---|---|
| `--semantic source\|chir` | source；仅 generate/check |
| `--cjc EXECUTABLE` | cjc；显式指定要求 semantic chir |
| `--chir-worker EXECUTABLE` | 无；要求 semantic chir；缺失时诊断并保留源码 fallback |
| `--chir-import-path DIR` | 可重复；要求 semantic chir |
| `--highlight-adapter ABSOLUTE_PATH` | 与 highlight-node 成对；仅 generate/check；绝对文件路径，不是 shell 命令 |
| `--highlight-node ABSOLUTE_PATH` | 与 adapter 成对；拒绝 shell 元字符 |

CHIR 失败不升级语义权威性，也不替代注释真值。真实 worker 的构建见[CHIR](../how-to/chir.md)；锁定适配器和错误策略见[高亮](../how-to/highlighting.md)。

## serve

`cjdoc serve --project . --port 8080`。`--port` 默认 8080，`--open` 默认关闭；后者请求浏览器打开。`--agent-full` 可选。当前 serve 复用项目输入、缓存、受众、lint、jobs、cfg 与源码链接选项，也接受 `--output`、`--format`、`--locale`、`--force-owned`；重建时强制加入 HTML，服务根为输出下的 `html/`，额外格式不是 HTTP 根。不要使用 `--stdout`：serve 始终是站点预览进程，解析接受该标志不代表它变成管道输出命令。semantic/外部库存/高亮 host 等受 generate/check 限定的参数不能用于 serve。状态、重建与退出行为见[预览](../how-to/preview.md)。

状态接口为 `http://127.0.0.1:<port>/__cjdoc/status.json`，返回 `cjdoc.serve-status/1`：

| 字段 | 含义 |
|---|---|
| `schemaVersion` | 固定为 `cjdoc.serve-status/1` |
| `status` | 最近一次构建成功为 `ok`，失败为 `error` |
| `port` | 当前监听端口 |
| `builds` | 初次生成与后续重建的累计尝试次数，失败也计入 |
| `successfulBuilds` | 其中成功构建的累计次数 |
| `lastError` | 最近一次构建失败的提示；下一次成功后清空为 `""`。具体诊断看服务终端 |

监视范围包括源码、Markdown、`cjpm.toml`、`cjpm.lock` 与 `cjdoc.toml`；保存后重建，浏览器需要手动刷新。重建失败后仍运行的服务保留最近成功站点；若进程因输入错误退出，修正输入后重新启动。在服务终端按 `Ctrl+C` 停止。

## diff

```text
cjdoc diff OLD NEW [--format text|json] [--deny-breaking-api|--deny-potentially-breaking-api]
cjdoc diff --baseline OLD --current NEW [--format text|json] [--deny-breaking-api|--deny-potentially-breaking-api]
```

格式默认 text。两个输入都必需，不能多给第三个位置参数；仅接受输入、格式及 API deny 选项。`--deny-breaking-api` 阻断 `breaking`，`--deny-potentially-breaking-api` 阻断 `potentially-breaking`；要拒绝两类变化，同时提供两个选项。严格 API baseline 是另一个检查接口，连新增也会拒绝。[完整两份源码流程](../how-to/compare-and-version.md)。

## versions compose

| 选项 | 约束 |
|---|---|
| `--version ID=PATH` | 必需、可重复；实际生成的版本站点输入 |
| `--output DIR` | 必需；组合站点输出 |
| `--latest ID` | 默认首个 `--version` 的 ID，不按版本号排序；显式值必须属于版本集合 |
| `--label ID=TEXT` | 默认 ID；显示标签，不是源码版本 |
| `--channel ID=TEXT` | 默认 `unspecified`；发布渠道文本 |
| `--status ID=TEXT` | 默认 `published`；发布状态文本 |
| `--base-path ID=PATH` | 默认 ID；版本基路径，受安全相对路由规则约束 |
| `--release ID=TEXT` | 发布说明文本，不要求是 URL |
| `--diff ID=PATH` | 关联已存在 diff 文件 |
| `--force-owned` | 默认关闭；输出所有权规则不变 |

每个元数据选项对相同 ID 不可重复赋值，引用的 ID 必须存在。[版本专题](../how-to/compare-and-version.md)包含完整输入和安全回退。

## query、mcp 和 schema

query/mcp 要求 1–64 个显式 `--snapshot PATH`，支持当前 docs.json、agent/manifest.json、versions.json；不发现项目、不写输出、不隐式加载网络。query 另要求恰好一个 `--request FILE`，`-` 表示 stdin；mcp 不接受 request。所有请求、分页、身份和域结果见[查询协议](query-protocol.md)。

`cjdoc schema list` 列出当前可导出的 schema 名字，`cjdoc schema NAME` 输出该 schema。不同索引有各自 schema 版本；不能把 Doc IR 的 current-only 规则误用于全部协议。

## 默认值、优先级与退出码

显式 CLI 值控制相应生成选项；未指定时按项目配置及默认值。`max-doc-ir-mib` 的 CLI 覆盖配置；`--min-*-coverage` 不覆盖配置，而是增加另一套检查。重复 format 去重，cache-dir/no-cache 取最后一个；不要依赖其他重复参数来表达组合语义。离线 render 不回读当前项目配置。

| 范围 | 退出码 | 含义 |
|---|---|---|
| 生成/检查/差异等普通命令 | 0 | 完成且所选策略未失败 |
| 同上 | 1 | 文档 error、要求的 warning/覆盖率/API gate、受控生成失败等 |
| 同上 | 2 | 用法、配置或输入错误；具体诊断区分原因 |
| query | 0 | 成功或协议规定的正常域结果，不等于有唯一匹配 |
| query | 2 | invalid_request、scope_mismatch、stale_cursor |
| query | 3 | unavailable / 资源或快照加载失败 |
| mcp 启动 | 2 / 3 | 分别为无效参数/输入与不可用；启动后按 JSON-RPC/tool 结果解释 |

query 的 stale、ambiguous、not-found 等必须读取结构化 status，不只检查进程是否为 0。具体域状态和返回形式以[协议参考](query-protocol.md)为准。
