# 产物与格式参考

`generate` 和 `render` 的六种 `--format` 是 `json`、`markdown`、`html`、`api-surface`、`coverage`、`symbol-index`。一次命令可重复指定 `--format`；未指定时只输出 `json`。常见位置相对 `--output` 输出根，默认输出根为 `target/doc`。

```bash
cjdoc generate --project . \
  --format html \
  --format markdown \
  --format json \
  --format api-surface \
  --format coverage \
  --format symbol-index
```

六种格式共享一次源码捕获；实际产物以 schema 和输出根为准，不要根据展示 slug 推算文件路径。生成与静态发布任务见[生成与发布](../how-to/generate-and-publish.md)，版本站点见[比较 API 与管理版本](../how-to/compare-and-version.md)。

## 六种输出格式

| `--format` | 主要路径 | 用途与边界 |
|---|---|---|
| `json` | `docs.json` | 当前 Doc IR 全量捕获，默认格式。可作为当前版本离线 `render` 输入；不是仅含 public API 的安全发布摘录。 |
| `markdown` | `markdown/index.md`，以及包、容器声明、概念页和资源文件 | 可提交仓库或接入其他文档站。索引引用同一格式目录内的包/声明/页面文件。 |
| `html` | `html/index.html`、包页/声明页、概念页和伴随资源 | 可直接由浏览器打开的静态站点，包含本地搜索、导航、主题和机器读取产物。部署时复制整个 `html/`，不可只复制首页或 `agent/` 子目录。 |
| `api-surface` | `api-surface/api-surface.json` | 当前 `cjdoc.api-surface/3` API 快照，供 diff 或严格基线检查；不是 Doc IR。 |
| `coverage` | `coverage/coverage.json`、`coverage/quality.json`；配置了多语言时还有 `coverage/translations.json` | 指标报告、lint/质量报告和翻译覆盖报告。详见[检查文档质量](../how-to/check-quality.md)。 |
| `symbol-index` | `symbol-index/symbol-index.json` | `cjdoc.symbol-index/2` 符号库存；请求 HTML 时也会生成相应机器库存。 |

`--stdout` 只适用于恰好一种 JSON 类格式：`json`、`api-surface`、`coverage`、`symbol-index`；不能与 `--output` 同用。诊断写入 stderr，stdout 保持单个 JSON 文档。Markdown 与 HTML 不是 JSON stdout 格式。

`--stdout --format coverage` 是实现接受的 JSON 单格式例外：stdout 只写 `coverage/coverage.json` 的第一个产物，不会同时写目录格式下的 `coverage/quality.json` 或多语言 `coverage/translations.json`；需要完整报告集合时使用目录输出。

`--doc-version ID` 需要同时输出 HTML，并把文档发布标签放入站点信息。该标签是文档发布元数据，不等同于 SDK/compiler 认证或依赖包版本。语言选择与输出目录结构见下节。

## 多语言产物布局

`--locale zh-CN|en` 选择单个语言的用户界面和可用作者译文，默认 `zh-CN`；它不自动翻译。`--all-languages` 让 `generate` 或 `render` 按 `[i18n].languages` 输出各语言目录：

```text
target/doc/
├── html/zh-CN/index.html
├── html/en/index.html
├── markdown/zh-CN/index.md
├── markdown/en/index.md
└── docs.json
```

每种语言各有独立 `html/<language>/`、`markdown/<language>/` 文档根；其他共享产物只写一份。示例中的 `docs.json` 仅当请求 `json` 格式时存在，其中保留全部作者语言变体。`--all-languages` 要求配置 `[i18n]`，只支持目录输出，不能与 `--locale` 或 `--stdout` 同用；如果 `languages` 省略，只输出 default-language。`serve --locale` 用来预览单个语言，不能借此跳过其他已发布语言的质量/翻译检查。

