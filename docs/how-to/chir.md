# 为声明补充类型和签名信息（CHIR）

启用 `--semantic chir` 后，cjdoc 把捕获到的源码交给一个独立的 worker 进程编译，把编译器确认过的类型拼写和签名写进 Doc IR。本页构建这个 worker 并验证结果。

## 什么时候用本页

- 需要在文档数据里得到规范化类型（例如 `std.core.String` 而不是源码里的 `String`）和编译器层面的签名，并查看每条声明的语义状态。
- 只想生成站点、检查注释或发布文档时**不需要**本页：默认的 `--semantic source` 不编译被扫描项目，更快，也不需要 compiler 或 worker。
- 即使启用，CHIR 也只是保守补充：部分声明仍可能是 `partial` 或 `unavailable`，注释始终是文档真值。

## 前提条件

- 已按[安装 cjdoc](../getting-started/install.md)安装 `cjdoc`，当前终端已加载仓颉 SDK 环境，`cjc -v` 报告 1.2.0。
- 从源码构建的：安装时保存了 `CJDOC_SOURCE`（源码目录）与 `CJDOC_REVISION`（完整提交号）。
- 安装发行包的：先 `git clone https://github.com/lIlIIlIll/cjdoc.git`，把 `CJDOC_SOURCE` 设为克隆目录，把 `CJDOC_REVISION` 设为发行包 `release-manifest.json` 里的 `sourceCommit`（v0.7.8 为 `5c065affd2c45f61549c06808537731ce46b436b`）。
- worker 必须和正在使用的 `cjdoc` 来自同一提交：两者之间的协议版本不同时，worker 不能混用。
- 与 SDK 匹配的**静态** stdx 1.2.0，即同时包含 `stdx.chir.cjo` 与 `libstdx.chir.a` 的那一层。动态库目录不能代替。
- Bash、Git、Python 3 与 `cjpm`。本页命令按 Linux 编写，Windows 差异写在相应步骤里。

练习目录要放在磁盘上，不要用内存文件系统承载构建输出：

```bash
mkdir -p "$HOME/.cache/cjdoc/examples"
TASK_ROOT="$(mktemp -d "$HOME/.cache/cjdoc/examples/chir.XXXXXX")"
printf '%s\n' "$TASK_ROOT"
```

记下打印出的路径，后面所有命令都沿用 `$TASK_ROOT`。

## 第一步：检出与安装版本一致的源码

```bash
: "${CJDOC_SOURCE:?请设置为安装时保存的 CJDOC_SOURCE}"
: "${CJDOC_REVISION:?请设置为安装时保存的 CJDOC_REVISION}"
git clone --no-hardlinks "$CJDOC_SOURCE" "$TASK_ROOT/cjdoc-source"
cd "$TASK_ROOT/cjdoc-source"
git checkout --detach "$CJDOC_REVISION"
git rev-parse --verify HEAD
```

预期最后一条输出与 `$CJDOC_REVISION` 相同的提交号。用副本而不是安装时的源码目录，是因为构建会写 `tools/chir-worker/target/`，副本也让整份练习可以随时删除。

## 第二步：只构建 CHIR worker

先设置静态 stdx 路径，把它改成你机器上的实际位置（macOS/Windows 的平台目录见安装页）：

```bash
export CANGJIE_STDX_PATH="$HOME/toolchains/sts-1.2.0/linux_x86_64_cjnative/static/stdx"
test -f "$CANGJIE_STDX_PATH/stdx.chir.cjo" && test -f "$CANGJIE_STDX_PATH/libstdx.chir.a"
```

仓库用两个脚本处理构建：`scripts/with_sts_cjpm.sh` 固定本仓使用的编译器选项，`scripts/with_stdx.py` 校验 stdx 与当前编译器匹配。它们都靠环境变量工作，所以整段构建放进子 shell，变量不会污染后续命令：

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

`GITHUB_WORKSPACE` 与 `RUNNER_TEMP` 只是脚本用来定位源码根和临时目录的变量名，本地照设即可，不需要 GitHub Actions。预期终端以 `cjpm build success` 结束，worker 位于 `tools/chir-worker/target/release/bin/main`（Windows 为 `main.exe`）。

把运行时需要的三个绝对路径定下来：

```bash
CHIR_WORKER="$TASK_ROOT/cjdoc-source/tools/chir-worker/target/release/bin/main"
if [ -f "$CHIR_WORKER.exe" ]; then CHIR_WORKER="$CHIR_WORKER.exe"; fi
CHIR_CJC="$(command -v cjc)"
CHIR_IMPORT_PATH="$CANGJIE_STDX_PATH"
printf '%s\n%s\n%s\n' "$CHIR_WORKER" "$CHIR_CJC" "$CHIR_IMPORT_PATH"
for path in "$CHIR_WORKER" "$CHIR_CJC" "$CHIR_IMPORT_PATH"; do
  [ -e "$path" ] || printf '不存在的路径：%s\n' "$path" >&2
done
```

预期三行分别是 worker 可执行文件、`cjc`、静态 stdx 目录的绝对路径，且没有“不存在的路径”提示。Windows 的 Git Bash 在把路径交给原生进程前需要转换：

```bash
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    CHIR_WORKER="$(cygpath -m "$CHIR_WORKER")"
    CHIR_CJC="$(cygpath -m "$CHIR_CJC")"
    CHIR_IMPORT_PATH="$(cygpath -m "$CHIR_IMPORT_PATH")"
    ;;
esac
```

## 第三步：生成带语义的文档

建一个没有外部依赖的静态库 `chirdemo`：

