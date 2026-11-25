# 产物与格式参考

`generate` 与 `render` 的六种 `--format`、每种格式写出的文件、这些文件的 schema 名字与 wire 版本。写文件的操作步骤见[生成与发布](../how-to/generate-and-publish.md)，版本站点见[比较与多版本](../how-to/compare-and-version.md)。

## 六种输出格式

| `--format` | 主要路径 | 内容 |
|---|---|---|
| `json` | `docs.json` | 当前 Doc IR 全量捕获，默认格式；可作为当前版本的 `render` 输入 |
| `markdown` | `markdown/index.md` 及包、声明、概念页文件 | 可提交仓库或接入其他文档站的 Markdown |
| `html` | `html/index.html` 及包页、声明页、概念页、脚本与样式 | 可直接从 `file://` 打开的静态站点，带本地搜索与机器读取产物 |
| `api-surface` | `api-surface/api-surface.json` | `cjdoc.api-surface/3` 快照，供 `diff` 与严格基线检查；不是 Doc IR |
| `coverage` | `coverage/coverage.json`、`coverage/quality.json`；配置多语言时还有 `coverage/translations.json` | 指标报告、质量报告、翻译覆盖报告 |
| `symbol-index` | `symbol-index/symbol-index.json` | `cjdoc.symbol-index/2` 符号库存 |

```bash
cjdoc generate --project . \
  --format json --format markdown --format html \
  --format api-surface --format coverage --format symbol-index
```

六种格式共享一次源码捕获；未指定 `--format` 时只写 `json`。实际路径以输出根下的文件和 schema 为准，不要用标题或签名推算文件名。

`--stdout` 只接受恰好一种 JSON 类格式（`json`、`api-surface`、`coverage`、`symbol-index`）：内容写到 stdout，诊断写到 stderr。`--stdout --format coverage` 只输出 `coverage/coverage.json` 这一个文档，不含 `quality.json` 或 `translations.json`；需要整套报告时用目录输出。

`--doc-version TEXT` 要求同时生成 HTML，并额外写出 `html/version.json`（`cjdoc.version/1`），把发布标签写进站点信息：

```json
{
  "schemaVersion": "cjdoc.version/1",
  "id": "0.7.8",
  "label": "0.7.8",
  "project": "demo"
}
```

该标签是文档发布元数据，不等同于 SDK/编译器认证或依赖包版本。

## 输出根与所有权清单

默认输出根是 `<project>/target/doc`（`render` 为工作目录下的 `target/doc`）。无论选了几种格式，输出根下都有一份 `.cjdoc-output.json`（`cjdoc.output/3`），记录本次写入的文件与目录及其 SHA-256：

```json
{
  "schemaVersion": "cjdoc.output/3",
  "digestAlgorithm": "sha256",
  "directories": [],
  "files": [
    {"path": "docs.json", "sha256": "4c649055a45ace15bd9ca1745dd4dcfb4d1b28dbeb35dc7c9ad9e643ba013880"}
  ]
}
```

`directories` 只列确实创建的子目录；没有 `html/` 时它是空数组。这份清单决定后续写入可以替换哪些文件。目录已存在但不属于 cjdoc 管理时，写入被拒绝；`--force-owned` 只在所有权契约允许时替换，不是任意覆盖。处理方法见[管理输出](../how-to/manage-outputs.md)。

## 各格式的文件树

以下树来自一个单包项目（包 `demo`、一个公开函数）实际生成的输出，`<id>` 是稳定对象标识，随输入变化。

`--format json`：

```text
target/doc/
├── .cjdoc-output.json
└── docs.json
```

`--format markdown`：

```text
target/doc/
├── .cjdoc-output.json
└── markdown/
    ├── index.md
    ├── packages/
    │   └── package-<id>.md
    └── symbols/
        └── symbol-<id>.md
```

`index.md` 是包清单，每项链接同目录内的包文件。包文件按声明列出签名、参数、返回值、说明与源码位置，容器声明另有独立的 `symbols/symbol-<id>.md`；块内的相对链接按该文件自身位置生成。启用概念文档后还有 `markdown/concepts/…`。

`--format api-surface`、`--format coverage`、`--format symbol-index`：

```text
target/doc/
├── .cjdoc-output.json
├── api-surface/api-surface.json
├── coverage/coverage.json
├── coverage/quality.json
├── coverage/translations.json   # 仅配置了 [i18n] 语言列表时
└── symbol-index/symbol-index.json
```

