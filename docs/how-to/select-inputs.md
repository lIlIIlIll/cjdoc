# 选择要扫描的源码

本指南用一个小型 workspace 展示 workspace 成员、path dependency、显式源码路径、条件编译和 audience 的区别，并说明怎样让 cjdoc 读取 cjpm 已准备好的缓存依赖。生成范围会改变 API 页面和索引内容，因此 CI 与本地检查应使用相同的选择参数。

## 前提

- 已安装可运行的 cjdoc 原生二进制，并已配置其仓颉运行时环境。安装方式见[从源码安装](../getting-started/install.md)。
- Bash、Cangjie SDK 1.2.0 和 cjpm。只有准备缓存依赖时才需要先运行 cjpm。
- 本页的 workspace 输入由命令创建，不依赖 cjdoc 源码仓、外部网址或预置提交。

以下命令在 Bash 中执行。先确认 `$HOME/.cache` 位于磁盘文件系统而非 tmpfs；本页会在其中创建独立任务目录。

## 创建 workspace 与路径依赖

workspace 包含两个成员 `app`、`peer`；`shared` 是 app 的路径依赖，但不是 workspace 成员。这个布局可以分别观察这两类输入。

```bash
mkdir -p "$HOME/.cache/agent-tmp"
chmod 700 "$HOME/.cache/agent-tmp"
export TASK_AREA="$(mktemp -d "$HOME/.cache/agent-tmp/cjdoc-input-selection.XXXXXX")"
export RUNNER_TEMP="$(mktemp -d "$TASK_AREA/runner-temp.XXXXXX")"
export TMPDIR="$RUNNER_TEMP" TMP="$RUNNER_TEMP" TEMP="$RUNNER_TEMP"
export PYTHONDONTWRITEBYTECODE=1
if [ -n "${CJDOC_SOURCE:-}" ]; then
  case "$TASK_AREA/" in
    "$CJDOC_SOURCE/"*) printf '任务文件必须位于 CJDOC_SOURCE 之外\n' >&2; exit 1 ;;
  esac
fi
export TASK_ROOT="$TASK_AREA/workspace"
mkdir -p "$TASK_ROOT/workspace/packages/app/src" \
  "$TASK_ROOT/workspace/packages/peer/src" \
  "$TASK_ROOT/workspace/shared/src"

cat > "$TASK_ROOT/workspace/cjpm.toml" <<'EOF'
[workspace]
members = ["packages/app", "packages/peer"]
EOF

cat > "$TASK_ROOT/workspace/packages/app/cjpm.toml" <<'EOF'
[package]
cjc-version = "1.2.0"
name = "app"
version = "0.1.0"
output-type = "static"

[dependencies]
shared = { path = "../../shared", output-type = "static" }
EOF

cat > "$TASK_ROOT/workspace/packages/app/src/api.cj" <<'EOF'
package app

/** 使用 feature cfg 时才出现的 API。 */
@When[feature == "extra"]
public func featureApi(): Int64 { 1 }

/** 内部辅助函数，仅在 audience all 输出中显示。 */
private func hiddenApi(): Unit {}
EOF

cat > "$TASK_ROOT/workspace/packages/peer/cjpm.toml" <<'EOF'
[package]
cjc-version = "1.2.0"
name = "peer"
version = "0.1.0"
output-type = "static"
EOF

cat > "$TASK_ROOT/workspace/packages/peer/src/api.cj" <<'EOF'
package peer

/** 第二个 workspace 成员的 API。 */
public func peerApi(): Unit {}
EOF

cat > "$TASK_ROOT/workspace/shared/cjpm.toml" <<'EOF'
[package]
cjc-version = "1.2.0"
name = "shared"
version = "0.1.0"
output-type = "static"
EOF

cat > "$TASK_ROOT/workspace/shared/src/api.cj" <<'EOF'
package shared

/** path dependency 中的 API。 */
public func sharedApi(): String { "shared" }
EOF
```

