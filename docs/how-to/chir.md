# 为声明补充类型和签名信息

普通生成只读源码和注释，产出签名、参数、返回值与说明。当你想在 Doc IR 里得到编译器确认过的类型拼写和签名，可以启用 CHIR 语义补充：cjdoc 把捕获到的源码交给一个独立 worker 进程编译，再把能可靠对应上的结果写进文档。worker 拿不到结果时，源码信息照旧保留。

本页构建并使用一个只做 CHIR 分析的 worker；已安装的 `cjdoc` 命令不需要重建或替换。

## 何时需要本页

- 只想生成站点、检查注释或发布文档时，不需要 CHIR，也不需要本页的任何构建步骤。默认的源码模式不编译被扫描项目，速度更快，也不需要 compiler。
- 需要补充声明的类型与规范化签名，并在文档数据里查看这些信息的可用状态时，可以启用 CHIR。
- 即使启用，也只是一次保守补充：部分声明可能只有 `partial` 或 `unavailable` 状态，注释始终是文档真值。

## 前提

- 已按[安装 cjdoc](../getting-started/install.md)安装 `cjdoc`，当前终端已加载仓颉 SDK 环境，`cjc -v` 报告 1.2.0。
- 安装时保存了 `CJDOC_SOURCE`（源码目录）和 `CJDOC_REVISION`（完整提交号）。这两个值只在本页读取源码时使用。
- 与该提交一致的源码副本可用：它提供 worker 源码，并保证 worker 和你正在用的 `cjdoc` 来自同一版本。
- 与 SDK 匹配的**静态** stdx 1.2.0。worker 需要静态目录中的 `stdx.chir.cjo` 和 `libstdx.chir.a`；动态库目录不能代替。
- Bash、Git、Python 3 与 `cjpm`。本页命令按 Linux Bash 编写；Windows 相关差异写在各步骤中。

## 准备练习目录

练习文件放在磁盘上的独立目录里，不要用内存文件系统承载构建输出：

```bash
mkdir -p "$HOME/.cache/cjdoc/examples"
export TASK_ROOT="$(mktemp -d "$HOME/.cache/cjdoc/examples/chir.XXXXXX")"
printf '%s\n' "$TASK_ROOT"
```

记下输出的路径。这只是一个放练习文件的位置，不是 cjdoc 的要求；后面所有命令都沿用 `$TASK_ROOT`。

## 1. 复制一份与安装版本一致的源码

```bash
: "${CJDOC_SOURCE:?请设置为安装时保存的 CJDOC_SOURCE}"
: "${CJDOC_REVISION:?请设置为安装时保存的 CJDOC_REVISION}"
git clone --no-hardlinks "$CJDOC_SOURCE" "$TASK_ROOT/cjdoc-source"
cd "$TASK_ROOT/cjdoc-source"
git checkout --detach "$CJDOC_REVISION"
git rev-parse --verify HEAD
```

最后一条命令应输出与 `$CJDOC_REVISION` 相同的提交号。用副本而不是安装时的源码目录，是因为构建会在 `tools/chir-worker/target/` 下写产物；副本能让原目录保持原样，也便于你之后直接删除整个练习目录。

## 2. 只构建 CHIR worker

worker 是一个独立的仓颉可执行程序，构建时需要静态 stdx 参与链接。仓库提供两个脚本处理这件事：`scripts/with_sts_cjpm.sh` 固定本仓使用的编译器选项，`scripts/with_stdx.py` 校验 stdx 是否与当前编译器匹配。它们都通过环境变量工作，所以下面把整段构建放进一个子 shell，构建结束后这些变量不会影响你之后的命令：

```bash
cd "$TASK_ROOT/cjdoc-source"
(
  export GITHUB_WORKSPACE="$TASK_ROOT/cjdoc-source"
  export RUNNER_TEMP="$(mktemp -d "$TASK_ROOT/build.XXXXXX")"
  export TMPDIR="$RUNNER_TEMP" TMP="$RUNNER_TEMP" TEMP="$RUNNER_TEMP"
  export CJDOC_PYTHON=python3
  export PYTHONDONTWRITEBYTECODE=1
  if command -v cygpath >/dev/null 2>&1; then
    export GITHUB_WORKSPACE="$(cygpath -m "$GITHUB_WORKSPACE")"
    export RUNNER_TEMP="$(cygpath -m "$RUNNER_TEMP")"
    export CANGJIE_STDX_PATH="$(cygpath -m "$CANGJIE_STDX_PATH")"
    export TMPDIR="$RUNNER_TEMP" TMP="$RUNNER_TEMP" TEMP="$RUNNER_TEMP"
  fi
  . scripts/with_sts_cjpm.sh
  python3 scripts/with_stdx.py --variant static -- bash -c 'cd tools/chir-worker && cjpm build --jobs 1'
)
```

