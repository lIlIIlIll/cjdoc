# 高级用法

这篇面向已经能用 cjdoc 生成一次文档、现在要处理多格式、依赖、多版本站点或自动化检查的使用者。基础命令见 [使用手册](usage.md)，配置文件见 [配置参考](configuration.md)，概念页写法见 [概念页与指南](guides.md)。命令都在项目根目录执行，默认输出到项目下的 `target/doc`。

## 一次生成多个格式

`--format` 可以重复，一次扫描同时产出多种结果：

```bash
cjdoc generate --project . \
  --format html \
  --format markdown \
  --format json \
  --format api-surface \
  --format coverage \
  --format symbol-index
```

不写 `--format` 时只生成 `json`。默认输出目录 `target/doc` 里的主要产物：

```text
target/doc/
├── docs.json                         # --format json
├── html/
│   ├── index.html                    # --format html
│   ├── search-index.json
│   ├── search-index.js
│   ├── symbol-index.json
│   ├── navigation-index.json
│   ├── llms.txt
│   ├── validation.html
│   └── style.css 等静态资源
├── markdown/index.md                 # --format markdown
├── api-surface/api-surface.json      # --format api-surface
├── coverage/coverage.json            # --format coverage
└── symbol-index/symbol-index.json    # --format symbol-index
```

- 多个格式共用同一次源码扫描，不会重复解析项目。
- HTML 是静态站点，直接用浏览器打开 `html/index.html` 即可，搜索在 `file://` 下也能工作，不需要起服务器。
- 需要把单个 JSON 产物写到标准输出时用 `--stdout`，它只接受恰好一个 JSON 类格式（`json`、`api-surface`、`coverage`、`symbol-index`），不能和 `--output` 同时使用。

## 处理 workspace 与依赖

默认扫描 `--project` 指向的项目：workspace 成员会自动包含，依赖默认不包含。下面几种情况需要额外处理：

| 场景 | 做法 |
|---|---|
| `cjpm.toml` 声明了 workspace members | 不用加参数，所有成员模块会自动一起扫描 |
| 依赖以 path dependency 写在 manifest 里 | 加 `--include-path-dependencies` |
| 依赖源码不在能自动发现的位置 | 用 `--dependency-source NAME=PATH` 显式指定，可重复 |
| 依赖源码已在 cjpm 缓存里 | 加 `--include-cached-dependencies`，需要时用 `--cjpm-cache` 指定缓存根 |

```bash
cjdoc generate --project . --format html --include-path-dependencies
```

```bash
cjdoc generate --project . \
  --format html \
  --dependency-source shared=../shared
```

`--dependency-source` 的 `PATH` 相对当前工作目录；目录里要有自己的 `cjpm.toml`。`--include-cached-dependencies` 会按 `cjpm.lock` 在 cjpm 缓存中查找依赖源码，缓存根默认是 `$HOME/.cjpm`，可用 `--cjpm-cache` 改；`--cjpm-cache` 必须和这个开关一起用。

cjdoc 不会为了生成文档下载任何依赖或文档：找不到的依赖只会被跳过并输出 warning（例如 `CJDOC1021`），其余源码照常生成。要看到依赖的文档，请先在本地用 `cjpm` 正常解析、准备好依赖源码，再运行 cjdoc。

如果依赖来自 Git 或二进制缓存、需要把文档与本次构建实际使用的输入关联起来，这类更严格的用法不在本文范围，见本文末尾的“维护者文档”。

## 控制可见范围、语言和条件编译

### 可见范围

| `--audience` | 显示的声明 |
|---|---|
| `external`（默认） | `public` 和 `protected` |
| `package` | 除 `private` 外 |
| `all` | 全部 |

```bash
cjdoc generate --project . --format html --audience all
```

audience 同时影响 HTML、Markdown、JSON、搜索、agent 产物和覆盖率统计，`check` 也按选定 audience 检查。

