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

## 生成 API surface 和 coverage

用 `api-surface` 保存公开 API 的稳定快照：

```bash
cjdoc generate --project . --format api-surface --stdout > api-surface.json
```

用 `coverage` 查看声明和参数的文档覆盖率：

```bash
cjdoc generate --project . --format coverage --stdout
```

这两个命令默认使用 `external` audience。需要把它们接入 CI 时，见 [`docs/advanced-usage.md`](advanced-usage.md#在-ci-中检查-api-和文档覆盖率)。

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
