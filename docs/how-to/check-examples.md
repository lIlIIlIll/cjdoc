# 编译并运行文档注释里的示例

用 `cjdoc check --check-examples` 检查 API 注释里的仓颉代码。写了 `run` 的用例还会执行，并在提供 `output` 时比较标准输出。普通 `check` 和 `generate` 默认不检查示例。

## 前提条件

- 在已加载仓颉 SDK 的终端里进入项目根，`cjdoc` 和 `cjc` 都能运行。
- 项目已有 `@example`；没有时可先完成[第一个站点](../tutorials/first-site.md)。
- 只能检查可信源码里的示例。`run` 会运行实际程序，且当前环境必须能为它施加内存限制，否则报告 `CJDOC3074`。

## 1. 检查已有示例

```bash
cjdoc check --project . --check-examples
```

首站教程中的 `greet` 应编译并运行通过，条件是 stdout 与两行预期输出一致。检查成功时退出码为 `0`；类型链接告警不等于示例失败。`check` 不写站点。

## 2. 加入一个预期失败示例

在教程项目 `src/api.cj` 末尾追加 `add`。第一条用例会运行，第二条展示编译器应拒绝的调用：

~~~cangjie
/**
 * 返回两个整数之和。
 *
 * 示例使用 1 和 2 相加，得到 3。
 *
 * @param left 左操作数。
 * @param right 右操作数。
 * @return 两数之和。
 * @example 计算两个整数之和 {must-pass run}
 * ```cangjie
 * println(add(1, 2))
 * ```
 * ```output
 * 3
 * ```
 * @example 调用不存在的函数 {must-fail}
 * ```cangjie
 * missingApi()
 * ```
 */
public func add(left: Int64, right: Int64): Int64 {
    left + right
}
~~~

示例只写函数体内的语句；片段所需 `import` 写在所属源码文件顶部。同一个 `@example` 下的多个 `cangjie` 围栏可以共享变量，不同 `@example`（包括不同语言）分别检查。

