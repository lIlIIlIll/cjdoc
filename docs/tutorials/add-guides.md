# 为同一个库加入首页、包概述和指南

让读者从项目首页了解 `docdemo`，再从包概述或上手指南进入 `greet` 的 API 页面。完成后，指南也会出现在 `greet` 的相关文档中。

## 前提条件

在[第一个站点](first-site.md)创建的 `docdemo/` 中继续，保留 `cjpm.toml` 和 `src/api.cj`，并在已加载 SDK 的终端运行 `cjdoc`。制作本地示意图时另需 Python 3。

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

```output
Hello, Cangjie!
```

从[开始使用](start.md)了解输入边界，再查看 API 参考。
~~~

下一步创建图片；`start.md` 链接指向本页稍后编写的指南。相对路径从 `docs/index.md` 算起。登记为页面的 Markdown 链接会指向生成的网页。

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

生成站点时，cjdoc 会从 `docs/images/hello.png` 读取图片并随页面发布。Windows 上如果看到 `CJDOC4026`，图片被省略，替代文本仍会保留。支持的图片格式和大小见[状态与限制](../reference/states-and-limits.md)。

## 2. 写包概述

包概述显示在 `docdemo` 包页顶部，第一段正文作为摘要。新建完整 `docs/packages/docdemo.md`：

```markdown
# docdemo 包

这个包提供 `greet`，用于生成固定格式的问候字符串。

[第一次调用](../start.md)包含示例与输入边界。

<!-- cjdoc-bind target="docdemo.greet" -->
```

`cjdoc-bind` 把包概述和 `greet` 关联起来。目标必须出现在本次生成的文档中并能唯一识别，否则会看到 `CJDOC2051`，页面不会建立该关联。

## 3. 写带章节和 API 绑定的指南

新建 `docs/start.md`，写一篇有两个小节的指南：

~~~markdown
# 开始使用

## 第一次问候

```cangjie
println(greet("Cangjie"))
```

```output
Hello, Cangjie!
```

> [!NOTE]
>
> 这里的示例用于阅读；需要编译和固定输出时，使用 API 注释中的 example 指令。

## 名字的边界

空白原样保留；空字符串得到以下结果：

```cangjie
println(greet(""))
```

```output
Hello, !
```

[返回项目首页](index.md)。

<!-- cjdoc-bind target="docdemo.greet" -->
~~~

`[!NOTE]` 要单独写在引用块第一行，后面空一行再写正文。这里的代码供阅读；要编译它，请把片段放进 API 注释的 `@example`，再用[示例检查](../how-to/check-examples.md)。重载绑定和提示的写法见[指南 Markdown 参考](../reference/doc-comments.md#指南-markdown-与-api-绑定)。

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

`id` 用来标识同一篇指南，`route` 是生成地址，必须留在 `concepts/` 下。`[docs.pages.sections]` 左侧是稳定章节键，右侧是标题对应的短锚点。以后翻译指南时可以沿用 `usage` 和 `boundaries`，只改右侧的锚点。规则见[配置参考](../reference/configuration.md)。

## 5. 生成并阅读新页面

```bash
cjdoc generate --project . --format html
```

打开 `target/doc/html/index.html`。首页应显示项目介绍、图片和「开始使用」链接。点进指南，在「相关 API」打开 `greet`；`greet` 页上的「相关指南」应该能跳回来。从包页点「阅读完整包概述」，会打开 `concepts/packages/docdemo.html`。

分享小节时，复制页面上的标题链接。完整片段包含页面生成时加上的前缀，不要从小节文字手拼。

## 失败时怎么办

| 看到什么 | 怎么处理 |
|---|---|
| `conceptual Markdown source does not exist` | 确认 `[[docs.pages]].source` 对应文件已创建，路径和大小写都以项目根为准 |
| 首页或包页没有自定义说明 | 核对 `[docs].index` 或 `[docs.packages]` 的文件；这两类文件缺失时可能回退到默认说明 |
| `CJDOC2051`，指南关联不到 `greet` | 核对限定名、所选受众及目标是否唯一；重载要使用签名选择器 |
| `CJDOC3110`，章节跳不到对应位置 | 核对右侧锚点是否唯一且存在；重复标题时从生成页确认带后缀的锚点 |
| `route` 被拒绝 | 使用 `concepts/` 下的安全相对路径，不带 `..`、查询串或 `#` |

## 下一步

[为同一份 API 和指南发布中英文](publish-languages.md)。