这些文件组成一个完整的本地 workspace。cjdoc 会自动读取 `workspace.members`，但不会默认包含 `shared` 路径依赖。

## 生成时选择输入

用 `--include-path-dependencies` 包含 `app/cjpm.toml` 中声明的路径依赖。显式传入目标编译所用的 cfg；cjdoc 不会从编译器设置推断自定义 cfg 值。

```bash
cjdoc generate --project "$TASK_ROOT/workspace" \
  --format html --format json --output "$TASK_ROOT/selected-extra" \
  --include-path-dependencies --cfg feature=extra --audience external
```

`html/search-index.json` 应包含 `peerApi`、`sharedApi` 和 `featureApi`，但不含 `hiddenApi`。`docs.json` 保留所有已采集声明，包括私有声明；它不是经过 audience 过滤的 API 输出。下面同时检查两种产物：

```bash
python3 - "$TASK_ROOT/selected-extra/docs.json" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1]).parent
document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
names = {item["name"] for item in document["declarations"]}
expected = {"peerApi", "sharedApi", "featureApi", "hiddenApi"}
missing = expected - names
if missing:
    raise SystemExit(f"缺少已选择的声明：{sorted(missing)}")
search = (root / "html/search-index.json").read_text(encoding="utf-8")
if "featureApi" not in search or "hiddenApi" in search:
    raise SystemExit("external audience 搜索结果与预期不符")
print("workspace、路径依赖、cfg 与 external audience 已选中")
PY
```

audience 会筛选 HTML、Markdown、搜索、Agent 输出和覆盖率中的声明，但不会过滤完整的 `docs.json`。不要把该 JSON 当作已脱敏的 API 导出发布。

另生成 `--audience all` 站点，检查私有声明也进入搜索索引：

```bash
cjdoc generate --project "$TASK_ROOT/workspace" \
  --format html --format json --output "$TASK_ROOT/all-audience" \
  --include-path-dependencies --cfg feature=extra --audience all

python3 - "$TASK_ROOT/all-audience/html/search-index.json" <<'PY'
import sys
from pathlib import Path

search = Path(sys.argv[1]).read_text(encoding="utf-8")
if "hiddenApi" not in search:
    raise SystemExit("audience=all 搜索结果中未发现私有声明")
print("audience=all 搜索结果包含 hiddenApi")
PY
```

若要观察 cfg 排除该条件 API 的效果，可对同一源码指定另一个值并生成到独立目录：

```bash
cjdoc generate --project "$TASK_ROOT/workspace" \
  --format json --output "$TASK_ROOT/selected-basic" \
  --include-path-dependencies --cfg feature=basic --audience external
```

`feature=basic` 时 `featureApi` 会被排除，workspace 成员仍会包含。比较不同选择结果时使用不同输出目录。

## 显式指定依赖源码

当依赖源码不在自动发现的位置时，使用 `--dependency-source NAME=PATH` 显式加入一个本地 Cangjie package。名称会标记在捕获的依赖图中，目录必须包含自己的 `cjpm.toml`。项目有多个候选依赖目录时，也可以借此只选择其中一个。

```bash
cjdoc generate --project "$TASK_ROOT/workspace" \
  --format json --output "$TASK_ROOT/explicit-source" \
  --dependency-source shared="$TASK_ROOT/workspace/shared"
```

生成结果应包含 `sharedApi`。`--dependency-source` 可重复，路径按 cjdoc 进程的当前工作目录解释；例子使用绝对路径，避免受运行目录影响。不要传入压缩包、二进制目录或缺少 `cjpm.toml` 的路径。

## 使用 cjpm 已准备的缓存依赖

此流程从安装时记录的 `CJDOC_REVISION` 读取 cjdoc 源码仓库 `cjpm.toml`、`cjpm.lock` 中实际固定的 `yjson` Git 依赖，并创建独立消费项目，在其自己的锁文件与 cjpm 缓存中准备同一提交，然后让 cjdoc 读取它。它不把 cjdoc 自身的大型项目作为被扫描输入，也不把依赖 URL/提交写成独立猜测值。

