# 为同一个库加入首页、包概述和指南

上一课生成的站点只有 API 列表。本页给同一个 `docdemo` 库加上项目首页、包概述和一篇指南，让读者先看到项目用途、再从指南了解用法，并能在 `greet` 的 API 页面和指南之间互相跳转。

**完成后你会得到**：`target/doc/html/index.html` 变成一页带说明和图片的项目首页，包页顶部出现你写的概述，指南页位于 `target/doc/html/concepts/guides/start.html`，两页都与 `greet` 互相链接。

## 前提条件

- 已完成[第一个站点](first-site.md)，在同一个 `docdemo/` 目录继续，保留现有的 `cjpm.toml` 和 `src/api.cj`。
- 当前终端里的 `cjdoc` 和仓颉 SDK 环境仍可用，`cjdoc --version` 输出 `cjdoc 0.7.8`。
- 生成图片的步骤需要 Python 3。

本页新增三个 Markdown 文件和一张小图片，然后添加一个 `cjdoc.toml`；不依赖 cjdoc 仓库里的示例文件。

## 1. 写项目首页

项目首页是读者进入站点后看到的第一篇概念文档。先建文档目录：

```bash
mkdir -p docs/packages docs/images
```

再新建完整 `docs/index.md`：

~~~markdown
# docdemo

用一个名字生成问候语，不改变名字里的空白。

![问候语文字示意](images/hello.png)

```cangjie
println(greet("Cangjie"))
```

从[开始使用](start.md)了解输入边界，再查看 API 参考。
~~~

首页正文里的 `start.md` 链接指向下一步要写的指南，`images/hello.png` 是接下来要生成的本地图片。相对图片路径以 `docs/index.md` 为基准；指向已登记概念页源文件的相对链接会被改写成输出路由。

### 生成一张可随站点发布的图片

仍在项目根执行。以下脚本用标准库直接写出一个 240×64 的纯色 PNG，不需要额外 Python 包，也不依赖网络：

```bash
python3 - <<'PY'
import struct, zlib
from pathlib import Path

width, height = 240, 64
raw = (b"\x00" + bytes([0x14, 0x6A, 0x54]) * width) * height

def chunk(kind, data):
    return (struct.pack(">I", len(data)) + kind + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))

png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw, 9))
       + chunk(b"IEND", b""))
Path("docs/images/hello.png").write_bytes(png)
PY
```

预期 `docs/images/hello.png` 存在且是 PNG 文件：`file docs/images/hello.png` 报告 `PNG image data, 240 x 64, 8-bit/color RGB, non-interlaced`。生成时 cjdoc 会把这个 PNG 复制进站点，所以发布后不需要再带原始 `docs/` 目录。

本地图片支持 PNG、JPEG、GIF、WebP 和 AVIF，不接受 SVG 或改名的其它文件，大小也有上限。Windows 上的图片读取能力受限，图片会被省略并报告 `CJDOC4026`，Markdown 替代文本仍然保留；格式与大小限制见[状态与限制](../reference/states-and-limits.md)。

## 2. 写包概述

包概述显示在 `docdemo` 包页顶部，第一段正文作为摘要。新建完整 `docs/packages/docdemo.md`：

```markdown
# docdemo 包

这个包提供 `greet`，用于生成固定格式的问候字符串。

[第一次调用](../start.md)包含示例与输入边界。

<!-- cjdoc-bind target="docdemo.greet" -->
```

`<!-- cjdoc-bind target="docdemo.greet" -->` 把这页概述关联到 `greet`。绑定目标必须是本次生成中实际存在、对当前受众可见且能唯一识别的声明；写错目标不会中断生成，而是打印 `warning[CJDOC2051]: unresolved conceptual API binding ...`，页面缺少“相关 API”关联。

## 3. 写带章节和 API 绑定的指南

指南把阅读顺序固定下来，并让同一份内容同时出现在指南页和 API 页面两侧。新建完整 `docs/start.md`：

~~~markdown
# 开始使用

## 第一次问候

```cangjie
println(greet("Cangjie"))
```

输出 `Hello, Cangjie!`。

> [!NOTE]
>
> 这里的示例用于阅读；需要编译和固定输出时，使用 API 注释中的 example 指令。

## 名字的边界

空字符串得到 `Hello, !`；空白原样保留。

[返回项目首页](index.md)。

<!-- cjdoc-bind target="docdemo.greet" -->
~~~