```bash
CHIR_TASK_ROOT="$TASK_ROOT/chirdemo"
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

项目本身不需要先跑 `cjpm build`：worker 用 `--cjc` 指定的编译器自行编译这份源码。

```bash
cd "$CHIR_TASK_ROOT"
cjdoc generate --project . \
  --format json --output target/doc-chir \
  --semantic chir \
  --cjc "$CHIR_CJC" \
  --chir-worker "$CHIR_WORKER" \
  --chir-import-path "$CHIR_IMPORT_PATH"
```

预期退出码 `0`，终端只有普通的文档质量 warning，产物是 `target/doc-chir/docs.json`。出现 `CJDOC2101`–`CJDOC2106` 说明有语义没有补上，源码声明仍然保留，按下面“失败时怎么办”逐条处理。

## 第四步：查看记录下来的语义结果

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

这段示例源码的预期结果：

```text
provider chir: partial
greet semantic.state: partial
greet semantic.provider: chir
greet semantic.canonicalSignature: None
returnType semanticState: resolved
returnType semanticCanonical: std.core.String
returnType semanticProvider: chir
```

怎么读这些字段：

- `semantic.state` 是这次 worker 与源码声明的对应程度。`partial` 表示找到对应记录但只补到部分信息；`unavailable` 表示这次没有可用语义；`ambiguous` 表示无法一对一映射。声明级补充通常停在 `partial`。
- `semantic.provider` 为 `chir` 说明这些字段来自 worker 而不是源码解析。
- `canonicalSignature` 为 `None`（JSON 里是 `null`）表示这次没有提供，不代表签名有误；此时看 `state` 与源码签名。
- `returnType` 的三个字段分别给出返回类型语义的状态、规范化拼写与来源。它们不可用时继续看源码类型，不要据此认为 API 无法调用。

看到 `partial` 或 `unavailable` 是正常结果之一：CHIR 只补充能可靠映射的部分。不要因为 provider 里出现 `chir` 就认为所有声明都已完成类型检查。

## 失败时怎么办

worker 不可用或分析失败时，cjdoc 默认保留源码声明并给出 warning，生成继续。对 `check` 使用 `--deny-warnings` 时，这些 warning 会让检查以 `1` 退出；只跑 `check` 时退出码仍是 `0`。先看诊断码：

| 诊断码 | 实际消息与含义 | 先检查什么 |
|---|---|---|
| `CJDOC2101` | `CHIR worker executable is not configured`、`CHIR worker failed: ...`、`CHIR compiler version is unavailable` | 三个路径是否都给了；`--chir-worker` 是否指向存在且可执行的文件；`--cjc` 是否为 1.2.0 的 `cjc` |
| `CJDOC2102` | `CHIR import path is unavailable`、`CHIR does not support this cjpm manifest section` | `--chir-import-path` 是否指向含 `stdx.chir.cjo` 的静态 stdx；项目 `cjpm.toml` 是否用了 `[features]`、`[build]` 等 CHIR 不支持的段 |
| `CJDOC2103` | 编译执行失败或超时 | 用同一个 `cjc` 手动编译该包是否成功；SDK 与 stdx 是否同为 1.2.0 |
| `CJDOC2104` | worker 输出无法读取或反序列化 | worker 是否来自与 `cjdoc` 相同的提交；重新执行第二步 |
| `CJDOC2105` | 多个源码声明无法一对一对应 | 项目里是否有形状完全相同的同名重载；这类声明保留 `ambiguous` |
| `CJDOC2106` | 声明被识别但无法可靠映射，例如 `CHIR recognized 1 source declarations without a reliable structured mapping` | 类型别名、属性等没有稳定记录的声明；这些声明继续使用源码信息 |

| 现象 | 原因 | 处理 |
|---|---|---|
| `error: --cjc, --chir-worker, and --chir-import-path require --semantic chir`，退出码 `2` | 给出了语义参数但没有开关 | 补 `--semantic chir` |
| `error: semantic options are only valid for generate and check` | 对 `render` 用了 CHIR 参数 | `render` 读取既有 Doc IR，不接受这些参数；语义补充在 `generate` 阶段完成 |
| worker 不存在时终端提示 `cjdoc-process-supervisor: line 1: <路径>: No such file or directory` | `--chir-worker` 路径错误 | 用第二步打印的绝对路径 |
| 全部声明都是 `unavailable` | worker 或 compiler 不可用 | 先修 `CJDOC2101`，再重新生成 |

处理顺序通常是：确认三个路径都是绝对路径且存在，确认编译器与 stdx 版本匹配，再重新跑第三步并复查具体声明的语义字段。仍然 `partial` 的声明可能属于映射本身的保守结果。

**仅源码构建（v0.7.8 发行包不包含）：** 项目 `cjpm.toml` 的 `[package]` 里用 `compile-option` 或非空的 `override-compile-option` 写了 `--experimental`、`--enable-local-mode` 时，CHIR 会把这两个选项转交给编译器。非空的 override 替代 compile 选项，空的 override 保留 compile 选项。这只保证选项被传递：对应语法能否编译，仍取决于 `--cjc` 和与之匹配的 SDK/stdx 所构建的 worker 是否支持。写在目标专属表里的语言选项仍报告 `CJDOC2102`，以免把另一个目标的配置用到当前分析上。v0.7.8 发行包遇到这两个选项时报告 `CJDOC2102`。

CHIR 选项只属于 `generate` 与 `check`；参数与默认值见[CLI 参考](../reference/cli.md#可选语义和高亮后端)，字段含义见[状态与限制](../reference/states-and-limits.md)。

## 下一步

- [编译并运行文档示例](check-examples.md)：把注释里的示例变成可核对的结果。
- [按症状排查故障](troubleshoot.md)：处理命令、项目根与输出目录问题。