### 界面语言

`--locale zh-CN`（默认）或 `--locale en` 控制 HTML/Markdown 的结构标签语言，不会翻译作者写的正文。多语言站点用 `[i18n]` 配置和 `--all-languages` 生成各语言的独立目录，见 [多语言文档](i18n.md)。

### 条件编译

cjdoc 不会自动读取 compiler 的 target profile，也不会猜测条件值；把需要的条件显式传进去，可重复：

```bash
cjdoc generate --project . \
  --format html \
  --cfg feature=enabled \
  --cfg TARGET=server
```

同名条件给不同值会报错。源码里 `@When[...]` 等条件的求值结果决定声明是否进入文档；表达式无法解析时，相关声明会被跳过并输出 warning（`CJDOC1019`）。

## 管理输出目录

`--output` 改变生成位置：

```bash
cjdoc generate --project . \
  --format html \
  --output public/api-docs
```

结果在 `public/api-docs/html/index.html`。

输出目录由 cjdoc 通过一份所有权清单管理，规则如下：

- 首次使用某个目录时不要预先创建，让 cjdoc 自己创建。目录已存在但没有所有权清单时，命令会报错。
- 再次生成时可以继续使用同一个目录。cjdoc 只替换自己登记过的文件；上次生成、这次不再产出的文件会被清理，目录里不属于 cjdoc 的文件不会被删除。
- 如果 cjdoc 登记过的文件被手工改过，或新产物会覆盖目录里的未知内容，命令会拒绝写入。
- `--force-owned` 用于你已经确认要采用该目录内容的场景：替换被修改的已登记文件、接管冲突的产物目录。它不能把一个从未由 cjdoc 管理过的目录直接变成输出根目录，也不会递归删除无关文件。

```bash
cjdoc generate --project . \
  --format html \
  --output public/api-docs \
  --force-owned
```

输出目录和源码缓存目录不能互相嵌套或重叠。生成过程中不要手工修改输出目录里的文件；同一输出目录上的并发命令会被锁拦下，不会互相写坏产物。

## 调整缓存与并行度

源码缓存默认在 `<项目>/target/cjdoc/cache/source-v11`，重复生成会自动复用，通常不需要管理。缓存以源码内容、路径和工具链信息为键，升级 SDK 后旧条目不会命中，可以直接删除缓存目录重新开始。

```bash
cjdoc generate --project . --format html --cache-dir .cache/cjdoc
cjdoc generate --project . --format html --no-cache
```

- `--cache-dir <目录>`：换一个缓存位置，必须和输出目录分开。
- `--no-cache`：本次不使用缓存，用于排查“改了源码但页面没变”一类问题。

源码较多时可以提高并行解析数，范围 1 到 64，默认 1：

```bash
cjdoc generate --project . --format html --jobs 4
```

提高 `--jobs` 只影响扫描源码的并行度，不改变产物内容和输出顺序；内存或磁盘紧张时把值调小。`check` 也会使用缓存，`render` 不扫描源码、不使用源码缓存。

## 添加 GitHub 源码链接

想让 HTML 的声明页链接到 GitHub 上的源码位置，生成时提供仓库地址和版本：

```bash
cjdoc generate --project . --format html \
  --repository-url https://github.com/acme/pocketkit \
  --repository-revision v1.2.0
```

| 选项 | 说明 |
|---|---|
| `--repository-url` | 仓库根的 HTTPS 地址，形态必须是 `https://github.com/<owner>/<repo>` |
| `--repository-revision` | 生成链接使用的 tag、分支或 commit，不能含空白字符；必须和 URL 成对出现 |
| `--repository-root` | 可选，仓库根目录；不写时取 `--project` 的目录 |

生成的链接形如 `https://github.com/acme/pocketkit/blob/v1.2.0/src/api.cj#L12-L20`，显示在 HTML 的声明和成员源码位置旁。以下情况不会生成链接，而不是猜一个地址：

