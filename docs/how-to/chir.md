# 让编译器补齐类型和签名信息

`generate`、`check` 和 `serve` 默认在读入源码后启动配套的 CHIR worker，用编译器确认声明和类型，把结果补进文档。注释和声明仍来自源码；worker 失败时文档照常生成，只是少了这部分补充。`render`、`query`、`mcp` 只读已有快照，从不编译项目。

## 什么时候用本页

- 想让参数类型、返回类型和签名以编译器确认的形式显示。
- 想确认某条声明的语义补充是否成功。
- 这次不想编译项目，要显式改用源码信息。
- 默认编译器不适用，需要换 `cjc` 或补 import 路径。

只在意页面能否生成时，默认配置已经可用，不需要这里的任何选项。

## 前提条件

- 已按[安装指南](../getting-started/install.md)安装 `cjdoc`，`chir-worker-main`（Windows 为 `chir-worker-main.exe`）与它位于同一目录。发行归档同时包含两者；单独下载的主程序不含 worker。
- 当前终端已加载仓颉 SDK 1.2.0 运行时环境，`cjc -v` 可以运行。
- 项目依赖的源码和编译所需库已就绪。使用静态 stdx 的项目还要向编译器提供匹配的 import 路径。

worker 按 `cjdoc` 可执行文件的真实位置查找同目录文件，不搜索当前目录或 `PATH`，因此通过软链接调用 `cjdoc` 仍会用到安装目录旁的 worker。

## 第一步：准备一个带注释的函数

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

不需要先单独构建项目，也不用重复传语义开关和 worker 路径：

```bash
cjdoc generate --project . --format json --format html --output target/doc-chir
```

产物是 `target/doc-chir/docs.json` 和 `target/doc-chir/html/index.html`。worker 会分析捕获到的源码；项目无法编译或某条声明无法对应时，终端报告 `CJDOC2101`–`CJDOC2106`，源码声明仍然保留。

## 第三步：查看记录下来的语义结果

读取这次生成的 `docs.json`：

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

`returnType.semanticCanonical` 会显示 `std.core.String`，`semanticProvider` 为 `chir`。同时可能看到声明级 `state` 仍为 `partial`、`canonicalSignature` 为 `null`：这表示只补到了部分信息，继续以源码签名为准，不要把缺少完整签名当成编译错误。

`state` 的四个取值：

| 取值 | 含义 |
|---|---|
| `resolved` | 该项有可用的确定信息 |
| `partial` | 只补到部分信息 |
| `unavailable` | 本次没有可用语义 |
| `ambiguous` | 不能把语义记录唯一对应到源码声明 |

`partial` 和 `unavailable` 只针对这条声明或它所在的模块，不代表整个项目类型检查失败。

## 只使用源码信息

本次不希望编译项目时，显式选择源码模式：

```bash
cjdoc generate --project . --semantic source --format html
```

也可以在项目根的 `cjdoc.toml` 里保存这个选择：

```toml
[semantic]
mode = "source"
```

这样 `generate`、`check` 和 `serve` 就不再启动语义补充 worker；临时需要时用 `--semantic chir` 覆盖。源码模式不会展开宏，但仍按文档的条件配置筛选已识别的 `@When` 声明。用 `--cfg NAME=VALUE` 提供条件值，详见[选择输入](select-inputs.md)。

## 换编译器或补 import 路径

默认使用当前 `PATH` 中的 `cjc`。编译环境需要调整时才传这些选项。例如当前终端已设置静态 stdx 的 `CANGJIE_STDX_PATH`：

```bash
cjdoc generate --project . --semantic chir \
  --cjc "$(command -v cjc)" \
  --chir-import-path "$CANGJIE_STDX_PATH" \
  --format json --output target/doc-chir
```

`--chir-import-path` 可以重复，应指向匹配的编译输入目录，不能用动态库目录代替静态 stdx 的 `.cjo` 目录。三个选项都要求 `--semantic chir`；不写时 `--semantic` 默认就是 `chir`，配上 `--semantic source` 会报错。

项目 `[package]` 中的 `--experimental`、`--enable-local-mode` 会传递给 CHIR 编译器：非空的 `override-compile-option` 替代 `compile-option`，空 override 保留原选项。目标专属表里的语言选项不会被用于当前分析，而是报告 `CJDOC2102`。

## 指定另一个 worker

调试或特殊部署可以显式传入另一个 worker，它必须与主程序的产品版本和 worker 协议匹配，不要混用不同构建的安装文件：

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

`--chir-worker` 只是覆盖自动定位结果，普通安装和项目配置都不需要它。从源码构建 worker 的步骤见[构建说明](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/maintainer/build.md#可选-chir-worker)。

## 失败时怎么办

worker 不可用或分析失败时，生成保留源码/AST 信息并给出 warning；加 `--deny-warnings` 时这些 warning 会让命令以 `1` 退出。

| 诊断码 | 含义 | 处理 |
|---|---|---|
| `CJDOC2101` | 编译器或 worker 缺失、不可执行、无法定位 | 确认 SDK 已加载；重新安装完整的主程序和 worker，不要只复制 `cjdoc` |
| `CJDOC2102` | import 路径、依赖、cfg 或清单选项不受支持 | 准备对应依赖和静态 stdx；核对 import 路径与项目清单 |
| `CJDOC2103` | 编译失败或超时 | 用同一个 `cjc` 检查项目能否编译，核对 SDK/stdx 是否匹配 |
| `CJDOC2104` | worker 版本或协议不匹配，或输出无法读取 | 从同一次构建重新安装两个文件；自定义 worker 时检查版本与协议 |
| `CJDOC2105` | 记录不能唯一对应源码声明 | 检查同名重载；歧义声明保留 `ambiguous` |
| `CJDOC2106` | 声明已识别，但缺少可靠的结构化映射 | 继续使用该声明的源码信息，不要把它当成已解析 |

要看大项目里被重复诊断的回退问题，先按诊断码和源码位置定位单条声明；整模块不可用时只报告模块级失败，不会为每条声明重复报错。

`render` 只读取既有 Doc IR，不重新发现项目，也不运行 worker。要改变快照中的语义信息，重新运行 `generate`。参数规则见 [CLI 参考](../reference/cli.md#可选语义和高亮后端)。

## 下一步

- [编译并运行文档示例](check-examples.md)：检查注释中示例的编译和输出。
- [按症状排查故障](troubleshoot.md)：处理命令、项目根与输出目录问题。