每个 `##` 小节都会得到页内锚点，`[!NOTE]` 渲染为带“注意”标题的提示块：标记独占引用块第一行，空行之后是正文。指南里的代码不会因为写在 Markdown 里就成为编译测试；API 注释示例的检查入口见[检查示例](../how-to/check-examples.md)，提示 marker、局部链接与重载绑定的完整规则见[指南语法参考](../reference/doc-comments.md#指南-markdown-与-api-绑定)。

## 4. 在配置里登记页面

三个文件写好后，在项目根新建 `cjdoc.toml`，告诉 cjdoc 哪里是首页、包概述和指南：

```toml
[docs]
index = "docs/index.md"

[docs.packages]
docdemo = "docs/packages/docdemo.md"

[[docs.pages]]
id = "start"
source = "docs/start.md"
route = "concepts/guides/start.html"
title = "开始使用"
kind = "guide"

[docs.pages.sections]
usage = "第一次问候"
boundaries = "名字的边界"
```

`[docs.pages.sections]` 左侧是你维护的稳定章节键，右侧是该页标题的短锚点：`usage` 对应“第一次问候”，`boundaries` 对应“名字的边界”。页面链接中 `#` 后面的部分选择页内位置，生成后的完整标题链接还包含 cjdoc 的前缀，形如 `standalone--doc-第一次问候`。中文标题的短锚点与标题文字相同；英文标题转为小写，空格替换为 `-`，例如 `First greeting` 对应 `first-greeting`。章节键可跨语言和版本保持不变，右侧锚点则随标题调整。

`id` 是页面的稳定标识，`route` 是它在站点里的地址，只能使用项目内的安全相对路径，且必须留在 `concepts/` 下（写 `guides/start.html` 会报 `error: conceptual page route must stay under concepts/`）；不能包含 `..`、查询串或 fragment。`id` 和 `route` 后续也用于语言和版本切换，凭的是配置里的值，而不是页面标题。`title` 可以省略，此时使用源文件的一级标题。所有键和限制见[配置参考](../reference/configuration.md)。

## 5. 生成并阅读新页面

在项目根生成站点并打开首页：

```bash
cjdoc generate --project . --format html
xdg-open target/doc/html/index.html
```

命令打印 `generated ./target/doc`，退出码 `0`。macOS 用 `open target/doc/html/index.html`，Windows 用 `Start-Process .\target\doc\html\index.html`。

预期看到的结果：

- 首页显示标题 `docdemo`、说明文字、问候语示意图、`cangjie` 代码块，以及“继续阅读 开始使用”入口；其中“语言未知”一类标记说明这页还没有语言标注，配置 `[i18n]` 后才会消失。
- 从首页“API 参考”打开 `docdemo` 包页（`target/doc/html/packages/docdemo/index.html`）。页面顶部显示包概述的第一段；点击“阅读完整包概述”打开 `concepts/packages/docdemo.html`。
- `target/doc/html/concepts/guides/start.html` 里“第一次问候”排在“名字的边界”之前，“注意”提示块有可见标题和正文，`返回项目首页` 链接打开概念文档索引。
- 指南页底部“相关 API”指向 `greet`，`greet` 的 API 页面里“相关指南”列出包概述和这篇指南。

每节标题都有自己的地址片段，生成后可以直接复制页面上的小节链接分享；完整片段包含 cjdoc 生成的前缀，不要手写猜测。

## 失败时怎么办

- **指南页没有生成，命令退出码 `2`**：`source` 指向的文件不存在或大小写不一致，错误信息是 `error: conceptual Markdown source does not exist: ...`。先创建文件，或改正路径。
- **首页显示自动生成的默认说明**：启用概念文档但 `docs/index.md` 不存在时，页面会用项目名和默认导航生成首页，`index` 指向的文件缺失不会报错；核对 `index` 路径与文件是否存在。
- **包页顶部没有你写的概述**：先确认 `[docs.packages]` 的路径和文件名正确；路径存在但概述没能通过 `cjdoc-bind` 唯一关联到该包时，包页只显示中立的默认说明。配置文件指向的文件不存在时同样不报错，容易误以为概述被忽略。
- **章节链接跳不到位置**：`sections` 右侧必须写页面里实际存在的标题锚点，且同一锚点只能被一个章节键使用。不满足时生成仍成功，但会打印 `warning[CJDOC3110]: page 'start' section 'usage' has no unique captured heading; mapping omitted`；重复标题会各自带上 `-1`、`-2` 后缀，应从生成后的页面复制真实链接。
- **指南没关联到 API**：确认 `cjdoc-bind` 目标是本次生成中实际存在、对当前受众可见且能唯一识别的声明，不要通过扩大受众掩盖绑定问题。页面绑定与路由冲突的状态见[状态与限制](../reference/states-and-limits.md)。
- **`route` 被拒绝**：`route` 必须是留在 `concepts/` 下的安全相对路径，错误信息是 `error: [[docs.pages]] route must be a safe relative path` 或 `error: conceptual page route must stay under concepts/`，命令以 `2` 退出且不写出新站点。

## 下一步

[为相同 API 和章节发布中文、英文](publish-languages.md)。
