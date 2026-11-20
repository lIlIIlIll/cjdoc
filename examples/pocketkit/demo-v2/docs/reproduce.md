# 复现与本地生成 / Reproduce and author locally

本页给维护者用：从头重建本展示站，或在本地边改边预览。只想调用 PocketKit 的话，从
[目录与资源入门](guide.md)开始。

## 下载与复现

从展示页的「源码、配置与离线目录」下载 PocketKit 源码压缩包并解压。保留以下目录关系：

```text
source.json
examples/pocketkit/reproduce.py
examples/pocketkit/demo-v1/
examples/pocketkit/demo-v2/
examples/pocketkit/support-v1/
examples/pocketkit/diagnostics/
examples/pocketkit/check-modes/
```

`source.json` 记录生成器仓库的准确 revision；安装或编译该 revision 的 cjdoc，
不要将示例包版本、Doc IR schema 版本当成工具版本。调用者还需要 Cangjie SDK **1.2.0**。

在解压根目录执行，并把 cjdoc 换成你的可执行文件路径：

```sh
source /path/to/cangjie/envsetup.sh
cjc -v
cjpm -v
python3 examples/pocketkit/reproduce.py \
  --cjdoc /absolute/path/to/cjdoc --output ./generated --locale both
```

`generated` 必须尚不存在；脚本不会删除已有目录。它先生成固定 `support-v1` 索引，
再生成同库两个版本的中英文 HTML、JSON、Markdown、coverage 和 API diff，最后组合版本。
打开 `generated/composed/index.html`，在版本页选择 English 或中文。
该目录包含核心 API 页面与原始报告；展示首页和可读报告包装层由仓库的 Pages 构建再加。

`generated/check-modes/native-check.json` 是一次独立 `check --check-examples` 命令的证据，
覆盖只编译、运行并比对输出、预期编译失败和无代码跳过。它只说明整次命令的结果，不逐例断言。
诊断项目保留缺失与歧义引用的原生诊断和源码范围。

## 本地启动

先按上面的步骤生成依赖索引，再进入某个示例版本的目录：

```sh
cjdoc serve --project . --port 8080
```

访问 [本地预览 / Local preview](http://127.0.0.1:8080)。修改注释或指南后，serve 会重新生成。
`/__cjdoc/status.json` 提供构建状态，可用来确认这次修改确实重建成功。
静态 GitHub Pages 不运行编译器或常驻服务器，只发布已生成的页面。

[返回使用入门 / Back to the usage guide](guide.md)

## 文档演示的来源与边界

类型页的行为说明是库作者提供的契约，cjdoc 的语义补充不构成行为证明。
同名类型与外部字段的演示使用固定版本的 `pocket_support` 文档索引：本库的 `Stamp`
和依赖中的 `pocket_support.Stamp` 保持独立，`pocket_support.SourceLabel.text` 的目标也由该索引确定。
复现脚本先为 `support-v1` 生成索引，再生成两个教学快照；直接生成单个项目且未准备索引时，
外部参考会明确显示不可用。API 本身的源码、签名和作者契约仍然保留。
