# 比较两个版本的 API 并发布版本站点

用仓库自带的两份 PocketKit 教学源码生成 0.1.0 和 0.2.0 的 HTML 与 API 快照，读出差异，再组合成可切换版本的站点。完成后 `$WORK/site/` 是一个可以整体上传的站点：首页列出两个版本，版本页面里能切换，符号的外部文档链接打开独立的依赖库页面。

## 前提

- 已按[安装 cjdoc](../getting-started/install.md)安装，并在当前终端加载仓颉 SDK 环境。
- 安装时保存的 `CJDOC_SOURCE` 指向 cjdoc 源码；本页只用它复制 `examples/pocketkit/` 下的三份教学源码。使用自己的两份源码时不需要这个变量。
- Bash 和 `cp`。所有输出都在 `$HOME/.cache/cjdoc/examples` 下新建的目录，不改动源码目录。

`$HOME/.cache` 应在磁盘文件系统上，而不是 tmpfs。Linux 上可用 `df -T "$HOME/.cache"` 确认类型；空间不足时先把 `HOME` 换成其它有空间的父目录再执行下面的命令。

## 准备版本源码与依赖文档

先建练习根，把三份源码复制到同一个父目录：

```bash
: "${CJDOC_SOURCE:?请先按安装页保存 CJDOC_SOURCE}"
test -d "$CJDOC_SOURCE/examples/pocketkit"
mkdir -p "$HOME/.cache/cjdoc/examples"
VERSIONS_ROOT="$(mktemp -d "$HOME/.cache/cjdoc/examples/versions.XXXXXX")"
INPUT="$VERSIONS_ROOT/input"
WORK="$VERSIONS_ROOT/output"
mkdir -p "$INPUT" "$WORK"
cp -R "$CJDOC_SOURCE/examples/pocketkit/demo-v1" \
      "$CJDOC_SOURCE/examples/pocketkit/demo-v2" \
      "$CJDOC_SOURCE/examples/pocketkit/support-v1" "$INPUT"
V1="$INPUT/demo-v1"
V2="$INPUT/demo-v2"
SUPPORT="$INPUT/support-v1"
```

两个 demo 的 `cjpm.toml` 都用 `path = "../support-v1"` 声明依赖，所以必须让三者保持同级；不要改写清单里的相对路径。

两个 demo 的 `cjdoc.toml` 都通过 `[external-docs.pocket_support]` 读取 `docs/support-symbol-index.json`，并把链接基址设为 `./dependencies/support-v1`、版本设为 `support-v1`。先生成依赖库文档，再把它的符号索引放进两份 demo，demo 生成页面时才能得到可用的外部参考：

```bash
cjdoc generate --project "$SUPPORT" --format html --doc-version support-v1 \
  --locale en --no-cache --output "$WORK/support"
cp "$WORK/support/html/symbol-index.json" "$V1/docs/support-symbol-index.json"
cp "$WORK/support/html/symbol-index.json" "$V2/docs/support-symbol-index.json"
```

这里覆盖两份 demo 里可能存在的旧索引。索引必须来自这份 `support-v1` 源码，并带有 `support-v1` 版本字段；来源或版本不符时，页面会显示外部参考不可用或已过期，而不是可点击的链接。依赖文档用 `--locale en` 生成，它的界面语言与消费方的界面语言互相独立。

## 生成版本快照并阅读差异

分别生成两个真实版本的 HTML 和 API 快照。`--doc-version` 只写入站点元数据，不会改变源码，也不会让同一份源码变成另一个版本：

```bash
cjdoc generate --project "$V1" --format html --format api-surface \
  --doc-version 0.1.0 --no-cache --output "$WORK/v1"
cjdoc generate --project "$V2" --format html --format api-surface \
  --doc-version 0.2.0 --no-cache --output "$WORK/v2"
```

每个输出根下有 `html/index.html` 和 `api-surface/api-surface.json`。demo 的默认语言是 `zh-CN`；需要英文站点时加 `--locale en`，但两份快照要使用相同的受众和 cfg 选项。