`GITHUB_WORKSPACE` 是仓库脚本用来定位源码根的名字，`RUNNER_TEMP` 是本次构建的临时目录；这两个名字来自仓库脚本，本地照设即可，不需要 GitHub Actions。构建成功后 worker 可执行文件位于 `tools/chir-worker/target/release/bin/main`，Windows 为 `main.exe`。

先将 `CANGJIE_STDX_PATH` 设置为实际的静态 stdx 目录，再把运行时要用的三个路径定为绝对路径：

```bash
export CHIR_WORKER="$TASK_ROOT/cjdoc-source/tools/chir-worker/target/release/bin/main"
if [ -f "$CHIR_WORKER.exe" ]; then export CHIR_WORKER="$CHIR_WORKER.exe"; fi
export CHIR_CJC="$(command -v cjc)"
export CHIR_IMPORT_PATH="$CANGJIE_STDX_PATH"
printf '%s\n%s\n%s\n' "$CHIR_WORKER" "$CHIR_CJC" "$CHIR_IMPORT_PATH"
for path in "$CHIR_WORKER" "$CHIR_CJC" "$CHIR_IMPORT_PATH"; do
  [ -e "$path" ] || printf '不存在的路径：%s\n' "$path" >&2
done
```

三行输出应是 worker 可执行文件、`cjc` 和静态 stdx 目录的绝对路径；后面没有“不存在的路径”提示。

`$CANGJIE_STDX_PATH` 指向静态 stdx 目录，也就是包含 `stdx.chir.cjo` 和 `libstdx.chir.a` 的那一层。若该变量没有设置，把它设成实际解压位置；不要指向动态库目录。

Windows 的 Git Bash 在传给原生进程前需要转换路径：

```bash
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    export CHIR_WORKER="$(cygpath -m "$CHIR_WORKER")"
    export CHIR_CJC="$(cygpath -m "$CHIR_CJC")"
    export CHIR_IMPORT_PATH="$(cygpath -m "$CHIR_IMPORT_PATH")"
    ;;
esac
```

Linux 和 macOS 跳过这个分支。这三个路径会在下一步原样交给 `cjdoc`。

## 3. 生成带语义的文档

建一个没有外部依赖的静态库 `chirdemo`：

```bash
export CHIR_TASK_ROOT="$TASK_ROOT/chirdemo"
mkdir -p "$CHIR_TASK_ROOT/src"
cat > "$CHIR_TASK_ROOT/cjpm.toml" <<'EOF'
[package]
cjc-version = "1.2.0"
name = "chirdemo"
version = "0.1.0"
output-type = "static"
EOF
cat > "$CHIR_TASK_ROOT/src/api.cj" <<'EOF'
package chirdemo

/** 原样保留姓名并返回问候语。
 * @param name 要原样写入问候语的姓名。
 * @return 包含该姓名的问候语。
 */
public func greet(name: String): String { "Hello, ${name}!" }
EOF
```

用已安装的 `cjdoc` 生成 JSON，并开启 CHIR。项目本身不需要先跑 `cjpm build`；worker 会用 `--cjc` 指定的编译器自行编译这份源码：

```bash
cd "$CHIR_TASK_ROOT"
cjdoc generate --project . \
  --format json --output target/doc-chir \
  --semantic chir \
  --cjc "$CHIR_CJC" \
  --chir-worker "$CHIR_WORKER" \
  --chir-import-path "$CHIR_IMPORT_PATH"
```

产物在 `target/doc-chir/docs.json`。若出现 `CJDOC2101`–`CJDOC2106` 诊断，说明有语义没有补上；源码声明仍保留，处理办法见文末的失败小节。

## 4. 查看记录下来的语义结果

下面的脚本只读取这份 JSON 并打印 `greet` 的相关字段，不判断对错；结果由这次运行真实写入，声明级状态可能是 `partial`、`unavailable` 或 `ambiguous`，类型字段还可能是 `resolved`。

```bash
python3 - "$CHIR_TASK_ROOT/target/doc-chir/docs.json" <<'PY'
import json
import sys
from pathlib import Path

doc = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for provider in doc["providers"]:
    print(f'provider {provider["name"]}: {provider["state"]}')
greet = next(item for item in doc["declarations"] if item.get("name") == "greet")
semantic = greet["semantic"]
print(f'greet semantic.state: {semantic["state"]}')
print(f'greet semantic.provider: {semantic["provider"]}')
print(f'greet semantic.canonicalSignature: {semantic["canonicalSignature"]}')
return_type = greet.get("returnType")
if return_type is not None:
    print(f'returnType semanticState: {return_type["semanticState"]}')
    print(f'returnType semanticCanonical: {return_type["semanticCanonical"]}')
    print(f'returnType semanticProvider: {return_type["semanticProvider"]}')
PY
```

