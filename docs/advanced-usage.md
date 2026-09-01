# 高级用法

这篇说明适合已经成功生成过一次文档、现在需要处理多种输出、workspace、依赖或 CI 的工具使用者。每个场景都可以单独使用。

先进入项目根目录，并确认 `cjdoc` 已在 `PATH` 中：

```bash
cd <你的项目目录>
cjdoc --version
```

## 一次生成多个格式

如果要同时发布 HTML、Markdown，并保留机器可读的结果，可以一次指定多个 `--format`：

```bash
cjdoc generate --project . \
  --format json \
  --format markdown \
  --format html \
  --format api-surface \
  --format coverage
```

默认输出目录是 `target/doc`，主要文件如下：

```text
target/doc/
├── docs.json
├── markdown/index.md
├── html/index.html
├── html/search-index.js
├── html/search.js
├── html/style.css
├── api-surface/api-surface.json
└── coverage/coverage.json
```

HTML 和 Markdown 使用同一份生成结果。HTML 是静态站点，可以直接打开 `html/index.html`；`search-index.js` 让浏览器在 `file://` 下也能使用搜索。

## 管理输出目录

需要把文档放到其他位置时，使用 `--output`：

```bash
cjdoc generate --project . \
  --format html \
  --output public/api-docs
```

结果位于 `public/api-docs/html/index.html`。

首次使用某个输出目录时，不要预先创建该目录。cjdoc 会验证输出目录的所有权，并拒绝覆盖无法确认归属的内容。再次生成时，可以继续使用此前由 cjdoc 管理的目录。

`--force-owned` 只用于已有 cjdoc ownership manifest 的目录，或你明确要采用其中已登记内容时：

```bash
cjdoc generate --project . \
  --format html \
  --output public/api-docs \
  --force-owned
```

它不能把一个从未由 cjdoc 管理过的空目录直接变成输出根目录；这种情况请换用一个不存在的新目录。它也不会递归删除目录中的无关文件。输出目录和 source cache 也不能互相嵌套或重叠。

## 处理 workspace 和依赖

默认只扫描项目本身。项目的 `cjpm.toml` 声明了 path dependency 时，加入 `--include-path-dependencies`：

```bash
cjdoc generate --project . \
  --format html \
  --include-path-dependencies
```

如果依赖源码不在可自动发现的位置，可以显式提供只读源码目录。目录中应包含自己的 `cjpm.toml`：

```bash
cjdoc generate --project . \
  --format html \
  --dependency-source shared=../shared
```

要扫描 cjpm cache 中能够发现的依赖，使用：

```bash
cjdoc generate --project . \
  --format html \
  --include-cached-dependencies \
  --cjpm-cache /path/to/cjpm-cache
```

`--cjpm-cache` 必须和 `--include-cached-dependencies` 一起使用。cjdoc 不会为了生成文档下载网络依赖；缺少的依赖会产生诊断，已找到的源码仍可继续处理。

## 控制可见范围、语言和条件编译

默认生成 external 文档，只展示 `public` 和 `protected` 声明。需要在团队内部查看更多声明时，选择 audience：

| audience | 显示内容 |
|---|---|
| `external` | `public` 和 `protected`，默认值 |
| `package` | 除 `private` 之外的声明 |
| `all` | 所有声明 |

例如，生成包含内部声明的 HTML：

```bash
cjdoc generate --project . --format html --audience all
```

HTML 和 Markdown 默认使用中文结构标题。生成英文站点：

```bash
cjdoc generate --project . --format html --locale en
```

如果需要兼容旧式单页 Markdown，必须同时使用英文 locale：

```bash
cjdoc generate --project . \
  --format markdown \
  --locale en \
  --markdown-layout single
```

条件编译不会自动读取 compiler target profile。把需要的条件显式传给 cjdoc，并可重复指定：

```bash
cjdoc generate --project . \
  --format html \
  --cfg FEATURE=enabled \
  --cfg TARGET=server
```

## 控制缓存和并行度

默认 source cache 位于 `target/cjdoc/cache/source-v8`。正常重复生成时不需要管理它。要排查缓存影响或强制完整读取源码：

```bash
cjdoc generate --project . --format html --no-cache
```

也可以指定项目内的其他 cache 目录：

```bash
cjdoc generate --project . \
  --format html \
  --cache-dir .cache/cjdoc
```

cache 目录必须与 `target/doc` 或 `--output` 指定的目录分开。源码较多时可以增加 source worker 数量：

```bash
cjdoc generate --project . --format html --jobs 4
```

输出顺序仍由 cjdoc 固定，增加 `--jobs` 不应改变生成结果的内容顺序。

## 在 CI 中检查 API 和文档覆盖率

先在审查过的源码版本上生成 API snapshot，并把它作为项目文件保存：

```bash
cjdoc generate --project . --format api-surface --stdout > api-surface.json
```

之后在 CI 中检查 API 是否发生变化，并设置覆盖率门槛：

```bash
cjdoc check --project . \
  --api-surface-baseline api-surface.json \
  --min-symbol-coverage 80 \
  --min-parameter-coverage 90
```

