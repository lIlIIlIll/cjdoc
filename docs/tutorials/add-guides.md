# 为同一个库加入首页、包概述和指南

加上首页和指南后，`docdemo` 的站点不再只有 API 列表：读者先看到项目用途，再从包概述和指南了解怎么用，并能从 `greet` 的 API 页面跳回相关指南。

## 前提

- 已完成[第一个站点](first-site.md)，在同一个 `docdemo/` 目录继续，保留现有的 `cjpm.toml` 和 `src/api.cj`。
- 当前终端里的 `cjdoc` 和仓颉 SDK 环境仍可用。
- 准备图片的步骤需要 Python 3。

下面新增三个 Markdown 文件和一张小图片，不依赖 cjdoc 仓库里的示例文件。

## 1. 写项目首页

项目首页是读者进入站点后看到的第一篇概念文档。先创建文档目录：

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

首页正文里的 `start.md` 链接指向后面要写的指南，`images/hello.png` 是接下来要生成的本地图片。

### 准备可随站点发布的本地图片

仍在项目根执行。以下固定内容生成完整的 `docs/images/hello.png`，图片只显示问候语文字，不是界面截图，不需要额外 Python 包：

```bash
python3 - <<'PY'
import base64
from pathlib import Path
encoded = "iVBORw0KGgoAAAANSUhEUgAAAPAAAABACAMAAAATQQrVAAAAIVBMVEXt8upIVk8lNi+bpZ3S2NBib2i9xb06SkN+ioMzQzx3g3sn1dvwAAACWUlEQVRo3u2X67ajIAyFhSQgvP8DTxBQEM7pZaozXWt/P1qrNrBjbi4LAAAAAAAAAAAAAAAAgK/AWBqO2qusn2LdY0Mk3lojT9zZ/smu26fMLslLpm4W7FStNybY17aZBbvvE+xUKG8HEl5Z3VGyzDSx/38L9sfuaPkMZM1Ngp0mYyi52Asmo1k6E0S2f66ONLirDbJxWb31a73Z6CWmbbU+pDn6Y4HbBFMqPaqMBsF6UiRYw4MROYWfqIndhsam0d81u9OB+CCN4BK9mhde9vvuEuxsSOpc2ES2giXvQCa55U/Z4LgI4OzBlN+cLVJ2mNhBMOdTvDv+qhw+oMYBKRA7wZy3v3+3WDvN3FhEBV52cdU3o+BYUyo79jrBprBtQeXk87wt2wjeQ2xS3OxQ1RwpNWxrjEpjfwxpXx2Zb7mpSrvjefuzYGm32jGEtC824lJjpRhw1W3rULSaUOPtZLxHcKDK84JPeZ2ykXepzwtuV9aS/akG96vgPeTquTGkJ4JPbalKXEfB05DOgsMzA+zHBZ8y9OeixdyWrn7woGLDj4Jr9LMdBMtFSftAsKsVlyZtiY99SZdi/WhJtYFNBD9sS6ngZUu3hPTWNrX966R0yuHUIMMxeIhdWzP9y0Ma1XReixPBvw8eYVtZmtuvF7xwmpGMbGXn59HSn7tx+3rI0ajXuC9adYDMo2UcBS+8muRtKm37mknrTfhv/W/K3HVN3H4eGsetJ8n/W2uaf4vg9zGap+l9TB+wRnB412/fQ871mIRqM7ul9QIAAAAAAAAAAAAAAP49fwB/nw4S0PUz4gAAAABJRU5ErkJggg=="
Path("docs/images/hello.png").write_bytes(base64.b64decode(encoded, validate=True))
PY
```

首页里的相对图片路径以 `docs/index.md` 为基准。生成时 cjdoc 会把这个 PNG 复制进站点，所以发布后不需要再带上原始 `docs/` 目录。本地图片支持 PNG、JPEG、GIF、WebP 和 AVIF，不接受 SVG 或改名的其它文件，大小也有上限。Windows 上的图片读取能力受限，图片会被省略并报告 `CJDOC4026`，Markdown 替代文本仍然保留；格式与大小限制见[状态与限制](../reference/states-and-limits.md)。

## 2. 写包概述

包概述会显示在 `docdemo` 包页顶部，第一段正文作为摘要。新建完整 `docs/packages/docdemo.md`：