缓存依赖流程还需要本页安装时记录的 `CJDOC_SOURCE` 与 `CJDOC_REVISION`、配套的静态 stdx 1.2.0、`cjc`、`cjpm` 和 Bash。新终端须恢复源码身份并重新加载 SDK runtime；确认 `$HOME/.cache` 在磁盘文件系统而非 tmpfs，以下步骤会另建自己的任务目录和 Python 环境变量。

```bash
: "${CJDOC_SOURCE:?先按源码安装页设置 CJDOC_SOURCE}"
: "${CJDOC_REVISION:?从构建记录恢复与二进制配对的完整提交}"
test "$(git -C "$CJDOC_SOURCE" rev-parse --verify HEAD)" = "$CJDOC_REVISION"
export CJDOC_BIN="$CJDOC_SOURCE/target/release/bin/main"
if [ -f "$CJDOC_BIN.exe" ]; then export CJDOC_BIN="$CJDOC_BIN.exe"; fi
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) test -f "$CJDOC_BIN" ;;
  *) test -x "$CJDOC_BIN" ;;
esac
cjc -v
cjpm -v

mkdir -p "$HOME/.cache/agent-tmp"
chmod 700 "$HOME/.cache/agent-tmp"
export CACHE_TASK_ROOT="$(mktemp -d "$HOME/.cache/agent-tmp/cjdoc-input-cache.XXXXXX")"
export CACHE_RUNNER_TEMP="$(mktemp -d "$CACHE_TASK_ROOT/runner-temp.XXXXXX")"
export TMPDIR="$CACHE_RUNNER_TEMP" TMP="$CACHE_RUNNER_TEMP" TEMP="$CACHE_RUNNER_TEMP"
export PYTHONDONTWRITEBYTECODE=1
case "$CACHE_TASK_ROOT/" in
  "$CJDOC_SOURCE/"*) printf '任务文件必须位于 CJDOC_SOURCE 之外\n' >&2; exit 1 ;;
esac
export CACHE_PROJECT="$CACHE_TASK_ROOT/consumer"
mkdir -p "$CACHE_PROJECT/src"
git -C "$CJDOC_SOURCE" show "$CJDOC_REVISION:scripts/with_stdx.py" \
  > "$CACHE_TASK_ROOT/with_stdx.py"

export CJPM_CACHE="$HOME/.cjpm"
case "$CJPM_CACHE/" in
  "$CJDOC_SOURCE/"*) printf 'cjpm cache 必须位于 CJDOC_SOURCE 之外\n' >&2; exit 1 ;;
esac
git -C "$CJDOC_SOURCE" show "$CJDOC_REVISION:cjpm.toml" \
  > "$CACHE_TASK_ROOT/cjdoc-cjpm.toml"
git -C "$CJDOC_SOURCE" show "$CJDOC_REVISION:cjpm.lock" \
  > "$CACHE_TASK_ROOT/cjdoc-cjpm.lock"

# 从锁定提交的两个文件中读取相同的 yjson URL 与完整提交。

read -r YJSON_GIT YJSON_COMMIT < <(python3 - \
  "$CACHE_TASK_ROOT/cjdoc-cjpm.toml" "$CACHE_TASK_ROOT/cjdoc-cjpm.lock" <<'PY'
import re
import sys
from pathlib import Path

def dependency(path, section):
    text = Path(path).read_text(encoding="utf-8")
    block = re.search(rf"(?ms)^\[{re.escape(section)}\]\s*(.*?)(?=^\[|\Z)", text)
    if block is None:
        raise SystemExit(f"{path}: missing [{section}]")
    entry = re.search(r'(?m)^\s*"?yjson"?\s*=\s*\{([^}]*)\}', block.group(1))
    if entry is None:
        raise SystemExit(f"{path}: yjson dependency not found")
    fields = dict(re.findall(
        r'([A-Za-z][A-Za-z0-9_-]*)\s*=\s*"([^"]*)"', entry.group(1)))
    commit = fields.get("commitId", "")
    if not fields.get("git") or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise SystemExit(f"{path}: yjson must have a Git URL and full commit")
    return fields["git"], commit

manifest = dependency(sys.argv[1], "dependencies")
lock = dependency(sys.argv[2], "requires")
if manifest != lock:
    raise SystemExit("cjpm.toml yjson dependency does not match cjpm.lock")
print(*manifest, sep="\t")
PY
)
test -n "$YJSON_GIT" && test -n "$YJSON_COMMIT"

cat > "$CACHE_PROJECT/cjpm.toml" <<EOF
[package]
cjc-version = "1.2.0"
name = "cacheconsumer"
version = "0.1.0"
output-type = "static"

[dependencies]
yjson = { git = "$YJSON_GIT", commitId = "$YJSON_COMMIT", output-type = "static" }
EOF

cat > "$CACHE_PROJECT/src/api.cj" <<'EOF'
package cacheconsumer

import yjson.*

/** Parse a JSON value using the pinned yjson dependency.
 * @param text JSON source text.
 * @return The parsed value.
 */
public func parseValue(text: String): JsonNode { JsonNode.parse(text) }
EOF

cd "$CACHE_PROJECT"
python3 "$CACHE_TASK_ROOT/with_stdx.py" --variant static -- cjpm build --jobs 1
python3 - "$CACHE_PROJECT/cjpm.lock" "$YJSON_GIT" "$YJSON_COMMIT" <<'PY'
import sys
from pathlib import Path

lock = Path(sys.argv[1]).read_text(encoding="utf-8")
if sys.argv[2] not in lock or sys.argv[3] not in lock:
    raise SystemExit("cjpm.lock 没有记录从源仓清单读取的 yjson 提交")
print("消费项目锁定了同一 yjson Git 提交")
PY
```

