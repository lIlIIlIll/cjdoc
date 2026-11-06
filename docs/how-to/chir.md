# 使用 CHIR 补充源码语义

`--semantic chir` 会让 cjdoc 将被扫描源码交给独立 worker，尝试补充结构化 CHIR 语义。worker 编译失败或结果无法可靠映射时，cjdoc 保留源码/AST 信息并给出诊断；源码注释始终是文档真值。本指南从当前 cjdoc 源码 checkout 正式构建 generator 和 worker，再用真实的本地 package 生成两份 JSON 观察成功路径与 worker 缺失的 fallback。

## 前提与源码身份

- Cangjie STS SDK 1.2.0、与之配套的静态 stdx sidecar、Bash、Python 3、Git 和 `cjpm`。
- `CJDOC_SOURCE` 是构建当前 cjdoc 工具的完整源码 checkout；`CJDOC_REVISION` 记录其完整提交。构建与运行使用同一 checkout 下生成的二进制。
- 通过当前 shell 的 SDK 环境脚本加载 `cjc`、`cjpm` 和 runtime；本页构建步骤用仓库现有 wrapper 认证静态 stdx。构建需网络访问仓库锁定的依赖。
- 任务临时目录放在磁盘文件系统下，不放 tmpfs `/tmp`。生成器和 worker 的正式候选构建要求干净 checkout。

使用[源码安装页](../getting-started/install.md)保存的 `CJDOC_SOURCE` 与 `CJDOC_REVISION`，不要从另一目录猜测源码路径或仅凭版本号配对工具。若换了终端，按安装时记录重新设置这两个变量，并重新加载 SDK 环境：

```bash
: "${CJDOC_SOURCE:?请设置为源码安装时记录的 CJDOC_SOURCE}"
: "${CJDOC_REVISION:?请设置为源码安装时记录的 CJDOC_REVISION}"
test "$(git -C "$CJDOC_SOURCE" rev-parse --verify HEAD)" = "$CJDOC_REVISION"
mkdir -p "$HOME/.cache/agent-tmp"
chmod 700 "$HOME/.cache/agent-tmp"
export TASK_AREA="$(mktemp -d "$HOME/.cache/agent-tmp/cjdoc-chir.XXXXXX")"
export RUNNER_TEMP="$(mktemp -d "$TASK_AREA/runner-temp.XXXXXX")"
export TMPDIR="$RUNNER_TEMP" TMP="$RUNNER_TEMP" TEMP="$RUNNER_TEMP"
export PYTHONDONTWRITEBYTECODE=1
export CJDOC_PYTHON=python3

cd "$CJDOC_SOURCE"
python3 - "$CJDOC_SOURCE" "$CJDOC_REVISION" <<'PY'
import sys
from pathlib import Path
from scripts.worktree_identity import exact_worktree_identity

identity = exact_worktree_identity(Path(sys.argv[1]), sys.argv[2])
print(f"trusted source commit: {identity['headCommit']}")
PY

cjc -v
cjpm -v
```

两条版本命令都应显示 1.2.0。`exact_worktree_identity` 确认记录的提交与 checkout 的 Git 输入一致，并忽略构建器允许的生成目录；若校验失败，先回到安装时固定的干净提交，不要在未核实的源码上构建 worker。

后续使用的 `CJDOC_BIN` 与 `CHIR_WORKER` 都由下面的正式构建生成，并记录在同一 build manifest；它们与 `CJDOC_SOURCE`、`CJDOC_REVISION` 保持同一源码提交。

仓库正式入口通过 `scripts/with_sts_cjpm.sh` 和 `scripts/check.sh build` 固定 `-O2 --fno-chir-function-inlining`，并构建 `main` 与 `chir-worker-main`。下列流程在磁盘上的独立任务目录克隆已记录提交，构建产物不会写入 `CJDOC_SOURCE`。不要用手工 `cjc` 命令、单测的 O1 旗标或不同提交的 worker 替代。

```bash
export PRIVATE_SOURCE="$TASK_AREA/cjdoc-source"

git clone --no-hardlinks "$CJDOC_SOURCE" "$PRIVATE_SOURCE"
git -C "$PRIVATE_SOURCE" checkout --detach "$CJDOC_REVISION"
test "$(git -C "$PRIVATE_SOURCE" rev-parse --verify HEAD)" = "$CJDOC_REVISION"

cd "$PRIVATE_SOURCE"
export GITHUB_WORKSPACE="$PRIVATE_SOURCE"
set -a
eval "$(python3 scripts/with_stdx.py --variant static --print-env --)"
set +a
export CANGJIE_STDX_PATH="$CJDOC_STDX_PATH"
. scripts/with_sts_cjpm.sh
bash scripts/check.sh build --repo . \
  --main-binary-out target/release/bin/main \
  --worker-binary-out target/release/bin/chir-worker-main \
  --manifest target/ci-build/build-manifest.json

export CJDOC_BIN="$PRIVATE_SOURCE/target/release/bin/main"
if [ -f "$CJDOC_BIN.exe" ]; then export CJDOC_BIN="$CJDOC_BIN.exe"; fi
export CHIR_WORKER="$PRIVATE_SOURCE/target/release/bin/chir-worker-main"
if [ -f "$CHIR_WORKER.exe" ]; then export CHIR_WORKER="$CHIR_WORKER.exe"; fi
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) test -f "$CJDOC_BIN" && test -f "$CHIR_WORKER" ;;
  *) test -x "$CJDOC_BIN" && test -x "$CHIR_WORKER" ;;
esac
export CJC_FOR_CLI="$(command -v cjc)"
export CHIR_WORKER_FOR_CLI="$CHIR_WORKER"
export CHIR_IMPORT_PATH_FOR_CLI="$CANGJIE_STDX_PATH"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    export CJC_FOR_CLI="$(cygpath -m "$CJC_FOR_CLI")"
    export CHIR_WORKER_FOR_CLI="$(cygpath -m "$CHIR_WORKER_FOR_CLI")"
    export CHIR_IMPORT_PATH_FOR_CLI="$(cygpath -m "$CHIR_IMPORT_PATH_FOR_CLI")"
    ;;
esac
```
本页完整 worker 流程按 Linux x64 Bash 编写。Windows x64 的 Git Bash 分支会把 compiler、worker 和 stdx import 路径转换为原生路径，但本轮未在 Windows 实际运行。

