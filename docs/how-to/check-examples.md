# 编译并运行文档示例

本指南让 `cjdoc check` 编译 `@example` 中的仓颉片段，并在示例声明 `run` 时执行程序、核对预期标准输出。普通生成和普通检查都不会自动编译或运行示例。

## 前提

- 已完成[首次生成教程](../tutorials/first-site.md)，有 `docdemo/` 静态包及其 `src/api.cj`。
- 当前终端中 `cjdoc` 和 Cangjie SDK 的 `cjc` 可用；本例含运行测试，需要能建立示例运行的内存限制。无 `prlimit` 等能力的平台会拒绝运行并报告 `CJDOC3074`。
- 命令在 `docdemo/` 项目根目录执行。示例按函数体片段编写；需要 `import` 时把它放在所属源码文件中。

## 运行一组正确的正例

下面的完整 `src/api.cj` 用 `must-pass` 要求代码编译成功，用 `run` 要求实际运行，并用 `output` 围栏固定 stdout；第二个 `must-fail` 示例则要求编译器在示例片段中发现错误。检查会同时核对两种相反的编译约定。

在项目根执行此 Bash 块。它保存原始源文件，运行正例，再临时引入错误的 stdout 预期作为负例，最后恢复原文件。临时备份位于项目 `target/` 下，不使用系统临时目录。

```bash
set -eu
mkdir -p target
BACKUP="$(mktemp target/cjdoc-example-api.XXXXXX)"
cp src/api.cj "$BACKUP"
restore() {
  cp "$BACKUP" src/api.cj
  rm -f "$BACKUP"
}
trap restore EXIT HUP INT TERM

cat > src/api.cj <<'CJ'
package docdemo

/**
 * Returns a greeting and preserves the supplied name unchanged.
 * @param name Name to include in the greeting; an empty name is allowed.
 * @return The greeting text.
 * @example Greeting output {must-pass run}
 * ```cangjie
 * println(greet("Cangjie"))
 * ```
 * ```output
 * Hello, Cangjie!
 * ```
 * @example Unknown function is rejected {must-fail}
 * ```cangjie
 * missingApi()
 * ```
 */
public func greet(name: String): String {
    return "Hello, ${name}!"
}
CJ
cjdoc check --project . --check-examples

cat > src/api.cj <<'CJ'
package docdemo

/**
 * Returns a greeting and preserves the supplied name unchanged.
 * @param name Name to include in the greeting; an empty name is allowed.
 * @return The greeting text.
 * @example Greeting output with an incorrect expectation {must-pass run}
 * ```cangjie
 * println(greet("Cangjie"))
 * ```
 * ```output
 * Hello, Other!
 * ```
 * @example Unknown function is rejected {must-fail}
 * ```cangjie
 * missingApi()
 * ```
 */
public func greet(name: String): String {
    return "Hello, ${name}!"
}
CJ
if cjdoc check --project . --check-examples; then
  echo '错误：stdout 不匹配的示例通过了检查' >&2
  exit 1
else
  status=$?
fi
test "$status" -eq 1
```

第一次检查的成功判据是退出码 `0`；`must-fail` 在这里是预期编译失败的示例，不是整个检查的失败。第二次检查应包含 `CJDOC3072` 并退出 `1`，因为实际 stdout 与 `output` 围栏不匹配。`run` 失败、运行超时、stdout/stderr 超限和示例总数上限分别会产生相应诊断；固定限制和诊断码见[状态与限制参考](../reference/states-and-limits.md)。工作流结束时 shell trap 会还原教程中的 `src/api.cj`。若指令本身有语法或互斥错误，例如同时写 `must-pass` 与 `must-fail`，检查会报告 `CJDOC3033`，该示例不会编译。

## 选择检查命令

只检查示例时用 `check`；需要同时生成 HTML 时可用 `generate`。以下命令均从 `docdemo/` 根目录运行：

```bash
cjdoc check --project . --check-examples
cjdoc generate --project . --format html --check-examples --output target/doc-with-checked-examples
```

`check` 不写 HTML、Markdown 或 JSON。`generate` 可以生成站点，但检查失败仍会返回失败状态；要不要发布产物应另外检查退出码。此开关不会改变 HTML 页面显示为“已验证”的标记，因为产品不生成逐例通过徽章。

## 下一步

- [检查文档质量](check-quality.md)：配置覆盖率、lint 与 CI 退出码。
- [生成并发布文档](generate-and-publish.md)：输出六种格式并检查站点。
