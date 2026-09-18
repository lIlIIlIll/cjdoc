# 常用用法

这篇说明从源码注释到文档产物的常用操作。你需要先把 `cjdoc` 加入 `PATH`，并在一个包含 `cjpm.toml` 的项目根目录中运行命令。

## 生成 HTML 和 Markdown

HTML 适合直接在浏览器中查看，Markdown 适合提交到仓库或接入现有文档站点。两种格式可以一次生成：

```bash
cjdoc generate --project . \
  --format html \
  --format markdown
```

主要文件位于：

```text
target/doc/html/index.html
target/doc/markdown/index.md
```

打开 `target/doc/html/index.html` 就能查看 HTML 站点。它是静态文件，不需要启动服务器。

## GitHub 源码链接与 HTML 站点

生成源码链接需要显式提供 canonical GitHub HTTPS 仓库根、revision 和可选仓库根目录：

```bash
cjdoc generate --project . --format html \
  --repository-url https://github.com/<owner>/<repo> \
  --repository-revision <commit-or-ref> --repository-root .
```

`repository-url` 与 `repository-revision` 必须成对出现；`repository-root` 只能用于 `generate`，不能用于 `render` 或 `check`。不能证明源码文件位于仓库内时，页面省略 View source action，不生成猜测链接。HTML 站点可直接通过 `file://` 打开，包索引、声明页、搜索类别、主题和移动端抽屉均使用本地资源。

## 写文档注释

把 `/** ... */` 放在声明前面。普通的 `//` 和 `/* ... */` 注释不会绑定到声明。

````cangjie
/**
 * 从文本中读取一个整数。
 *
 * 这里是补充说明，会显示在 summary 后面。
 *
 * @param text 要读取的文本。
 * @return 读取到的整数。
 * @throws IllegalArgumentException 文本不是合法整数时抛出。
 * @since 0.1.0
 */
public func parse(text: String): Int64 {
    return 42
}
````

正文的第一段是 summary，后面的段落是 description。当前支持的结构化标签如下：

| 标签 | 用途 |
|---|---|
| `@param` | 说明参数 |
| `@return` | 说明返回值 |
| `@throws` | 说明可能抛出的异常 |
| `@see` | 添加相关 API 引用 |
| `@since` | 标记 API 引入的版本 |
| `@deprecated` | 标记不再建议使用的 API |
| `@author` | 记录作者 |
| `@version` | 记录 API 版本 |
| `@example` | 添加带可选标题的代码示例 |

`@example` 后可以写标题，随后使用 Markdown fenced code block 放置示例代码；示例会在 HTML 的“示例”区域单独渲染，在 Markdown 输出中保留代码围栏：

````cangjie
/**
 * 计算两个整数的和。
 *
 * @example 基本用法
 * ```cj
 * let result = add(1, 2)
 * ```
 *
 * @param left 左侧数值。
 * @param right 右侧数值。
 * @return 两数之和。
 */
````

示例内容会持续到下一个顶层结构化标签（例如 `@param` 或 `@return`）；代码围栏内部出现的 `@param` 等文本会保持为示例代码，不会被误解析成文档标签。

文档页的“声明详情”会把源码能够识别的继承、扩展和 `override` 关系投影为导航链接。目标在当前文档集中且匹配唯一时，JSON/HTML 使用稳定 `SymbolId`；目标缺失或不唯一时保留原始显示并标记 `unavailable` 或 `ambiguous`，不会生成猜测链接。AST fallback 只生成同一模块内可证明的反向 `subType`、`extendedBy` 关系；没有 provider 可靠目标时，AST fallback 的 `override` 保持 `unavailable`。

文档注释应紧邻它描述的声明。默认生成 external 文档，所以示例声明应为 `public` 或 `protected`。

## 重新生成文档

修改注释后，再运行原来的命令：

```bash
cjdoc generate --project . --format html
```

然后刷新 `target/doc/html/index.html`。默认缓存放在 `target/cjdoc/cache/source-v8`，通常不需要手动处理。

## 检查文档问题

`check` 只检查源码、声明绑定、引用和 lint，不生成 HTML 或 Markdown：

```bash
cjdoc check --project .
```

准备提交或发布前，可以提高 lint 要求，并把 warning 也视为失败：

```bash
cjdoc check --project . \
  --lint-profile strict \
  --deny-warnings
```

退出码含义如下：

| 退出码 | 含义 |
|---:|---|
| `0` | 没有被当前规则拒绝的诊断 |
| `1` | 存在 error，或 warning 被 `--deny-warnings` 提升 |
| `2` | CLI 参数或输入错误 |

## 生成 JSON

JSON 适合交给其他工具处理，默认文件是 `target/doc/docs.json`：