- 仓库地址不是 canonical 的 `https://github.com/<owner>/<repo>`。
- 模块的源码不在仓库根目录内，例如仓库外的 path 依赖。
- 源码文件缺少可靠的实际路径映射，或路径越过符号链接、仓库边界。

这组选项只用于 `generate`，`serve` 预览也接受；`render` 不接受，它只使用 `docs.json` 里已经写好的信息。

## 链接标准库 API 文档

HTML 和 Markdown 里出现能唯一对应到预置文档目录的标准库类型时，cjdoc 会自动加上官方文档链接，例如 `std.collection.ArrayList`。本地声明和显式声明的外部文档优先；名称有歧义、类型未收录或缺少可靠匹配时不加链接。

成员的折叠标题、展开后的参数和返回类型都保留类型链接；例如 `add(value: String)` 与 `addAll(entries: Array<String>)` 中的 `String`、`Array` 可分别打开对应 API。点击类型链接执行导航，点击成员名称或用键盘激活标题控制展开/收起。

`import std.collection.*` 这类已收录标准库包的通配导入只生成候选名称，不证明该包声明了同名类型。目录中只有一个文档目标时，未命中的通配候选不会阻止 `std.core.String`、`std.core.Array` 等后备链接；显式未知导入、未知或非标准库通配导入、条件导入及多个不同目标仍按歧义保守处理。

默认目标是 STS 1.2.0。如果构建信息里能唯一确定项目使用的 std 版本，cjdoc 会优先用那个版本；也可以显式指定：

```bash
cjdoc generate --project . \
  --format html \
  --stdlib-doc-version 1.1.0-beta.25
```

内置文档根的版本有 `1.0.5`、`1.1.0`、`1.1.0-beta.25`、`1.1.3` 和 `1.2.0`。其他版本需要同时给出以 `/libs/std` 结尾的 HTTPS 文档根：

```bash
cjdoc generate --project . \
  --format html \
  --stdlib-doc-version 1.1.4 \
  --stdlib-doc-base-url https://cj-docs.gitcode.com/zh/1.1.4/libs/std
```

约束：

- `--stdlib-doc-version` 必须以字母或数字开头，只包含字母、数字和 `.`、`-`、`+`、`_`，不能包含 `..`。
- `--stdlib-doc-base-url` 必须是 HTTPS、以 `/libs/std` 结尾，不能带 query 或 fragment。
- 这两个选项只用于 `generate`；`render` 保留生成时已经写入的链接，不重新计算。
- 选版本只是选择链接目标，不证明项目使用的标准库 API 与目标文档完全一致。1.2.0 和 1.1.0-beta.25 的页面与锚点经过校验，其他 1.1 系列版本是尽力匹配，未知版本不会猜测主机。

`--doc-version` 控制的是站点发布的文档版本（显示在页面上、写入 `html/version.json`），和这里的标准库文档版本是两个不同的选项。

## 组合多版本文档站

先为每个版本生成带版本标签的 HTML 站点，再把它们组合成一个带版本切换的站点：

```bash
cjdoc generate --project . --format html --doc-version 1.2.0 --output target/site-1.2
cjdoc generate --project . --format html --doc-version 1.3.0 --output target/site-1.3

cjdoc versions compose \
  --version 1.2.0=target/site-1.2/html \
  --version 1.3.0=target/site-1.3/html \
  --channel 1.2.0=stable \
  --channel 1.3.0=preview \
  --latest 1.3.0 \
  --output public/docs
```

`--version ID=PATH` 里的 `PATH` 是单个版本的站点目录，指向生成输出里的 `html/` 子目录（多语言站点见下文）。这个目录根下通常要有 `index.html`；配套的 `symbol-index.json` 用于跨版本跳转，`--format html` 会自动生成它。

