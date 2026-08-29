# stdx.chir and Source-CHIR binding findings

## Current daily result

20260829 `cjc` 可以生成 raw/opt serialized CHIR，`chir-dis` 可以反序列化成人类可读文本。然而同一 daily 的 stdx sidecar 没有 `stdx.chir.cjo`，所以普通 cjpm/cjc 项目无法 import `stdx.chir`。

Probe sources:

- `probes/chir_flow/fixture.cj`
- `probes/chir_loader/main.cj`

current daily loader 编译的确定结果：

```text
error: can not find package 'stdx.chir'
```

## Same-version local sidecar experiment

本机另有一套 compiler/stdlib/stdx 均为 `0.0.1` 的 local build。它不是 current daily，只用于确认公开 API 可以真实运行。使用显式 `--import-path`, `-L`, `-l stdx.chir` 和 `LD_LIBRARY_PATH` 后，以下调用通过：

```cj
let pkg = deserializePackage(CPointer<UInt8>(raw.pointer), bytes.size)
```

fixture 的关键输出：

```text
package=chir_probe
classes=2
structs=1
enums=1
extends=1
function=parse|public=true|owner=Parser|type=(String) -> T
function=parse|public=true|owner=Parser|type=(Array<UInt8>) -> T
function=pretty|public=true|owner=|type=() -> String
function=transform|public=true|owner=<package>|generic=1
function=解析|public=true|owner=<package>|type=(String) -> String
member=value|type=T|location=fixture.cj-8-5, scope: 0
extend=chir_probe:Parser|methods=1
```

输出中的类型名称在实际 CHIR 中带 canonical/internal identity；上面的片段为阅读性省略，完整 probe 会打印真实值。

## Source to CHIR binding gate

优先 key 原计划为 `file + kind + name + start line/column + owner`，signature 只辅助消歧。实测无法构造这个 key：`Function` 没有公开 `location`/`debugLocation`。当前 stdx 源码中存在 internal `_propLocation`，但没有 public getter。`MemberVar.location` 与当前源码树的 `CustomTypeDef.location` 不足以覆盖函数和 overload。

| Case | Result | 证据/原因 |
|---|---|---|
| same-name overload | FAIL | CHIR signature 能区分 overload，但 Function 无位置，不能可靠对应 source declaration |
| nested/member function | PARTIAL | `declaredParent` 对普通成员可用；仍无 source position |
| multiline signature | FAIL | CHIR 无公开 Function span，换行场景不能定位 |
| annotation | UNKNOWN | 当前源码公开 `customAnnoInstances`；current daily 无 artifact，local artifact 版本又不含同一 API surface |
| generic function | PARTIAL | local probe 得到 generic arity/type；仍无法位置回绑 |
| extension function | PARTIAL | ExtendDef target/methods 可读，但 method `declaredParent` 为空且无位置 |
| Unicode identifier | PARTIAL | source AST 与 local CHIR 都保留 `解析`；没有 location 完成双向证明 |

明确回答：**CHIR DebugLocation 当前不足以可靠地把 semantic Function 映射回 source declaration，结果是 FAIL。**

不采用的 fallback：

- 不解析 `.chirtxt` 中看似存在的位置；该格式不是公开稳定 API。
- 不按 mangled name 或字符串 type 猜测并标记为 Resolved。
- 不修改 compiler/stdx，也不复制内部反序列化器。

因此当前 explicit fallback 是 `std.ast -> SourceSnapshot -> AstSemanticProvider -> DocumentationBinder -> Doc IR`。`SemanticProvider` 接收 source snapshot 并返回 provider-neutral semantic result；未来只有当 G1-G7 全部通过才在独立 package 增加 `ChirSemanticProvider`。
