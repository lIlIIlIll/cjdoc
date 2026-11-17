# 生成并发布文档

用一次源码扫描生成可直接打开、可搜索、可分享深链的静态站点，再把完整的 `html/` 目录上传到静态托管。

## 前提条件

- 已完成[生成第一个站点](../tutorials/first-site.md)，`docdemo/` 中有 `cjpm.toml` 和 `src/api.cj`。
- 当前终端能运行 `cjdoc`，并已加载仓颉 SDK 环境。
- 下面所有命令都在 `docdemo/` 项目根目录执行。
- 可选的 HTTP 阅读步骤需要 Python 3；检查 HTTP 响应需要 `curl`。

## 1. 生成 HTML 站点

先定义一次输出目录，后面的命令沿用同一个值：

```bash
OUT=target/doc-publish
cjdoc generate --project . --format html --output "$OUT"
```

`--format html` 必须显式给出。省略 `--format` 时默认只生成 `docs.json`，不会产生网页。

输出目录由 cjdoc 创建和管理。目录已经存在时必须是一个 cjdoc 先前生成的输出根，否则命令拒绝写入；处理方法见[管理输出](manage-outputs.md)。

**预期结果**

- 终端打印 `generated target/doc-publish`，退出码 `0`。
- `$OUT/html/index.html` 是站点入口，可以直接用 `file://` 打开，不需要服务器。
- `$OUT/html/` 内另有导航、搜索索引、样式表、符号索引、`llms.txt`、`validation.html` 和 `agent/` 目录等伴随文件。
- `$OUT` 根目录的 `.cjdoc-output.json` 记录本次生成的相对路径与摘要，不要手工编辑。

## 2. 阅读页面、搜索和深链

打开入口（Linux）：

```bash
xdg-open "$OUT/html/index.html"
```

macOS 用 `open "$OUT/html/index.html"`，Windows PowerShell 用 `Start-Process .\target\doc-publish\html\index.html`。

**预期结果**

- 从首页进入 `docdemo` 包和 `greet`，能看到签名、参数、返回值说明和作者写下的示例。
- 点页眉的“搜索文档”或按 `Ctrl+K`（macOS 为 `⌘K`）、`/` 打开搜索，输入 `greet` 能打开匹配声明。
- 复制页面或成员的链接，在新标签页打开，能直接回到同一位置。指南页同样可通过搜索和链接进入。

站点是三栏布局：左侧导航树按名称筛选包、类型和成员，中间是正文，宽屏时右侧是本页目录。右上角的“显示设置”切换主题、字体和字号，选择保存在当前浏览器中。

HTML 中的示例是作者写下的代码和预期输出，页面不显示逐例通过标记。需要实际编译或运行时，使用[示例检查](check-examples.md)。

## 3. 指定站点字体

站点默认使用阅读者系统自带的字体。要让正文或代码优先使用某个字体，生成时给出字体族列表：

```bash
cjdoc generate --project . --format html --output "$OUT" \
  --html-font-sans '"Source Han Sans SC", system-ui, sans-serif' \
  --html-font-mono '"JetBrains Mono", ui-monospace, monospace'
```

**预期结果**：新生成的 `style.css` 中出现这两个字体族列表；刷新浏览器后，正文和签名改用列表中第一个已安装的字体。

cjdoc 不下载字体文件。阅读者没有安装时按列表顺序回退，所以列表末尾保留 `sans-serif` 或 `monospace` 这样的通用字体族。阅读者在“显示设置”里选过字体时，以阅读者的选择为准。

## 4. 通过 HTTP 阅读

静态站点可以直接用 `file://` 打开。需要在 HTTP 下查看时，从项目根启动一个本地服务器：

```bash
python3 -m http.server 8000 --bind 127.0.0.1 --directory "$OUT/html"
```

浏览器打开 `http://127.0.0.1:8000/`，再搜索并进入 `greet`。另开终端时不需要重新设置 `OUT`，可以直接检查这个固定地址：

```bash
curl -fsS -o /dev/null http://127.0.0.1:8000/
```

