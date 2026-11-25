# 配置代码高亮

仓颉代码围栏由内置 lexer 高亮，不需要 Node.js。本页确认默认效果、关闭高亮，并用仓库锁定的 adapter 为 JSON、Bash、Python、TOML、YAML 代码块启用外部高亮。生成的站点始终是静态文件：Node 只在生成时运行，读者和发布流程都不需要它。

## 什么时候用本页

- 只想让仓颉代码有颜色：默认配置已经如此，读完“前提条件”即可。
- 想让代码块保持纯文本、便于逐字对照：看“关闭高亮”。
- 想给 JSON、Bash、Python、TOML、YAML 上色：需要 adapter 小节，涉及 Node.js 与仓库源码副本。

## 前提条件

- 已按[安装 cjdoc](../getting-started/install.md)安装 `cjdoc`，当前终端已加载仓颉 SDK 环境。
- 前两步只需要已安装的 `cjdoc` 与 Bash；adapter 小节另需 Node.js、npm 与 `CJDOC_SOURCE`。

```bash
mkdir -p "$HOME/.cache/cjdoc/examples"
TASK_ROOT="$(mktemp -d "$HOME/.cache/cjdoc/examples/highlight.XXXXXX")"
printf '%s\n' "$TASK_ROOT"
```

后面所有命令都沿用 `$TASK_ROOT`。

## 第一步：确认内置高亮只处理仓颉

```bash
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

cd "$TASK_ROOT"
cjdoc generate --project . --format html --format json --output target/builtin
```

**预期结果**：退出码 `0`，产物在 `$TASK_ROOT/target/builtin/html/concepts/index.html`。仓颉块里 `public`、`func`、`String` 等带颜色（`<span class="cj-tok-keyword">` 这类标记），Python 块是纯文本。默认的 `mode = "static"` 加 `languages = ["cangjie"]` 只启动内置 lexer，不会运行任何外部程序。

## 第二步：关闭高亮

把 `mode` 改成 `off`，换一个新的输出目录：

```bash
cat > "$TASK_ROOT/cjdoc.toml" <<'EOF'
[docs]
index = "docs/index.md"

[highlight]
mode = "off"
languages = ["cangjie"]
on-error = "warn"
EOF

cd "$TASK_ROOT"
cjdoc generate --project . --format html --format json --output target/off
```

**预期结果**：打开 `$TASK_ROOT/target/off/html/concepts/index.html`，两段源码仍可读，但没有任何 `cj-tok-*` 标记，也没有颜色。`mode = "off"` 不删代码块、不改源码内容；想恢复内置高亮，把 `mode` 改回 `"static"`。

`mode` 只接受 `static` 与 `off`，其它值以 `2` 退出并提示 `error: [highlight].mode must be static or off`。

## 第三步：用锁定的 Node adapter 高亮外部语言

准备一个只属于本练习的 adapter 目录，复制四个文件并按锁文件安装依赖；`node_modules` 会装在这里，不写回仓库：

```bash
: "${CJDOC_SOURCE:?请设置为安装时保存的 CJDOC_SOURCE}"
HIGHLIGHT_DIR="$TASK_ROOT/highlight-tool"
mkdir -p "$HIGHLIGHT_DIR"
for file in .node-version adapter.mjs package.json package-lock.json; do
  cp "$CJDOC_SOURCE/tools/highlight/$file" "$HIGHLIGHT_DIR/$file"
done
HIGHLIGHT_ADAPTER="$HIGHLIGHT_DIR/adapter.mjs"
cd "$HIGHLIGHT_DIR"
npm ci --ignore-scripts
```

**预期结果**：`npm ci` 报告 `added 1 package`，`$HIGHLIGHT_DIR/node_modules/highlight.js` 存在。`npm ci` 按 `package-lock.json` 安装精确版本（Highlight.js 11.11.1），不运行包的生命周期脚本。registry 或 npm 缓存不可用时恢复网络后重试；不要改成 `npm install`，那会允许浮动版本。`adapter.mjs` 只提供 `json`、`bash`、`python`、`toml`、`yaml` 五种外部语言，仓颉始终走内置 lexer。

把外部语言写进配置，并用两个成对的绝对路径选项启动 adapter：

