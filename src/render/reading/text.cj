protected package cjdoc.render.reading

import cjdoc.model.*
import cjdoc.render.routes.label
import cjdoc.render.foundation.{RenderTextBuffer, markdownNodeText}

protected func typeHeadSpelling(spelling: String): String {
    match (spelling.indexOf("<")) {
        case Some(index) => spelling[..index].trimAscii()
        case None => spelling
    }
}

protected func typeGenericSuffix(spelling: String): String {
    let bytes = spelling.toArray()
    var depth: Int64 = 0
    var genericEnd: Int64 = -1
    var index: Int64 = 0
    for (byte in bytes) {
        if (byte == b'<') {
            depth++
        } else if (byte == b'>' && depth > 0) {
            depth--
            if (depth == 0) { genericEnd = index }
        }
        index++
    }
    if (genericEnd < 0 || genericEnd + 1 >= spelling.size) { "" }
    else { spelling[genericEnd + 1..] }
}

// Some source/AST providers record a generic type's spelling with trivia around
// angle brackets. Normalize only this display spelling; source signatures and
// semantic identities must remain byte-for-byte intact. Function arrows and
// generic constraints are deliberately left untouched.
protected func genericTypeDisplaySpelling(spelling: String): String {
    if (!spelling.contains("<") || spelling.contains("->") || spelling.contains("<:")) {
        return spelling
    }
    spelling.replace(" <", "<").replace("< ", "<")
        .replace(" >", ">").replace("> ", ">").replace(" ,", ",")
}

protected func contentLanguageLabel(tag: DocTag, locale: String): String {
    let language = tag.contentLanguage.getOrDefault({ => label(locale, "unknown language", "语言未知") })
    match (tag.translationState) {
        case "fallback" => label(locale, "Translation missing. Original text: ", "暂无当前语言翻译，原文：") + language
        case "empty-fallback" => label(locale, "Empty translation; original text: ", "译文为空；原文：") + language
        case "conflict-fallback" => label(locale, "Translation conflict; original text: ", "译文冲突；原文：") + language
        case "empty" => label(locale, "Translation is empty", "译文为空")
        case "conflict" => label(locale, "Translation conflict", "译文冲突")
        case "missing" => label(locale, "Translation missing", "翻译缺失")
        case "unpaired" => if (tag.contentLanguage == Some(locale)) { "" }
            else { label(locale, "Original text: ", "原文：") + language }
        case "unknown" => language
        case _ => language
    }
}

protected func findTag(comment: DocComment, name: String, subject!: ?String = None): ?DocTag {
    for (tag in comment.tags) {
        if (tag.name == name && (subject.isNone() || tag.subject == subject.getOrThrow())) { return Some(tag) }
    }
    None
}

protected func isUnitType(value: TypeRef): Bool {
    match (value.semantic.canonical) {
        case Some(canonical) => canonical == "Unit" || canonical == "std.core.Unit"
        case None => value.spelling.trimAscii() == "Unit"
    }
}

protected func summaryParagraph(comment: DocComment): ?MarkdownNode {
    if (comment.markdown.kind == "paragraph") { return Some(comment.markdown) }
    for (child in comment.markdown.children) {
        if (child.kind == "paragraph") { return Some(child) }
    }
    None
}

protected func topLevelParagraphIndex(comment: DocComment): Int64 {
    if (comment.markdown.kind == "paragraph") { return 0 }
    var index: Int64 = 0
    for (child in comment.markdown.children) {
        if (child.kind == "paragraph") { return index }
        index++
    }
    -1
}

protected func summaryPlainText(comment: DocComment): String {
    if (comment.localizationScope != "admonitions" && !comment.localizedTexts.isEmpty()) {
        for (tag in comment.tags where tag.name == "summary") {
            if (let Some(tree) <- tag.descriptionMarkdown) { return markdownNodeText(tree).trimAscii() }
        }
        return comment.summary.trimAscii()
    }
    match (summaryParagraph(comment)) {
        case Some(paragraph) => markdownNodeText(paragraph)
        case None =>
            if (comment.markdown.children.isEmpty() && comment.markdown.literal.isEmpty()) {
                comment.summary.trimAscii()
            } else { "" }
    }
}

