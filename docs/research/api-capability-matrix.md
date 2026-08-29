# cjdoc API capability matrix

调查日期：2026-08-29，2026-08-30 重新核对当前 `PATH`。结论来自本机 SDK 实物、可编译/可运行 probe 和本机 `cangjie_stdx` 源码；不是仅依据在线文档。

## 实际环境

| 项目 | 实际值 |
|---|---|
| latest daily compiler | `1.1.0-alpha.20260829040003 (cjnative)` |
| target | `x86_64-unknown-linux-gnu` |
| cjpm | `1.1.3` |
| compiler root | `/home/elliot/cangjie_sdk/main/linux_x64/vanilla/20260829/cangjie` |
| stdx sidecar | `/home/elliot/cangjie_sdk/main/linux_x64/vanilla/20260829/linux_x86_64_cjnative/dynamic/stdx` |
| current `daily` compiler path | `/home/elliot/cangjie_sdk/daily/cangjie/bin/cjc`，版本指向上面的 20260829 daily |
| `std.ast` artifact | compiler SDK 的 `modules/linux_x86_64_cjnative/std/std.ast.cjo` |
| `stdx.chir` artifact in 20260829 daily | **不存在**；dynamic/static stdx 目录和原始 stdx zip 均已检查 |

20260829 daily 确实包含 stdx；失败点不是“没有 stdx”，而是该 sidecar 没有交付 `stdx.chir` package。

## cjc CHIR 链路

`cjc --help` 中的真实选项是：

```text
--emit-chir <raw|opt>
--dump-chir
--output-type <exe|staticlib|dylib>
```

以下链路在 20260829 daily 上通过：

```bash
cjc --output-type=staticlib --emit-chir=raw \
  -o /tmp/cjdoc-probe-fixture.chir probes/chir_flow/fixture.cj
chir-dis /tmp/cjdoc-probe-fixture.chir
```

`.chir` 是二进制序列化文件，`chir-dis` 生成供人阅读的 `.chirtxt`。cjdoc 不解析该文本。

以下链路在 20260829 daily 上失败：

```bash
cjc --import-path "$CANGJIE_STDX_PATH" -L "$CANGJIE_STDX_PATH" \
  -l stdx.chir -o /tmp/chir-loader probes/chir_loader/main.cj
```

编译器的确定错误为 `can not find package 'stdx.chir'`。

## 总能力矩阵

结果只使用 `PASS`、`PARTIAL`、`FAIL`、`UNKNOWN`。`local sidecar` 指本机另一套 `0.0.1` compiler/stdlib/stdx 同版本组合；它只能证明 API 形态可运行，不能替代 current daily 的可用性证明。