| 选项 | 说明 |
|---|---|
| `--version ID=PATH` | 必填，可重复；`ID` 是版本标识，`PATH` 是该版本站点目录 |
| `--label ID=TEXT` | 版本显示名，默认同 `ID` |
| `--base-path ID=PATH` | 该版本在组合站点里的路径前缀，默认同 `ID`；不能是 `latest`，不能互相重叠 |
| `--channel ID=TEXT` | 渠道标记，默认 `unspecified`，显示在版本选择页 |
| `--status ID=TEXT` | 状态标记，默认 `published`，写入 `versions.json` |
| `--release ID=TEXT` | 版本发布信息，按纯文本显示在版本卡片上 |
| `--diff ID=FILE` | 关联该版本的 API diff 报告，见下文 |
| `--latest ID` | 最新版本，默认是第一个 `--version` |
| `--output <目录>` | 必填，组合结果输出目录 |
| `--force-owned` | 接管已有输出目录 |

组合后的输出目录包含：

```text
public/docs/
├── versions.json          # 版本清单：ID、路径、渠道、状态、latest
├── index.html             # 根选择页
├── latest/index.html      # 跳转到最新版本
├── version-navigation.js
└── <base-path>/...        # 每个版本的完整站点副本
```

注意事项：

- 每个版本页顶部会注入版本选择器：API 声明按稳定符号标识跨版本跳转，概念页按相同路由匹配；目标版本没有对应声明或页面时，选择器会标注“此版本没有该符号”或回退到版本首页。渠道和状态只是原样记录，cjdoc 不做发布策略判断。
- 组合命令只复制文件并注入版本选择器（以及 API diff 入口），不会重新生成或改写文档内容；不同版本可以是不同时间生成的，但站点结构要一致。
- `ID` 不能包含 `/`、`\`、`:`，不能是 `.` 或 `..`。版本源目录不能与输出目录重叠。
- 先生成 `cjdoc diff --format json` 的报告，再用 `--diff ID=FILE` 绑定到某个版本。报告会被复制为该版本的 `api-diff.json`，选择器和验证页会给出入口。
- 多语言站点：为每个版本用 `--all-languages --format html` 生成，然后把该版本的整个输出目录（含 `site-manifest.json`）作为 `--version` 的 `PATH`，而不是 `html/` 子目录。

## 生成 agent 可读产物

生成 HTML 时，cjdoc 同时写出供脚本或 AI 代理读取的产物：

| 文件 | 内容 |
|---|---|
| `html/navigation-index.json` | 全部页面的目录（含 API 声明页）：页面类别、标题、相对链接、稳定符号 ID、所属包/模块、语义状态 |
| `html/llms.txt` | 有大小上限的纯文本摘要：入口链接、概念页清单、包清单 |
| `html/llms-full.txt` | 只在加 `--agent-full` 时生成：概念页正文、包清单、公开符号的签名和文档摘要 |

```bash
cjdoc generate --project . --format html --agent-full
```

- `--agent-full` 用于 `generate`、`render` 和 `serve`；在 `generate`/`render` 里要求同时生成 HTML 格式。
- 这些文件使用相对链接、内容确定，可以直接通过 `file://` 消费，不需要解析 HTML。
- 只包含当前 audience 可见的声明；private 或被过滤的声明不会出现。文档不足以确定的内容保持 unavailable/partial，不会升级成确定结果。
- `llms.txt` 里列出的概念页是 `kind = "concept"` 的页面（最多 512 条），包清单来自自动生成的包页。
- 多语言站点使用 `--all-languages` 时，每个语言目录下各有一份对应的 agent 产物。
- 需要给下游工具一份字段说明时，可用 `cjdoc schema navigation-index` 导出；`cjdoc schema list` 列出所有可用名称。

## 从已有 docs.json 重新渲染

如果已经生成过 `docs.json`，可以只更换输出格式，不重新扫描源码：

```bash
cjdoc render \
  --input target/doc/docs.json \
  --format html \
  --format markdown \
  --output target/rendered-doc
```