两个教学库在 `cjdoc.toml` 的 `[coverage]` 里把 `symbols` 和 `parameters` 设为 `80`，`generate` 和 `check` 都会执行这个门槛：文档覆盖不足时命令以 `1` 退出，并给出实际百分比。默认受众 `external` 下这两份源码满足该门槛。不要为了跑通某个实验去放宽它；也不要用 `--audience all` 重新生成快照——它把私有声明也算进分母，会额外拉低覆盖率并让命令失败，得到的是另一份不可比的快照。

先看文本差异，再把同一份报告存成 JSON：

```bash
cjdoc diff \
  --baseline "$WORK/v1/api-surface/api-surface.json" \
  --current "$WORK/v2/api-surface/api-surface.json" \
  --format text
cjdoc diff \
  --baseline "$WORK/v1/api-surface/api-surface.json" \
  --current "$WORK/v2/api-surface/api-surface.json" \
  --format json > "$WORK/v1-to-v2.json"
```

文本报告开头给出项目、受众，随后一行是各类差异的计数，之后每个非 `unchanged` 条目列出分类、声明种类、标识、匹配状态和原因。这一对源码里，`demo-v2` 移除了 `TextCatalog.legacyCount`、新增了 `nonEmpty`，并给 `add(Int64)` 增加了 `radix` 参数，因此不会得到空差异。JSON 文件保留完整报告，组合站点时用它链接差异。

## 组合站点并补齐依赖页面

```bash
cjdoc versions compose \
  --version "0.1.0=$WORK/v1/html" \
  --channel 0.1.0=stable \
  --version "0.2.0=$WORK/v2/html" \
  --channel 0.2.0=preview \
  --diff "0.2.0=$WORK/v1-to-v2.json" \
  --latest 0.2.0 \
  --output "$WORK/site"

mkdir -p "$WORK/site/0.1.0/dependencies" "$WORK/site/0.2.0/dependencies"
cp -R "$WORK/support/html" "$WORK/site/0.1.0/dependencies/support-v1"
cp -R "$WORK/support/html" "$WORK/site/0.2.0/dependencies/support-v1"
```

`--version ID=PATH` 指向的是生成输出里的 `html` 目录，不是整个输出根。省略 `--label` 和 `--base-path` 时，两者都等于版本 ID，所以本页的版本页面位于 `site/0.1.0/` 和 `site/0.2.0/`。`--channel` 与默认的 `status=published` 只是展示文字，不验证发布流程。省略 `--latest` 时默认取第一个 `--version` 的 ID，而不是按版本号排序；这里显式指定 `0.2.0`，它会被标为最新并生成 `latest/` 跳转。`--diff` 把差异报告附到 0.2.0 版本，并在版本选择器里给出“版本变化”入口。

依赖库的完整 HTML 树要在 `compose` 之后复制到每个版本根的 `dependencies/support-v1`。本页生成的是单语言站点，版本根下就是 `index.html` 与 `symbols/` 等页面，符号页里的 `../dependencies/support-v1/...` 正好指到这里；如果你改用 `--all-languages`，输入的 `html/<语言>/` 会组合成 `<版本根>/<语言>/`，就要复制到 `<版本根>/<语言>/dependencies/support-v1`。如果先复制再组合，这些页面会被当成版本输入的一部分，从而被注入 PocketKit 的版本选择器；后复制则保持它们是独立依赖文档，但路径仍与配置里的 `base-url` 一致。

## 打开并发布版本站点

```bash
xdg-open "$WORK/site/index.html"
```

macOS 用 `open "$WORK/site/index.html"`，Windows 在 Git Bash 中用 `start "" "$WORK/site/index.html"`。首页应列出 `0.1.0`（stable）与 `0.2.0`（preview），并标出最新版本。

接着打开 `site/0.2.0/index.html`，在版本选择器里切到 `0.1.0`：两份源码都有的符号应落到 `0.1.0` 的对应页面。从只在 0.2.0 存在的 `nonEmpty` 页面切到 0.1.0 时，会退回目标版本首页，并标注“此版本没有该符号”或“此版本没有该页面”。缺失符号按可用的所属页面或版本首页回退；页面缺失回到版本首页，章节缺失落到同一页的页首。若组合的是多语言站点，目标版本没有当前语言时退回该版本的默认语言。这些回退是版本选择器的预期行为，不是链接损坏。