| Feature | Result | 经 probe 验证的 API / 证据 |
|---|---|---|
| Lexer / doc comment token | PASS | `cangjieLex`, `Token.kind`, `Token.value`, `Token.pos`, `TokenKind.COMMENT` |
| Parser / traversal | PASS | `parseProgram`, `Program.traverse`, `Visitor` |
| Source declaration range | PASS | `Decl.beginPos`, `Decl.endPos`；生成 getter 为 `0:0`，会被过滤 |
| Raw declaration spelling | PASS | 对已支持 declaration 使用 AST range 定位，并从原始 UTF-8 source 做 byte slice；header 终点由 lexer token 深度确定，不用正则 |
| Serialized CHIR generation | PASS | 20260829 `cjc --emit-chir=raw` + `chir-dis` |
| `stdx.chir` Package loading in current daily | FAIL | 20260829 stdx 中无 `stdx.chir.cjo` |
| Package | PARTIAL | local sidecar 的 `deserializePackage(...): Package` PASS；current daily 不可导入 |
| Function enumeration | PARTIAL | local sidecar `Package.functions` PASS；含编译器生成函数，需要过滤 package/name |
| Parameter | PARTIAL | `Function.parameters` PASS，但成员函数包含隐式 receiver，需语义过滤 |
| Class / interface | PARTIAL | `Package.classDefs`, `ClassDef.methods`, `instanceVars`, `implementedInterfaceTypes` PASS；current daily 不可导入 |
| Struct | PARTIAL | `Package.structDefs` PASS；current daily 不可导入 |
| Enum | PARTIAL | `Package.enumDefs` PASS；current daily 不可导入 |
| Extend | PARTIAL | `Package.extendDefs`, `ExtendDef.extendedType`, `methods` PASS；extension method 的 `declaredParent` 为空 |
| MemberVar | PARTIAL | `instanceVars`, `name`, `ty`, `location` PASS；current daily 不可导入 |
| AccessLevel | PARTIAL | `isPublic()` 区分 fixture 的 public/private；完整 public/protected/internal/private 枚举未发现 |
| Function owner | PARTIAL | class/interface/struct method 的 `declaredParent` PASS；extension method owner 缺失 |
| Generic parameters | PARTIAL | type/function `genericTypeParams` PASS；current daily 不可导入 |
| Parameter/return semantic type | PARTIAL | `funcSrcCodeType`, `parameters`, `Type.qualifiedName` 可读；输出仍包含 CHIR generic identity |
| Function signature | PARTIAL | 两个 `parse` overload 的 `funcSrcCodeType` 不同；current daily 不可导入 |
| Overload distinction | PARTIAL | String 与 `Array<UInt8>` overload 可区分；没有 source location 完成回绑 |
| Inheritance/interface relationship | PARTIAL | `implementedInterfaceTypes` 在 fixture 为 1；current daily 不可导入 |
| Annotation | UNKNOWN | 当前源码树公开 `customAnnoInstances`，本机 local sidecar artifact 版本较旧，未能编译该访问；current daily 无包 |
| Custom type DebugLocation | PARTIAL | 当前 stdx 源码公开 `CustomTypeDef.location`，但 20260829 daily 无可导入 artifact |
| MemberVar DebugLocation | PARTIAL | local sidecar 实际输出 `fixture.cj-8-5` |
| Function DebugLocation | FAIL | `Function` 内部有 `_propLocation`，没有 public read-only location API |
| Extension target | PARTIAL | `ExtendDef.extendedType.qualifiedName` PASS；方法本身 owner 为空 |
| Override relation | UNKNOWN | probe 未找到稳定的直接 override relationship API |
| Macro origin | UNKNOWN | 未发现可用于文档映射的稳定 origin API |
| Comments in CHIR | FAIL | 没有文档注释 API；注释必须来自 source lexer |

## Architecture Gate

| Gate | Result | 原因 |
|---|---|---|
| G1 稳定读取项目 CHIR | PASS | `cjc --emit-chir=raw` 和 `chir-dis` 均通过 |
| G2 枚举主要 public declaration | FAIL | current daily 普通项目无法导入 `stdx.chir` |
| G3 access level | FAIL | current daily 无 loader；local API 只验证了 `isPublic()` |
| G4 semantic type/signature | FAIL | current daily 无 loader |
| G5 declaration owner | FAIL | current daily 无 loader，且 local extension method owner 为空 |
| G6 source location 足以 binding | FAIL | Function 没有公开 location/debugLocation |
| G7 普通项目可依赖 `stdx.chir` | FAIL | 20260829 stdx sidecar 未交付该 package |

**决策：Gate C，且 v0.4 明确推迟 CHIR。** 当前使用 `std.ast -> SourceSnapshot -> AstSemanticProvider -> DocumentationBinder -> Doc IR`。公开 `SemanticProviderFactory`/`SemanticProviderSession` 是 provider-neutral 边界；所有 AST 类型均标为 `partial` 或 `unavailable`，不会伪装为 `resolved`。不复制 compiler parser、不解析 CHIR dump、不修改 compiler/stdx。

按当前版本范围，CHIR adapter 只保留为后续接入点；v0.4.0 的构建、运行、测试和 renderer 均不依赖 `stdx.chir`。未来只有重新验证 G1 到 G7 全部 PASS，才允许独立实现 `ChirSemanticProvider`。
