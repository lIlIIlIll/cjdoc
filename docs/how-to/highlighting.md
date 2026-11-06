# 配置代码高亮

本指南在同一个项目中依次生成内置 Cangjie 高亮、关闭高亮，以及用锁文件固定的 Node.js adapter 高亮 Python。最后用一个实际的 worker 启动失败观察警告与严格错误模式。Node 只在生成时运行外部 adapter；生成的网站不需要 Node 或 `node_modules`。

## 前提与源码、Node 身份

- 已按[源码安装](../getting-started/install.md)完成当前 cjdoc checkout 的正式构建，并在当前 shell 中加载 Cangjie SDK runtime。
- `CJDOC_SOURCE` 指向该 checkout，`CJDOC_REVISION` 记录其完整提交；以下使用同一 checkout 生成的 `target/release/bin/main` 和 adapter 源码。
- 外部高亮需要 Node.js **26.11.1**、npm、Bash、Python 3。仓库 `tools/highlight/.node-version` 指定 26.11.1；`package.json` 允许 `>=26.10.0 <27.0.0`，但只把 26.11.1 声明为本仓验收版本。请通过组织批准的 Node 安装方式准备该确切版本，再运行下列检查。
- 本地 package 由本页创建；生成时不构建被扫描项目。

先使用[源码安装页](../getting-started/install.md)记录的 `CJDOC_SOURCE` 与 `CJDOC_REVISION`。若换了终端，从构建记录恢复变量并重新加载 SDK runtime；不要从当前目录或版本字符串推测二进制来源。

```bash
: "${CJDOC_SOURCE:?请设置为源码安装时记录的 CJDOC_SOURCE}"
: "${CJDOC_REVISION:?请设置为源码安装时记录的 CJDOC_REVISION}"
test "$(git -C "$CJDOC_SOURCE" rev-parse --verify HEAD)" = "$CJDOC_REVISION"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) export CJDOC_BIN="$CJDOC_SOURCE/target/release/bin/main.exe" ;;
  *) export CJDOC_BIN="$CJDOC_SOURCE/target/release/bin/main" ;;
esac
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) test -f "$CJDOC_BIN" ;;
  *) test -x "$CJDOC_BIN" ;;
esac

```

`CJDOC_BIN` 来自该记录提交下的正式源码构建；若文件不存在，回到安装页完成源码构建。`node --version` 应输出 `v26.11.1`。仓库 `tools/highlight/.node-version` 指定 26.11.1，`package.json` 允许 `>=26.10.0 <27.0.0`，但本页只使用 26.11.1。请通过组织批准的 Node 安装方式准备该版本；Windows 的源码工具使用 Git Bash。

接下来将 adapter 的四个输入文件从记录的 Git 提交读取到任务目录，再按锁文件安装依赖。`npm ci` 的 `node_modules`、npm cache 和临时文件都留在任务目录，不改动受保护的源码 checkout。

```bash
mkdir -p "$HOME/.cache/agent-tmp"
chmod 700 "$HOME/.cache/agent-tmp"
export TASK_AREA="$(mktemp -d "$HOME/.cache/agent-tmp/cjdoc-highlighting.XXXXXX")"
export RUNNER_TEMP="$(mktemp -d "$TASK_AREA/runner-temp.XXXXXX")"
export TMPDIR="$RUNNER_TEMP" TMP="$RUNNER_TEMP" TEMP="$RUNNER_TEMP"
export PYTHONDONTWRITEBYTECODE=1
export npm_config_cache="$TASK_AREA/npm-cache"
node --version
npm --version
export TASK_ROOT="$TASK_AREA/project"
export HIGHLIGHT_DIR="$TASK_AREA/highlight-tool"
case "$TASK_AREA/" in
  "$CJDOC_SOURCE/"*) printf '任务文件必须位于 CJDOC_SOURCE 之外\n' >&2; exit 1 ;;
esac
mkdir -p "$HIGHLIGHT_DIR"
for file in .node-version adapter.mjs package.json package-lock.json; do
  git -C "$CJDOC_SOURCE" show "$CJDOC_REVISION:tools/highlight/$file" \
    > "$HIGHLIGHT_DIR/$file"
done
test "$(cat "$HIGHLIGHT_DIR/.node-version")" = "26.11.1"
export HIGHLIGHT_ADAPTER="$HIGHLIGHT_DIR/adapter.mjs"

cd "$HIGHLIGHT_DIR"
npm ci --ignore-scripts
```