`--format coverage` 在未配置多语言时只有 `coverage.json` 与 `quality.json`；配置 `[i18n].languages` 后多出 `translations.json`。

`--format html`（含 `--agent-full` 时另加两项）：

```text
target/doc/
├── .cjdoc-output.json
└── html/
    ├── index.html
    ├── navigation-index.json
    ├── search-index.json
    ├── search-index.js
    ├── search.js
    ├── sidebar-index.js
    ├── theme-bootstrap.js
    ├── symbol-alias.js
    ├── style.css
    ├── symbol-index.json
    ├── llms.txt
    ├── llms-full.txt            # 仅 --agent-full
    ├── agent-full-index.json    # 仅 --agent-full
    ├── validation.html
    ├── packages/<包名分段>/index.html
    ├── packages/package-<id>.html  # 历史链接兼容页
    ├── <包>/<类型>/<成员>/index.html
    ├── symbols/<slug>-<id>.html
    ├── symbols/symbol-<id>.html
    ├── concepts/…               # 启用 [docs] 后
    └── agent/
        ├── manifest.json
        ├── docs.json
        ├── pages/…
        ├── packages/…
        └── symbols/…
```

类型和独立成员的 HTML 正文写入 `<包>/<类型>/<成员>/index.html` 等实际文件。重载共用一个选择页，每条签名另有独立文件。两种旧 `symbols/*.html` 文件都直接链接到对应正文；它们不是正文或机器表示。存在概念文档时，`concepts/` 下还有首页、模块页、包页与配置的指南路由。分页的导航与全文产物按需追加 `navigation-index-part-<n>.json`、`llms-full-part-<n>.txt`。

包参考页写入 `packages/<包名分段>/index.html`，例如 `packages/pocketkit/authoring/index.html`。HTTP 站点链接使用以 `/` 结尾的目录地址；通过 `file://` 打开时链接到实际文件。以前分享的 `packages/package-….html` 仍能打开同一个包并保留查询参数和片段；关闭 JavaScript 时，旧页面也可以直接阅读。

`html/` 下的相对路径都以该文档根为基准，因此整棵目录既能用静态 HTTP 子路径托管，也能用 `file://` 打开。部署要复制整个 `html/`：只复制 `index.html`、或只搬运 `agent/` 都会让 manifest 指向的页面与全文入口失效。

`--agent-full` 适用于 generate、render、serve；非 serve 命令要求同时请求 `html`。它只增加聚合全文 `llms-full.txt` 与分片描述 `agent-full-index.json`，不加它也有逐页、逐声明的 Markdown/JSON 表示。

## HTML 机器读取产物

| 路径 | schema | 说明 |
|---|---|---|
| `navigation-index.json` | `cjdoc.navigation-index/2` | 导航索引首片，含 `completeness` 与 `pagination`（`offset`、`returned`、`total`、`part`、`parts`、`next`、`pathBase`）；必须沿 `next` 读到结束，首片不是完整枚举 |
| `search-index.json`、`search-index.js` | `cjdoc.search-index/12`，内嵌 `cjdoc.search-contract/3` | 静态站搜索用 `discovery` + `bounded-static`，只支持 `search` |
| `symbol-index.json` | `cjdoc.symbol-index/2` | 符号库存，与 `--format symbol-index` 内容同类 |
| `agent/manifest.json` | `cjdoc.machine-manifest/3` | 绑定快照、发布修订、作用域、资源哈希，以及每个 HTML/Markdown/JSON 表示的相对路径 |
| `agent/docs.json` | `cjdoc.doc-ir/19` | 与 manifest 对应的自包含 Doc IR |
| `agent/symbols/*.json` | `cjdoc.declaration/3` | 单条声明的独立表示，含分类与源码投影 |
| `agent/pages/*.json`、`agent/pages/*.md` | `cjdoc.page/2` | 概念页、包页或项目页的独立表示 |
| `agent/packages/*` | `cjdoc.page/2`、`cjdoc.declaration/3` | 包页与包内声明的 Markdown/JSON 表示 |
| `agent-full-index.json` | `cjdoc.agent-full-index/1` | 全文分片描述：顺序、`unitCount`、`partByteLimit`、各分片范围与摘要 |
| `llms.txt` | 无 schema | 精简发现入口，链接目录、表示 manifest 与全文入口；不是全站枚举 |
| `validation.html` | — | HTML 站点的验证结果页；可附加验证或 API 差异报告 |