**预期结果**：`curl` 以退出码 `0` 结束，说明首页返回成功；`__cjdoc/status.json` 这类只有 `serve` 提供的路径在这里会得到 `404`，属于正常现象。页面、搜索结果和声明深链都能阅读后，在服务器终端按 `Ctrl+C` 停止。

端口被占用时，在服务器命令和浏览器地址中同时改用空闲端口。

## 5. 发布整个 HTML 目录

把 `$OUT/html/` 的**全部内容**上传到静态托管的文档根目录，保留子目录、文件名大小写和相对路径。

- 不要只上传 `index.html`。
- 不要遗漏资源、搜索索引或 `agent/` 目录。
- cjdoc 只生成文件，不替你上传或配置托管平台。
- 已[生成多语言站点](../tutorials/publish-languages.md)时，上传共同的 `html/` 根，而不是只上传 `en/` 或 `zh-CN/`。

**预期结果**：从托管地址打开首页，搜索 `greet`，再直接打开一个声明或成员深链，都能正常显示。

## 6. 按需生成其它格式

`--format` 可以重复。用一次扫描生成站点、Markdown、快照和报告：

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

**预期结果**：输出根下出现下表位置的文件，诊断仍写到标准错误。

| 输出根下的位置 | 你会得到什么 |
|---|---|
| `html/index.html` | 可直接打开或发布的站点 |
| `markdown/index.md` | Markdown 文档入口 |
| `docs.json` | 保存供以后重新渲染或查询的 Doc IR 快照 |
| `api-surface/api-surface.json` | 用于比较 API 的快照 |
| `coverage/coverage.json`、`coverage/quality.json` | 文档覆盖率与结构质量报告 |
| `symbol-index/symbol-index.json` | 供其它文档项目使用的符号索引 |

重复生成会更新 cjdoc 管理的文件，并移除这次不再需要的旧产物；不要手工修改这些文件。完整目录、各格式字段和多语言布局见[产物参考](../reference/artifacts.md)。

## 7. 把单个 JSON 写入标准输出

需要把快照交给管道或保存为单文件时，选择一个 JSON 类格式并加 `--stdout`：

```bash
mkdir -p target
cjdoc generate --project . --format json --stdout > target/docdemo.docs.json
```

**预期结果**：`target/docdemo.docs.json` 是单个完整 JSON 文档，诊断只出现在标准错误。读取前先检查生成命令的退出码。

`--stdout` 只接受恰好一个 `json`、`api-surface`、`coverage` 或 `symbol-index` 格式，不能与 `--output`、`--force-owned` 或 `--all-languages` 同用。需要多个格式时改用目录输出。

## 失败时怎么办

| 看到的提示或现象 | 原因 | 处理 |
|---|---|---|
| 目录里没有 `html/` | 省略了 `--format`，只生成了 JSON | 显式加 `--format html`，重新生成 |
| `error: invalid --html-font-sans value`（或 `--html-font-mono`） | 字体名含不合法字符、名字未用双引号包住，或整串超过 256 字节 | 每项只保留字母、数字、空格、`_`、`-`；带空格的名字用双引号包住 |
| `error: --html-font-sans requires --format html` | 给了字体选项但没有生成 HTML | 同时加 `--format html` |
| `error: --stdout requires exactly one JSON-producing format` | 同时给了 HTML、Markdown 或多个格式 | 只保留一个 JSON 类格式 |
| `error: --stdout and --output are mutually exclusive` | 同一次命令里既重定向又指定目录 | 二选一 |
| 打开的还是旧页面 | 浏览器地址属于另一个输出目录，或该目录未被本次命令更新 | 确认打开的是本页 `$OUT/html/index.html` 后刷新；用 HTTP 时确认服务器的 `--directory` 指向这个目录 |
| 发布后搜索或资源不可用 | 只上传了部分文件，或托管平台改动了路径大小写 | 重新上传完整 `html/` 树 |
| 输出冲突或写入被拒绝 | 目录不是 cjdoc 生成的，或被其它进程锁定 | 见[管理输出](manage-outputs.md)，按提示处理锁与所有权 |

## 下一步

- [设置文档质量门槛](check-quality.md)。
- [编译并运行注释示例](check-examples.md)。
- [从保存的快照重新生成文档](render-snapshots.md)。
