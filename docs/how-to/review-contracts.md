# 核对 API 说明与实际行为

选一个准备发布的 API，把说明中的输入、返回、异常和状态承诺与实现逐条对照，再用可运行示例检查关键边界。覆盖率能找到缺项，但“已经写了说明”不表示说明正确。

## 前提

- 选择你能阅读实现的项目和 API；可以继续使用[首站教程](../tutorials/first-site.md)的 `docdemo/`。
- 要运行本页示例，当前终端需能使用已安装的 `cjdoc` 和仓颉 SDK；示例运行环境要求见[检查示例](check-examples.md)。

## 逐个 API 核对说明

从读者实际会调用的函数或类型开始，记录说明在哪里、实现怎样处理，以及仍需作者确认的部分：

| 复核维度 | 要确认什么 |
|---|---|
| 输入与前置条件 | 有效范围、端点、默认值、空值、负值和单位；前置条件是否由调用者保证，还是实现会检查。 |
| 返回与异常 | 每种结果和异常的触发条件；同一个异常类型在不同方法中可能有不同条件。 |
| 状态和失败 | 成功、失败、重复调用之后的状态；操作顺序是否重要，失败前是否可能已修改对象。 |
| 所有权与资源 | 返回的是独立副本还是共享引用；谁关闭资源，关闭后哪些操作可用。 |
| 并发与性能 | 调用是否需要同步；复杂度和性能承诺的适用条件与依据。 |
| 翻译与来源 | 译文是否描述同一个参数、异常或章节；继承、条件编译和未解析类型是否影响说明。 |

结论可以是“说明与实现一致”“说明有误”“缺少说明，需要补充”“缺少依据，待作者确认”或“不适用”。不要因为一次正常调用成功，就把所有权、失败原子性或线程安全标为已确认。

## 验证一个边界条件

下面为[注释参考中的 `clamp`](../reference/doc-comments.md#完整的-clamp-throws-示例)补上三个可运行示例：区间外、上下界相等，以及下界大于上界。实现与参考页相同，注释只使用中文。

在 `docdemo/` 项目中新建完整 `src/clamp.cj`。如果之前已经保存了参考页的同名文件，用下面的内容替换它，不要在别的文件中重复声明 `clamp`：

~~~cangjie
package docdemo

/**
 * 将 value 限制在闭区间 [lower, upper] 内。
 *
 * 合法边界下，区间外的值取最近边界；上下界相等时返回该边界。
 * @param value 要限制的整数。
 * @param lower 闭区间下界。
 * @param upper 闭区间上界。
 * @return 闭区间内的限制结果。
 * @throws IllegalArgumentException 当 lower 大于 upper 时抛出。
 * @example 区间外取最近边界 {must-pass run}
 * ```cangjie
 * println(clamp(-1, 0, 10))
 * println(clamp(11, 0, 10))
 * ```
 * ```output
 * 0
 * 10
 * ```
 * @example 上下界相等 {must-pass run}
 * ```cangjie
 * println(clamp(99, 4, 4))
 * ```
 * ```output
 * 4
 * ```
 * @example 下界大于上界 {must-pass run}
 * ```cangjie
 * try {
 *     let _ = clamp(1, 2, 1)
 *     println("未抛出异常")
 * } catch (_: IllegalArgumentException) {
 *     println("边界无效")
 * }
 * ```
 * ```output
 * 边界无效
 * ```
 */
public func clamp(value: Int64, lower: Int64, upper: Int64): Int64 {
    if (lower > upper) {
        throw IllegalArgumentException("lower must be less than or equal to upper")
    }
    if (value < lower) { return lower }
    if (value > upper) { return upper }
    value
}
~~~

从项目根编译并检查示例：

```bash
cjpm build
cjdoc check --project . --check-examples
```

检查退出 `0` 表示这些示例编译、运行并匹配了各自的 `output`。第三个示例必须捕获 `IllegalArgumentException`；如果实现不再抛异常，实际输出会变成“未抛出异常”，检查就会失败。出现 `CJDOC3072` 时对照实际输出与预期；出现编译或运行环境诊断时，按[示例检查](check-examples.md)处理。

这三个例子检查了所列边界，没有覆盖所有整数和所有环境。需要发布该函数的文档时，重新运行 `cjdoc generate --project . --format html`，在 `clamp` 页面阅读注释与示例。

## 区分示例能检查的事实与作者承诺

返回值、异常触发、状态变化等可以为选定输入编写示例。并发安全、分配失败后的状态、资源释放责任和复杂度，通常还需要实现审查、专门测试或作者说明。没有相应依据时，保留待确认项，不从方法名或单线程运行推导结论。

检查译文时，对照同一条逻辑说明，而不是只看有没有英文。缺译、歧义和来源不确定的含义见[状态与限制](../reference/states-and-limits.md)。

维护 cjdoc 的 PocketKit 样例时，可以另外运行[维护者的读者契约复核](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/maintainer/api-reading-audit.md#验证入口)；它不是核对你自己项目的前提。

## 下一步

- [检查质量并设置覆盖率门槛](check-quality.md)。
- [编写更多编译和运行示例](check-examples.md)。
- [比较两个版本的 API](compare-and-version.md)。