这样读结果：

- `semantic.state` 表示这次 worker 与源码声明的对应程度。`partial` 表示已找到对应记录但只补到部分信息；`unavailable` 表示这次没有可用语义；`ambiguous` 表示无法一对一映射。声明级补充不会把结果标成完全解析，所以这里通常是 `partial`。
- `semantic.provider` 为 `chir` 说明这几个字段来自 worker 而不是源码解析。
- `semantic.canonicalSignature` 是规范化签名；输出 `None`（JSON 中为 `null`）表示这次没有提供，不代表签名有误，此时看 `state` 与源码里的签名。
- `returnType` 的三个字段描述返回类型语义的状态、规范化拼写和来源 provider。结合这三个值阅读结果；字段不可用时继续查看源码类型，不把它解释为 API 无法调用。

看到 `partial` 或 `unavailable` 是正常结果之一：CHIR 只补充它能可靠映射的部分，其他声明继续使用源码信息。不要因为 provider 里出现 `chir` 就认为所有声明都已解析。

## 以后在新终端继续使用

副本和产物都留在 `$TASK_ROOT` 下，不需要重新构建。新终端只需加载 SDK 环境、加入安装前缀，再恢复三个路径：

```bash
export CANGJIE_SDK_ROOT="$HOME/toolchains/sts-1.2.0/cangjie"
. "$CANGJIE_SDK_ROOT/envsetup.sh"
export CJDOC_PREFIX="$HOME/.local"
export PATH="$CJDOC_PREFIX/bin:$PATH"
export CANGJIE_STDX_PATH="$HOME/toolchains/sts-1.2.0/linux_x86_64_cjnative/static/stdx"
export CHIR_WORKER="<你的 TASK_ROOT>/cjdoc-source/tools/chir-worker/target/release/bin/main"
export CHIR_CJC="$(command -v cjc)"
export CHIR_IMPORT_PATH="$CANGJIE_STDX_PATH"
cjdoc --version
```

把 `<你的 TASK_ROOT>` 换成练习目录开头打印的路径，Windows 的 worker 文件名加 `.exe`，并按第 2 步的 `cygpath` 转换三个路径。`CJDOC_SOURCE`、`CJDOC_REVISION`、`GITHUB_WORKSPACE`、`RUNNER_TEMP` 和 `CJDOC_PYTHON` 只在副本里构建 worker 时需要；日常生成文档不需要它们。

## worker 或 compiler 失败时

worker 不可用或分析失败时，cjdoc 默认保留源码声明并产生 warning，说明这次哪些语义没有补上。启用了拒绝 warning 的策略时，检查仍可因此失败。先看诊断码，再决定改哪一项：

| 诊断码 | 含义 | 先检查什么 |
|---|---|---|
| `CJDOC2101` | worker 或 compiler 不可用，或编译器版本无法识别 | `--chir-worker` 指向的文件是否存在且可执行；`--cjc` 是否为 1.2.0 的 `cjc` |
| `CJDOC2102` | 被扫描项目的输入、依赖或构建配置无法由 worker 重建 | `--chir-import-path` 是否指向静态 stdx；项目 `cjpm.toml` 是否使用了 CHIR 不支持的段（如 `[features]`、`[build]` 或无法识别的编译选项） |
| `CJDOC2103` | compiler 执行失败或超时 | 用同一 `cjc` 手动编译该包是否成功；SDK 与 stdx 是否同为 1.2.0 |
| `CJDOC2104` | worker 输出无法读取或反序列化 | worker 是否来自与 `cjdoc` 相同的提交；重新执行第 2 步构建 |
| `CJDOC2105` | 多个源码声明无法一对一对应 | 项目里是否有形状完全相同的同名重载；这类声明会保留 `ambiguous` |
| `CJDOC2106` | 声明被识别但不能可靠映射到结构化记录 | 类型别名、属性等没有稳定记录的声明；这些声明使用源码信息 |

处理顺序通常是：确认三个路径都是绝对路径且文件存在，确认编译器与 stdx 版本匹配，再重新生成。修好之后重跑第 3 步，重新查看具体声明的语义字段；仍然是 `partial` 的声明可能属于映射本身的保守结果。

CHIR 选项只属于 `generate` 和 `check`；`render` 读取既有 Doc IR，不接受这些参数。参数与默认值见[CLI 参考](../reference/cli.md#可选语义和高亮后端)，字段含义见[状态与限制](../reference/states-and-limits.md)。

## 下一步

- [编译并运行文档示例](check-examples.md)，把注释里的示例变成可核对的结果。
- [按症状排查故障](troubleshoot.md)，处理命令、项目根与输出目录问题。
