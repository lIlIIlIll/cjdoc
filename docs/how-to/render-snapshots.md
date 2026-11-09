# 从保存的快照重新生成文档

`cjdoc render` 读取一份已经保存的 `docs.json`，重新输出 HTML、Markdown 等格式，不重新扫描仓颉源码。源码已经不在手边、或者只想换一种输出格式时用它；快照内容保持不变，只是重新排版。

## 前提

- 已完成[首次生成教程](../tutorials/first-site.md)，并能在 `docdemo/` 项目根运行 `cjdoc`。
- 快照必须是当前版本 cjdoc 生成的 `cjdoc.doc-ir/18`。旧版本快照不会自动升级。

## 保存快照并复制到独立目录

先在 `docdemo/` 根目录把文档保存为 JSON：

```bash
cjdoc generate --project . --format json --output target/doc-ir-capture
```

`target/doc-ir-capture/docs.json` 是这次生成的完整快照。下面把它复制到项目之外的一个新目录，模拟只拿到快照、没有源码的场景：

```bash
mkdir -p "$HOME/.cache/cjdoc/examples"
WORK="$(mktemp -d "$HOME/.cache/cjdoc/examples/replay.XXXXXX")"
cp target/doc-ir-capture/docs.json "$WORK/current.json"
```

`WORK` 只在这里定义一次。后面的 `render` 命令都在这个目录里启动，不再读取项目目录或项目内的 `target/`。当前 shell 本身留在 `docdemo/`，因为 `render` 在子 shell 中执行。

## 从快照生成 HTML 和 Markdown

```bash
(
  cd "$WORK"
  cjdoc render --input current.json \
    --format html --format markdown \
    --output rendered
)
```

`render` 不需要 `--project`，也不读取 `cjpm.toml`、项目配置或源码缓存；它只认 `--input` 指向的这份 JSON。产物在 `$WORK/rendered/`：

- `$WORK/rendered/html/index.html`：可以直接用浏览器打开的静态站点。
- `$WORK/rendered/markdown/index.md`：Markdown 版本，及其目录内的包页、声明页和概念页文件。

打开这两个文件应看到与 `docdemo` 生成时相同的项目首页和 `greet` 页面内容。快照里已经记录了源码位置、项目、受众、语言，以及生成时用 `--doc-version` 写入的版本标签；`render` 原样沿用这些信息：它不会重新观察源码、重新执行示例、重新计算依赖和标准库链接，也不会因为当前项目配置变化而改变输出。

## 选择格式和输出目录

`--format` 可重复，支持的格式与 `generate` 相同：`json`、`markdown`、`html`、`api-surface`、`coverage`、`symbol-index`。省略时默认只生成 `json`。`--output` 省略时写到当前目录下的 `target/doc`；如果在 `$WORK` 里运行，就写 `$WORK/target/doc`。输出目录要由 cjdoc 创建和管理，不要提前手工建一个空目录。

```bash
(
  cd "$WORK"
  cjdoc render --input current.json --format html --output site
)
```

需要换一个站点版本标签时可以加 `--doc-version`，同样是写入元数据，不改变快照内容。`render` 不执行项目配置里的覆盖率门槛，也不会因为门槛失败而以 `1` 退出；覆盖率与质量报告根据快照里的声明和诊断重新生成，不重新扫描源码。

## 遇到问题怎么办

- **报 Doc IR 版本或 schema 错误**：快照来自旧版本的 cjdoc。原始项目源码还在时，用当前 cjdoc 重新执行 `cjdoc generate --project . --format json` 得到新快照；源码已经不在时，没有受支持的旧快照迁移路径。
- **`--input` 文件找不到**：确认命令是在 `$WORK` 里执行的，且 `current.json` 已复制进去；也可以用绝对路径传给 `--input`。
- **输出目录被拒绝**：目录已存在且不是 cjdoc 生成的，或其中文件被手工改过。换一个新的输出目录；确认可以覆盖时再加 `--force-owned`。
- **页面里缺少某个声明或示例结果**：`render` 只展示快照里已有的内容。生成快照时没有包含的声明、没有运行过的示例，重新渲染也不会出现。

## 下一步

- [比较两个版本的 API 并发布版本站点](compare-and-version.md)：为不同源码分别生成快照并组合。
- [生成并发布文档](generate-and-publish.md)：从源码生成并发布完整 HTML 树。
- [产物与格式参考](../reference/artifacts.md)：各格式的实际路径、Doc IR wire 版本和目录布局。
