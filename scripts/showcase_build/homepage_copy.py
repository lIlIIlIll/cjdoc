"""Reader task labels; implementation identities and evidence stay in the manifest."""
GROUPS = (
    ("read", "阅读 API", "Read APIs", ("compact-members", "type-navigation", "chinese-contracts", "resource-lifetime", "search-discovery", "external-docs", "extension-origin")),
    ("use", "开始使用", "Start using cjdoc", ("guide-association", "offline-source", "local-authoring")),
    ("verify", "核对结果与版本", "Check results and versions", ("doctest-results", "api-diff", "multi-version", "quality", "boundaries")),
    ("integrate", "集成与能力边界", "Integrations and limits", ("machine-output", "external-contract-merge")),
)

# (Chinese action, English action, Chinese task description, English task description)
TASKS = {
    "compact-members": ("比较 add 重载", "Compare add overloads", "筛选 add，展开两个重载并对照参数与契约。", "Filter add and expand both overloads to compare their parameters and contracts."),
    "type-navigation": ("跟随返回类型", "Follow a return type", "从 openText 的返回类型进入 TextReader，再查看 Readable 接口。", "Follow openText to its TextReader return type, then inspect Readable."),
    "chinese-contracts": ("查看参数与边界", "Read parameters and boundaries", "查看 window 的命名参数、默认值、可选数组及异常条件。", "Inspect window's named parameters, defaults, optional arrays and exception conditions."),
    "resource-lifetime": ("了解关闭责任", "Read the close contract", "查看谁拥有阅读会话、何时关闭，以及关闭后读取的异常。", "Check session ownership, closing and exceptions when reading after close."),
    "guide-association": ("阅读入门指南", "Read the getting-started guide", "从指南进入精确的 String 重载，再通过相关指南返回。", "Follow the guide to the exact String overload and return through its related guide."),
    "search-discovery": ("搜索示例 API", "Search example APIs", "按名称与已索引类型字段查找 API，并检查无匹配提示。", "Search names and indexed type fields, including no-match results."),
    "doctest-results": ("查看示例执行结果", "Inspect example results", "核对源 @example、输入、退出码与原生指令检查证据。", "Trace source examples, inputs, exit codes and native directive evidence."),
    "api-diff": ("比较两个版本", "Compare both versions", "查看新增、删除、重载和文档变化，打开变更前后的声明。", "Inspect additions, removals, overload and documentation changes with before/after links."),
    "multi-version": ("切换 API 版本", "Switch API versions", "切换共同成员，查看已删除成员和旧重载的不可用提示。", "Switch common members and inspect unavailable removed members and old overloads."),
    "quality": ("定位文档缺项", "Find documentation gaps", "核对覆盖率分母，按 API、源码位置或诊断码筛选缺项。", "Check coverage denominators and filter findings by API, source or diagnostic code."),
    "external-docs": ("查看依赖声明", "Open dependency declarations", "区分本地 Stamp 与固定 support-v1 的 SourceLabel 及其字段。", "Distinguish the local Stamp from SourceLabel and its field in fixed support-v1."),
    "offline-source": ("下载源码或离线站", "Download source or offline site", "保留完整目录后，可离线使用导航、搜索、展开和复制。", "Keep the full extracted tree to use navigation, search, expansion and copy offline."),
    "machine-output": ("核对机器可读产物", "Inspect machine outputs", "在 HTML、索引、JSON、Markdown 和 llms 输出之间核对同一声明。", "Trace the same declaration through HTML, indices, JSON, Markdown and llms outputs."),
    "boundaries": ("查看隔离诊断示例", "Inspect isolated diagnostics", "查看故意设置的缺失引用、同名歧义和失败、跳过结果。", "Inspect deliberately unresolved links, ambiguous names, failures and skips."),
    "local-authoring": ("在本地预览修改", "Preview local edits", "按指南运行 serve；启动、修改与重建另有真实验证记录。", "Run serve locally; startup, edits and rebuilds have separate recorded evidence."),
    "extension-origin": ("查看扩展约束", "Inspect extension constraints", "查看源码中的 Entry<String> 约束，不推断所有泛型实例都适用。", "Inspect the source Entry<String> constraint without assuming every instance applies."),
    "external-contract-merge": ("查看当前边界", "Review current limits", "目前只有显式页面关联，完整外置契约合并尚未实现。", "Explicit page associations exist; full external-contract merging is not implemented."),
}

LIMITS = {
    "type-navigation": ("关系保留源码来源和现有 AST 状态，不推断未知继承。", "Relations retain source provenance and current AST states; unknown inheritance is not inferred."),
    "guide-association": ("支持精确重载的页面关联，尚不合并完整外置契约。", "Exact-overload page association is supported; full external contracts are not merged."),
    "doctest-results": ("旧执行器保留逐例运行、跳过；原生指令检查只有整次命令证据。", "The legacy runner retains per-example execution/skips; native directive checks retain aggregate evidence only."),
    "api-diff": ("分类与比较状态来自原生 diff；未知语义保持未知。", "Classifications and comparison states come from native diff; unknown semantics remain unknown."),
    "boundaries": ("负例单独展示，故意失败不会计为通过。", "Negative examples are isolated; deliberate failures are never counted as passes."),
    "extension-origin": ("只展示源码约束，完整扩展适用性推断尚未实现。", "Source constraints are shown; full extension applicability inference is not implemented."),
    "external-contract-merge": ("完整外置契约合并尚未实现。", "Full external-contract merging is not implemented."),
}
