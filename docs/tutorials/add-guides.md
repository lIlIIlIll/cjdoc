# 为同一个库加入首页与指南

把 `docdemo` 的 API 参考变成有阅读顺序的文档：项目首页解释用途，包概述介绍 API，指南通过稳定章节关联 `greet`。

## 前提与起点

完成[第一个站点](first-site.md)，起始目录为该教程创建的 `docdemo/`。保留完整 `cjpm.toml` 和 `src/api.cj`，SDK 1.2.0 环境和已安装的 `cjdoc` 仍有效。以下新增四个文本文件和一张小图片，不依赖 cjdoc 仓库里的 fixture。图片准备命令需要 Python 3。

## 1. 登记页面

在项目根创建 `cjdoc.toml`，完整内容为：

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

创建源文件目录：

```bash
mkdir -p docs/packages docs/images
```

`id` 与章节键用于后续语言、版本切换，不要把译文标题当作身份。完整键表见[配置参考](../reference/configuration.md)。

## 2. 写首页和包概述

完整 `docs/index.md`：

~~~markdown
# docdemo

用一个名字生成问候语，不改变名字里的空白。

![问候语文字示意](images/hello.png)

```cangjie
println(greet("Cangjie"))
```

从[开始使用](start.md)了解输入边界，再查看 API 参考。
~~~

完整 `docs/packages/docdemo.md`：

```markdown
# docdemo 包

这个包提供 `greet`，用于生成固定格式的问候字符串。

[第一次调用](../start.md)包含示例与输入边界。

<!-- cjdoc-bind target="docdemo.greet" -->
```

包概述第一段会显示在包页；链接进入完整概述。绑定目标必须是本次生成中实际存在、对当前受众可见且能唯一识别的声明。

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

首页中的相对图片路径以 `docs/index.md` 为基准。Linux 会安全捕获并复制该 PNG，发布后无需原始 `docs/` 源目录。不要改用 SVG 或任意文件扩展名：本地资产有格式和大小限制。当前 Windows 缺少等价的安全 no-follow 读取能力，会拒绝嵌入并给出 `CJDOC4026`，而不是冒险读取；本轮不声称 Windows 图片嵌入成功。

## 3. 写带章节与 API 绑定的指南

完整 `docs/start.md`：

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

## 4. 生成并沿两个方向阅读

在项目根执行：

```bash
cjdoc generate --project . --format html
xdg-open target/doc/html/index.html
```

确认项目首页有作者说明和“开始使用”入口；包页有概述；指南内“第一次问候”排在“名字的边界”之前，提示块可读，返回首页链接有效。指南关联 API 指向 `greet`，API 页面也能进入相关指南。打开 `target/doc/html/concepts/guides/start.html`，检查两个章节链接可直接定位。

若页面缺失，先检查 `source` 文件与大小写。指南文件缺失是错误；包概述或首页文件缺失可能出现自动占位，不能把占位当作自己的正文。章节映射值必须是实际存在的标题锚点；两个逻辑键不能指向同一个锚点。重复标题会获得不同后缀，应从生成页复制各自的真实链接，不能凭相同标题猜测。重复逻辑页、危险路由、不可见或歧义 API 绑定的状态见[状态与限制](../reference/states-and-limits.md)。不要通过删除诊断或扩大受众掩盖绑定错误。

`route` 只采用项目内的安全 `concepts/...` 相对路径，不能包含 `..`、查询串或 fragment。页面排序与其他配置规则以[配置参考](../reference/configuration.md)为准。

## 下一步

[为相同 API 和章节发布中文、英文](publish-languages.md)。
