package pocket_checks

/**
 * 只编译示例；故意包含运行时异常来证明没有执行它。
 * Compile only: this would throw if it were run.
 * @example 只编译 / Compile only {must-pass}
 * ```cangjie
 * throw IllegalStateException("compile-only example must not execute")
 * ```
 */
public func compileOnly(): Unit {}

/**
 * 编译并运行，输出由原生检查器精确核对。
 * Compile and run with an exact native output expectation.
 * @example 运行并检查输出 / Run with pinned output {run}
 * ```cangjie
 * println("PocketKit checked output")
 * ```
 * ```output
 * PocketKit checked output
 * ```
 */
public func runWithOutput(): Unit {}

/**
 * 预期编译失败；原生检查器确认失败发生在示例内部。
 * Expected compilation failure must belong to the example, not its package.
 * @example 预期类型错误 / Expected type error {must-fail}
 * ```cangjie
 * let value: Int64 = "not an integer"
 * ```
 */
public func expectedCompileFailure(): Unit {}

/**
 * 没有代码围栏的解释保留跳过诊断，不能称为通过的示例。
 * No code fence: the native warning is retained, not counted as a pass.
 * @example 说明性内容 / Explanation only
 * 调用者先阅读契约；此段没有待执行代码。
 */
public func explanationOnly(): Unit {}