`agent/manifest.json` 是路径映射的事实来源；不要由标题、签名或 slug 推算路径。读取 `agent-full-index.json` 时要对照 manifest 的 `snapshotId` 与 `publicationRevision`，并校验分片 SHA-256、范围与续取信息。

Doc IR 只装在内存或只有 `docs.json` 时，结果的 `packagedRepresentations` 为 `false`：规范路由存在不代表资源真的随包复制。装载 `agent/manifest.json` 才会校验资源哈希与完整表示映射。

新发布使用 `cjdoc.machine-manifest/3` + `cjdoc.read/3`：包的 HTML 表示使用新包地址的实际 `index.html` 文件，声明地址与 `/2` 相同。CLI 仍能验证和查询 `/1` + `/1` 和 `/2` + `/2` 的旧发布，沿用各自的原始地址。manifest 版本必须与读取投影版本配对；三种发布的 `agent/docs.json` 均为 Doc IR v18。

## 多语言产物布局

`--locale zh-CN|en` 选择单个语言的界面与已有作者译文，默认 `zh-CN`，不翻译正文。`--all-languages` 让 generate 或 render 按 `[i18n].languages` 输出每个语言的目录；没有显式语言列表时报 `--all-languages requires explicit [i18n] languages`。

```text
target/doc/
├── .cjdoc-output.json
├── site-manifest.json
├── docs.json
├── html/
│   ├── zh-CN/…（完整站点根）
│   ├── en/…
│   └── <包>/<类型>/index.html（默认语言的公开 API）
└── markdown/
    ├── zh-CN/…
    └── en/…
```

每种语言各有独立的 `html/<language>/` 与 `markdown/<language>/` 文档根；`docs.json` 只写一份并保留全部作者语言变体。默认语言的 API 正文和重载选择页同时发布在共同的 `html/` 根下，仍使用默认语言目录下的资源。各语言的机器包保持独立；`site-manifest.json`（`cjdoc.site-manifest/1`）为每个逻辑身份登记一个公开 `href`：

```json
{
  "schemaVersion": "cjdoc.site-manifest/1",
  "project": "demo",
  "version": null,
  "defaultLanguage": "zh-CN",
  "routes": [
    {"language": "en", "pageId": "api-home", "symbolId": null, "sectionId": null,
     "ownerSymbolId": null, "href": "html/en/index.html"}
  ]
}
```

`--all-languages` 只支持 generate/render 的目录输出，不能与 `--locale` 或 `--stdout` 同用。页面语言切换使用相对链接；目标语言缺页时转到该语言首页，章节尽量映射到配对页的对应标题，否则回到页首。

## 版本站点

`cjdoc versions compose` 把已生成的站点复制成带版本选择器的组合站：

```text
versions/
├── .cjdoc-output.json
├── index.html               # 跳到 --latest 指定的版本
├── versions.json            # cjdoc.versions/2
├── version-navigation.js
├── latest/index.html
└── <base-path>/…            # 每个版本一份完整站点
```

`versions.json` 记录 `schemaVersion`、`project`、`latest`、`latestPolicy`（`first-listed` 或 `explicit`）与每个版本的 `id`、`label`、`basePath`、`channel`、`status`、`index`、`symbolIndex`、`apiDiff`：

```json
{
  "schemaVersion": "cjdoc.versions/2",
  "project": "composed",
  "latest": "v1",
  "latestPolicy": "first-listed",
  "versions": [
    {"id": "v1", "label": "v1", "basePath": "v1", "channel": "unspecified",
     "status": "published", "index": "v1/index.html",
     "symbolIndex": "v1/symbol-index.json", "apiDiff": null}
  ]
}
```

站点自带 `symbol-index.json` 时 `symbolIndex` 才有路径，否则为 `null`；只有附加了 diff 文件时 `apiDiff` 才指向 `<base-path>/api-diff.json`。组合只复制既有站点并注入选择器，不重新生成正文，也不校验各版本内容是否一致。最多 64 个站点、合计 256 MiB、65532 个文件；单份 diff 输入最多 32 MiB。

## Schema 与 wire 版本

`cjdoc schema list` 当前输出以下 28 个名字。除标为别名的名字外，括号里是对应 JSON 的 `schemaVersion`。

