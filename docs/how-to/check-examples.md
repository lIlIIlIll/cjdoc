# 编译并运行文档示例

示例默认只显示，不编译也不运行。用 `cjdoc check --check-examples` 编译 `@example` 中的仓颉片段，并在示例声明 `run` 时执行程序、核对预期标准输出，让注释里的示例成为可以验证的说明。

## 前提

- 已完成[首次生成教程](../tutorials/first-site.md)，`docdemo/` 中有 `src/api.cj` 和带 `@example` 的公开 `greet`。
- `cjdoc` 与仓颉 SDK 的 `cjc` 在当前终端可用。
- 带 `run` 的示例需要当前环境能构建可执行文件并设置内存限制；无法建立限制的平台会拒绝运行并报告 `CJDOC3074`，示例不会被静默跳过。
- 以下命令在 `docdemo/` 项目根执行。

`@example` 的代码只能写函数体内的语句，不是完整程序：变量、调用和 `println` 直接写在片段里，需要 `import` 时把它放在所属源码文件顶部。

## 检查首站教程的示例

首站教程的 `greet` 注释已经带有一个 `{must-pass run}` 示例和 `Hello, Cangjie!` 的 `output` 围栏。直接检查：

```bash
cjdoc check --project . --check-examples
```

没有示例相关的 error 且退出码为 `0`，表示示例编译通过、程序实际运行，且标准输出与围栏一致。源码模式下可能仍有 `CJDOC3041` 类型链接 warning，它不表示示例失败。示例编译、运行或输出比较失败时，会打印对应诊断和示例所在位置，命令以 `1` 结束。退出码 `0` 只说明这次检查覆盖的示例成立，不表示 HTML 已经生成。

## 编写正例与预期失败示例

在同一个 `src/api.cj` 末尾追加下面这个完整函数，演示两种相反的约定：`must-pass run` 要求代码编译并运行成功，`must-fail` 要求编译器在示例片段中报错。文件中原有的 `greet` 和 `internalGreeting` 保持不变：

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

保存后再次检查：

```bash
cjdoc check --project . --check-examples
```

没有示例相关的 error，命令仍以 `0` 结束。`add` 的第二个示例写成 `must-fail`，检查会要求编译器在示例代码上报错；这次报错是预期的，示例不会运行，也不会让整个检查失败。如果这个片段反而编译成功，命令会报告 `CJDOC3070` 说明预期失败没有发生。

`must-fail` 只接受归属于示例自身的编译错误。若失败发生在所属源码或依赖上，检查报告 `CJDOC3031`，不会把上下文错误算作示例已验证。

## 生成站点时同时检查

需要同时产出 HTML 时，把开关加到 `generate`：

```bash
cjdoc generate --project . --format html --check-examples --output target/doc-checked
```

`generate` 会写入本次生成的文件；示例检查失败时文件仍会写出，但命令以 `1` 结束。发布前先确认退出码为 `0`。`check` 只做检查，不写 HTML、Markdown 或 JSON。

HTML 页面显示作者写下的示例代码和预期输出，不显示逐例通过标记，也没有执行徽章。示例是否真的编译、运行过，只能看这两条命令的诊断和退出码。

## 输出不匹配时

如果 `output` 围栏写成 `4` 而实际输出是 `3`，检查会报告 `CJDOC3072`，消息里带预期与实际输出，命令以 `1` 结束。先比较两段文本：比较时统一换行符并忽略首尾空行，中间的空格、标点和行数必须一致。然后修改函数让行为符合说明，或修改围栏让预期符合真实输出，再重新检查。不要删除示例来让检查通过。

常见失败按下面的顺序排查：

- `CJDOC3071`：程序运行后以非零状态退出，消息中带有 stderr。示例片段被放进无参数 `main` 执行，不能读取程序参数；检查代码里是否会抛异常或依赖未设置的环境。
- `CJDOC3072`：输出与围栏不一致，处理方式同上。
- `CJDOC3030`：编译器错误落在示例代码上，检查片段里的标识符、类型和语句位置。
- `CJDOC3031`：错误落在所属项目或源文件，先让 `cjpm build` 和普通 `cjdoc check` 通过。
- `CJDOC3033`：示例指令本身写错，例如同时写 `must-pass` 和 `must-fail`、`run` 与 `must-fail` 同用、`error="…"` 没有搭配 `must-fail`、`flags="..."` 使用了白名单之外的选项。该示例不会进入编译。
- `CJDOC3032`：`@example` 中没有 `cangjie` 代码围栏。这是 warning，但写了指令的示例还会同时得到 `CJDOC3070`，因为预期的检查没有发生。
- `CJDOC3070`：写了指令但没有得到预期检查结果。例如预期失败的示例实际编译成功、`error="…"` 指定的文字没有出现在编译错误中，或示例因环境原因没有真正检查。

## 诊断码与资源限制

每次检查最多编译 256 个示例，超出后停止并报告 `CJDOC3031`。带 `run` 的示例另有固定上限：

| 项目 | 上限 | 超限诊断 |
|---|---|---|
| 单次运行时间 | 10 秒 | `CJDOC3073` |
| 标准输出、标准错误 | 各 64 KiB | `CJDOC3075` |
| 运行内存 | 2048 MiB；无法构建可执行文件或建立限制时也拒绝运行 | `CJDOC3074` |

这些限制固定写在产品中，不能通过 `cjdoc.toml` 或示例指令调整。逐例结果只通过诊断和退出码报告，不生成独立结果文件。完整指令、`flags` 白名单和标签规则见[文档注释参考](../reference/doc-comments.md#示例)，限制汇总见[状态与限制参考](../reference/states-and-limits.md)。

## 下一步

- [检查文档质量](check-quality.md)：读取覆盖率报告并设置发布门槛。
- [生成并发布文档](generate-and-publish.md)：输出六种格式并发布站点。
