# 目录与资源入门 / Catalogue and lifetime

先创建目录，追加文本，再按位置读取。显式绑定的是 **String 重载**，不是同名的整数重载。
Create a catalogue, append a string, and read the first entry. The binding below selects the **String overload**.

<!-- cjdoc-bind target="pocketkit.TextCatalog.add" selector="signature:public func add(value: String): Unit" provenance="docs/guide.md" version="demo-v2" -->

```cangjie
import pocketkit.*
main() {
    let catalog = TextCatalog()
    catalog.add("hello")
    assert(catalog.at(0) == "hello")
}
```

从关联 API 进入具体重载后，通过该成员的相关指南回到这里。
这是页面与 API 的关联，不是完整外置契约合并。源码中的 @example 有真实执行报告；
不能凭指南中存在代码块声称它被执行过。

Follow the explicit API binding and return via the member's related guide. This is a page association,
not a complete external-contract merge. Execution evidence belongs to the source @example, not to this Markdown fence.

## 阅读器责任 / Reader ownership

<!-- cjdoc-bind target="pocketkit.io.TextReader.read" selector="member" provenance="docs/guide.md" version="demo-v2" -->

从 openText 的返回类型进入 TextReader，再查看其 Readable 接口。关闭是幂等的，
关闭后读取会抛出异常。阅读器只管理内存会话，不管理文件描述符。

Follow openText → TextReader → Readable. The caller owns the in-memory session; close is idempotent,
and reading a closed session throws. There is no operating-system file descriptor to close.

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
中英文 HTML、JSON、Markdown、coverage、doctest、API diff，并调用原生版本组合。
入口为 `generated/zh-CN/composed/index.html` 和 `generated/en/composed/index.html`。
该目录包含核心 API 页面与原始报告；展示首页和可读报告包装层由仓库的 Pages 构建生成。

The output directory must not exist. Open the composed index for either language.
Core APIs and native reports are reproducible here; the showcase homepage and report presentation
are added by the repository's Pages build.

`generated/check-modes/native-check.json` 保存独立的 `check --check-examples` 命令证据，
包括只编译、运行并比对输出、预期编译失败和无代码跳过的输入。它是整体检查结果，
不冒充原生逐例状态。各版本 `doctest/results.json` 单独记录旧 doctest 管线的运行和跳过；
诊断项目故意错误的示例仍是 failed。

Directive checks provide aggregate command evidence, while the legacy doctest report retains
its actual per-example run/skip/failure results. A guide code fence is not execution evidence.

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

[返回项目指南 / Project guide](index.md)