`--input` 必填，文件必须是当前版本 cjdoc 生成的 `docs.json`（即 `--format json` 的产物），旧格式会被拒绝。`render` 默认输出到当前目录下的 `target/doc`，支持 `--stdout`、`--force-owned`、`--locale`、`--all-languages`、`--doc-version` 和 `--agent-full`（后两者要求 `--format html`）。

它不读取项目源码、`cjdoc.toml`、依赖或网络，页面里的链接、绑定和版本信息都来自 JSON。适合离线重放、换格式发布，或把一次生成的结果分发给多个下游。源码或注释有变化时应重新运行 `generate`，而不是重渲染旧 JSON。

## 在 CI 中检查 API 与文档覆盖率

`check` 只做检查、不写站点产物，适合放在 CI 里做门禁。步骤如下。

先在主分支上生成一份审查过的 API 快照，提交到仓库：

```bash
cjdoc generate --project . --format api-surface --stdout > docs/api-surface.json
```

之后在 CI 里生成当前快照、检查文档、拒绝破坏性 API 变化：

```yaml
name: docs
on:
  pull_request:
jobs:
  docs:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Generate the current API snapshot
        run: cjdoc generate --project . --format api-surface --stdout > api-surface.json
      - name: Check docs, examples, and coverage
        run: |
          cjdoc check --project . \
            --check-examples \
            --api-surface-baseline docs/api-surface.json \
            --min-symbol-coverage 80 \
            --min-parameter-coverage 90
      - name: Deny breaking API changes
        run: |
          cjdoc diff --baseline docs/api-surface.json \
            --current api-surface.json \
            --format text \
            --deny-breaking-api
```

前置条件：CI runner 上已经安装仓颉 SDK，并把 `cjdoc` 放进 `PATH`（安装见 [README](../README.md)）；`--check-examples` 还要求 `cjc` 可用。

- `--api-surface-baseline` 要求当前公开 API 与快照完全一致；有变化就失败。基线有意更新时，重新生成 `docs/api-surface.json` 并提交。生成快照和运行检查要使用同一个 audience（默认 `external`）。
- `--min-symbol-coverage`、`--min-parameter-coverage` 是一次性门槛；长期门槛写在 `cjdoc.toml` 的 `[coverage]` 里，`generate` 和 `check` 都会执行（见 [配置参考](configuration.md)）。
- `--check-examples` 会编译示例，带 `{run}` 的示例还会实际运行；示例指令的写法见 [使用手册](usage.md)。
- `--deny-warnings` 可把 warning 也视为失败。`check` 不接受 `--format`、`--output`、`--stdout`、`--locale` 和 `--force-owned`。
- `diff` 只比较两份快照，不扫描项目。默认退出码 `0`；`--deny-breaking-api` 或 `--deny-potentially-breaking-api` 命中对应分类时返回 `1`；参数或输入错误返回 `2`。加 `--format json` 可得到机器可读报告。

`generate` 和 `check` 的退出码：`0` 表示通过，`1` 表示有 error 诊断或门槛未通过，`2` 表示参数或输入错误。

## 性能与缓存建议

- 重复生成时保留默认源码缓存，不要每次加 `--no-cache`；缓存以内容和工具链为键，失效是自动的。
- CI 里可以缓存 `target/cjdoc/cache`（例如 `actions/cache`）。源码大量变化时缓存命中率会下降，但仍能覆盖未改动的文件。
- 只生成需要的格式：`check` 不生成站点，纯门禁场景不要跑完整 HTML；需要 HTML 时再生成一次即可。
- 大型 workspace 可以从 `--jobs 1` 逐步增加并行度，观察内存和磁盘；结果内容与顺序不随 `--jobs` 改变。
- `render` 不重新扫描源码，比重新 `generate` 快；但它要求输入 JSON 与当前版本匹配，不能拿旧文件绕过检查。
- 输出目录放在本地磁盘，避免网络文件系统；输出和缓存不要互相嵌套。