`npm ci` 会核对锁文件中的依赖版本与完整性，且不运行生命周期脚本。若配置的 registry 或 npm cache 不可用，恢复网络访问，或先准备与锁文件完整性匹配的包，再重试。不要在示例项目中另装浮动版本的 Highlight.js。

## 创建完整示例项目

项目首页中放一段 Cangjie 和一段 Python 代码围栏。默认配置只让内置 Cangjie lexer 处理 Cangjie；Node adapter 尚未参与。

```bash
test ! -e "$TASK_ROOT" || { printf '请选择新的 TASK_ROOT\n' >&2; exit 1; }
mkdir -p "$TASK_ROOT/src" "$TASK_ROOT/docs"

cat > "$TASK_ROOT/cjpm.toml" <<'EOF'
[package]
cjc-version = "1.2.0"
name = "highlightdemo"
version = "0.1.0"
output-type = "static"
EOF

cat > "$TASK_ROOT/src/api.cj" <<'EOF'
package highlightdemo

/** 原样保留姓名并返回问候语。 */
public func greet(name: String): String { "Hello, ${name}!" }
EOF

cat > "$TASK_ROOT/cjdoc.toml" <<'EOF'
[docs]
index = "docs/index.md"

[highlight]
mode = "static"
languages = ["cangjie"]
on-error = "warn"
EOF

cat > "$TASK_ROOT/docs/index.md" <<'EOF'
# Code highlighting example

内置 Cangjie lexer 处理第一个代码块，不需要 Node.js：

```cangjie
public func greet(name: String): String { "Hello, ${name}!" }
```

在选择 Python 且配置外部 adapter 前，Python 块保持原文：

```python
def greet(name):
    return f"Hello, {name}!"
```
EOF

"$CJDOC_BIN" generate --project "$TASK_ROOT" \
  --format html --format json --output "$TASK_ROOT/builtin"
```

打开 `$TASK_ROOT/builtin/html/concepts/index.html`。Cangjie 代码应有内置高亮；Python 块仍以原文显示。默认静态配置只包含 `cangjie`，不要求 Node，也不会尝试启动外部程序。

## 关闭高亮

将 `mode` 设为 `off` 并生成到新的输出目录。代码块仍显示为文本，只是不添加高亮标记：

```bash
cat > "$TASK_ROOT/cjdoc.toml" <<'EOF'
[docs]
index = "docs/index.md"

[highlight]
mode = "off"
languages = ["cangjie"]
on-error = "warn"
EOF

"$CJDOC_BIN" generate --project "$TASK_ROOT" \
  --format html --format json --output "$TASK_ROOT/off"
```

打开 `$TASK_ROOT/off/html/concepts/index.html` 并确认两段源码仍可读。`mode = "off"` 不是删除 fenced code，也不改变注释或源码；若希望返回内置 Cangjie 高亮，恢复 `mode = "static"`。

## 用锁定的 Node adapter 高亮 Python

启用 Python 后，内置 Cangjie lexer 仍处理 Cangjie；Python 由本任务目录中的锁定 adapter 与 Highlight.js 11.11.1 处理。需要同时传入 Node 可执行文件和 adapter 的**绝对路径**；两个参数只适用于 `generate`/`check`，必须成对出现，路径不能包含 CLI 拒绝的 shell 元字符。

```bash
cat > "$TASK_ROOT/cjdoc.toml" <<'EOF'
[docs]
index = "docs/index.md"

[highlight]
mode = "static"
languages = ["cangjie", "python"]
on-error = "warn"
EOF

export HIGHLIGHT_NODE="$(command -v node)"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    export HIGHLIGHT_NODE="$(cygpath -m "$HIGHLIGHT_NODE")"
    export HIGHLIGHT_ADAPTER="$(cygpath -m "$HIGHLIGHT_ADAPTER")"
    case "$HIGHLIGHT_NODE" in [A-Za-z]:/*|//*) ;; *) printf 'Node 路径不是 Windows 绝对路径\n' >&2; exit 1 ;; esac
    case "$HIGHLIGHT_ADAPTER" in [A-Za-z]:/*|//*) ;; *) printf 'adapter 路径不是 Windows 绝对路径\n' >&2; exit 1 ;; esac
    ;;
  *)
    case "$HIGHLIGHT_NODE" in /*) ;; *) printf 'Node 路径不是绝对路径\n' >&2; exit 1 ;; esac
    case "$HIGHLIGHT_ADAPTER" in /*) ;; *) printf 'adapter 路径不是绝对路径\n' >&2; exit 1 ;; esac
    ;;
esac
test -f "$HIGHLIGHT_NODE" && test -f "$HIGHLIGHT_ADAPTER"
"$CJDOC_BIN" generate --project "$TASK_ROOT" \
  --format html --format json --output "$TASK_ROOT/external" \
  --highlight-node "$HIGHLIGHT_NODE" \
  --highlight-adapter "$HIGHLIGHT_ADAPTER"
```
Linux/macOS 使用原生 POSIX 绝对路径。Windows Git Bash 会在传入 `--highlight-node`、`--highlight-adapter` 和缺失 Node 负例前用 `cygpath -m` 转成 Windows drive/UNC 路径；这部分只按当前 CLI 路径解析规则静态核对，本轮未在 Windows 实际运行。

