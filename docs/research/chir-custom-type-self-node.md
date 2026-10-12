# CHIR custom-type self node: measurement and verdict

Investigated because a review comment on the CI PR (#84) claimed that the worker's pre-order type
walk makes the source argument `Int64` receive the canonical identity `Box` for a signature such as
`Box<Int64>`.

## Measurement

```json
{
  "conclusion": "No source change to the provider or worker is justified: the misattribution does not reproduce, the consumer already guards the shape, and the only real gap was missing coverage for the several-argument form, which this change adds.",
  "consumerHandling": {
    "code": "src/chir_provider.cj unwraps exactly one leading self node via chirDirectChildren",
    "condition": "rawChildren.size == 1 && nodes[rawChildren[0]].qualifiedName == head.qualifiedName",
    "existingTests": [
      "chirSelfWrapperIsUnwrappedIntoOneArgument",
      "chirSelfWrapperWithoutInnerNodeYieldsNoArgument",
      "nestedSameNamedArgumentIsPreserved"
    ],
    "gapClosedHere": "severalTypeArgumentsStayUnderTheSingleSelfWrapper: several arguments stay under the single self node, so one level of unwrapping is sufficient and does not depend on the argument count"
  },
  "endToEnd": "generate --semantic chir for `public func unwrapInt(x: Box<Int64>): Int64` reports CJDOC2102 (FALLBACK) and emits the parameter source-only with semantic.state 'unavailable'; no resolved identity is claimed, so Int64 cannot be linked as Box.",
  "finding": "CustomType.typeArgs exposes the receiver as ONE leading self node, for one or several type arguments alike. A pre-order walk therefore repeats the type once at the node level, which matches the review observation.",
  "issue": "review thread PRRT_kwDOUIK_R86rEGrY on PR #84: 'Remove the duplicated custom-type node'",
  "measuredShapes": {
    "Box<Int64>": [
      "Box(args=1)",
      "CustomType Box(args=1)",
      "Int64"
    ],
    "Pair<Int64,String>": [
      "Pair(args=1)",
      "CustomType Pair(args=2)",
      "Int64",
      "std.core.String"
    ],
    "std.core.Collection<T>": [
      "Collection(args=1)",
      "CustomType Collection(args=1)",
      "T"
    ]
  },
  "method": "cjc --output-type=staticlib --emit-chir=raw, then stdx.chir deserializePackage; walked funcSrcCodeType.paramTypes and every CustomType.typeArgs entry",
  "recordedAt": "2026-10-12T01:13:09.044190+00:00",
  "schemaVersion": "cjdoc.chir-typeargs-probe/1",
  "toolchain": "Cangjie Compiler 1.3.0-alpha.06 (cjnative) + matching dynamic stdx sidecar",
  "verdict": "not reproducible as described"
}
```
