# 比较两个版本的 API 并组合多版本站点

为两份源码分别生成 API 快照，读出差异报告，再用 `versions compose` 把它们组合成一个可切换版本、可附差异报告的站点。

## 什么时候用本页

- 发布新版本前想知道相对上一版新增、删除、改动了哪些 API。
- 想让读者在一个站点里切换多个版本，或在 CI 里拒绝破坏性变化。
- 只想重新渲染一份已有快照、不重新扫描源码时用[重渲染快照](render-snapshots.md)，不需要本页。

## 前提条件

- 已按[安装 cjdoc](../getting-started/install.md)安装，当前终端已加载仓颉 SDK 环境。
- 安装时保存的 `CJDOC_SOURCE` 指向 cjdoc 源码：本页只用它复制 `examples/pocketkit/` 下的教学源码。使用自己的两份源码时不需要它。
- Bash 与 `cp`；输出放在磁盘文件系统上（`df -T "$HOME/.cache"` 确认不是 tmpfs）。

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

两个 demo 的清单都用 `path = "../support-v1"` 声明依赖，所以三者必须保持同级，不要改写清单里的相对路径。

## 第一步：生成依赖库文档并放进两份源码

两个 demo 的 `cjdoc.toml` 都通过 `[external-docs.pocket_support]` 读取 `docs/support-symbol-index.json`，链接基址是 `./dependencies/support-v1`，版本是 `support-v1`。先生成依赖文档，再把索引复制进两份 demo：

```bash
cjdoc generate --project "$SUPPORT" --format html --doc-version support-v1 \
  --locale en --no-cache --output "$WORK/support"
cp "$WORK/support/html/symbol-index.json" "$V1/docs/support-symbol-index.json"
cp "$WORK/support/html/symbol-index.json" "$V2/docs/support-symbol-index.json"
```

预期 `$WORK/support/html/` 与两份 `docs/support-symbol-index.json` 都已更新。索引必须来自这份 `support-v1` 源码并带 `support-v1` 版本字段；来源或版本不符时，页面显示外部参考不可用或已过期，而不是可点击链接。依赖文档用 `--locale en` 生成，它的界面语言与消费方互不影响。

## 第二步：为两个版本生成快照

`--doc-version` 只写入站点元数据，不会让同一份源码变成另一个版本：

```bash
cjdoc generate --project "$V1" --format html --format api-surface \
  --doc-version 0.1.0 --no-cache --output "$WORK/v1"
cjdoc generate --project "$V2" --format html --format api-surface \
  --doc-version 0.2.0 --no-cache --output "$WORK/v2"
```

预期每个输出根下有 `html/index.html` 和 `api-surface/api-surface.json`，两条命令都以 `0` 退出。demo 在 `cjdoc.toml` 的 `[coverage]` 里把 `symbols` 与 `parameters` 设为 `80`，`generate` 与 `check` 都会执行该门槛；默认受众 `external` 下两份源码满足它。

两份快照必须用相同的 `--audience` 和 `--cfg` 生成，否则后面的 `diff` 拒绝比较。也不要随手用 `--audience all` 重新生成：私有声明进入分母后覆盖率会下降，可能触发 demo 的 80% 门槛并以 `1` 退出，得到的是另一份不可比的快照。

## 第三步：阅读差异

```bash
cjdoc diff \
  --baseline "$WORK/v1/api-surface/api-surface.json" \
  --current "$WORK/v2/api-surface/api-surface.json" \
  --format text
```

开头列出项目、受众、比较状态和各类差异数量，之后列出变更条目。先找 `breaking`，例如这两份源码里 `TextCatalog.legacyCount` 的移除。再读 `potentially-breaking` 及每条的原因：当类型或返回契约不能可靠判定为等价时，即便新增参数本身是可选的，也要复核该条目。

`demo-v2` 移除了 `TextCatalog.legacyCount`、新增了 `nonEmpty`、给 `add` 增加了可选参数，所以不会得到空差异。`--format` 默认 `text`；要保存完整报告供组合站点使用，改成 `--format json` 并重定向到文件：

```bash
cjdoc diff \
  --baseline "$WORK/v1/api-surface/api-surface.json" \
  --current "$WORK/v2/api-surface/api-surface.json" \
  --format json > "$WORK/v1-to-v2.json"
```

两种调用等价：`cjdoc diff OLD NEW` 或显式写 `--baseline`/`--current`，但不能同时混用位置参数和选项。

`comparison` 为 `resolved` 才表示差异已完整判定；收集不完整或字段无法解析时，报告不会把未知项写成“无变化”。

## 第四步：组合版本站点并补齐依赖页面

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

预期终端输出 `composed 2 documentation versions into <目录>`，`$WORK/site/` 下有 `index.html`、`latest/`、`0.1.0/`、`0.2.0/`、`versions.json` 与版本选择脚本。`versions.json` 里两个版本的 `channel` 分别是 `stable` 与 `preview`，`latest` 是 `0.2.0`。

几个容易出错的地方：