`check` 默认使用 `external` audience。生成 snapshot 时也使用默认 audience，避免把内部声明混入对外 API 基线。snapshot 不一致，或覆盖率低于显式门槛时，命令返回非零退出码。

只想读取覆盖率 JSON 时：

```bash
cjdoc generate --project . --format coverage --stdout > coverage.json
```

在 GitHub Actions 或其他 CI 中，直接运行同一条命令即可。CI runner 需要先安装 cjdoc，并把它加入 `PATH`；不需要把仓库验收脚本当成工具用户的前置步骤。

GitHub Actions 的最小检查步骤：

```yaml
- name: Check Cangjie documentation
  run: |
    cjdoc check --project . \
      --api-surface-baseline api-surface.json \
      --min-symbol-coverage 80 \
      --min-parameter-coverage 90
```

## 从已有 JSON 重新渲染

如果已有一份 `docs.json`，可以只更换输出格式，不重新扫描源码：

```bash
cjdoc render \
  --input target/doc/docs.json \
  --format html \
  --format markdown \
  --output target/rendered-doc
```

`render` 会先验证输入的 schema 和引用关系。它不读取项目源码，因此源码注释或声明有变化时，应重新运行 `generate`。

v6/v7 只能作为严格的只读输入迁移到当前 v8 输出；cjdoc 不会重新生成旧版本格式。

## 查看内嵌 schema

需要让下游工具了解当前 binary 支持的 schema 时，先查看名称：

```bash
cjdoc schema list
```

输出某个 schema，例如当前 Doc IR：

```bash
cjdoc schema doc-ir > doc-ir.schema.json
```

## 从源码构建（维护者用）

普通工具用户应优先下载 release binary。只有在发布页没有对应资产，或你正在修改 cjdoc 时，才从源码构建。

源码构建需要可用的 `cjc`、`cjpm`，并能访问 `cjpm.lock` 固定的 Git 依赖，或已经准备好对应的 cjpm cache。在仓库根目录运行：

```bash
cjpm build
./cjdoc --version
```

仓库根目录的 `./cjdoc` launcher 在 binary 不存在时也会尝试构建。维护者验收使用 `scripts/check.sh`；发布验收和证据分层见 [`docs/release-process.md`](release-process.md)。

## 能力边界

- 当前生成的 Doc IR 版本是 `cjdoc.doc-ir/8`。
- CHIR 尚未接入，部分类型和语义关系会标为 `partial` 或 `unavailable`。
- 宏调用和没有显式 `--cfg` 输入的条件编译不会被强行展开。
- 单次扫描、单个源码文件和辅助输入都有大小及数量限制，超限时会保留 partial 结果并输出诊断。
- POSIX 平台可以在满足安全条件时嵌入本地图片；当前 Windows 不嵌入本地 asset，并会产生 `CJDOC4026` 和 partial 状态。

## CLI 选项速查

| 选项 | 命令 | 默认值 | 用途 |
|---|---|---|---|
| `--project <dir>` | `generate`, `check` | `.` | 项目或 workspace 根目录 |
| `--input <file>` | `render` | 无 | 已有的 Doc IR JSON |
| `--format <name>` | `generate`, `render` | `json` | `json`、`markdown`、`html`、`api-surface` 或 `coverage`，可重复 |
| `--output <dir>` | `generate`, `render` | `target/doc` | 输出目录 |
| `--stdout` | `generate`, `render` | 关闭 | 把单个 JSON 产物写到 stdout |
| `--audience <name>` | `generate` | `external` | `external`、`package` 或 `all` |
| `--lint-profile <name>` | `generate`, `check` | `standard` | `off`、`standard` 或 `strict` |
| `--deny-warnings` | `check` | 关闭 | 把 warning 也作为失败 |
| `--jobs <1..64>` | `generate`, `check` | `1` | source worker 数量 |
| `--cfg NAME=VALUE` | `generate`, `check` | 无 | 条件编译输入，可重复 |
| `--include-path-dependencies` | `generate`, `check` | 关闭 | 扫描 manifest 中的 path dependency |
| `--include-cached-dependencies` | `generate`, `check` | 关闭 | 扫描可发现的 cjpm cache dependency |
| `--dependency-source NAME=PATH` | `generate`, `check` | 无 | 显式提供只读 dependency source，可重复 |
| `--cjpm-cache <dir>` | `generate`, `check` | 默认 cache | 指定 cjpm cache，需同时启用 cached dependencies |
| `--cache-dir <dir>` | `generate`, `check` | `target/cjdoc/cache/source-v8` | 指定 source cache |
| `--no-cache` | `generate`, `check` | 关闭 | 禁用 source cache |
| `--locale <name>` | `generate`, `render` | `zh-CN` | HTML/Markdown 结构语言 |
| `--markdown-layout <name>` | `generate`, `render` | `site` | `site` 或英文 `single` |
| `--api-surface-baseline <file>` | `generate`, `check` | 无 | 对账 API snapshot |
| `--min-symbol-coverage <0..100>` | `generate`, `check` | 无 | 声明覆盖率门槛 |
| `--min-parameter-coverage <0..100>` | `generate`, `check` | 无 | 参数覆盖率门槛 |
| `--force-owned` | `generate`, `render` | 关闭 | 显式采用已有输出目录内容 |
