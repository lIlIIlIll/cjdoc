#!/usr/bin/env python3
"""Write real Cangjie sources and stable reader tasks; never synthesize a search index."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

RECIPE = "rdr-scale-v1"
MANIFEST = """[package]
cjc-version = "1.2.0"
name = "reader_scale"
organization = ""
description = "Reproducible API reader corpus"
version = "1.0.0"
target-dir = ""
script-dir = ""
output-type = "static"
compile-option = ""
override-compile-option = ""
link-option = ""
package-configuration = {}

[dependencies]
"""
I18N = """[i18n]
default-language = "zh-CN"
languages = ["zh-CN", "en"]
missing-translation = "warn"
"""


def digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def comment(lines: list[str], indent: str = "") -> str:
    return indent + "/**\n" + "".join(indent + " * " + line + "\n" for line in lines) + indent + " */\n"


def matcher(name: str, types: list[str] | None = None) -> dict:
    result = {"qualifiedName": name}
    if types is not None:
        result["parameterTypes"] = types
    return result


def member_type(size: int) -> tuple[str, int]:
    name = f"Member{size}"
    rows = [comment([f"保存 {size} 个可独立定位的阅读槽位。", f"@summary[lang=en] A catalogue of {size} independently addressable slots."]),
            f"public class {name} {{\n"]
    for index in range(size):
        lines = [f"读取编号 {index} 的槽位，保留完整作者正文。"]
        if index % 3 == 0:
            lines.append(f"@summary[lang=en] Read catalogue slot {index} without discarding author text.")
        rows.extend([comment(lines, "    "), f"    public func member{index:04d}(): Int64 {{ {index} }}\n"])
    rows.append("}\n")
    return "".join(rows), size + 1


def overload_type(size: int) -> tuple[str, dict]:
    owner = f"reader_scale.Overload{size}"
    rows = [comment([f"比较 {size} 种显式参数类型，名称不证明语义相同。", f"@summary[lang=en] Select between {size} explicitly different input types."]),
            f"public class Overload{size} {{\n"]
    targets = []
    for index in range(size):
        type_name = f"Choice{index:02d}"
        lines = [f"接受 {type_name}，返回作者声明的类别编号。", f"@summary[lang=en] Accept {type_name} and return its documented category.",
                 f"@param value 类别 {index} 的输入，不推断额外约束。", f"@return 固定编号 {index}。",
                 f"@postcondition 返回值等于 {index}；不声明线程安全或复杂度。"]
        extra = ', retryBudget!: Int64 = 3, descriptiveLabel!: String = "保留作者契约，不截断签名"' if size == 16 and index == 15 else ""
        types = [type_name, "Int64", "String"] if extra else [type_name]
        rows.extend([comment(lines, "    "), f"    public func choose(value: {type_name}{extra}): Int64 {{ {index} }}\n"])
        targets.append({**matcher(owner + ".choose", types),
                        "callShape": f"choose(Choice{index:02d}())", "documentedReturn": index})
    rows.append("}\n")
    return "".join(rows), {"id": f"overloads-{size}", "owner": owner,
                            "name": "choose", "count": size, "targets": targets}


def feature_source() -> tuple[str, int]:
    long_zh = "边界说明保留作者原文，不自动证明行为正确。" * 180 + " rdr_tail_boundary_token"
    long_en = "The complete authored explanation remains available on the API page. " * 90 + "rdr_tail_boundary_token"
    lines = [comment(["可由类型约束显式引用的作者接口。"]),
             "public interface ReaderConstraint { func category(): Int64 }\n",
             comment(["保留泛型约束，不从文本猜测规范类型。"]),
             "public class ConstrainedBox<T> where T <: ReaderConstraint {}\n",
             comment(["保存泛型值。", "@summary[lang=en] Store one generic value."]),
             "public class GenericBox<T> {\n    public let value: T\n    public init(value: T) { this.value = value }\n",
             "    public func mapped<U>(transform: (T) -> U): U { transform(value) }\n}\n",
             "public open class ReaderBase {\n    /** 从基类继承的标记。 */\n    public func inheritedMarker(): Int64 { 1 }\n}\n",
             "public class ReaderDerived <: ReaderBase {}\n",
             "extend ReaderDerived {\n    /** 由扩展提供的标记。 */\n    public func extensionMarker(): Int64 { 2 }\n}\n",
             comment(["按显式命名参数选择标签。", "@param value 原始数值。", "@param retries 调用方指定的重试预算。", "@param label 原样返回的标签。", "@return 输入标签。"]),
             'public func namedOptions(value: Int64, retries!: Int64 = 3, label!: String = "批量"): String { label }\n',
             comment(["搜索契约中的显式 guard 条件。", "@summary[lang=en] Search an explicitly authored guard condition.",
                      "@param value 输入数值。", "@precondition rdr_contract_guard: value >= 0 is the documented caller domain.", "@return 原始数值。"]),
             "public func guardedOperation(value: Int64): Int64 { value }\n",
             comment(["返回具有明确源码拼写的类型。", "@summary[lang=en] Return the explicitly named packet type."]),
             "public func fetchPacket(value: String): Choice15 { Choice15() }\n",
             comment(["保存超过正文索引摘录长度的完整说明。", "", long_zh,
                      "@summary[lang=en] Preserve prose beyond the search excerpt boundary.", "@description[lang=en] " + long_en,
                      "@example 长代码仍须完整渲染", "```cangjie", *[f"let retainedLine{n:03d} = {n}" for n in range(100)], "```"]),
             "public func longContract(): Unit {}\n"]
    # Interface + method, constrained type, generic type/field/init/method,
    # base type/method, derived type, extension/member, and four free functions.
    return "\n".join(lines), 16


def query_cases() -> list[dict]:
    cases = [
        ("exact", "member0499", "reader_scale.Member500.member0499"),
        ("qualified", "reader_scale.Member500.member0499", "reader_scale.Member500.member0499"),
        ("parameter", "param:Choice15", "reader_scale.Overload16.choose"),
        ("return", "return:Choice15", "reader_scale.fetchPacket"),
        ("contract", "rdr_contract_guard", "reader_scale.guardedOperation"),
        ("typo", "member049x", "reader_scale.Member500.member0499"),
        ("package", "package:reader_scale member0499", "reader_scale.Member500.member0499"),
        ("overload", "owner:Overload16 param:Choice15", "reader_scale.Overload16.choose"),
        ("many", "member", "reader_scale.Member500.member0499"),
    ]
    result = []
    for index, (kind, query, expected) in enumerate(cases, 1):
        target = matcher(expected, ["Choice15", "Int64", "String"] if kind in {"parameter", "overload"} else None)
        result.append({"id": f"S{index:03d}", "kind": kind, "query": query,
                       "expected": [target], "expectedOutcome": "hit"})
    result.extend([
        {"id": "S010", "kind": "missing", "query": "rdr_genuinely_absent_token", "expected": [], "expectedOutcome": "absent"},
        {"id": "S011", "kind": "excerpt-boundary", "query": "rdr_tail_boundary_token",
         "expected": [matcher("reader_scale.longContract")], "expectedOutcome": "excerpt-boundary"},
    ])
    return result


def generate_corpus(destination: Path, scale: int) -> dict:
    if scale < 1000 or scale > 50000:
        raise ValueError("declarations must be in 1000..50000")
    destination = destination.absolute()
    destination.mkdir(parents=True, exist_ok=False)
    files = {"cjpm.toml": MANIFEST, "cjdoc.toml": I18N}
    declarations = 0
    members = []
    overloads = []
    for size in (50, 500):
        source, count = member_type(size)
        files[f"src/member{size}.cj"] = "package reader_scale\n\n" + source
        declarations += count
        for ordinal in (1, size):
            members.append({"id": f"member-{size}-{ordinal}", "owner": f"reader_scale.Member{size}",
                            "qualifiedName": f"reader_scale.Member{size}.member{ordinal - 1:04d}", "ordinal": ordinal})
        if size == 500:
            members.append({"id": "member-500-257", "owner": "reader_scale.Member500",
                            "qualifiedName": "reader_scale.Member500.member0256", "ordinal": 257})
    for index in range(16):
        files[f"src/choice{index:02d}.cj"] = f"package reader_scale\n\n/** 输入类别 {index}。 */\npublic class Choice{index:02d} {{}}\n"
        declarations += 1
    for size in (2, 4, 8, 16):
        source, case = overload_type(size)
        files[f"src/overload{size}.cj"] = "package reader_scale\n\n" + source
        declarations += size + 1
        overloads.append(case)
    source, count = feature_source()
    files["src/features.cj"] = "package reader_scale\n\n" + source
    declarations += count
    files["src/exported/library.cj"] = "package reader_scale.exported\n\n/** 原包公开的数值。 */\npublic func exportedValue(): Int64 { 7 }\n"
    files["src/reexport.cj"] = "package reader_scale\n\npublic import reader_scale.exported.*\n"
    declarations += 1
    remaining = scale - declarations
    for start in range(0, remaining, 100):
        package = f"reader_scale.bulk{start // 100:04d}"
        rows = [f"package {package}\n"]
        for index in range(start, min(start + 100, remaining)):
            rows.extend([comment([f"读取稳定槽位 {index}，不修改任何共享状态。"]),
                         f"public func lookup{index:05d}(): Int64 {{ {index} }}\n"])
        files[f"src/bulk{start // 100:04d}/entries.cj"] = "\n".join(rows)
    sources = []
    for relative, text in sorted(files.items()):
        path = destination / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        content = text.encode("utf-8")
        path.write_bytes(content)
        sources.append({"path": relative, "sha256": digest(content)})
    manifest = {"schemaVersion": "cjdoc.reader-corpus/1", "recipe": RECIPE,
                "targetDeclarations": scale, "sourceDeclarations": declarations + remaining,
                "countSemantics": "explicit source declarations; native projection count is measured separately, including re-exports",
                "features": ["50/500-members", "2/4/8/16-overloads", "generic-constraints", "named-default-parameters",
                             "inheritance", "extension", "re-export", "long-contract-code", "zh-CN/en", "missing-translation-fallback"],
                "sources": sources, "queries": query_cases(), "members": members, "overloads": overloads,
                "visuals": [{"qualifiedName": "reader_scale.longContract"},
                            {"qualifiedName": "reader_scale.namedOptions"},
                            {"qualifiedName": "reader_scale.ConstrainedBox"}]}
    manifest["sourceSha256"] = digest(json.dumps(sources, sort_keys=True, separators=(",", ":")).encode())
    (destination / "reader-corpus.json").write_text(json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--declarations", required=True, type=int)
    args = parser.parse_args()
    result = generate_corpus(args.output, args.declarations)
    print(json.dumps({"recipe": result["recipe"], "sourceDeclarations": result["sourceDeclarations"],
                      "sourceSha256": result["sourceSha256"]}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
