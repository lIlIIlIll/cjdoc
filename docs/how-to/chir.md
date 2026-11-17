# 查看和调整 CHIR 语义补充

当前源码版的 `generate`、`check`、`serve` 默认使用配套 CHIR worker，补充编译器确认的类型信息。worker 与 `cjdoc` 一起安装，命令会按主程序的真实位置寻找同目录的 `chir-worker-main`（Windows 为 `chir-worker-main.exe`），不需要在每个项目中配置路径。

本页描述当前源码版。已发布的 0.7.8 仍默认使用源码模式，也不包含 worker；使用该发行包时请阅读[对应版本的 CHIR 指南](https://github.com/lIlIIlIll/cjdoc/blob/v0.7.8/docs/how-to/chir.md)。

## 前提条件

- 已按[安装指南](../getting-started/install.md)安装同一次构建的 `cjdoc` 和 worker，并在当前终端加载对应 SDK 的运行时环境。
- `cjc -v` 可以运行，且与构建 worker 的 SDK 匹配。默认使用当前 `PATH` 中的 `cjc`。
- 项目依赖的源码和编译所需库已经准备好。使用静态 stdx 的项目，还需要向编译器提供匹配的 import 路径。

CHIR 只补充能可靠对应到源码声明的信息。声明和注释仍来自源码；`partial`、`unavailable` 不表示整个项目已经完成类型检查。

## 第一步：准备一个小项目

在自己的练习目录创建 `chirdemo`：

```bash
mkdir -p chirdemo/src
cd chirdemo
cat > cjpm.toml <<'EOF'
[package]
cjc-version = "1.2.0"
name = "chirdemo"
version = "0.1.0"
output-type = "static"
EOF
cat > src/api.cj <<'EOF'
package chirdemo

/** 原样保留姓名并返回问候语。
 * @param name 要原样写入问候语的姓名。
 * @return 包含该姓名的问候语。
 */
public func greet(name: String): String { "Hello, ${name}!" }
EOF
```

## 第二步：生成文档

不需要先单独构建项目，也不需要重复传入语义开关和 worker 路径：

```bash
cjdoc generate --project . --format json --format html --output target/doc-chir
```

产物是 `target/doc-chir/docs.json` 和 `target/doc-chir/html/index.html`。worker 会用编译器分析捕获到的源码；项目无法编译或某条声明无法对应时，终端会报告 `CJDOC2101`–`CJDOC2106`，源码声明仍保留。

## 第三步：查看记录下来的语义结果

读取这次生成的 `docs.json`，查看具体声明和返回类型：

```bash
python3 - target/doc-chir/docs.json <<'PY'
import json
import sys
from pathlib import Path

doc = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
greet = next(item for item in doc["declarations"] if item.get("name") == "greet")
semantic = greet["semantic"]
print(f'greet semantic.state: {semantic["state"]}')
print(f'greet semantic.provider: {semantic["provider"]}')
print(f'greet semantic.canonicalSignature: {semantic["canonicalSignature"]}')
return_type = greet["returnType"]
print(f'returnType semanticState: {return_type["semanticState"]}')
print(f'returnType semanticCanonical: {return_type["semanticCanonical"]}')
print(f'returnType semanticProvider: {return_type["semanticProvider"]}')
PY
```

这个简单函数的返回类型可补充为 `std.core.String`，来源为 `chir`。声明级状态仍可能是 `partial`，`canonicalSignature` 也可能是 `None`（JSON 的 `null`）；这时继续使用源码签名，不要把没有提供的完整签名当成编译错误。

- `resolved` 表示该项有可用的确定信息。
- `partial` 表示只补到部分信息。
- `unavailable` 表示这次没有可用语义。
- `ambiguous` 表示不能把语义记录唯一对应到源码声明。

## 只使用源码信息

如果本次不希望编译项目，显式选择源码模式：

```bash
cjdoc generate --project . --semantic source --format html
```

也可以在项目根的 `cjdoc.toml` 中保存这个选择：

```toml
[semantic]
mode = "source"
```

这样 `generate`、`check`、`serve` 都只使用源码/AST 信息，不启动 CHIR worker。临时需要 CHIR 时，用 `--semantic chir` 覆盖项目配置。

## 使用另一个编译器或 import 路径

默认安装已提供 worker；只有编译环境需要调整时才传这些选项。例如，当前终端已设置静态 stdx 的 `CANGJIE_STDX_PATH`：

```bash
cjdoc generate --project . --semantic chir \
  --cjc "$(command -v cjc)" \
  --chir-import-path "$CANGJIE_STDX_PATH" \
  --format json --output target/doc-chir
```

`--chir-import-path` 可以重复。它应指向匹配的编译输入目录，不能用动态库目录代替静态 stdx 的 `.cjo` 目录。

项目 `[package]` 中的 `--experimental`、`--enable-local-mode` 编译选项会传递给 CHIR 编译器：非空 `override-compile-option` 替代 `compile-option`，空 override 保留原选项。目标专属表中的语言选项仍报告 `CJDOC2102`，避免把另一个目标的配置用于当前分析。

## 开发时覆盖 worker

调试或特殊部署可以显式传入另一个 worker。它必须与主程序的产品版本、worker 协议匹配；不要混用不同构建的安装文件。

从源码安装时保存了 `CJDOC_SOURCE`，并按[构建说明](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/maintainer/build.md#可选-chir-worker)构建了配套 worker 后，可以选择它：

```bash
: "${CJDOC_SOURCE:?请设置为匹配主程序的源码目录}"
CHIR_WORKER="$CJDOC_SOURCE/tools/chir-worker/target/release/bin/main"
if [ -f "$CHIR_WORKER.exe" ]; then CHIR_WORKER="$CHIR_WORKER.exe"; fi
if command -v cygpath >/dev/null 2>&1; then
  CHIR_WORKER="$(cygpath -m "$CHIR_WORKER")"
fi
cjdoc generate --project . --semantic chir \
  --chir-worker "$CHIR_WORKER" --format json --output target/doc-chir
```

`--chir-worker` 覆盖自动定位结果。普通安装和项目配置不需要这项路径。

## 失败时怎么办

worker 不可用或分析失败时，生成保留源码/AST 信息并给出 warning。使用 `--deny-warnings` 时，这些 warning 会使命令以 `1` 退出。

| 诊断码 | 含义 | 处理 |
|---|---|---|
| `CJDOC2101` | compiler 或 worker 缺失、不可执行或无法定位 | 确认 SDK 已加载；重新安装完整的主程序和 worker，不要只复制 `cjdoc` |
| `CJDOC2102` | import 路径、依赖、cfg 或清单选项不受支持 | 准备对应依赖和静态 stdx；核对 import 路径及项目清单 |
| `CJDOC2103` | 编译失败或超时 | 用同一个 `cjc` 检查项目是否能编译，核对 SDK/stdx 是否匹配 |
| `CJDOC2104` | worker 版本或协议不匹配，或输出无法读取 | 从同一次构建重新安装两个文件；自定义 worker 时检查其版本与协议 |
| `CJDOC2105` | 记录不能唯一对应源码声明 | 检查同名重载；歧义声明保留 `ambiguous` |
| `CJDOC2106` | 声明已识别，但缺少可靠的结构化映射 | 继续使用该声明的源码信息，不把它标成语义已解析 |

`render` 只读取既有 Doc IR，不重新发现项目，也不运行 worker。要改变快照中的语义信息，重新运行 `generate`。参数规则见[CLI 参考](../reference/cli.md#可选语义和高亮后端)。

## 下一步

- [编译并运行文档示例](check-examples.md)：检查注释中示例的编译和输出。
- [按症状排查故障](troubleshoot.md)：处理命令、项目根与输出目录问题。

