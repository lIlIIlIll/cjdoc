package declaration_groups

/**
 * 应用入口。
 * @summary[lang=en] Application entry.
 * @group 10-application 应用 API
 */
public class Application {
    /**
     * 应用成员。
     * @param value 输入值。
     * @param[lang=en] value Input value.
     * @return 原值。
     * @return[lang=en] The input value.
     * @group 10-application 应用 API
     */
    public func apply(value: Int64): Int64 { value }

    /**
     * 生成代码成员。
     * @group 20-generated-spi 生成代码 SPI
     */
    public func support(): Unit {}
}

/**
 * 生成代码入口。
 * @group 20-generated-spi 生成代码 SPI
 */
public class Generated {}

/**
 * 第一方实现入口。
 * @group 30-first-party-internal 第一方内部接口
 */
public class InternalBridge {}

/** 未分组入口。 */
public func ungrouped(): Unit {}

/**
 * 纯文本标题。
 * @group 40-text <img src=x onerror=alert(1)>
 */
public func escapedTitle(): Unit {}

/**
 * 代码中的文本不声明分组。
 *
 * ```text
 * @group 99-fenced Fenced text
 * ```
 */
public func fenced(): Unit {}

/**
 * 不可见的所有者。
 * @group 90-hidden Hidden owner
 */
private class Hidden {
    /**
     * 不可见成员。
     * @group 90-hidden Hidden member
     */
    public func hidden(): Unit {}
}

/**
 * 应用函数。
 * @group 10-application 应用 API
 */
public func applicationFunction(): Unit {}

/**
 * 生成代码函数。
 * @group 20-generated-spi 生成代码 SPI
 */
public func generatedFunction(): Unit {}
