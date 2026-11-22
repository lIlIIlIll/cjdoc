# 核对 API 说明与实际行为

选一个准备发布的 API，把说明里的输入、返回、异常和状态承诺与实现逐条对照，再用可运行示例锁定关键边界。覆盖率能找到缺项，但“已经写了说明”不代表说明正确。

## 什么时候用本页

- 一个 API 即将对外发布，说明里出现了“截断”“合并”“线程安全”之类需要兑现的承诺。
- 想确认注释里的异常、默认值和边界描述与源码一致。
- 要为一个边界补上能长期防回归的示例。

只想找漏写的字段时，用[检查质量](check-quality.md)更快；本页关心的是写得对不对。

## 前提条件

- 选一个你能读到实现的项目和 API；可以继续使用[生成第一个站点](../tutorials/first-site.md)里的 `docdemo/`。
- 要运行本页示例，终端需能使用已安装的 `cjdoc` 和仓颉 SDK；示例运行环境要求见[检查示例](check-examples.md)。
- 命令在项目根执行。

## 第一步：列出要核对的维度

从读者实际会调用的函数或类型开始，对每个维度记录：说明在哪里、实现怎样处理、哪些仍需作者确认。

| 复核维度 | 要确认什么 |
|---|---|
| 输入与前置条件 | 有效范围、端点、默认值、空值、负值和单位；前置条件由调用者保证，还是实现会检查 |
| 返回与异常 | 每种结果和异常的触发条件；同一异常类型在不同方法中条件可能不同 |
| 状态和失败 | 成功、失败、重复调用后的状态；操作顺序是否重要；失败前是否可能已修改对象 |
| 所有权与资源 | 返回独立副本还是共享引用；谁关闭资源；关闭后哪些操作可用 |
| 并发与性能 | 调用是否需要同步；复杂度和性能承诺的适用条件与依据 |
| 翻译与来源 | 译文是否描述同一个参数、异常或章节；继承、条件编译和未解析类型是否影响说明 |

结论用这几种之一：「说明与实现一致」「说明有误」「缺少说明，需要补充」「缺少依据，待作者确认」「不适用」。不要因为一次正常调用成功，就把所有权、失败原子性或线程安全标为已确认。

## 验证一个边界条件

下面为[注释参考中的 `clamp`](../reference/doc-comments.md#完整的-clamp-throws-示例)补三个示例：区间外、上下界相等、下界大于上界。

在 `docdemo/` 项目中新建完整 `src/clamp.cj`。如果之前已保存参考页的同名文件，用下面内容替换，不要在别的文件里重复声明 `clamp`：

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

从项目根编译并检查：

```bash
cjpm build
cjdoc check --project . --check-examples
```

**预期结果**：`cjpm build` 打印 `cjpm build success`；`cjdoc check` 退出码 `0`，表示三个示例都编译、运行并匹配了各自的 `output`。

## 第二步：证明示例能挡住回归

第三个示例必须捕获 `IllegalArgumentException`。把实现里的抛异常分支删掉后重新检查，实际输出会变成 `未抛出异常`，检查随即失败：

```text
error[CJDOC3072]: @example '下界大于上界' output mismatch: expected 边界无效, got 未抛出异常
```

命令退出码 `1`。这正是示例的价值：说明里的异常承诺一旦与实现脱节，检查就会挡住。验证完记得把抛异常分支改回去，重新跑一遍 `cjdoc check --project . --check-examples` 确认回到 `0`。

出现 `CJDOC3072` 时对照实际输出与预期；出现编译或运行环境诊断时，按[检查示例](check-examples.md)处理。

## 第三步：在页面上复核读者看到的内容

重新生成站点，在 `clamp` 页面阅读注释与示例：

```bash
cjdoc generate --project . --format html
```

**预期结果**：`target/doc/html/index.html` 中的 `clamp` 页面同时显示说明、`@throws` 和三个示例，示例代码与预期输出连着显示。页面展示的是作者写下的输出，不会带上本次运行的实际结果；要通过与否看 `--check-examples`。

## 示例能验证的与作者仍需承诺的

返回值、异常触发、状态变化可以为选定输入编写示例。并发安全、分配失败后的状态、资源释放责任和复杂度，通常还需要实现审查、专门测试或作者说明。没有相应依据时保留待确认项，不从方法名或单线程运行推导结论。

这三个例子覆盖了所列边界，不覆盖所有整数和所有环境。

检查译文时对照同一条逻辑说明，而不是只看有没有英文。缺译、歧义和来源不确定的含义见[状态与限制](../reference/states-and-limits.md)。

维护 cjdoc 自身的 PocketKit 样例时，可以另外运行[维护者的读者契约复核](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/maintainer/api-reading-audit.md#验证入口)；它不是核对你自己项目的前提。

## 下一步

- [检查质量并设置覆盖率门槛](check-quality.md)。
- [编写更多编译和运行示例](check-examples.md)。
- [比较两个版本的 API](compare-and-version.md)。
