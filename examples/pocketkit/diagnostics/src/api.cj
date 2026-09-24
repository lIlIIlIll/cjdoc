package pocket_diagnostics

/**
 * 故意触发编译失败的隔离示例，不属于默认入门结果。
 *
 * 本项目只检验失败被如实记录。没有 expected-failure 成功模式，raw status 必须保持 failed，
 * 不能把它计入通过样本。{@link MissingDocumentationTarget} 应保持 unresolved。
 *
 * @example 故意错误的赋值
 * ```cj
 * let value: Int64 = "not an integer"
 * ```
 */
public func deliberateFailure(): Unit {}

/** 第一个 Owner，供跨作用域同名成员诊断使用。 */
public class First {
    /** @return 固定文本。 */
    public func duplicate(): String { "first" }
}

/** 第二个 Owner，供跨作用域同名成员诊断使用。 */
public class Second {
    /** @return 固定文本。 */
    public func duplicate(): String { "second" }
}

/**
 * {@link duplicate} 在本项目不唯一，应该显示 ambiguous 而不是猜测一个目标。
 * {@link First.duplicate()} 和 {@link Second.duplicate()} 提供限定名示例。
 */
public func ambiguousReference(): Unit {}

/**
 * 明确跳过不含代码的说明，不声称已经验证。
 * @example 说明性示例（无可执行代码围栏）
 * 阅读返回值和来源，但不要把这段说明当成运行成功。
 */
public func explanatoryExample(): Unit {}