## 可选扩展：CHIR 语义与外部高亮

这两个能力都需要额外的本地可执行文件，普通项目不需要配置。

### 用 CHIR 补充语义

默认 `--semantic source` 只读源码和注释。如果你有与当前 SDK 匹配的 CHIR worker，可以让它补充结构化语义：

```bash
cjdoc generate --project . --format html \
  --semantic chir \
  --cjc /path/to/cjc \
  --chir-worker /path/to/cjdoc-chir-worker \
  --chir-import-path /path/to/sdk/lib
```

- `--cjc` 指定编译器，默认 `cjc`；`--chir-import-path` 可重复；`--chir-worker` 指向独立 worker 可执行文件。
- 只有 `--semantic chir` 才接受这三个选项；`render` 不接受语义选项。
- worker 未配置或 CHIR 处理失败时，cjdoc 保留源码结果并输出 warning（`CJDOC2101` 等），不会中断生成。
- 如何构建 worker 见 [维护者构建说明](maintainer/build.md)。

### 使用外部高亮后端

内置高亮只覆盖仓颉，由 `cjdoc.toml` 的 `[highlight]` 控制。如果你有 cjdoc 的高亮适配器和 Node 运行时，可以让 `json`、`bash`、`python`、`toml`、`yaml` 这些语言使用外部高亮：

```bash
cjdoc generate --project . --format html \
  --highlight-adapter /opt/cjdoc/highlight/adapter.mjs \
  --highlight-node /usr/bin/node
```

- 两个选项必须成对出现，都要求绝对路径，且不能包含 shell 元字符；只用于 `generate` 和 `check`。
- 适配器失败时保留纯文本并输出 warning（`CJDOC3120`）；`[highlight].on-error = "error"` 时改为 error（`CJDOC4027`）并使构建失败。
- 没有适配器时不要传这组选项；适配器的实现与打包见 [维护者文档索引](maintainer/README.md)。

## 能力边界

- 生成、检查、渲染都不联网：不下载依赖、不下载标准库文档、不访问外部文档站。依赖和文档必须事先在本地准备好。
- 不读取 compiler 的 target profile，不自动展开宏；条件编译要显式传 `--cfg`，无法解析的条件会让声明被跳过。
- 无法唯一解析的类型引用保留原文并标记为不可用，cjdoc 不会猜测目标。
- GitHub 源码链接只支持 `https://github.com/<owner>/<repo>` 形式的仓库根，且要求源码确实位于仓库根内。
- 标准库链接只是文档参考，不证明项目所用 API 与目标文档版本一致；未收录或匹配不唯一的类型不加链接。
- Windows 上不嵌入本地图片，只保留替代文本（`CJDOC4026`）；页面会被标记为不完整（partial）。
- 单次扫描、单个源码文件和辅助输入都有大小及数量上限；超限时保留已收集的结果并输出诊断，生成状态会变成 partial。
- `--locale` 只影响界面标签，不翻译作者正文；多语言首版只支持 `zh-CN` 和 `en`，并且最多发布两种语言。
- `versions compose` 只做“复制 + 注入版本选择器”，不重新生成、不校验各版本的内容一致性；版本源目录必须包含 `index.html`（或带 `site-manifest.json` 的多语言输出根）。
- `render` 只接受当前版本生成的 `docs.json`，不接受旧文件；它不会重新读取项目，因此源码变化后必须重新 `generate`。

## 维护者文档

源码构建、发布流程、内部格式与 schema 维护、跨文档链接的完整规则等维护者内容不面向普通使用者：

- [维护者文档索引](maintainer/README.md)
- [构建与本地门禁](maintainer/build.md)
- [内部格式与 schema 维护](maintainer/doc-ir.md)
- [跨文档链接维护](maintainer/document-links.md)
- [发布流程](maintainer/release-process.md)