```bash
cat > "$TASK_ROOT/cjdoc.toml" <<'EOF'
[docs]
index = "docs/index.md"

[highlight]
mode = "static"
languages = ["cangjie", "python"]
on-error = "warn"
EOF

HIGHLIGHT_NODE="$(command -v node)"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    HIGHLIGHT_NODE="$(cygpath -m "$HIGHLIGHT_NODE")"
    HIGHLIGHT_ADAPTER="$(cygpath -m "$HIGHLIGHT_ADAPTER")"
    ;;
esac
cd "$TASK_ROOT"
cjdoc generate --project . --format html --format json --output target/external \
  --highlight-node "$HIGHLIGHT_NODE" \
  --highlight-adapter "$HIGHLIGHT_ADAPTER"
```

**预期结果**：退出码 `0` 且没有 `CJDOC3120`。打开 `$TASK_ROOT/target/external/html/concepts/index.html`，仓颉块仍是内置高亮，Python 块里的 `def`、函数名与字符串带语法颜色。

两个选项必须同时出现，且都是绝对路径（Windows 在生成前转成原生路径）。CLI 不会把参数当命令字符串交给 shell；含 shell 元字符的值在参数解析阶段就被拒绝。配置里的 `languages` 只决定哪些围栏交给谁处理，写进去不会安装语法，也不会授权运行其它程序。外部进程只继承 `PATH`、`SystemRoot`、`WINDIR`、`TEMP`、`TMP`、`TMPDIR`、`LANG`，不继承 `NODE_OPTIONS`、`NODE_PATH` 或其它项目环境。

发布时只复制生成的 `html/` 树，不需要 Node、`node_modules` 或 adapter 目录。

## 高亮的资源上限

高亮是可选展示层，受固定预算约束：

| 对象 | 上限 | 超出时 |
|---|---|---|
| 单个代码块 | 256 KiB 源码、65,536 个 span | 该块按纯文本输出 |
| 一次生成合计 | 8,192 个 span、4 MiB 元数据 | 后续块省略高亮，报告 `CJDOC3028`，代码原文保留 |
| 外部适配器 | 输入 2 MiB、输出 3 MiB | 视为后端失败，按 `on-error` 处理 |

这些上限不是可调大的性能参数；保留纯文本仍然是可读文档。

## 失败时怎么办

外部进程失败时，代码块保留原文、只是没有高亮，行为由 `[highlight].on-error` 决定：

| 配置 | 现象 |
|---|---|
| `warn`（默认） | 报告 `warning[CJDOC3120]: highlighting backend unavailable or invalid; code text was preserved`，生成以 `0` 退出，产物可用 |
| `error` | 报告 `error[CJDOC4027]: highlighting backend failed and [highlight].on-error is "error"; code text was preserved`，生成以 `1` 退出，代码原文仍写入产物 |

| 现象 | 原因 | 处理 |
|---|---|---|
| `CJDOC3120` 或 `CJDOC4027` | `--highlight-node`/`--highlight-adapter` 指错文件、adapter 目录没跑 `npm ci`、Node 不可执行，或返回结果无法解析 | 核对两个路径存在且可执行，在 adapter 目录重新 `npm ci`，再生成 |
| `error: --highlight-adapter and --highlight-node must be supplied together`，退出码 `2` | 只给了一个选项 | 两个一起给；这时不会启动后端 |
| `error: --highlight-node requires an absolute path` 或 `error: --highlight-adapter requires an absolute path` | 传了相对路径 | 用 `command -v node` 与 `$HIGHLIGHT_ADAPTER` 展开后的绝对路径 |
| `error: --highlight-node requires a path without shell metacharacters` | 值里带空格、`;` 等字符 | 直接给可执行文件的绝对路径，不要写 `node --version` 这类命令 |
| `error: [highlight].languages contains duplicate language 'cangjie'`，退出码 `2` | 同一语言在数组里出现两次 | 去重；语言名归一化后也不能重复 |
| `error: [highlight].languages must not be empty`，退出码 `2` | 把数组写成空 | 至少列一个语言，或删掉整行使用默认值 |
| 写了 `languages = ["python"]` 但仍是纯文本 | 只列语言不会启用外部后端 | `generate`、`check` 或 `serve` 时同时给出两个路径选项 |
| `check` 因高亮 warning 失败 | 用了 `--deny-warnings` | 要么修好后端，要么在不需要外部高亮时把它从 `languages` 移除 |

配置键与可选值见[配置参考](../reference/configuration.md)，选项与约束见[CLI 参考](../reference/cli.md#可选语义和高亮后端)。

## 下一步

- [生成并发布完整静态站点](generate-and-publish.md)。
- [按症状排查故障](troubleshoot.md)。
