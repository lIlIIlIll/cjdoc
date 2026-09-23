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

```cangjie
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
```

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
| `@example` | 添加带可选标题、可选指令的代码示例 |

`@example` 后可以写标题，标题后可以写一个用 `{}` 包裹的指令块，随后使用 Markdown fenced code block 放置示例代码；示例会在 HTML 的“示例”区域单独渲染，在 Markdown 输出中保留代码围栏：

~~~cangjie
/**
 * 计算两个整数的和。
 *
 * @example 基本用法
 * ```cangjie
 * let result = add(1, 2)
 * ```
 *
 * @param left 左侧数值。
 * @param right 右侧数值。
 * @return 两数之和。
 */
~~~

示例内容会持续到下一个顶层结构化标签（例如 `@param` 或 `@return`）；代码围栏内部出现的 `@param` 等文本会保持为示例代码，不会被误解析成文档标签。

默认情况下，`@example` 只负责收集、清理并渲染示例内容，指令块只是随注释一起记录在 Doc IR 的 `directives` 字段中，不会改变输出。需要校验示例中的 API、参数和类型时，可显式启用 `--check-examples`：cjdoc 会把每个语言标记为 `cangjie` 的 fenced code block 放入声明所属的源码包中，调用 `cjc` 进行编译校验，并按指令决定是否运行。没有该开关时指令完全不生效，既不会编译也不会运行示例。编译失败会产生 error，缺少 `cangjie` fenced code block 会产生 warning；其他语言的代码块不会参与校验。该选项要求 `cjc` 已在 `PATH` 中，且示例应是可以放入函数体的代码片段。`@see` 引用仍会参与符号解析和文档 lint。

指令块写在 `@example` 标题之后，用 `{}` 包裹，指令之间用空格分隔；需要值的指令写成 `name="value"`：

| 指令 | 含义 |
|---|---|
| `must-pass` | 显式固定“该示例必须编译通过，并且必须真的被检查过” |
| `must-fail` | 该示例必须编译失败，并且失败必须发生在示例代码之内 |
| `error="…"` | 与 `must-fail` 搭配，要求编译器输出包含该片段 |
| `run` | 编译通过后把示例作为可执行程序运行，要求退出码为 0 |
| `flags="…"` | 为该示例的 `cjc` 调用追加选项，只接受下面的白名单 |

指令名区分大小写，不允许重复。`must-pass` 与 `must-fail` 互斥，`run` 不能与 `must-fail` 同时出现，`error=` 必须搭配 `must-fail`。语法错误、冲突、未知指令以及白名单之外的选项都会产生 `CJDOC3033`，此时该示例不会被排队编译：

~~~cangjie
/**
 * 计算两个整数的和。
 *
 * @example 故意失败的用法 {must-fail error="undeclared identifier"}
 * ```cangjie
 * let result = missingApi(1, 2)
 * ```
 *
 * @example 基本用法 {run flags="--int-overflow wrapping"}
 * ```cangjie
 * println(add(1, 2))
 * ```
 * ```output
 * 3
 * ```
 */
~~~

`flags="…"` 允许的 `cjc` 选项：

- `--cfg KEY=VALUE`：`KEY` 是标识符，`VALUE` 只含字母、数字与 `_.+-`。内置键名（如 `os`、`arch`）不在这里重复列举，由 `cjc` 拒绝。
- `-Woff GROUP` 与 `-Won GROUP`：`all`、`unused`、`unused-main`、`deprecated`、`unsupport-compile-source`、`package-import`、`parser`、`semantics`、`interpreter`、`apilevel-check`。`driver-arg` 不在列表中，因为它会掩盖上一条里的错误。
- `--int-overflow MODE`：`throwing`、`wrapping`、`saturating`。
- 单独出现的 `--experimental`、`-O0`、`-O1`、`-O2`、`-Os`、`-Oz`。

输出路径与源文件列表仍由 cjdoc 掌握，因此 `-o`、`--output-type`、`-p`、`-L`、`-l`、`--import-path`、`@file` 等一律被拒绝。

带 `run` 的示例可以额外使用语言标记为 `output` 的 fenced code block 固定标准输出：每个示例最多一个 `output` 块，且必须同时带 `run`，否则产生 `CJDOC3033`。比较前两侧都会统一换行符并去掉首尾空行，因此 `println` 结尾的那一个换行不需要写出。示例本身会被包装进一个无参数的 `main`，所以引用 `args` 的示例无法通过编译；需要 `exit` 等函数时，`import` 写在示例所属的源码文件里。

运行时的限制是固定的：单次运行上限 10 秒，stdout 与 stderr 各上限 64 KiB，一次检查最多 256 个示例。可执行文件用 `--static --output-type exe` 构建，这样示例即使没有把 SDK 运行库放进 `LD_LIBRARY_PATH` 也能运行；静态链接不可用的环境会报告 `CJDOC3038`。

固定结果但检查没有真正发生，同样算失败：`CJDOC3034` 表示固定为失败的示例却编译通过、失败并不在示例代码内（例如整个源码包本身编译不过）、缺少 `cangjie` 代码块，或因为限制与临时目录问题而被跳过；`CJDOC3035` 表示运行退出码非 0；`CJDOC3036` 表示 stdout 与 `output` 块不一致；`CJDOC3037` 表示超过运行时限被终止；`CJDOC3039` 表示输出超过上限。

文档注释应紧邻它描述的声明。默认生成 external 文档，所以示例声明应为 `public` 或 `protected`。

## 重新生成文档

修改注释后，再运行原来的命令：

```bash
cjdoc generate --project . --format html
```

然后刷新 `target/doc/html/index.html`。默认缓存放在 `target/cjdoc/cache/source-v11`，通常不需要手动处理。

## 选择语义后端

普通生成默认使用 `source` 模式。需要验证同一份源码经过 Cangjie compiler 和 `stdx.chir` 结构化 API 的结果时，只在 `generate` 或 `check` 上显式选择 CHIR：

```bash
cjdoc generate --project . --semantic chir --format json --stdout
```

CHIR 模式从本次源码快照编译 raw CHIR，不读取 host 上未捕获的源文件；可用 `--cjc <path>` 指定 compiler，并可重复传入 `--chir-import-path <dir>`。compiler、输入构建约束、编译、artifact/worker 协议和 overload 映射问题分别产生 `CJDOC2101`–`CJDOC2106` warning。任何 CHIR 失败都会保留 source declarations；注释和最终 Doc IR 仍由源码路径决定。

`render` 只读取已有 Doc IR，因此不能选择 semantic backend。

## 检查文档问题

`check` 只检查源码、声明绑定、引用和 lint，不生成 HTML 或 Markdown：

```bash
cjdoc check --project .
```

同时编译校验（并按指令运行）API 示例：

```bash
cjdoc check --project . --check-examples
```

`--check-examples` 是显式开关，不会改变普通 `generate` 或 `check` 的默认行为；没有它时 `@example` 指令完全不生效。开启后，默认只做编译，不执行示例；只有带 `run` 的示例才会被构建为可执行文件并运行。源码包本身无法由 `cjc` 编译时，诊断会区分为上下文编译失败（`CJDOC3031`）而不是示例失败。

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

输出到目录时，`coverage` 还会生成独立的 `coverage/quality.json`。`--stdout` 保持输出原有的 presence coverage；规则与指标说明见[文档质量检查](documentation-quality.md)。

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
