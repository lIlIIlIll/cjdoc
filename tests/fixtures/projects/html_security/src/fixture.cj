package html_security_fixture

/**
 * <script>alert("unsafe")</script>
 *
 * [unsafe link](javascript:alert(1))
 *
 * <img src="x" onerror="alert(1)">
 *
 * ## Safe heading
 *
 * ```html
 * <script>shown as code</script>
 * ```
 */
public func renderSafe(): Unit {}
