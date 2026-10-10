"""Translate report UI text while preserving raw evidence and author examples."""
from html.parser import HTMLParser
import html

HEADINGS = {
    "验证与变化 / Validation and changes": ("验证与变化", "Validation and changes"),
    "文档覆盖 / Coverage": ("文档覆盖", "Coverage"),
    "文档内容质量 / Documentation quality": ("文档内容质量", "Documentation quality"),
    "原生指令检查 / Native directive checks": ("原生指令检查", "Native directive checks"),
    "示例验证 / Doctest": ("示例验证", "Doctest"),
    "诊断与缺口 / Diagnostics": ("诊断与缺口", "Diagnostics"),
    "API 变化 / API diff": ("API 变化", "API diff"),
    "构建来源 / Provenance": ("构建来源", "Provenance"),
    "全部验证结果 / All validation results": ("全部验证结果", "All validation results"),
    "。分子、分母和百分比均来自原报告；覆盖率不证明契约正确。 All values come from the native report; coverage is not correctness.":
        ("。分子、分母和百分比均来自原报告；覆盖率不证明契约正确。", "All values come from the native report; coverage is not correctness."),
    "这是原生保守占位文本启发式，不是语义正确性证明。 Values and findings come directly from the native report.":
        ("这是原生保守占位文本启发式，不是语义正确性证明。", "Values and findings use the native conservative placeholder heuristic; they do not prove semantic correctness."),
    "Compile, run, expected compile failure and skipped source examples are checked by the native CLI. 这是整次命令证据；当前引擎没有逐例结果报告，因此不宣称每个示例的独立通过状态。":
        ("原生命令检查只编译、运行、预期编译失败和跳过的源码示例。这是整次命令证据；当前引擎没有逐例结果报告，不宣称每个示例的独立通过状态。", "The native CLI checks compile, run, expected compile failure and skipped source examples. This is aggregate command evidence, not individual example results."),
    "此 legacy doctest/results.json 执行器记录编译后运行与跳过；不提供 compile-only 或 expected-failure 成功转换。 New native directive checks are shown separately as aggregate command evidence. Failed remains failed, including deliberately invalid diagnostic examples.":
        ("旧 doctest/results.json 执行器记录编译后运行与跳过，不把只编译或预期失败转换为成功。原生指令检查单独展示整次命令证据。故意错误的诊断示例仍保留失败状态。", "The legacy doctest/results.json runner records execution after compilation and skips; it does not convert compile-only or expected-failure cases into success. Native directive checks are separate aggregate evidence. Deliberately invalid diagnostic examples remain failed."),
    "分类、匹配状态与证据直接来自原生 diff，不在展示层重新判定。版本通过本次真实输入快照与原生文档索引绑定。 ":
        ("分类、匹配状态与证据直接来自原生 diff，不在展示层重新判定。版本通过本次真实输入快照与原生文档索引绑定。 ", "Classifications, matching states and evidence come directly from the native diff. Versions are bound to the exact input snapshots and native indices. "),
}

# Reader-facing wording for the raw native diff vocabulary. Raw values stay in
# data-* attributes and the raw JSON block for traceability.
DIFF_CLASSIFICATIONS = {
    "additive": ("新增兼容变化", "Added"),
    "breaking": ("不兼容变化", "Breaking"),
    "potentially-breaking": ("潜在不兼容变化", "Potentially breaking"),
    "documentation-only": ("仅文档变化", "Documentation only"),
    "metadata-only": ("仅元数据变化", "Metadata only"),
    "unchanged": ("未变化", "Unchanged"),
}

DIFF_MATCH_STATES = {
    "ambiguous": ("匹配歧义，未自动判定", "Ambiguous match, not auto-resolved"),
    "added": ("新增声明", "Added declaration"),
    "removed": ("删除声明", "Removed declaration"),
    "exact": ("签名与结构一致", "Signature and structure match"),
    "fallback": ("按名称回退匹配", "Matched by name fallback"),
    "changed": ("签名变化", "Signature changed"),
}


