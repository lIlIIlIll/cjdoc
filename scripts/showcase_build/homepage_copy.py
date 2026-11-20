"""Reader task labels; implementation identities and evidence stay in the manifest."""
GROUPS = (
    ("read", "阅读 API", "Read APIs", ("compact-members", "type-navigation", "chinese-contracts", "resource-lifetime", "search-discovery", "external-docs", "extension-origin")),
    ("use", "开始使用", "Start using cjdoc", ("guide-association", "offline-source", "local-authoring")),
    ("verify", "核对结果与版本", "Check results and versions", ("native-example-checks", "api-diff", "multi-version", "quality", "boundaries")),
    ("integrate", "集成与能力边界", "Integrations and limits", ("machine-output", "external-contract-merge")),
)

# (Chinese action, English action, Chinese task description, English task description)
TASKS = {
    "compact-members": ("比较 add 重载", "Compare add overloads", "筛出 add，展开两个重载，对照参数、返回值与异常。", "Filter add and expand both overloads to compare parameters, returns and exceptions."),
    "type-navigation": ("跟随返回类型", "Follow a return type", "从 openText 的返回类型进入 TextReader，再打开它实现的 Readable。", "Follow openText to its TextReader return type, then open the Readable interface."),
    "chinese-contracts": ("查看参数与边界", "Read parameters and boundaries", "查看 window 的命名参数、默认值、可选数组和越界异常。", "Inspect window's named parameters, defaults, optional arrays and out-of-range exception."),
    "resource-lifetime": ("了解关闭责任", "Read the close contract", "确认阅读会话归谁拥有、何时关闭，以及关闭后读取会怎样。", "Check who owns the session, when to close it, and what reading after close does."),
    "guide-association": ("阅读入门指南", "Read the getting-started guide", "从指南的关联跳到 String 重载，再从声明页返回同一小节。", "Follow the guide's link to the String overload, then return to the same section."),
    "search-discovery": ("搜索示例 API", "Search example APIs", "按名称、参数和返回类型查找 API，并查看无匹配时的提示。", "Find APIs by name, parameter and return type, including the no-match message."),
    "native-example-checks": ("查看示例检查结果", "Check example results", "打开原生检查报告，看哪些示例被编译、运行或要求失败。", "Open the native check report to see which examples compile, run or must fail."),
    "api-diff": ("比较两个版本", "Compare both versions", "查看新增、删除、重载和文档变化，从条目跳到改前改后的声明。", "Inspect additions, removals, overload and documentation changes, with before/after declarations."),
    "multi-version": ("切换 API 版本", "Switch API versions", "切换共同成员，查看已删除成员和旧重载的不可用提示。", "Switch common members and inspect the unavailable notices on removed members and old overloads."),
    "quality": ("定位文档缺项", "Find documentation gaps", "看覆盖率分母，按 API、源码位置或诊断码筛出缺项。", "Check coverage denominators and filter gaps by API, source location or diagnostic code."),
    "external-docs": ("查看依赖声明", "Open dependency declarations", "区分本地 Stamp 与固定 support-v1 的 SourceLabel 及其字段。", "Distinguish the local Stamp from SourceLabel and its field in fixed support-v1."),
    "offline-source": ("下载源码或离线站", "Download source or offline site", "保留完整目录，解压后即可离线导航、搜索、展开和复制。", "Keep the whole extracted tree to navigate, search, expand and copy offline."),
    "machine-output": ("核对机器可读产物", "Inspect machine outputs", "在 HTML、索引、JSON、Markdown 和 llms 输出之间核对同一个声明。", "Trace one declaration through the HTML, indices, JSON, Markdown and llms outputs."),
    "boundaries": ("查看隔离诊断示例", "Inspect isolated diagnostics", "查看故意留下的缺失引用、同名歧义，以及诊断指到的源码行。", "Inspect deliberately unresolved links, ambiguous names and the source lines diagnostics point to."),
    "local-authoring": ("在本地预览修改", "Preview local edits", "运行 serve，改一处注释，确认页面在保存后重建。", "Run serve, edit one comment, and confirm the page rebuilds after saving."),
    "extension-origin": ("查看扩展约束", "Inspect extension constraints", "查看源码里的 Entry<String> 约束，不推断其他泛型实例同样适用。", "Inspect the source Entry<String> constraint without assuming other instances qualify."),
    "external-contract-merge": ("查看当前边界", "Review current limits", "目前只有显式页面关联，完整外置契约合并尚未实现。", "Only explicit page associations exist; full external-contract merging is not implemented."),
}

LIMITS = {
    "type-navigation": ("关系保留源码来源和现有 AST 状态，不推断未知继承。", "Relations retain source provenance and current AST states; unknown inheritance is not inferred."),
    "guide-association": ("支持精确重载的页面关联，尚不合并完整外置契约。", "Exact-overload page association is supported; full external contracts are not merged."),
    "native-example-checks": ("报告记录整次命令的退出状态，不逐例声明结果。", "The report records the whole command's exit status, not a result per example."),
    "api-diff": ("分类与比较状态来自原生 diff；未知语义保持未知。", "Classifications and comparison states come from native diff; unknown semantics remain unknown."),
    "boundaries": ("负例单独展示，故意失败不会计为通过。", "Negative examples are isolated; deliberate failures are never counted as passes."),
    "extension-origin": ("只展示源码约束，完整扩展适用性推断尚未实现。", "Source constraints are shown; full extension applicability inference is not implemented."),
    "external-contract-merge": ("完整外置契约合并尚未实现。", "Full external-contract merging is not implemented."),
}