```bash
cjdoc generate --project . --format json
```

如果要把 JSON 直接交给管道，使用 `--stdout`：

```bash
cjdoc generate --project . --format json --stdout > docs.json
```


`--stdout` 只能与一个 JSON 格式一起使用。诊断写入 stderr，所以重定向后的 `docs.json` 仍是单个 JSON 文档。

## 运行 doctest

`@example` 标签中的 ` ```cj ` 或 ` ```cangjie ` fenced code 可以选择性执行。项目根的 `cjdoc.toml` 使用独立的 `[doctest]` 表：

```toml
[doctest]
mode = "warn"       # off（默认）、warn 或 deny
timeout-ms = 2000
memory-mb = 2048    # Cangjie native backend requires at least 2048 MiB
jobs = 1
```

`warn` 会继续生成并返回 `0`，`deny` 在编译失败、运行失败或超时后返回 `1`。生成目录会增加 `doctest/results.json`，其版本为 `cjdoc.doctest/1`；`check` 会执行检查但不写 artifact。每个代码块在独立工作目录编译和运行，命令通过参数数组传递，不经过 shell。启用 doctest 时不能使用 `--stdout`，因为该选项必须保持单一 JSON 输出。

## 生成 API surface 和 coverage

用 `api-surface` 保存公开 API 的稳定快照：

```bash
cjdoc generate --project . --format api-surface --stdout > api-surface.json
```

用 `diff` 比较两个 API snapshot。它先按稳定 symbol id 匹配，再用模块、包、owner、kind、name 做唯一回退匹配；证据不足时报告 `potentially-breaking`，不会假装已经证明 breaking：

```bash
cjdoc diff --baseline api-surface.json --current api-surface-next.json --format text --deny-breaking-api --deny-potentially-breaking-api
```

默认只报告差异并返回 `0`。显式 deny 选项分别把 breaking 或证据不足的 potentially-breaking 变更变成失败；`--format json` 输出 `cjdoc.api-diff/1` 报告，适合 CI 采集。v1 API snapshot 仍可作为只读 baseline 输入；当前生成器只生成 v2。

用 `coverage` 查看当前版本的文档覆盖率。输出版本为 `cjdoc.documentation-coverage/2`，包含 symbols、parameters、returns、throws、examples、deprecated、semanticLinks 七类总览，并按 package/module 给出确定性分组：

```bash
cjdoc generate --project . --format coverage --stdout
```