ZH = {
    "semanticLinks counts explicit comment references and @see links only; signature type links are reported separately in diagnostics. A zero denominator means no applicable items; the original percentage remains in the raw report.":
        "注释引用解析率仅统计注释中的显式引用与 @see；签名类型链接另列在诊断中。分母为零表示无适用项，原始百分比仍保留在原始报告中。",
    "Not attached for this version. This is not a completed diff demonstration.": "此版本未附变化报告，不能视为已完成版本比较。",
    "Not attached. No execution claim is made.": "未附执行报告，不宣称示例已执行。",
    "No diagnostics were emitted. This is not a proof of semantic completeness.": "未产生诊断，这不证明语义信息完整。",
    "Raw Doc IR with diagnostic source ranges": "原始文档 IR 与诊断源码范围",
    "View / download exact checked source": "查看或下载实际检查的源码",
    "Input hashes and build metadata": "输入哈希与构建信息",
    "Raw native check evidence": "原生检查的原始证据",
    "Raw diagnostic JSON": "原始诊断 JSON",
    "Raw coverage JSON": "原始覆盖率 JSON",
    "Raw quality JSON": "原始内容质量 JSON",
    "Raw doctest JSON": "原始示例验证 JSON",
    "Raw API diff JSON": "原始 API 变化 JSON",
    "Baseline snapshot": "变更前快照", "Current snapshot": "变更后快照",
    "Exact input hashes": "准确输入哈希", "Filter diagnostics": "筛选诊断",
    "Project diagnostic": "项目诊断", "Not applicable": "无适用项",
    "Source @example": "源码 @example", "Source API": "对应 API",
    "Collection state: ": "采集状态：", "Audience: ": "面向读者：", "; audience: ": "；面向读者：",
    "; assessment: ": "；评估方法：", "Summary: ": "汇总：", "Mode: ": "模式：",
    "Exit code: ": "退出码：", "exitCode: ": "退出码：", "; durationMs: ": "；耗时（毫秒）：",
    "; timeout-ms: ": "；超时（毫秒）：", "; memory-mb: ": "；内存（MiB）：", "; jobs: ": "；并行任务：",
    "; comparisonState: ": "；比较状态：", "matchState: ": "匹配状态：",
    "Before: ": "变更前：", "After: ": "变更后：", " diagnostics": " 条诊断",
    " / warning": " / 警告", " / error": " / 错误", " / info": " / 信息",
    ": passed": "：通过", ": failed": "：失败", ": skipped": "：跳过", ": timeout": "：超时",
    "documentation summary is missing": "缺少文档摘要",
    "documentation description is empty": "文档详细说明为空",
    "value-returning symbol is missing @return documentation": "有返回值的声明缺少 @return 说明",
    "public symbol is missing an @example": "公开声明缺少 @example 示例",
    "return type has an unresolved type link": "返回类型的文档链接未解析",
}

EXACT_ZH = {
    "Before: absent": "变更前：无此声明", "After: absent": "变更后：无此声明",
    "Scope": "范围", "Name": "名称", "Metric": "指标", "Documented": "已记录", "Total": "总数",
    "Percent": "百分比", "Meaningful": "有效内容", "project": "项目", "all": "全部",
    "packages": "包", "modules": "模块", "symbols": "声明摘要", "parameters": "参数说明",
    "returns": "返回说明", "throws": "已写异常说明", "examples": "示例", "deprecated": "弃用说明",
    "semanticLinks": "注释引用解析率", "additive": "新增兼容变化", "breaking": "不兼容变化",
    "potentially-breaking": "潜在不兼容变化", "documentation-only": "仅文档变化", "metadata-only": "仅元数据变化",
    "doctest": "示例验证", "api-diff": "API 变化", "coverage": "文档覆盖", "diagnostics": "诊断", "provenance": "构建来源",
}


class LocalizedUI(HTMLParser):
    def __init__(self, text: str, locale: str) -> None:
        super().__init__(convert_charrefs=False)
        self.locale, self.protected, self.output = locale, 0, []
        self.source_spans = []
        self.feed(text)

    def handle_starttag(self, tag: str, attrs: list) -> None:
        if tag in {"pre", "code"}:
            self.protected += 1
        if tag == "span":
            source_text = "data-report-source-text" in dict(attrs)
            self.source_spans.append(source_text)
            if source_text:
                self.protected += 1
        original = self.get_starttag_text()
        if self.locale == "zh-CN" and tag == "input" and "data-report-filter" in dict(attrs):
            original = original.replace('placeholder="API, file, code or message"', 'placeholder="API、文件、诊断码或说明"')
        self.output.append(original)

    def handle_endtag(self, tag: str) -> None:
        self.output.append(f"</{tag}>")
        if tag in {"pre", "code"}:
            self.protected -= 1
        if tag == "span" and self.source_spans and self.source_spans.pop():
            self.protected -= 1

    def handle_data(self, value: str) -> None:
        if not self.protected:
            for original, alternatives in HEADINGS.items():
                value = value.replace(original, alternatives[0 if self.locale == "zh-CN" else 1])
            if self.locale == "zh-CN":
                if value in EXACT_ZH:
                    value = EXACT_ZH[value]
                else:
                    for original, translated in ZH.items():
                        value = value.replace(original, translated)
        self.output.append(html.escape(value, quote=False))

    def handle_entityref(self, name: str) -> None:
        self.output.append('&' + name + ';')

    def handle_charref(self, name: str) -> None:
        self.output.append('&#' + name + ';')


def localize_ui(text: str, locale: str) -> str:
    return ''.join(LocalizedUI(text, locale).output)