`with_stdx.py` 必须识别通过认证的**静态** sidecar，其中应包含 CHIR 编译与链接所需的 `stdx.chir.cjo`、`libstdx.chir.a`。若认证或正式构建失败，先修正匹配的 SDK/stdx 或 checkout，不要把 worker 指向其他库目录。

build manifest 记录此候选构建的二进制 identity。后续步骤将 `CJDOC_BIN` 与 `CHIR_WORKER` 作为同一工具链使用。

## 使用真实 worker 生成文档

示例 package 没有外部依赖，也不需要运行 `cjpm build`。启用 CHIR 后，worker 会用指定的 `cjc` 编译源码并读取显式 import path；普通 source-only 生成不会编译被扫描项目，但 CHIR 流程需要 SDK 与 compiler。

```bash
export TASK_ROOT="$RUNNER_TEMP/chir-input"
test ! -e "$TASK_ROOT" || { printf '请选择新的 TASK_ROOT\n' >&2; exit 1; }
mkdir -p "$TASK_ROOT/src"
cat > "$TASK_ROOT/cjpm.toml" <<'EOF'
[package]
cjc-version = "1.2.0"
name = "chirdemo"
version = "0.1.0"
output-type = "static"
EOF
cat > "$TASK_ROOT/src/api.cj" <<'EOF'
package chirdemo

/** 原样保留姓名并返回问候语。
 * @param name 要原样写入问候语的姓名。
 * @return 包含该姓名的问候语。
 */
public func greet(name: String): String { "Hello, ${name}!" }
EOF

"$CJDOC_BIN" generate --project "$TASK_ROOT" \
  --format json --output "$TASK_ROOT/with-chir" \
  --semantic chir \
  --cjc "$CJC_FOR_CLI" \
  --chir-worker "$CHIR_WORKER_FOR_CLI" \
  --chir-import-path "$CHIR_IMPORT_PATH_FOR_CLI"
```

检查生成的 Doc IR 中实际记录的 provider 和 worker 诊断：

```bash
python3 - "$TASK_ROOT/with-chir/docs.json" <<'PY'
import json
import sys
from pathlib import Path

doc = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert any(provider["name"] == "chir" for provider in doc["providers"])
failures = [item for item in doc["diagnostics"]
            if item["code"] in {"CJDOC2101", "CJDOC2102", "CJDOC2103",
                                "CJDOC2104", "CJDOC2105", "CJDOC2106"}]
if failures:
    raise SystemExit("CHIR worker 报告失败：" + "; ".join(
        f'{item["code"]}: {item["message"]}' for item in failures))
assert any(item["name"] == "greet" for item in doc["declarations"])
print("已记录 CHIR provider，未发现 worker 失败诊断，源码声明仍在 Doc IR 中")
PY
```

此检查只确认本次运行记录了 CHIR provider、没有 worker 失败诊断，并保留源码声明。CHIR 是保守补充；不要据此推断每个符号都已解析，也不能证明注释符合运行时行为。

## worker 缺失时保留源码 fallback

`--semantic chir` 可以不传 `--chir-worker`；源码声明仍保留，cjdoc 会报告 `CJDOC2101`。下面的负例仍使用相同 compiler 与 import path，只省略 worker 选项：

```bash
"$CJDOC_BIN" generate --project "$TASK_ROOT" \
  --format json --output "$TASK_ROOT/without-worker" \
  --semantic chir --cjc "$CJC_FOR_CLI" \
  --chir-import-path "$CHIR_IMPORT_PATH_FOR_CLI"

python3 - "$TASK_ROOT/without-worker/docs.json" <<'PY'
import json
import sys
from pathlib import Path

doc = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert any(provider["name"] == "chir" for provider in doc["providers"])
assert any(item["code"] == "CJDOC2101" for item in doc["diagnostics"])
assert any(item["name"] == "greet" for item in doc["declarations"])
print("worker 缺失已报告，源码声明仍保留在 Doc IR 中")
PY
```

compiler 失败、CHIR 输出无效、输入 package 不受支持或 import path 不可用时，也会保留 source/AST fallback，并报告 `CJDOC2101` 至 `CJDOC2106` 的诊断。先检查诊断，再决定是否调整工具链。CHIR 选项适用于 `generate` 和 `check`，不适用于读取既有 Doc IR 的 `render`。见[CLI 参考](../reference/cli.md)和[排错指南](troubleshoot.md)。
