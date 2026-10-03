package cjdoc.render

import cjdoc.model.*

// Display labels only: IR identifiers and source spellings remain unchanged.
internal func htmlKindLabel(kind: String, locale: String): String {
    if (locale != "zh-CN") { return kind }
    match (kind) {
        case "class" => "类"
        case "struct" => "结构体"
        case "interface" => "接口"
        case "enum" => "枚举"
        case "enumCase" => "枚举项"
        case "constructor" => "构造器"
        case "function" => "函数"
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
        case "implements" => "实现"
        case _ => kind
    }
}

internal func htmlStateLabel(state: String, locale: String): String {
    if (locale != "zh-CN") { return state }
    match (state) {
        case "resolved" => "已解析"
        case "partial" => "部分解析"
        case "unavailable" => "未提供"
        case "ambiguous" => "不明确"
        case "complete" => "完整"
        case "incomplete" => "不完整"
        case "error" => "错误"
        case "warning" => "警告"
        case "info" => "提示"
        case _ => state
    }
}

internal func htmlReferenceStateLabel(state: String, locale: String): String {
    match (state) {
        case "ambiguous" => label(locale, "Documentation link is ambiguous", "文档链接不明确")
        case "resolved" => label(locale, "Documentation link resolved", "文档链接已解析")
        case _ => label(locale, "Documentation link unavailable", "暂无文档链接")
    }
}

internal func htmlContextLabel(symbol: SymbolDoc): String {
    let out = RenderTextBuffer()
    out.append(symbol.name)
    if (!symbol.genericParameters.isEmpty()) {
        out.append("<")
        var first = true
        for (parameter in symbol.genericParameters) {
            if (!first) { out.append(", ") }; first = false
            out.append(parameter)
        }
        out.append(">")
    }
    if (symbol.kind == "function" || symbol.kind == "constructor") {
        out.append("(")
        var first = true
        for (parameter in symbol.parameters) {
            if (!first) { out.append(", ") }; first = false
            out.append(parameter.typeRef.spelling)
        }
        out.append(")")
    }
    out.toString()
}
