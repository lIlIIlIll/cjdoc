# 生成并发布文档

在含 `cjpm.toml` 的项目根运行 `cjdoc`。生成的 HTML 可直接打开，也可原样上传到静态托管。没有项目可用时，先完成[第一个站点](../tutorials/first-site.md)。

## 1. 生成 HTML 站点

指定 HTML 格式和发布目录：

```bash
OUT=target/doc-publish
cjdoc generate --project . --format html --output "$OUT"
```

命令成功后打开 `$OUT/html/index.html`。如果没有 `[output].formats` 且省略 `--format`，命令只生成 `$OUT/docs.json`。想让项目平时直接生成 HTML，可以在 `cjdoc.toml` 保存默认值：

```toml
[output]
formats = ["html"]
```

这时在项目根执行 `cjdoc generate` 即可，显式的 `--format` 会替换整份格式列表。对现有 `[output]` 表增加或修改 `formats`，不要再写一个同名表。

使用新目录，或复用 cjdoc 之前生成的输出根。不要先建空目录，也不要把手工修改放进生成文件；重新生成会移除不再需要的已管理产物。遇到目录或锁冲突，见[管理输出](manage-outputs.md)。

## 2. 阅读页面、搜索和深链

用浏览器打开生成的 `index.html`，不需要本地服务器。点「搜索文档」，或按 `Ctrl+K`（macOS 为 `⌘K`）、`/`，输入一个公开声明的名称。在 `docdemo` 中可搜索 `greet`，打开其签名、参数、返回值和示例。

宽屏左侧是包和声明导航，右侧是本页目录。可以在包导航里按名称筛选，也可以在页眉搜索整站。

在页眉的「显示设置」调整阅读方式：

| 想改变什么 | 设置 |
|---|---|
| 长代码行不想横向滚动 | 「代码块长行 → 自动换行」 |
| 长预期输出一开始就展开 | 「长输出默认状态 → 展开」 |
| 一开始只看示例标题 | 在「示例默认状态」选择折叠 |
| 同一 API 的同级提示集中读 | 「API 提示 → 按类型合并」；默认逐条显示，只有一条时仍单独显示 |
| 还原字号、字体、主题及其他阅读设置 | 「恢复默认设置」；语言和搜索筛选不变 |

分享页面时用页首的**复制链接**；成员操作区的**复制链接**指向该成员的独立页，而不是类型总览，「查看源码」是单独的操作。HTTP 上类型和成员使用目录地址：`/pocketkit/TextCatalog/`、`/pocketkit/TextCatalog/join/`；`/pocketkit/TextCatalog/find/` 列出 `find` 的重载，从具体签名页复制的链接会回到该签名。离线打开时复制的是带 `index.html` 的实际文件地址；浏览器拒绝写入剪贴板时，可以选中并手动复制显示的地址。若多个声明的名字在目标文件系统上无法区分（例如大小写或 Unicode 等价拼写），生成器会分配不同的地址，这时不要手工拼路径。

设置在支持本地存储的浏览器中保留。不同 API 或指南正文里的提示不会合并。换行和折叠不改变复制内容，也不影响[示例检查](check-examples.md)。示例输出是作者写下的预期文本。

## 3. 指定站点字体

要为正文和代码指定默认字体，重新生成时传字体族列表：

```bash
cjdoc generate --project . --format html --output "$OUT" \
  --html-font-sans '"Source Han Sans SC", system-ui, sans-serif' \
  --html-font-mono '"JetBrains Mono", ui-monospace, monospace'
```

刷新页面后使用列表中第一个已安装的字体。cjdoc 不下载字体文件；建议在列表末尾保留通用字体族。读者在显示设置里选过字体时，以读者的选择为准。若报 `invalid --html-font-sans value` 或 mono 对应错误，检查[字体列表规则](../reference/cli.md#生成和离线渲染的输出选项)。

## 4. 通过 HTTP 阅读

想在本地模拟静态托管时，用 Python 3 提供整个 `html/`：

```bash
python3 -m http.server 8000 --bind 127.0.0.1 --directory "$OUT/html"
```

打开 `http://127.0.0.1:8000/`，试一次搜索和深链。端口已被占用时，同时换命令和浏览器地址里的端口。使用结束按 `Ctrl+C`。这个静态服务器不会自动重建，也没有 `__cjdoc/status.json`；要边改边看，用[本地预览](preview.md)。

## 5. 发布整个 HTML 目录

确认生成命令以 `0` 结束，再把 `$OUT/html/` 的**全部内容**上传到托管平台的文档根目录。保留子目录、相对路径和文件名大小写。若有多语言或多版本，发布共同的站点根，不要只传一棵语言或版本子树。

从托管地址打开首页，搜索一个声明，再直接打开它的链接。若首页可用但搜索、样式或深链失效，检查是否漏传了资源、索引或页面子目录。发布前检查报告、源码链接以及 `agent/` 中的机器文档是否适合公开；[选择受众不等于脱敏](select-inputs.md)。

静态托管要把以 `/` 结尾的目录地址交给该目录的 `index.html`，不需要前端重写规则；站点挂在 `/docs/` 时，声明链接保留 `/docs/`，版本站里的链接也保留当前版本。双语站的默认语言 API 地址没有语言前缀：默认语言是 `zh-CN` 时，`/docs/pocketkit/TextCatalog/` 是中文，`/docs/en/pocketkit/TextCatalog/` 是英文，入口不受浏览器语言影响。

## 6. 按需生成其它格式

一次生成站点、Markdown、快照和报告：

```bash
cjdoc generate --project . \
  --format html --format markdown --format json \
  --format api-surface --format coverage --format symbol-index \
  --output "$OUT"
```

| 输出根下的位置 | 用途 |
|---|---|
| `html/index.html` | 阅读或发布站点 |
| `markdown/index.md` | 阅读 Markdown 文档 |
| `docs.json` | 查询或重渲染快照 |
| `api-surface/api-surface.json` | 比较版本间的 API |
| `coverage/coverage.json`、`coverage/quality.json` | 检查覆盖率和文档质量 |
| `symbol-index/symbol-index.json` | 让其他项目链接到本站文档 |

完整文件清单见[输出文件参考](../reference/artifacts.md)。

## 7. 把单个 JSON 写入标准输出

```bash
mkdir -p target
cjdoc generate --project . --format json --stdout > target/project.docs.json
```

退出码为 `0` 后再读取 `target/project.docs.json`；诊断写到标准错误。`--stdout` 要求恰好一个 JSON 类格式（`json`、`api-surface`、`coverage` 或 `symbol-index`），不能与 `--output`、`--force-owned`、`--all-languages` 同用。

## 失败时怎么办

- **没有 `html/`**：显式请求 `--format html`。
- **打开的还是旧页面**：确认浏览器打开的是这次生成的 `$OUT/html/index.html`，或服务器的 `--directory` 正指向它，然后刷新。
- **生成后目录存在但命令以 `1` 退出**：先修诊断，重新生成并检查退出码，不要因为有文件就发布。
- **写入被拒绝**：不要删不明的所有权记录或锁；按[管理输出](manage-outputs.md)处理。