围栏语言必须是小写 `cangjie`，可以用反引号或波浪线；`cj` 只高亮，不供检查。空的 `cangjie` 围栏也不算代码。若要把同一个用例的准备步骤和调用分开展示，把两个 `cangjie` 围栏写在同一个 `@example` 下，见[多用例写法](../reference/doc-comments.md#示例)。

配置 `[i18n]` 时，无语言限定的示例属于默认语言；`@example[lang=en]` 是独立用例，即使同标题也不和默认语言配对。`--check-examples` 检查两条，变量不能跨用例使用。

保存后重新执行 `cjdoc check --project . --check-examples`。第一条应输出 `3`，第二条应在 `missingApi()` 处编译失败；两种结果都符合预期，命令应退出 `0`。如果第二条反而能编译，报告 `CJDOC3070`；若错误发生在源码或依赖而不能归因于该片段，报告 `CJDOC3031`，也不能算通过。

用例只要求编译时写 `{must-pass}`。`{run}` 不带 `output` 只要求运行成功；有空的 `output` 则要求没有 stdout。纯编译用例不要写 `output`。完整指令见[示例参考](../reference/doc-comments.md#示例)。

## 3. 生成站点时同时检查示例

需要同时产出 HTML 时，把开关加到 `generate`：

```bash
cjdoc generate --project . --format html --check-examples --output target/doc-checked
```

成功后打开 `target/doc-checked/html/index.html`。如果示例失败，命令仍可能写出文件，但退出为 `1`；发布前先修复并重新运行。

页面展示示例及作者写的**预期输出**，不会显示逐例通过标记。代码和输出放在同一个单元里，可分别复制；长输出折叠时，「复制输出」仍会复制全文。教程和短例对照可选[示例布局](../reference/doc-comments.md#html-示例布局)，不影响检查。

## 4. 按诊断码处理失败

| 诊断码 | 含义 | 处理 |
|---|---|---|
| `CJDOC3072` | 实际 stdout 与 `output` 围栏不一致 | 见下一节 |
| `CJDOC3071` | 程序运行后以非零状态退出，消息中带 stderr | 示例被放进无参数 `main` 执行，不能读取程序参数；检查是否会抛异常或依赖未设置的环境 |
| `CJDOC3030` | 编译器错误落在示例代码上 | 检查片段里的标识符、类型和语句位置 |
| `CJDOC3031` | 错误落在所属项目或源文件；超过 256 个示例时也报这个码 | 先让 `cjpm build` 和普通 `cjdoc check` 通过 |
| `CJDOC3033` | 示例指令本身写错 | 见下表 |
| `CJDOC3032` | `@example` 中没有非空的小写 `cangjie` 围栏（warning） | 补上可编译代码；只有 `output` 不算。有指令的示例还会同时得到 `CJDOC3070` |
| `CJDOC3070` | 写了指令但没得到预期检查结果 | 例如预期失败实际编译成功、`error="…"` 指定的文字没出现在编译错误中，或示例因环境原因没被真正检查 |
| `CJDOC3073` | 单次运行超过 10 秒被终止 | 缩短示例，或把长时间计算移出注释示例 |
| `CJDOC3074` | 无法构建可执行文件或建立内存限制 | 换一个支持该能力的平台或环境，或去掉 `run` |
| `CJDOC3075` | stdout 或 stderr 超过 64 KiB | 减少示例打印量 |

`CJDOC3033` 覆盖的指令错误包括：同时写 `must-pass` 和 `must-fail`、`run` 与 `must-fail` 同用、`error="…"` 没有搭配 `must-fail`、`flags="…"` 使用了白名单之外的选项、`output` 围栏没有配 `run`、一个示例写了多个 `output` 围栏。该示例不会进入编译。实际提示形如：

```text
error[CJDOC3033]: @example '指令冲突' has invalid directives: 'must-pass' and 'must-fail' conflict (accepted: must-pass, must-fail, run, error="…", flags="…")
```

## 输出不匹配时

如果 `output` 围栏写成 `4` 而实际输出是 `3`，检查报告：

```text
error[CJDOC3072]: @example '计算两个整数之和' output mismatch: expected 4, got 3
```

命令以 `1` 退出。比较会统一换行符并忽略首尾空行；中间空格、标点和换行仍要一致。先根据诊断确定哪一边不符合 API 的约定，再改实现或预期输出。诊断优先显示用例标题；没有标题时按声明限定名查找。若希望仅有 warning 时也返回失败，使用 `--deny-warnings`。

## 资源上限

每次检查最多编译 256 个示例，超出后停止并报告 `CJDOC3031`（`example compilation stopped after 256 examples`）。带 `run` 的示例另有固定上限：

| 项目 | 上限 | 超限诊断 |
|---|---|---|
| 单次运行时间 | 10 秒 | `CJDOC3073` |
| 标准输出、标准错误 | 各 64 KiB | `CJDOC3075` |
| 运行内存 | 2048 MiB；无法构建可执行文件或建立限制时也拒绝运行 | `CJDOC3074` |

这些限制固定写在产品中，不能通过 `cjdoc.toml` 或示例指令调整。逐例结果只通过诊断和退出码报告，不生成独立结果文件。完整指令、`flags` 白名单和标签规则见[文档注释参考](../reference/doc-comments.md#示例)，限制汇总见[状态与限制参考](../reference/states-and-limits.md)。

## 下一步

- [PocketKit 的文档注释示例](https://github.com/lIlIIlIll/cjdoc/blob/main/examples/pocketkit/demo-v2/docs/doc-comments.md#示例与输出)：对照四种检查方式与生成页面。
- [检查文档质量](check-quality.md)：读取覆盖率报告并设置发布门槛。
- [生成并发布文档](generate-and-publish.md)：输出六种格式并发布站点。
