# 生成并发布文档

为项目生成可直接打开、搜索和分享深链的 HTML 站点，再将完整目录发布到静态托管。需要离线快照或报告时，可以在同一次生成中选择其它格式。

## 前提

- 已完成[首次生成教程](../tutorials/first-site.md)，后续命令从 `docdemo/` 项目根执行；当前目录含 `cjpm.toml` 和 `src/api.cj`。
- 已安装 `cjdoc`，并在当前终端加载仓颉 SDK 环境。
- 可选的 HTTP 阅读步骤需要 Python 3；检查 HTTP 响应的命令需要 `curl`。

## 生成 HTML 并找到 API

选择输出目录。下面只定义一次 `OUT`，你可以换成自己的路径；首次生成时让 cjdoc 创建这个目录，后面的命令沿用同一个值：

```bash
OUT=target/doc-publish
cjdoc generate --project . --format html --output "$OUT"
xdg-open "$OUT/html/index.html"
```

macOS 使用 `open "$OUT/html/index.html"`；Windows PowerShell 使用实际输出路径执行 `Start-Process`。如果目录已存在但不是 cjdoc 管理的输出，换一个尚不存在的目录，处理方法见[管理输出](manage-outputs.md)。

浏览器打开的是 `$OUT/html/index.html`。进入 `docdemo` 包和 `greet`，阅读签名、参数、返回与示例。点页眉的“搜索文档”打开搜索，输入 `greet`，打开匹配的声明；复制页面或成员链接，在新标签页打开，确认能直接回到对应位置。指南也可通过搜索和页面链接进入。

HTML 中的示例是作者写下的内容和预期输出。需要实际编译或运行它们时，使用[示例检查](check-examples.md)。

站点三栏布局：左侧是包、类型与成员的导航树（顶部输入框按名称筛选），中间是正文，宽屏右侧是本页目录。按 `Ctrl+K`（macOS 为 `⌘K`）或 `/` 打开搜索；右上角的“显示设置”可以切换主题、字体和字号，选择会保存在当前浏览器里，下次打开同一站点时保留。

## 指定站点字体

站点默认使用阅读者系统自带的字体。要让正文或代码优先使用某个字体，在生成时给出字体列表：

```bash
cjdoc generate --project . --format html --output "$OUT" \
  --html-font-sans '"Source Han Sans SC", system-ui, sans-serif' \
  --html-font-mono '"JetBrains Mono", ui-monospace, monospace'
```

刷新浏览器中的站点，正文和签名会改用列表中第一个已安装的字体。cjdoc 不下载字体文件；阅读者没有安装时按列表顺序回退，所以列表最后保留 `sans-serif` 或 `monospace` 这样的通用字体族。阅读者在“显示设置”里选了字体时，以阅读者的选择为准。

如果命令报 `invalid --html-font-sans value`，检查每一项是否只含字母、数字、空格、`_`、`-`，带空格的名字是否用双引号包住，整串是否超过 256 字节。报 `requires --format html` 时补上 `--format html`。

## 在本地通过 HTTP 阅读

静态站点可以直接用 `file://` 打开。如果要在 HTTP 下查看，在同一个终端从项目根启动服务器：

```bash
python3 -m http.server 8000 --bind 127.0.0.1 --directory "$OUT/html"
```

浏览器打开 `http://127.0.0.1:8000/`，再搜索并进入 `greet`。另开终端时，不需要重新设置 `OUT`，可以直接检查这个固定地址：

```bash
curl -fsS -o /dev/null http://127.0.0.1:8000/
```

退出码 `0` 表示首页返回成功。页面、搜索结果和声明深链都可阅读后，在服务器终端按 `Ctrl+C` 停止。如果端口被占用，在服务器命令和浏览器地址中同时改用空闲端口。

## 发布整个 HTML 目录

将 `$OUT/html/` 的**全部内容**上传到静态托管的文档根目录，保留子目录、文件名大小写和相对路径。不要只上传 `index.html`，也不要遗漏资源、搜索索引或 `agent/` 目录。cjdoc 生成文件，不替你上传或配置托管平台。

发布后从托管地址打开首页，搜索 `greet`，再直接打开一个声明或成员深链。若已[生成多语言站点](../tutorials/publish-languages.md)，上传共同的 `html/` 根，而不是只上传 `en/` 或 `zh-CN/`。

## 选择其它格式或一次生成六种格式

`--format` 可以重复。下面沿用同一个输出目录，用一次扫描生成站点、Markdown、快照和报告：

```bash
cjdoc generate --project . \
  --format html \
  --format markdown \
  --format json \
  --format api-surface \
  --format coverage \
  --format symbol-index \
  --output "$OUT"
```

| 输出根下的位置 | 你会得到什么 |
|---|---|
| `html/index.html` | 可直接打开或发布的站点 |
| `markdown/index.md` | Markdown 文档入口 |
| `docs.json` | 保存供以后重新渲染或查询的 Doc IR 快照 |
| `api-surface/api-surface.json` | 用于比较 API 的快照 |
| `coverage/coverage.json`、`coverage/quality.json` | 文档覆盖率与结构质量报告 |
| `symbol-index/symbol-index.json` | 供其它文档项目使用的符号索引 |

HTML 自己还会在 `html/` 内生成导航、搜索和符号索引文件。完整目录、各格式字段和多语言布局见[产物参考](../reference/artifacts.md)。重复生成会更新 cjdoc 管理的文件，并移除这次不再需要的旧产物；不要手工修改这些文件。

## 把单份 JSON 写入标准输出

要将快照交给管道或保存为单文件，选择一个 JSON 类格式并加 `--stdout`：

```bash
mkdir -p target
cjdoc generate --project . --format json --stdout > target/docdemo.docs.json
```

`target/docdemo.docs.json` 保存结构化文档，诊断仍写到标准错误。读取前先检查生成命令的退出码。`--stdout` 只支持单个 `json`、`api-surface`、`coverage` 或 `symbol-index` 格式，不能与 `--output`、`--force-owned` 或 `--all-languages` 同用。需要多个格式时改用目录输出。

## 遇到问题怎么办

- **没有 HTML**：显式加 `--format html`；省略格式时默认只生成 JSON。
- **打开的还是旧页面**：确认浏览器地址属于本页的 `$OUT/html/`，然后刷新。使用 HTTP 时确认服务器的 `--directory` 仍指向这个目录。
- **发布后搜索或资源不可用**：重新上传完整 `html/` 树，并确认托管平台保留路径大小写。
- **输出冲突或生成失败**：先读终端诊断和退出码。文件冲突见[管理输出](manage-outputs.md)，项目与参数问题见[按症状排错](troubleshoot.md)。

## 下一步

- [设置文档质量门槛](check-quality.md)。
- [编译并运行注释示例](check-examples.md)。
- [从保存的快照重新生成文档](render-snapshots.md)。