- `--version ID=PATH` 指向生成输出里的 `html` 目录，不是整个输出根。省略 `--label` 和 `--base-path` 时两者都等于版本 ID，所以版本页面位于 `site/0.1.0/`、`site/0.2.0/`。
- 省略 `--latest` 时取**第一个** `--version` 的 ID（`latestPolicy` 为 `first-listed`），不是按版本号排序。
- `--channel` 与默认的 `status=published` 只是展示文字，不验证发布流程。
- 依赖库的完整 HTML 树要在 `compose` **之后**复制，才会保持为独立依赖文档。先复制再组合，它们会被当成版本输入并注入版本选择器。
- 使用 `--all-languages` 时，输入的 `html/<语言>/` 会组合成 `<版本根>/<语言>/`，依赖页面要复制到 `<版本根>/<语言>/dependencies/support-v1`。

## 第五步：打开并检查站点

```bash
xdg-open "$WORK/site/index.html"
```

macOS 用 `open "$WORK/site/index.html"`，Windows 在 Git Bash 中用 `start "" "$WORK/site/index.html"`。

预期：首页列出 `0.1.0`（stable）与 `0.2.0`（preview）并标出最新版本；从 `site/0.2.0/index.html` 切到 `0.1.0` 时，两份源码都有的符号落到 `0.1.0` 的对应页面；`site/0.2.0/` 下的符号页面里“另请参阅”链接打开 `site/0.2.0/dependencies/support-v1/` 下的依赖页面。

回退行为属于选择器的正常结果，不是链接损坏：只在 0.2.0 存在的 `nonEmpty` 在目标版本会预先标注“此版本没有该符号”并打开仍存在的所属页面；所属页面也不存在时回到版本首页；章节缺失落到同一页页首；多语言站点缺少当前语言时退回该版本默认语言。

`versions.json` 是组合清单，不代替目录里的实际页面：要确认某符号是否存在于某版本，直接打开该版本页面或其符号索引。发布时上传整个 `$WORK/site/`，版本选择器和 `latest/` 都依赖同级目录。

## 在 CI 里拒绝变化

`diff` 默认只报告，不因差异失败。加拒绝选项后，报告仍输出到标准输出，只改变退出码：

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

存在 `breaking` 时第一条退出 `1`，存在 `potentially-breaking` 时第二条退出 `1`。两个选项各查各的分类，不要用其中一个代替另一个。两类都要拒绝时就都写，并且仍要查看 `comparison` 是否为 `resolved`。

要求两份快照完全一致（连新增 API 和文档改动也算失败）时，用 `check` 的严格 baseline：

```bash
cjdoc check --project "$V2" --api-surface-baseline "$WORK/v1/api-surface/api-surface.json"
```

预期以 `1` 退出，并逐条列出如 `error: API surface additive at function ...::nonEmpty#g0()` 的差异。这只是 API surface 门槛；文档诊断与覆盖率仍按 `check` 自己的规则单独判定。

## 失败时怎么办

| 现象 | 原因 | 处理 |
|---|---|---|
| `error: API diff inputs must match project, audience, and cfgProfile`，退出码 `2` | 两份快照的 project、受众或 cfg 不同 | 用相同的 `--audience`、`--cfg` 从两份源码重新生成快照再比较 |
| `unsupported API surface schema 'cjdoc.doc-ir/19'`，退出码 `2` | 把 Doc IR（`docs.json`）当成 API 快照传给了 `diff` | 改用 `api-surface/api-surface.json` |
| 外部参考显示“无外部参考” | 索引缺失、版本字段不符，或索引在生成前没有放进 demo | 重新生成 `support-v1`，覆盖两份 demo 的 `docs/support-symbol-index.json`，再生成两个版本 |
| 依赖链接打不开 | 依赖 HTML 树没复制，或复制后又跑了 `compose` | 按配置的相对路径把完整 `support/html` 复制到版本根，复制后不要再 `compose` |
| 切换版本后停在首页 | 目标版本缺少该页面、符号、语言或章节 | 正常回退；从该版本首页重新导航 |
| `error: duplicate version id '0.1.0'`，退出码 `2` | 同一 ID 出现两次 | 每个版本用唯一 ID |
| `error: version source has no index.html '<路径>'`，退出码 `2` | `--version` 指向了输出根而不是 `html/` | 改为 `.../v1/html` |
| `error: --latest names an unknown version '9.9.9'` 或 `error: version metadata assignment names unknown version '9.9.9'` | 元数据选项引用了未出现的 ID | 先为该 ID 添加 `--version` |
| `error: global symbols coverage … is below …`，退出码 `1` | 用了 `--audience all` 等改变了覆盖率分母 | 按默认受众重新生成快照，不要放宽配置里的门槛 |
| 想再加一个版本 | `--version` 必须是独立源码生成出的 `html` 目录 | 用同一份源码换个 ID 只会得到内容相同的版本，不会让旧快照变成新源码 |

## 下一步

- [从保存的快照重新生成文档](render-snapshots.md)：不重新扫描源码，换一种输出格式。
- [生成并发布文档](generate-and-publish.md)：发布单个站点的完整 HTML 树。
- [CLI 参考](../reference/cli.md)：`diff` 与 `versions compose` 的选项、默认值和退出码。
