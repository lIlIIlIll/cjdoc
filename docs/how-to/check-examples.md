# 编译并运行文档注释里的示例

用 `cjdoc check --check-examples` 编译 `@example` 中的仓颉片段，并在示例声明了 `run` 时执行程序、核对预期标准输出，让注释里的说明变成可验证的约定。

## 前提条件

- 已完成[生成第一个站点](../tutorials/first-site.md)，`docdemo/` 中有 `src/api.cj` 和带 `@example` 的公开 `greet`。
- 当前终端能运行 `cjdoc` 和仓颉 SDK 的 `cjc`。
- 带 `run` 的示例需要当前平台能构建可执行文件并施加内存限制；无法建立限制时会拒绝运行并报告 `CJDOC3074`，示例不会被静默跳过。
- 命令都在 `docdemo/` 项目根执行。

示例代码只能写函数体内的语句，不是完整程序：变量、调用和 `println` 直接写在片段里，需要 `import` 时把它放在所属源码文件顶部。

## 1. 检查已有示例

首站教程的 `greet` 注释带有一个 `{must-pass run}` 示例和 `Hello, Cangjie!` 的 `output` 围栏。直接检查：

```bash
cjdoc check --project . --check-examples
```

**预期结果**：没有示例相关的 error，退出码 `0`。源码模式下可能仍有 `CJDOC3041` 类型链接 warning，它不表示示例失败。

退出码 `0` 只说明这次检查覆盖的示例成立，不表示 HTML 已经生成。

## 2. 加入一个预期失败示例

在同一个 `src/api.cj` 末尾追加下面这个函数，演示两种相反的约定：`must-pass run` 要求代码编译并运行成功，`must-fail` 要求编译器在示例片段中报错。文件中已有的 `greet` 和 `internalGreeting` 保持不变：

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

**预期结果**：仍然没有示例相关的 error，退出码 `0`。`add` 的第二个示例写成 `must-fail`，检查要求编译器在示例代码上报错；这个报错是预期的，示例不会运行，也不会让整个检查失败。若该片段反而编译成功，会报告 `CJDOC3070` 说明预期失败没有发生。

`must-fail` 只接受归属于示例自身的编译错误。失败若发生在所属源码或依赖上，检查报告 `CJDOC3031`，不把上下文错误算作示例已验证。

## 3. 生成站点时同时检查示例

需要同时产出 HTML 时，把开关加到 `generate`：

```bash
cjdoc generate --project . --format html --check-examples --output target/doc-checked
```

**预期结果**：生成的文件照常写出（`target/doc-checked/html/index.html` 存在）；示例检查全部通过时退出码 `0`，有失败时仍写出文件但退出码为 `1`。发布前先确认退出码为 `0`。

`check` 只做检查，不写 HTML、Markdown 或 JSON。HTML 页面显示作者写下的示例代码和预期输出，不显示逐例通过标记，也没有执行徽章；示例是否真的编译、运行过，只能看这两条命令的诊断和退出码。

## 4. 按诊断码处理失败

| 诊断码 | 含义 | 处理 |
|---|---|---|
| `CJDOC3072` | 实际 stdout 与 `output` 围栏不一致 | 见下一节 |
| `CJDOC3071` | 程序运行后以非零状态退出，消息中带 stderr | 示例被放进无参数 `main` 执行，不能读取程序参数；检查是否会抛异常或依赖未设置的环境 |
| `CJDOC3030` | 编译器错误落在示例代码上 | 检查片段里的标识符、类型和语句位置 |
| `CJDOC3031` | 错误落在所属项目或源文件；超过 256 个示例时也报这个码 | 先让 `cjpm build` 和普通 `cjdoc check` 通过 |
| `CJDOC3033` | 示例指令本身写错 | 见下表 |
| `CJDOC3032` | `@example` 中没有 `cangjie` 代码围栏（warning） | 补上围栏；写了指令的示例还会同时得到 `CJDOC3070` |
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

命令以 `1` 结束。比较时统一换行符并忽略首尾空行，中间的空格、标点和行数必须完全一致。先比较两段文本，然后修改函数让行为符合说明，或修改围栏让预期符合真实输出，再重新检查。不要删除示例来让检查通过。

## 资源上限

每次检查最多编译 256 个示例，超出后停止并报告 `CJDOC3031`（`example compilation stopped after 256 examples`）。带 `run` 的示例另有固定上限：

| 项目 | 上限 | 超限诊断 |
|---|---|---|
| 单次运行时间 | 10 秒 | `CJDOC3073` |
| 标准输出、标准错误 | 各 64 KiB | `CJDOC3075` |
| 运行内存 | 2048 MiB；无法构建可执行文件或建立限制时也拒绝运行 | `CJDOC3074` |

这些限制固定写在产品中，不能通过 `cjdoc.toml` 或示例指令调整。逐例结果只通过诊断和退出码报告，不生成独立结果文件。完整指令、`flags` 白名单和标签规则见[文档注释参考](../reference/doc-comments.md#示例)，限制汇总见[状态与限制参考](../reference/states-and-limits.md)。

## 下一步

- [检查文档质量](check-quality.md)：读取覆盖率报告并设置发布门槛。
- [生成并发布文档](generate-and-publish.md)：输出六种格式并发布站点。