验证 Doc IR 中的高亮来源和真实 engine revision：

```bash
python3 - "$TASK_ROOT/external/docs.json" <<'PY'
import json
import sys
from pathlib import Path

doc = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))

def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)

highlights = [item for item in walk(doc) if item.get("engineId") == "highlight.js"]
if not any(item.get("language") == "python"
           and item.get("engineRevision") == "11.11.1/cjdoc-map-1"
           and item.get("state") == "complete" for item in highlights):
    raise SystemExit("固定的外部 adapter 没有生成完整 Python 高亮结果")
print("Python 使用 highlight.js 11.11.1/cjdoc-map-1 高亮")
PY
```

在 `$TASK_ROOT/external/html/concepts/index.html` 检查实际页面；发布时只需复制生成的 `html/` 树，不复制 `tools/highlight` 或 `node_modules`。adapter 只接受 `json`、`bash`、`python`、`toml`、`yaml` 五种外部语言；Cangjie 使用内置 lexer。配置里的 `languages` 只选择哪些代码围栏可高亮，不授权任意程序或语言模块。

## 外部进程失败时保留代码原文

以下负例故意把 Node 可执行路径设为任务临时目录中的**不存在文件**，adapter 源仍取自记录的源码提交。这个无效 host 配置用于触发 worker 启动失败，不是可用后端或成功示例。路径仍为绝对路径，因此 CLI 参数解析成功，生成时才会出现后端故障。

先保持 `on-error = "warn"`，并把失败诊断记录到独立日志：

```bash
export MISSING_NODE="$TASK_ROOT/not-installed-node"
test ! -e "$MISSING_NODE"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) export MISSING_NODE="$(cygpath -m "$MISSING_NODE")" ;;
esac
"$CJDOC_BIN" generate --project "$TASK_ROOT" \
  --format html --format json --output "$TASK_ROOT/external-warning" \
  --highlight-node "$MISSING_NODE" \
  --highlight-adapter "$HIGHLIGHT_ADAPTER" \
  2> "$TASK_ROOT/external-warning.log"
```

该次生成保留代码原文，并报告 `CJDOC3120` warning；查看 `$TASK_ROOT/external-warning.log`。要把同一类后端故障提升为错误，改为 `on-error = "error"` 并使用新输出目录：

```bash
cat > "$TASK_ROOT/cjdoc.toml" <<'EOF'
[docs]
index = "docs/index.md"

[highlight]
mode = "static"
languages = ["cangjie", "python"]
on-error = "error"
EOF

if "$CJDOC_BIN" generate --project "$TASK_ROOT" \
  --format html --format json --output "$TASK_ROOT/external-error" \
  --highlight-node "$MISSING_NODE" \
  --highlight-adapter "$HIGHLIGHT_ADAPTER" \
  2> "$TASK_ROOT/external-error.log"; then
  printf '预期高亮后端失败\n' >&2
  exit 1
else
  status=$?
  printf '按预期失败，退出码：%s\n' "$status"
fi
```

失败模式报告 `CJDOC4027` error，并保留原代码文本；查看 `$TASK_ROOT/external-error.log` 中的诊断。恢复 Node 与 adapter 的正确绝对路径并把 `on-error` 设回 `warn`（或删除该键恢复默认值）后重新生成。配置错误与 CLI 参数错误发生在后端启动之前，见[配置参考](../reference/configuration.md)和[CLI 参考](../reference/cli.md)。
