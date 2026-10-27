# 复现与本地生成 / Reproduce and author locally

本页面向需要从头复现本展示站或在本机生成文档的维护者。使用 PocketKit 的调用者请从
[目录与资源入门 / Catalogue and lifetime](guide.md) 开始。
This page is for maintainers who reproduce this showcase or generate docs locally.
API callers should start from the catalogue guide.

## 下载与复现 / Download and reproduce

从展示页的“源码和配置”下载链接保存 PocketKit 源码压缩包并解压。保留以下目录关系：
Download and extract the source archive from the showcase downloads page. Keep its layout intact:

```text
source.json
examples/pocketkit/reproduce.py
examples/pocketkit/demo-v1/
examples/pocketkit/demo-v2/
examples/pocketkit/support-v1/
examples/pocketkit/diagnostics/
examples/pocketkit/check-modes/
```

使用 Cangjie SDK **1.2.0**，加载 SDK 的 `envsetup.sh`，并确认 `cjc -v` 与 `cjpm -v`。
`source.json` 记录生成器仓库的准确 revision；安装或编译该 revision 的 cjdoc，
不要将示例包版本、Doc IR schema 版本当成工具版本。

Use SDK **1.2.0** and the cjdoc repository revision recorded in `source.json`.
Run these commands from the archive root; replace the cjdoc path with your installed executable:

```sh
source /path/to/cangjie/envsetup.sh
cjc -v
cjpm -v
python3 examples/pocketkit/reproduce.py \
  --cjdoc /absolute/path/to/cjdoc --output ./generated --locale both
```

`generated` 必须尚不存在。脚本先生成固定 `support-v1` 索引，再生成同库两个版本的
中英文 HTML、JSON、Markdown、coverage、API diff，并调用原生版本组合。
入口为 `generated/composed/index.html`；在版本页选择 English 或中文。
该目录包含核心 API 页面与原始报告；展示首页和可读报告包装层由仓库的 Pages 构建生成。

The output directory must not exist. Open the composed index for either language.
Core APIs and native reports are reproducible here; the showcase homepage and report presentation
are added by the repository's Pages build.

`generated/check-modes/native-check.json` 保存独立的 `check --check-examples` 命令证据，
包括只编译、运行并比对输出、预期编译失败和无代码跳过的输入。它是整体检查结果，
不冒充原生逐例状态。诊断项目保留缺失与歧义引用的原生诊断和源码范围；
其中的故意错误代码仅作为文档内容展示，不宣称已经执行。

Directive checks provide aggregate command evidence, not per-example results.
A guide code fence or a documented invalid example is not execution evidence.

## 本地启动 / Local authoring

先完成上面的复现步骤以生成依赖索引，再在此示例版本的目录内执行：
After reproduction creates the dependency index, run this in the selected example version directory:

```sh
cjdoc serve --project . --port 8080
```

访问 [本地预览 / Local preview](http://127.0.0.1:8080)。修改注释或指南后，serve 会重新生成。
`/__cjdoc/status.json` 提供构建状态。静态 Pages 不运行编译器或常驻服务器。

Visit the local URL and edit a comment to trigger rebuilding. The status endpoint reports build state.
Static GitHub Pages does not run this compiler or server.

[返回使用入门 / Back to the usage guide](guide.md)

## 文档演示的来源与边界

类型页的行为说明是库作者提供的契约，cjdoc 的语义补充不构成行为证明。
同名类型与外部字段的演示使用固定版本的 `pocket_support` 文档索引：本库的 `Stamp`
和依赖中的 `pocket_support.Stamp` 保持独立，`pocket_support.SourceLabel.text` 的目标也由该索引确定。
复现脚本先为 `support-v1` 生成索引，再生成两个教学快照；直接生成单个项目且未准备索引时，
外部参考会明确显示不可用。API 本身的源码、签名和作者契约仍然保留。
