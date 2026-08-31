# std.ast findings

## Lexer probe

Probe: `probes/ast_lexer/main.cj`

```bash
source /home/elliot/cangjie_sdk/main/linux_x64/vanilla/20260829/cangjie/envsetup.sh
cjc probes/ast_lexer/main.cj -o /tmp/probe_ast_lexer
/tmp/probe_ast_lexer
```

| 能力 | 实际 API | 结果 | 限制 |
|---|---|---|---|
| 词法分析 | `cangjieLex(source)` | PASS | 返回可迭代的 `Tokens` |
| token kind | `Token.kind`, `TokenKind.COMMENT` | PASS | `/** ... */` 与普通 block comment 都是 COMMENT，需检查 value 前缀 |
| token text | `Token.value` | PASS | 原始 CRLF 保留在 value 中 |
| token position | `Token.pos.line`, `Token.pos.column` | PASS | 1-based；column 按 UTF-8 byte 计数 |
| doc comment 识别 | `kind == COMMENT && value.startsWith("/**")` | PASS | `/* */` 与 `//` 默认不收集 |

LF、CRLF、中文注释与中文标识符均实际运行。中文 probe 中 `/** 中文 */` 后的换行 token column 为 14，证明 column 不是 Unicode scalar 数量。

## Parser probe

Probe: `probes/ast_parser/main.cj`

```bash
cjc probes/ast_parser/main.cj -o /tmp/probe_ast_parser
/tmp/probe_ast_parser
```

核心入口是 `parseProgram(cangjieLex(source))`，遍历入口是 `Program.traverse(visitor)`，visitor 继承 `Visitor` 并 override 对应 `visit`。

| 结构 | Visitor/API | Result | 实际观察 |
|---|---|---|---|
| class | `visit(ClassDecl)` | PASS | `identifier`, `beginPos`, `endPos` 可读 |
| struct | `visit(StructDecl)` | PASS | 同上 |
| interface | `visit(InterfaceDecl)` | PASS | 无显式 modifier 的接口成员需按 owner 解释为 public |
| enum | `visit(EnumDecl)`, `EnumDecl.constructors` | PASS | case 作为独立 `enumCase`；Constructor 自身 range 为 `0:0`，范围由首末 token 推导 |
| extend | `visit(ExtendDecl)`, `extendType` | PASS | 真实字段是 `extendType`，不是 `extendedType` |
| supertype relationship | `ClassDecl/StructDecl/InterfaceDecl/EnumDecl/ExtendDecl.superTypes` | PASS | 实际类型均为 `ArrayList<TypeNode>`；只提供 AST spelling，不区分 class inheritance 与 interface conformance 的语义结果 |
| extension target | `ExtendDecl.extendType: TypeNode` | PASS | 可稳定取得含泛型实参的源码类型结构；当前只标记 `partial`，不解析为 canonical type |
| func | `visit(FuncDecl)`, `funcParams`, `declType` | PASS | `init` 同样以 FuncDecl 出现 |
| prop | `visit(PropDecl)` | PASS | 生成的 getter 也被遍历，但位置为 `0:0`，必须过滤 |
| constructor | `FuncDecl.identifier == "init"`, `visit(PrimaryCtorDecl)` | PASS | 普通 init 与 primary constructor 均进入 Doc IR；primary 参数来自 `funcParams` |
| type alias | `visit(TypeAliasDecl)` | PASS | identifier/range 可读 |
| generic declaration | `Decl.isGenericDecl`, `genericParam.parameters` | PASS | MVP 只记录 AST spelling，语义状态为 partial |
| member declaration | source range containment | PASS | class/interface/struct/extend 成员已覆盖；函数局部 declaration 被过滤。仓颉 class declaration 只能位于顶层，因此不构造不存在的 nested type fixture |
| annotations | `Decl.annotations` | PASS | 通过 token spelling 保存，不解析宏执行结果 |

实际 parser 输出包含：

```text
interface|Reader|2:1|2:47
class|Parser|3:1|9:2
func|init|5:5|5:49
prop|count|8:5|8:45
func|get|0:0|0:0
extend|Parser < String >|13:1|13:75
relationship|Parser|superType|Reader
relationship|extend|extensionTarget|Parser < String >
relationship|extend|superType|Reader
type-alias|Name|14:1|14:26
```

## 对 MVP 的结论

- `std.ast` 足以作为 source truth：注释、源码位置、声明结构、modifier、annotation、参数和类型 spelling。
- 对已支持 declaration，`sourceSignature` 由 AST range 回到原始 UTF-8 source
  切片，并使用 lexer token 深度找到 body 左花括号，因此保留 annotation、换行和
  内部空格。enum case 的节点 range 无效，改用 constructor 首末 token 位置。
- AST type spelling 不是 type checking 结果，所以 Doc IR 明确写 `state: partial`、`canonical: null`。
- 内部 source snapshot 保存 `superType` 和 `extensionTarget` spelling；v5 provider capability 将 relationships 标为 false，不会把它升级为 semantic inheritance/implementation 或自动生成类型链接。
- 任何 0/invalid position 的生成节点都不作为 source declaration。
- 20260829 daily 的 `parseProgram` 在 67 层连续 `BinaryExpr` 上可稳定触发 native
  SIGSEGV；66 层 PASS。产品在隔离 worker 中运行 parser；若 worker 因 SIGSEGV
  退出，再以 lexer token 深度确认已知的连续二元表达式形状并产生可恢复的
  `CJDOC1012`。因此 enum case 和嵌套泛型等可正常解析的标点不会被误判。普通
  parser exception 保留为 `CJDOC1011`，该文件被跳过，其他文件仍进入 partial
  Doc IR。
