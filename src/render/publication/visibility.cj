protected package cjdoc.render.publication

import cjdoc.model.*
import cjdoc.render.codec.isDocIrContainerKind
import std.collection.*

protected func isContainerDeclaration(symbol: SymbolDoc): Bool {
    isDocIrContainerKind(symbol.kind)
}

protected func indexSymbols(documentation: DocumentationSet): HashMap<String, SymbolDoc> {
    let index = HashMap<String, SymbolDoc>()
    for (symbol in documentation.declarations) { index[symbol.id] = symbol }
    index
}


protected func isTypeDeclaration(symbol: SymbolDoc): Bool {
    symbol.kind == "class" || symbol.kind == "struct" || symbol.kind == "interface" ||
        symbol.kind == "enum" || symbol.kind == "typeAlias"
}