再打开 0.2.0 的 `TextCatalog` 页面，它的注释里有 `@see pocket_support.SourceLabel`；点击“另请参阅”里的链接，应打开 `site/0.2.0/dependencies/support-v1/` 下的依赖库页面。依赖页面本身没有 PocketKit 的版本选择器，因为它在组合完成后才被复制进来。

`site/versions.json` 记录每个版本的 `id`、`label`、`basePath`、`channel`、`status`、入口和附带的差异报告。它是组合清单，不代替目录里的实际页面：要确认某个符号是否存在于某版本，直接打开该版本的页面或它的符号索引。发布时上传整个 `$WORK/site/`，不要只复制某一个版本目录；版本选择器和 `latest/` 都依赖同级的其它目录。

## 拒绝破坏性变化或要求完全不变

前面的 `diff` 只报告差异，不因为差异本身失败。要把它当作检查，加上对应的拒绝选项：

```bash
cjdoc diff \
  --baseline "$WORK/v1/api-surface/api-surface.json" \
  --current "$WORK/v2/api-surface/api-surface.json" \
  --deny-breaking-api
cjdoc diff \
  --baseline "$WORK/v1/api-surface/api-surface.json" \
  --current "$WORK/v2/api-surface/api-surface.json" \
  --deny-potentially-breaking-api
```

`--deny-breaking-api` 在存在 `breaking` 项时以 `1` 退出；`--deny-potentially-breaking-api` 在存在 `potentially-breaking` 项时以 `1` 退出。两个选项各查各的分类；要同时拒绝两类，就两个都写。报告仍会输出到标准输出，便于在 CI 日志里查看原因。

如果要求两份快照完全没有变化，包括新增 API 和文档变化，使用严格 baseline：

```bash
cjdoc check --project "$V2" --api-surface-baseline "$WORK/v1/api-surface/api-surface.json"
```

它把任何非 `unchanged` 条目都当作失败，比只拒绝破坏性变化更严格，因此新增的 `nonEmpty` 和改动过的文档也会让检查退出 `1`。这只是一个 API surface 门槛；文档诊断和覆盖率仍按 `check` 自己的规则单独判定。

## 遇到问题怎么办

- **`diff` 以 `2` 失败**：两份快照的 project、audience 或 cfgProfile 不一致。用相同的 `--audience`、`--cfg` 从两份源码重新生成快照，再比较；不要靠改版本标签绕过输入不匹配。
- **外部参考状态显示“无外部参考”**：检查索引是否缺失、版本字段是否匹配，以及 demo 生成前是否已放入新索引。重新生成 `support-v1`，覆盖两份 demo 的 `docs/support-symbol-index.json`，再重新生成两个版本。
- **点击依赖链接打不开**：按配置的相对路径把完整 `support/html` 复制到每个组合版本根的 `dependencies/support-v1`；复制后不要再运行 `compose`，否则选择器会被注入依赖页面。
- **切换版本后落在首页**：目标版本确实缺少该页面、符号、语言或章节，选择器已按回退规则处理；从该版本首页重新导航即可。
- **`compose` 报输入错误**：确认 `--version` 指向 `html` 目录且其中存在 `index.html`；版本 ID 不能重复，元数据选项引用的 ID 必须已经出现在 `--version` 中。
- **想再加一个版本**：每个 `--version` 应指向一份独立源码生成出来的 `html` 目录。若真要展示第三份快照，必须说明它用的是哪份源码：用同一份 V2 源码换个版本 ID 再组合，只会让选择器多出一个内容与 0.2.0 相同的版本，不会让旧快照变成新源码。

## 下一步

- [从保存的快照重新生成文档](render-snapshots.md)：不重新扫描源码，换一种输出格式。
- [生成并发布文档](generate-and-publish.md)：发布单个站点的完整 HTML 树。
- [排查常见故障](troubleshoot.md)：处理快照不匹配、依赖链接和输出冲突。
- [CLI 参考](../reference/cli.md)：`diff` 与 `versions compose` 的选项、默认值和退出码。