// Human-facing labels should not expose internal relation-kind spellings.
protected func readerRelationshipLabel(kind: String, locale: String): String {
    if (locale == "zh-CN") {
        if (kind == "subType") { return "子类型" }
        return htmlKindLabel(kind, locale)
    }
    match (kind) {
        case "superType" => "Parent type"
        case "subType" => "Subtype"
        case "extensionTarget" => "Extension target"
        case "genericConstraint" => "Generic constraint"
        case "extendedBy" => "Extended by"
        case "inheritedMember" => "Inherited member"
        case "implements" => "Implements"
        case "implementedBy" => "Implemented by"
        case "override" => "Overrides"
        case "overriddenBy" => "Overridden by"
        case "overrides" => "Overrides"
        case "inherits" => "Inherits"
        case _ => htmlKindLabel(kind, locale)
    }
}

protected func htmlKindLabel(kind: String, locale: String): String {
    if (locale != "zh-CN") { return englishKindLabel(kind) }
    match (kind) {
        case "class" => "类"
        case "struct" => "结构体"
        case "interface" => "接口"
        case "enum" => "枚举"
        case "enumCase" => "枚举项"
        case "constructor" => "构造器"
        case "function" => "函数"
        case "macro" => "宏"
        case "property" => "属性"
        case "variable" => "变量"
        case "typeAlias" => "类型别名"
        case "extend" => "扩展"
        case "root" => "主模块"
        case "dependency" => "依赖模块"
        case "superType" => "父类型"
        case "extensionTarget" => "扩展目标"
        case "genericConstraint" => "泛型约束"
        case "parameter" => "参数"
        case "return" => "返回值"
        case "field" => "字段"
        case "extendedBy" => "由扩展声明提供"
        case "inheritedMember" => "继承成员"
        case "packageAlias" => "包别名"
        case "single" => "单项导入"
        case "alias" => "别名导入"
        case "all" => "全部导入"
        case "multi" => "多项导入"
        case "inherits" => "继承"
        case "overrides" => "重写"
        case "override" => "重写"
        case "overriddenBy" => "被重写"
        case "implements" => "实现"
        case "implementedBy" => "被实现"
        case _ => kind
    }
}

// Camel-case IR kinds read as identifiers in badges; the rest are already words.
private func englishKindLabel(kind: String): String {
    match (kind) {
        case "typeAlias" => "type alias"
        case "enumCase" => "enum case"
        case "extend" => "extension"
        case _ => kind
    }
}


// reader surface (HTML, site Markdown, declaration Markdown) selects them
// through this predicate instead of keeping a private copy of the list.
public func isBehaviorContractTag(name: String): Bool {
    name == "precondition" || name == "postcondition" || name == "invariant" ||
        name == "performance" || name == "state" || name == "concurrency" ||
        name == "platform" || name == "compatibility" || name == "error"
}

// Calling context includes these published lifecycle/error/version conditions
// even when the descriptive narrative is not selected.
protected func isCallContractTag(name: String): Bool {
    isBehaviorContractTag(name) || name == "throws" || name == "deprecated" || name == "since"
}

protected let DECLARATION_MARKDOWN_SECTIONS: Array<String> = ["signature", "description",
    "parameters", "returns", "contracts", "examples", "relations", "source"]

protected func behaviorContractLabel(name: String, locale: String): String {
    if (locale != "zh-CN") { return name }
    match (name) {
        case "precondition" => "前置条件"
        case "postcondition" => "后置条件"
        case "invariant" => "不变量"
        case "performance" => "性能"
        case "state" => "状态"
        case "concurrency" => "并发"
        case "platform" => "平台"
        case "compatibility" => "兼容性"
        case "error" => "错误行为"
        case _ => name
    }
}
