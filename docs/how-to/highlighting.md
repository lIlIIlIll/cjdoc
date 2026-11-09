# 配置代码高亮

Cangjie 代码围栏默认由内置 lexer 高亮，不需要 Node.js，也不需要额外安装。本页先确认内置效果，再演示关闭高亮，最后用仓库锁定的 adapter 为 Python 代码块开启外部高亮。生成的网站始终是静态文件：Node 只在生成文档时运行，读者和发布流程都不需要它。

## 何时需要本页

- 只想让 Cangjie 代码有颜色：默认配置已经这样，读完“前提”即可结束。
- 想让代码块保持纯文本，便于逐字对照：看第 2 步。
- 想高亮 JSON、Bash、Python、TOML、YAML：需要最后的外部 adapter 小节，那里才涉及 Node.js 和源码副本。

## 前提

- 已按[安装 cjdoc](../getting-started/install.md)安装 `cjdoc`，当前终端已加载仓颉 SDK 环境。
- 第 1、2 步只需要已安装的 `cjdoc` 与 Bash。

## 准备练习目录

练习文件放在磁盘上的独立目录里：

```bash
mkdir -p "$HOME/.cache/cjdoc/examples"
export TASK_ROOT="$(mktemp -d "$HOME/.cache/cjdoc/examples/highlight.XXXXXX")"
printf '%s\n' "$TASK_ROOT"
```

记下输出的路径。这只是练习文件的存放位置，不是 cjdoc 的要求；后面所有命令都沿用 `$TASK_ROOT`。

## 1. 创建带两种代码围栏的项目

项目首页里放一段 Cangjie 和一段 Python 代码。默认配置只让内置 lexer 处理 Cangjie：

~~~bash
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
~~~

打开 `$TASK_ROOT/target/builtin/html/concepts/index.html`。Cangjie 代码有内置高亮；Python 块以原文显示。默认的 `mode = "static"` 配合 `languages = ["cangjie"]` 只启动内置 lexer，不会尝试运行任何外部程序。

## 2. 关闭高亮

把 `mode` 设为 `off` 并生成到新的输出目录。代码块仍在页面上，只是不再添加高亮标记：

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

打开 `$TASK_ROOT/target/off/html/concepts/index.html`，两段源码仍可读，只是没有颜色。`mode = "off"` 不删除代码围栏，也不改动源码内容；想恢复内置高亮，把 `mode` 改回 `"static"`。

## 3. 用锁定的 Node adapter 高亮 Python

本例选用 Node.js **26.11.1**；这一步还需要 npm，以及安装时保存的 `CJDOC_SOURCE` 源码目录。准备一个只属于本练习的 adapter 子目录，复制四个文件，再按锁文件安装依赖；`node_modules` 会放在这个子目录里，不写回安装源码。

```bash
: "${CJDOC_SOURCE:?请设置为安装时保存的 CJDOC_SOURCE}"
export HIGHLIGHT_DIR="$TASK_ROOT/highlight-tool"
mkdir -p "$HIGHLIGHT_DIR"
for file in .node-version adapter.mjs package.json package-lock.json; do
  cp "$CJDOC_SOURCE/tools/highlight/$file" "$HIGHLIGHT_DIR/$file"
done
export HIGHLIGHT_ADAPTER="$HIGHLIGHT_DIR/adapter.mjs"
cd "$HIGHLIGHT_DIR"
npm ci --ignore-scripts
```

`npm ci` 按 `package-lock.json` 安装精确版本并校验完整性，不运行包的生命周期脚本。若 registry 或 npm 缓存不可用，恢复网络访问后重试；不要改成 `npm install`，那会允许浮动版本。

复制出的 `.node-version` 记录本例使用的 `26.11.1`，可用 `node --version` 核对当前版本。Node 及其依赖只用于生成时的外部进程，发布时只复制生成的 `html/` 树，不复制这个目录。

### 同时处理两种语言

启用 Python 后，内置 lexer 继续处理 Cangjie，Python 交给 adapter。两个选项必须成对出现，且都是绝对路径：

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
    ;;
esac
cd "$TASK_ROOT"
cjdoc generate --project . --format html --format json --output target/external \
  --highlight-node "$HIGHLIGHT_NODE" \
  --highlight-adapter "$HIGHLIGHT_ADAPTER"
```

打开 `$TASK_ROOT/target/external/html/concepts/index.html`：Cangjie 块沿用内置高亮，Python 块现在带 `def`、字符串等语法颜色。

Linux 和 macOS 使用原生 POSIX 绝对路径；Windows Git Bash 的分支在生成之前将两个路径转为原生 Windows 路径。

CLI 只接受绝对路径，并拒绝包含 shell 元字符的值；它不会把参数当作命令字符串交给 shell 执行。

### 能高亮哪些语言

adapter 只提供 `json`、`bash`、`python`、`toml`、`yaml` 五种外部语言，版本由锁文件固定在 Highlight.js 11.11.1。Cangjie 始终走内置 lexer。配置里的 `languages` 只决定哪些围栏交给谁处理：把某个语言写进去不会安装语法，也不会授权运行其它程序。

## 外部进程失败时发生什么

Node 不可执行、adapter 缺失或返回无法解析的结果时，代码块保留原文，只是没有高亮。行为由 `on-error` 决定：

- `warn`（默认）：报告 `CJDOC3120` warning，生成继续，产物可用。
- `error`：报告 `CJDOC4027` error，生成以非零状态结束，代码原文仍写入产物。

常见原因是 `--highlight-node` 或 `--highlight-adapter` 指错了文件、adapter 目录没有执行 `npm ci`，或者两个选项只给了一个——只给一个会在参数解析阶段就失败，不会走到启动后端。核对路径后重新生成即可。

配置键与可选值见[配置参考](../reference/configuration.md)，选项与约束见[CLI 参考](../reference/cli.md#可选语义和高亮后端)。

## 下一步

- [生成并发布完整静态站点](generate-and-publish.md)。
- [按症状排查故障](troubleshoot.md)。