```markdown
# docdemo 包

这个包提供 `greet`，用于生成固定格式的问候字符串。

[第一次调用](../start.md)包含示例与输入边界。

<!-- cjdoc-bind target="docdemo.greet" -->
```

`<!-- cjdoc-bind target="docdemo.greet" -->` 把这份概述关联到 `greet`。绑定目标必须是本次生成中实际存在、对当前受众可见且能唯一识别的声明。

## 3. 写带章节与 API 绑定的指南

指南把阅读顺序固定下来，并让同一份内容同时出现在指南和 API 页面两侧。新建完整 `docs/start.md`：

~~~markdown
# 开始使用

## 第一次问候

```cangjie
println(greet("Cangjie"))
```

输出 `Hello, Cangjie!`。

> [!NOTE]
> 这里的示例用于阅读；需要编译和固定输出时，使用 API 注释中的 `@example` 指令。

## 名字的边界

空字符串得到 `Hello, !`；空白原样保留。

[返回项目首页](index.md)。

<!-- cjdoc-bind target="docdemo.greet" -->
~~~

指南代码不会因出现在 Markdown 中就自动成为编译测试。API 注释示例的检查入口见[检查示例](../how-to/check-examples.md)；提示 marker、局部链接与重载绑定的完整规则见[指南语法参考](../reference/doc-comments.md#指南-markdown-与-api-绑定)。

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

`[docs.pages.sections]` 左侧是你维护的稳定章节键，右侧是该页标题的短锚点：`usage` 对应“第一次问候”，`boundaries` 对应“名字的边界”。页面链接中 `#` 后面的部分选择页内位置，生成后的完整标题链接还包含 cjdoc 的前缀。中文标题的短锚点与标题文字相同；英文标题转为小写，空格替换为 `-`，例如 `First greeting` 对应 `first-greeting`。章节键可跨语言和版本保持不变，右侧锚点则随标题调整。

`id` 是页面的稳定标识，`route` 是它在站点里的地址。两者后续也用于语言和版本切换，凭的是配置里的值，而不是页面标题。所有键和限制见[配置参考](../reference/configuration.md)。

## 5. 生成并阅读新页面

在项目根生成站点并打开首页：

```bash
cjdoc generate --project . --format html
xdg-open target/doc/html/index.html
```

生成后确认这些结果：

- 首页显示项目说明和“开始使用”入口，问候语示意图正常显示。
- `docdemo` 包页顶部有包概述和“阅读完整包概述”入口。
- `target/doc/html/concepts/guides/start.html` 里“第一次问候”排在“名字的边界”之前，提示块可读，返回首页链接有效。
- 指南页的“相关 API”指向 `greet`，`greet` 的 API 页面也能进入相关指南。

每节标题都有自己的地址片段，生成后可以直接复制页面上的小节链接分享；完整片段包含 cjdoc 生成的标题前缀，不要手写猜测。

## 遇到问题怎么办

- **指南页没有生成**：检查 `source` 指向的文件是否存在，路径大小写是否一致。指南源文件缺失会让生成报错。
- **首页显示自动生成的默认说明**：启用概念文档但 `docs/index.md` 不存在时，页面会用项目名生成默认首页；核对 `index` 路径与文件是否存在。
- **包页没有显示你写的概述**：先确认 `[docs.packages]` 的路径和文件名正确；路径存在但概述没能通过 `cjdoc-bind` 唯一关联到该包时，包页顶部不显示概述。配置文件指向的文件不存在时不会报错，页面会回退为中立的默认包说明，容易误以为概述被忽略。
- **章节链接跳不到位置**：`sections` 右侧必须写页面里实际存在的标题锚点。两个不同的章节键不能指向同一个锚点；重复标题会各自带上 `-1`、`-2` 后缀，应从生成后的页面复制真实链接。
- **指南没关联到 API**：确认 `cjdoc-bind` 目标是本次生成中实际存在、对当前受众可见且能唯一识别的声明，不要通过扩大受众掩盖绑定问题。页面绑定与路由冲突的状态见[状态与限制](../reference/states-and-limits.md)。

`route` 只能使用项目内的安全 `concepts/...` 相对路径，不能包含 `..`、查询串或 fragment。

## 下一步

[为相同 API 和章节发布中文、英文](publish-languages.md)。