| `cjdoc schema` 名字 | wire 版本 | 说明 |
|---|---|---|
| `doc-ir`、`doc-ir-v19` | `cjdoc.doc-ir/19` | 两个名字都输出当前 Doc IR；解码器只接受 v19 |
| `diagnostics` | `cjdoc.diagnostics/2` | 诊断数组 envelope |
| `cfg-matrix` | `cjdoc.cfg-matrix/2` | 多 cfg profile 的 Doc IR 集合 |
| `search-index`、`search-index-v12` | `cjdoc.search-index/12` | 两个名字相同 |
| `symbol-index` | `cjdoc.symbol-index/2` | 符号库存 |
| `navigation-index`、`navigation-index-v2` | `cjdoc.navigation-index/2` | 无后缀名字指向 v2 |
| `navigation-index-v1` | `cjdoc.navigation-index/1` | 冻结的旧结构，缺 v2 的完整性与续取语义 |
| `api-surface`、`api-surface-v3` | `cjdoc.api-surface/3` | 两个名字相同 |
| `api-diff`、`api-diff-v2` | `cjdoc.api-diff/2` | 两个名字相同 |
| `documentation-coverage` | `cjdoc.documentation-coverage/2` | 覆盖率报告 |
| `documentation-quality` | `cjdoc.documentation-quality/1` | 质量报告 |
| `versions`、`versions-v2` | `cjdoc.versions/2` | 版本站点 manifest |
| `translation-coverage` | `cjdoc.translation-coverage/1` | 翻译覆盖报告 |
| `site-manifest` | `cjdoc.site-manifest/1` | 跨语言路由 manifest |
| `agent-full-index` | `cjdoc.agent-full-index/1` | 聚合全文分片索引 |
| `declaration` | `cjdoc.declaration/3` | 单条声明的独立表示 |
| `page` | `cjdoc.page/2` | 单个概念页的独立表示 |
| `machine-manifest` | `cjdoc.machine-manifest/3`、`/2`、`/1` | 发布写 `/3`；schema 也描述可验证读取的 `/2` 和 `/1` 包 |
| `query-request` | `cjdoc.query-request/4` | 固定快照查询请求 |
| `query-result` | `cjdoc.query-result/5` | 查询结果 envelope |
| `search-contract` | `cjdoc.search-contract/3` | 不是 JSON Schema，是搜索行为契约数据 |
| `source-provenance` | `cjdoc.source-provenance/1` | 调用方 source receipt 的输入契约，不是默认输出文件 |

别名不是不同 wire 版本：`navigation-index` 与 `navigation-index-v2` 都是 v2，只有显式写 `navigation-index-v1` 才拿到 v1。`cjdoc.version/1`（`html/version.json`）与 `cjdoc.serve-status/1`（serve 状态接口）不在 `schema list` 里，它们是产物字段的契约。仓库里的 `docs/schema/` 保留同名静态 JSON Schema 文件，运行时以 `cjdoc schema <name>` 的输出为准。

### current-only 的适用范围

`cjdoc.doc-ir/19` 是当前 Doc IR wire：`render`、query 加载器与解码器都不迁移 `/18` 或更早版本，旧 JSON 必须从原始源码重新生成。这条规则只针对 Doc IR；其他协议各自有版本号，`navigation-index-v1` 就是明确保留的冻结 schema。

## 其他命令写出的文件

| 命令 | 输出 |
|---|---|
| `cjdoc diff --format json` | `cjdoc.api-diff/2` 报告写到 stdout，不是文档 `--format` 之一 |
| `cjdoc diff --format text` | 人类可读摘要与条目，写到 stdout |
| `cjdoc versions compose` | `cjdoc.versions/2` manifest 与各版本站点副本 |
| `cjdoc query` | 单个 `cjdoc.query-result/5` envelope，写到 stdout |
| `cjdoc mcp` | 每行一个 JSON-RPC 2.0 对象，写到 stdout |
| `cjdoc check` | 只写诊断到 stderr，不写输出目录 |

Doc IR 里捕获的来源投影会随 `docs.json` 一并写出；它引用的 receipt 使用 `cjdoc.source-provenance/1`，是输入契约而不是站点产物。查询与 MCP 的协议见[查询协议](query-protocol.md)，状态词含义见[状态与限制](states-and-limits.md)。
