# stdx.chir and source–CHIR binding findings

## Verification baseline

The current integration uses a same-version Cangjie 1.3.0 compiler and `stdx` sidecar. The repository wrapper authenticates the compiler and sidecar artifacts, verifies their target/version, and exposes the selected sidecar through `CANGJIE_STDX_PATH`. The project does not modify the SDK, compiler, std, or stdx sources.

The probe and fixture evidence is repository-relative:

- `probes/chir_flow/fixture.cj`
- `probes/chir_loader/main.cj`
- `tests/fixtures/projects/chir_semantics/src/api.cj`

## Working CHIR path

Explicit `--semantic chir` follows this path:

1. Source discovery reads and normalizes each source file once.
2. The source snapshot records package/import/re-export structure, cfg inputs, and manifest text.
3. A private worker staging directory receives only those captured source bytes.
4. The worker invokes `cjc --emit-chir=raw --output-type=staticlib` with the configured import roots and cfg values.
5. The worker bounds compiler output and artifact size, calls `stdx.chir.deserializePackage`, and emits a small versioned response protocol.
6. The provider adapter consumes structured functions, members, custom types, enum cases, and extension targets.
7. The source provider remains the declaration/comment boundary; unmatched or ambiguous CHIR records produce warnings and source-backed output remains available.

The worker never invokes a shell, network client, or `cjpm`; it does not parse `chir-dis` text or debug strings.

## Public API observations

The current same-version sidecar exposes enough structured data for conservative enrichment:

```text
Package.functions
Package.allCustomTypeDefs
CustomTypeDef.instanceVars/staticVars
EnumDef.constructors
Function.declaredParent
Function.genericTypeParams
Function.funcSrcCodeType.paramTypes
ExtendDef.extendedType
```

The implementation filters `isCompilerAdd()` and `isImported()` records and keeps package identity in every serialized record. Ordinary member owners come from `declaredParent`; extension members use the `ExtendDef` target identity because extension functions do not provide a stable source span.

## Binding limits

A CHIR `Function` has no stable public source span that can be used as the sole binding key. Therefore the provider does not claim exact source-to-CHIR identity. It uses package/name/owner plus generic arity and parameter count as a conservative disambiguator:

| Case | Result | Policy |
|---|---|---|
| unique top-level function | PARTIAL | retain source declaration and attach partial CHIR type data |
| ordinary member function | PARTIAL | match `declaredParent` owner |
| extension function | PARTIAL | match `ExtendDef.extendedType` target |
| same-name overload with unique shape | PARTIAL | accept only one unique shape |
| same-name overload with equal shapes | WARNING | emit `CJDOC2105`, do not claim one-to-one mapping |
| type alias/property without stable CHIR record | WARNING | source-backed result and `CJDOC2106` |
| enum case | PARTIAL | match owner type and constructor source name |
| compiler-generated/imported function | EXCLUDED | filtered before binding |
| comments | SOURCE ONLY | lexer/source snapshot remains authoritative |

The explicit fallback is not a failure of generation: it is the contract that source comments and declarations survive semantic-provider failure. A renderer receives only current Doc IR v11 and never imports `stdx.chir` or a provider implementation.

## Failure categories

- `CJDOC2101`: compiler, worker executable, or compiler version unavailable.
- `CJDOC2102`: captured project input or dependency/build configuration cannot be reproduced by the worker.
- `CJDOC2103`: compiler failure or timeout.
- `CJDOC2104`: raw artifact, deserialization, or worker response failure.
- `CJDOC2105`: one-to-one source mapping is ambiguous.
- `CJDOC2106`: a source declaration is known but cannot be reliably mapped to a structured CHIR record.

This split is intentional: users can distinguish toolchain/input failures from a conservative mapping warning without changing the Doc IR schema or provider SPI.