发布时部署对应输出目录的完整内容，不要只复制 `index.html`。页头语言切换使用相对链接；目标语言缺少页面时转到该语言首页，章节尽量映射到配对页对应标题，否则回到页首。译文选择和页面配对见[多语言注释](doc-comments.md#多语言注释)及[发布多语言页面](../tutorials/publish-languages.md)。

## HTML 静态站与附带机器产物

HTML renderer 会生成首页、包页、声明页、概念页、搜索/侧栏/主题脚本、样式表和页面资源。典型位置包括：

```text
html/
├── index.html
├── search-index.json
├── search-index.js
├── sidebar-index.js
├── theme-bootstrap.js
├── search.js
├── symbol-alias.js
├── style.css
├── navigation-index.json
├── symbol-index.json
├── llms.txt
├── validation.html
├── agent/
│   ├── manifest.json
│   ├── docs.json
│   ├── symbols/...
│   ├── pages/...
│   └── reports/...
└── agent-full-index.json       # 仅 --agent-full
```

此树为入口示意；声明页面、package 页面、concept 页面、语言子目录、资源和 manifest 映射会随输入增减。以 manifest 中各表示的实际相对路径为准，不拼接 slug 或臆造扩展名。所有 `html/` 下相对路径都以当前文档根为基准，可从静态 HTTP 子路径和 `file://` 使用。

HTML 默认包含可见声明/页面的机器读取入口和逐页、逐声明 Markdown/JSON 表示；不要求 `--agent-full`。`--agent-full` 只增加聚合全文与分片索引，适用于 `generate`、`render`、`serve`，且 `generate`/`render` 时必须同时请求 `html`。要使用每声明独立表示，应部署完整 HTML 根，不能只搬运 `agent/`，因为 manifest 指向的 HTML 和全文入口在根目录。

机器读取重点：

| 路径 | 当前 schema / 含义 |
|---|---|
| `navigation-index.json` | `cjdoc.navigation-index/2` 导航索引的首片，含实际续取路径；必须沿 `pagination.next` 读取到结束，首片不等于完整枚举。 |
| `search-index.json`、`search-index.js` | `cjdoc.search-index/11`，内嵌 `cjdoc.search-contract/2`；静态站搜索使用 `discovery` + `bounded-static`。 |
| `symbol-index.json` | `cjdoc.symbol-index/2` 符号库存。 |
| `agent/manifest.json` | `cjdoc.machine-manifest/1`；绑定快照、发布修订、作用域、资源哈希与实际 HTML/Markdown/JSON 表示路径。 |
| `agent/docs.json` | 与 manifest 对应的自包含 `cjdoc.doc-ir/18`。 |
| `agent/symbols/*.json` | `cjdoc.declaration/3` 独立声明，含 classification/source 投影。 |
| `agent/pages/*.json` | `cjdoc.page/2` 概念、包或项目页。 |
| `agent-full-index.json` | 仅 `--agent-full`：`cjdoc.agent-full-index/1` 全文分片描述，提供顺序、范围、摘要和完整性信息。 |
| `llms.txt` | 精简发现入口，链接目录、表示 manifest 和已启用全文入口；不是完整正文或全站枚举。 |

不同表示文件中 Markdown 的相对链接按文件位置生成；manifest、索引和根级摘要的路径按文档根解析。manifest 是路径映射的事实来源，不应根据 title、签名或旧版聚合 Markdown 推算路径。Full-index 读取者要对照 manifest 的 `snapshotId` 和 `publicationRevision`，并校验分片 SHA-256、范围和续取。仅有 HTML/JSON 产物或成功构建不构成作者契约或运行示例的验证回执。固定输入查询见[查询协议](query-protocol.md)，状态含义见[状态与限制](states-and-limits.md)。

## Schema 与 wire 版本清单

以下是当前 `cjdoc schema list` 暴露的**所有**协议名称和对应 wire 版本。除明确标作别名的名称外，括号内是 schema 中的 `cjdoc.<name>/<version>`。

| schema 命令名称 | wire 版本 | 说明 |
|---|---:|---|
| `doc-ir`、`doc-ir-v18` | `doc-ir/18` | 两个名称都导出当前 Doc IR；decoder 仅接受 v18。 |
| `diagnostics` | `diagnostics/2` | 诊断数组 envelope。 |
| `cfg-matrix` | `cfg-matrix/2` | 多配置 profile 的 Doc IR 集合。 |
| `search-index`、`search-index-v11` | `search-index/11` | 两个名称相同。 |
| `symbol-index` | `symbol-index/2` | 符号索引。 |
| `navigation-index`、`navigation-index-v2` | `navigation-index/2` | 无后缀名称指向当前 v2。 |
| `navigation-index-v1` | `navigation-index/1` | 冻结的旧 wire 结构，保留供明确选择；缺少 v2 的整体完整性/续取语义。 |
| `api-surface`、`api-surface-v3` | `api-surface/3` | 两个名称相同。 |
| `api-diff`、`api-diff-v2` | `api-diff/2` | 两个名称相同。 |
| `documentation-coverage` | `documentation-coverage/2` | 覆盖报告。 |
| `documentation-quality` | `documentation-quality/1` | 质量报告。 |
| `versions`、`versions-v2` | `versions/2` | 多版本站点 manifest。 |
| `translation-coverage` | `translation-coverage/1` | 翻译覆盖报告。 |
| `site-manifest` | `site-manifest/1` | 站点路由 manifest。 |
| `agent-full-index` | `agent-full-index/1` | 聚合全文分片索引。 |
| `declaration` | `declaration/3` | 独立声明表示。 |
| `page` | `page/2` | 独立页面表示。 |
| `machine-manifest` | `machine-manifest/1` | HTML machine bundle manifest。 |
| `query-request` | `query-request/3` | 固定快照查询请求。 |
| `query-result` | `query-result/4` | 查询结果 envelope。 |
| `search-contract` | `search-contract/2` | **不是 JSON Schema**；共享搜索行为契约数据。 |
| `source-provenance` | `source-provenance/1` | 调用方 source receipt；是来源输入契约，不是默认文档根产物。 |

使用 `cjdoc schema list` 列出名称，`cjdoc schema <name>` 输出对应内容。注意别名不是不同 wire 版本：例如 `navigation-index` 与 `navigation-index-v2` 都是 v2；只有显式 `navigation-index-v1` 是 v1。完整静态 schema 文件以 `docs/schema/` 为生成源，不代表每个文件都由 `schema list` 另列一个命令名称。

### current-only 的适用范围

`cjdoc.doc-ir/18` 是**当前 Doc IR wire**：`render`、query loader 和当前 decoder 不迁移 `/17` 或更早版本；旧 JSON 应从原始源码重新生成。这个规则不等于“所有 schema 都只有一个历史版本”或“所有其他协议也 current-only”。有独立版本号的 navigation-index v1 是明确保留的冻结 schema；各机器协议各自按上表版本验证。不要把 Doc IR current-only 扩大解释为所有 index schema 的迁移策略。

## 其他命令生成的相关文件

`cjdoc diff --format json` 输出 API diff 报告 `cjdoc.api-diff/2`，不属于六种文档 renderer `--format`。`versions compose` 生成 `cjdoc.versions/2` manifest，并复制、组织各版本已经生成的站点；它不重新生成版本正文。Doc IR 中捕获的来源投影可能写入文件 provenance 和 source-reference；其 receipt 输入另用 `cjdoc.source-provenance/1`，不是默认 `html/` 输出。

版本、API diff 和它们的输入身份见[比较 API 与管理版本](../how-to/compare-and-version.md)。完整 schema 以运行时 `cjdoc schema <name>` 为准；本页版本表描述当前源码支持的 wire，不承诺旧格式自动升级。