`cjpm build` 会准备真实 Git 源码并写入消费项目的 `cjpm.lock`；生成器依赖 URL 与 commitId 先从记录的源码仓 `cjpm.toml`、`cjpm.lock` 两边读取并核对，再检查消费项目生成的锁文件包含相同二者。默认缓存根目录为 `$HOME/.cjpm`；若 cjpm 配置了其他根目录，把 `CJPM_CACHE` 改成该实际路径，并确认构建与读取使用同一缓存。该目录与 cjdoc 的 `--cache-dir` 不同。

检查缓存依赖是否包含且没有被跳过：

```bash
python3 - "$CACHE_TASK_ROOT/cached-dependency-output/docs.json" <<'PY'
import json
import sys
from pathlib import Path

doc = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
names = {item["name"] for item in doc["dependencies"]}
if "yjson" not in names:
    raise SystemExit("未采集到锁定的 yjson 源码依赖")
missing = [item for item in doc["diagnostics"] if item["code"] == "CJDOC1021"]
if missing:
    raise SystemExit("有缓存依赖被跳过：" + "; ".join(
        item["message"] for item in missing))
print("已从 cjpm 缓存采集固定的 yjson 依赖")
PY
```

所有消费项目输入、构建产物、生成结果和 cjpm cache 都在 `$CACHE_TASK_ROOT` 或 `$CJPM_CACHE`，并与受保护的 `CJDOC_SOURCE` 分离；`--no-cache` 让 cjdoc 不写源码解析缓存。cjdoc 不会下载缺失的锁定依赖；找不到时会跳过并给出 `CJDOC1021`。只有在真实本地 checkout 且其中有自己的 `cjpm.toml` 时才使用 `--dependency-source NAME=PATH`。`--cjpm-cache` 必须与 `--include-cached-dependencies` 一起使用；选项适用范围见[CLI 参考](../reference/cli.md)。

## 后续任务

- [配置输入与输出](../reference/configuration.md)
- [管理生成产物与缓存](manage-outputs.md)
- [生成与发布文档](generate-and-publish.md)