兼容读取旧 coverage artifact 时使用 `cjdoc schema documentation-coverage-v1`；生成器不会覆盖或重写 v1 schema。当前 coverage 默认使用 `external` audience。需要把它们接入 CI 时，见 [`docs/advanced-usage.md`](advanced-usage.md#在-ci-中检查-api-和文档覆盖率)。

质量规则和覆盖率门禁写在项目根的 `cjdoc.toml`：

```toml
[lint]
severity = "warning"
missing-example = "off"
broken-link = "error"

[coverage]
symbols = 90
parameters = 95
semantic-links = 100

[coverage.package.basic]
symbols = 100
```

规则支持 `off`、`warning`、`error`；覆盖率阈值为 0–100，package 表只覆盖同名包，未设置的指标继承全局阈值。

用 `symbol-index` 导出面向工具和 agent 的稳定导航索引：

```bash
cjdoc generate --project . --format symbol-index --stdout > symbol-index.json
```

输出版本为 `cjdoc.symbol-index/1`。每个可见声明包含稳定 `id`、源码范围、HTML 路由、语义关系和 `@see` 引用；无法唯一解析的目标保留状态而不伪造 `targetId`。索引也可与 HTML 一起生成，文件位于 `target/doc/html/symbol-index.json`；单独生成仍位于 `target/doc/symbol-index/symbol-index.json`，后者适合作为外部文档 resolver 的本地输入。

## Agent-readable navigation and context

生成 HTML 时，站点会同时写入两个不依赖 HTML 解析的机器入口：

- `html/navigation-index.json`：项目、包、声明和概念页的稳定页面目录，版本为 `cjdoc.navigation-index/1`；每条声明记录 `symbolId`、HTML 路由、package/module 和显式 semantic state。
- `html/llms.txt`：有界的摘要索引，使用相对链接指向页面，适合 agent 先枚举再读取。

需要包含签名、参数、返回值、throws、示例和概念 Markdown 时，显式启用完整索引：

```bash
cjdoc generate --project . --format html --agent-full
```

这会额外生成 `html/llms-full.txt`。两个文本文件、导航 JSON 和 symbol index 都由同一份 Doc IR 直接生成，按当前 audience 过滤，不会把 private 声明或猜测的摘要暴露给工具。缺失、partial 和 unavailable 语义状态会原样保留；输出有固定大小和条数上限，并且重复生成保持确定性。

`navigation-index.json` 的 schema 可用下面的命令读取：

```bash
cjdoc schema navigation-index > navigation-index.schema.json
```

`llms.txt` 和 `llms-full.txt` 的链接是相对路径，版本组合器复制它们后仍可通过 `file://` 使用。

## Conceptual documentation

项目根目录下存在 `docs/`，或配置了 `cjdoc.toml` 的 `[docs]` / `[[docs.pages]]` 时，cjdoc 会把面向用户的概念文档发布到 `concepts/`。`docs/index.md` 是项目指南；模块和包页面会从当前 Doc IR 生成。额外页面使用受限的相对路径配置：

```toml
[docs]
index = "docs/index.md"

[[docs.pages]]
source = "docs/guides/start.md"
route = "concepts/guides/start"
title = "Getting started"
```

HTML 和 Markdown 概念页都会链接回 API 参考；HTML 会转义原始 HTML，并默认不把远程 Markdown 链接变成可点击的外链。概念页也会加入 `html/search-index.json`，类型为 `concept`。

## 本地 serve/watch

开发时可以启动 loopback-only 静态服务，并在源码、Markdown 或配置变更后自动重新生成：

```bash
cjdoc serve --project . --port 8080
```

服务只绑定 `127.0.0.1`。使用 `--open` 请求系统默认浏览器打开站点；`/__cjdoc/status.json` 返回构建次数、成功构建次数和最近一次错误。构建失败时服务继续提供最近一次成功的站点，直到进程退出。

## 发布多个本地文档版本

先为每个版本生成独立、可复制的 HTML 目录，并用 `--doc-version` 写入版本元数据：

```bash
cjdoc generate --project . --format html --doc-version 1.3.0 --output target/docs-1.3
```

然后只用本地目录组合静态站点：

```bash
cjdoc versions compose --version 1.2.0=target/docs-1.2/html --version 1.3.0=target/docs-1.3/html --label 1.3.0=Current --channel 1.2.0=stable --channel 1.3.0=stable --status 1.2.0=published --status 1.3.0=latest --latest 1.3.0 --output public/docs
```

组合结果包含 `versions.json`、根版本选择页和 `latest/` 别名；每个版本目录自包含，可直接通过 `file://` 打开。页面选择器优先使用 `html/symbol-index.json` 中的稳定 symbol ID 跨版本定位；删除或新增的声明会明确回退到该版本首页并标记 unavailable。channel、status 和 latest 只记录命令行显式值，不连接网络，也不启动服务。

如果已有 `cjdoc.api-diff/1` 报告，可以用 `--diff VERSION=FILE` 把它绑定到目标版本。组合器会原样复制报告到目标版本的 `api-diff.json`，在 `versions.json` 写入 `apiDiff`，并在版本 selector 显示 Changes 链接；它不会改写 API diff 或 Doc IR。

`versions.json` 的 schema 是 `cjdoc.versions/1`，源文件位于 `docs/schema/versions.schema.json`。

## 查看已有 JSON

如果已经有 `docs.json`，可以只重新生成 HTML 或 Markdown，不重新扫描源码：

```bash
cjdoc render \
  --input target/doc/docs.json \
  --format html \
  --format markdown \
  --output target/rendered-doc
```

`render` 读取并验证输入的 Doc IR。输出目录应使用一个尚不存在的目录，或使用之前由 cjdoc 管理的目录；不要把包含无关文件的目录直接交给 cjdoc。

## 常见问题

### 页面没有声明

确认声明是 `public` 或 `protected`，并且使用的是 `/** ... */`。默认 `external` audience 会隐藏 private 声明。查看内部 API 时运行：

```bash
cjdoc generate --project . --format html --audience all
```

### 生成结果是 partial

这表示部分源码、语义信息或引用没有完整解析。先查看命令输出的诊断，再确认是否需要为条件编译传入 `--cfg`，或是否需要把依赖源码显式纳入扫描范围。生成器会保留能够解析的部分，不会把不确定信息标成已解析。

### 输出目录报所有权或冲突错误

首次生成时不要预先创建 `target/doc`。cjdoc 会验证输出目录的所有权，并拒绝覆盖无法确认归属的内容。换用一个不存在的新输出目录；再次生成时，可以继续使用此前由 cjdoc 管理的目录。已有目录中的内容需要被明确采用时，见 [`高级用法`](advanced-usage.md#管理输出目录)。

## 下一步

需要处理 workspace、依赖、条件编译、缓存、多个输出格式或 CI 时，继续阅读 [`docs/advanced-usage.md`](advanced-usage.md)。
