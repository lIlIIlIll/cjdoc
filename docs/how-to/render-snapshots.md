# 从保存的快照重新生成文档

用 `cjdoc render` 读取一份已保存的 `docs.json`，重新输出 HTML 或 Markdown，不重新扫描仓颉源码。适合把同一次捕获分发给不同读者、给旧站点换输出格式，或在源码已不在手边时再生成一份站点。

## 什么时候用本页

- 已经有一份 `cjdoc.doc-ir/20` 的 `docs.json`，想换输出格式或换输出目录。
- 想把生成和发布分开：先在有源码的机器上捕获，再在别处渲染。
- 只想改站点版本标签或附加报告，不想重新分析源码。

需要修改注释、示例结果或语义信息时，`render` 做不到；回到源码重新 `generate`。

## 前提条件

- 已完成[生成第一个站点](../tutorials/first-site.md)，能在 `docdemo/` 项目根运行 `cjdoc`。
- 快照必须是当前 cjdoc 生成的 `cjdoc.doc-ir/20`。旧版本快照不会自动升级。

## 1. 保存快照

在 `docdemo/` 根目录把文档保存为 JSON：

```bash
cjdoc generate --project . --format json --output target/doc-ir-capture
```

**预期结果**：`target/doc-ir-capture/docs.json` 是这次生成的完整快照，`schemaVersion` 为 `cjdoc.doc-ir/20`。

把它复制到项目之外的新目录，模拟只拿到快照、没有源码的场景：

```bash
mkdir -p "$HOME/.cache/cjdoc/examples"
WORK="$(mktemp -d "$HOME/.cache/cjdoc/examples/replay.XXXXXX")"
cp target/doc-ir-capture/docs.json "$WORK/current.json"
```

`WORK` 只在这里定义一次。后面的 `render` 命令都在这个目录里启动。

## 2. 从快照生成 HTML 和 Markdown

```bash
(
  cd "$WORK"
  cjdoc render --input current.json \
    --format html --format markdown \
    --output rendered
)
```

`render` 不需要 `--project`，也不读取 `cjpm.toml`、项目配置或源码缓存；它只认 `--input` 指向的这份 JSON。

**预期结果**

- 终端打印 `generated rendered`，退出码 `0`。
- `$WORK/rendered/html/index.html`：可以直接用浏览器打开的静态站点。
- `$WORK/rendered/markdown/index.md`：Markdown 版本，以及同目录内的包页、声明页和概念页文件。
- 两个入口显示与 `docdemo` 生成时相同的首页和 `greet` 页面内容。

快照里已经记录源码位置、项目、受众、语言，以及生成时用 `--doc-version` 写入的版本标签；`render` 原样沿用这些信息。它不会重新观察源码、重新执行示例、重新计算依赖和标准库链接，也不会因为当前项目配置变化而改变输出。离线重放同样保留快照里的源码来源状态，不重新打开 Git 或回执。

## 3. 选择格式和输出目录

`--format` 可重复，取值与 `generate` 相同：`json`、`markdown`、`html`、`api-surface`、`coverage`、`symbol-index`。省略时默认只生成 `json`。

```bash
(
  cd "$WORK"
  cjdoc render --input current.json --format html --output site
)
```

**预期结果**：`site/html/index.html` 可打开。

- 省略 `--output` 时写到当前目录下的 `target/doc`；在 `$WORK` 中运行就是 `$WORK/target/doc`，其中的 `docs.json` 是重新序列化的快照。
- 输出目录要由 cjdoc 创建和管理，不要提前手工建一个空目录。手工建好的目录会以退出码 `2` 拒绝，提示 `error: bounded read could not access file: '<目录>/.cjdoc-output.json'`。
- 需要换站点版本标签时加 `--doc-version`（要求同时生成 HTML），它写入元数据，不改变快照内容。
- 需要一次性输出单个 JSON 类格式时用 `--stdout`，它要求恰好一种 `json`、`api-surface`、`coverage` 或 `symbol-index`，且不能与 `--output` 同用。

`render` 不执行项目配置里的覆盖率门槛，也不会因为门槛失败而以 `1` 退出；覆盖率与质量报告根据快照里的声明和诊断重新生成。它也不启动 CHIR worker，不检查示例。

## 失败时怎么办

| 现象 | 原因 | 处理 |
|---|---|---|
| `error: render requires --input` | 没给 `--input` | 加上 `--input <docs.json>` |
| `error: bounded read could not access file: '/…/current.json'` | 路径不存在，或命令不在 `$WORK` 里执行 | 确认已把 `current.json` 复制到当前目录，或给 `--input` 绝对路径 |
| `error: invalid Doc IR at $.schemaVersion: expected 'cjdoc.doc-ir/20'` | 快照来自旧版本 cjdoc | 源码还在时用当前 cjdoc 重新 `generate --format json`；源码已不在时没有受支持的迁移路径 |
| 输出目录被拒绝 | 提前手工建了目录，或登记产物被改过 | 换一个尚不存在的新输出路径；确认可丢弃手工修改后加 `--force-owned` |
| `error: --project is not valid for render` （或其他选项） | 给 `render` 加了项目、依赖、受众、lint、cfg 或缓存类选项 | 去掉这些选项，改用 `generate` |
| `error: --doc-version requires --format html` | 只写了版本标签没生成 HTML | 同时加 `--format html` |
| 页面里缺少某个声明或示例结果 | 快照里本来就没有 | `render` 只展示快照已有内容；补齐后重新 `generate` |

## 下一步

- [比较两个版本的 API 并发布版本站点](compare-and-version.md)：为不同源码分别生成快照并组合。
- [生成并发布文档](generate-and-publish.md)：从源码生成并发布完整 HTML 树。
- [产物与格式参考](../reference/artifacts.md)：各格式的实际路径、Doc IR wire 版本和目录布局。
