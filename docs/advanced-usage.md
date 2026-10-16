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
├── html/navigation-index.json
├── html/llms.txt
├── html/search-index.js
├── html/search.js
├── html/style.css
├── api-surface/api-surface.json
├── doctest/results.json
└── coverage/coverage.json
```

HTML 和 Markdown 使用同一份生成结果。HTML 是静态站点，可以直接打开 `html/index.html`；`search-index.js` 让浏览器在 `file://` 下也能使用搜索。

## 概念文档与本地预览

项目配置了 `[docs]` 或 `[[docs.pages]]` 后，概念页面会与 API 站点一起生成到 `html/concepts/` 和 `markdown/concepts/`。`docs/index.md`、模块/包概览以及显式配置的 guides 页面共享安全的 Markdown 投影；概念页会被加入搜索索引。

HTML API 包索引会复用真实包概述的首段（最多 240 个 Unicode 字符）并链接到完整概念页；导入、示例和长篇指南仍只在概念页展示。可沿用自动路径 `docs/packages/<package-slug>.md`，或配置：

```toml
[docs.packages]
pocketkit = "docs/pocketkit.md"
```

也可在已有 `[[docs.pages]]` 上设置 `package = "pocketkit"`（包概述可设置 `kind = "package"`），将现有指南绑定到包。多语言页面继续按同一逻辑 `id` 与 `language` 配对，沿用 [#64](https://github.com/lIlIIlIll/cjdoc/issues/64) 的语言回退，不猜正文语言。

包页简介段落用作者页已知的 `language` 标注 `lang`；例如中文站点回退到英文概述时，英文摘要仍标为 `en`，界面标签仍使用中文。未声明的正文语言不补写 `lang`。

未启用概念文档、包文件不存在（既有合成回退）、空白/只有标题的作者页、当前投影不可见，以及无法唯一归属的同名跨模块包，均不创建简介容器或入口。包名在完整 Doc IR 内唯一才足以关联；同名包须由既有显式 API binding 的可见目标证明同一 moduleId + package，否则安全省略。绑定不存在/不适用于当前受众或 cfg 时也省略，不跳 latest。概念页的“包 API”返程定位当前语言、当前文档集的包页 `#declarations`。JSON 快照保留作者页，`render` 不需要重新读取项目文件。

同名包的模块证据必须来自该包自己的 API binding，指向其他辅助包的链接不作为归属证据。同一作者文件同时用于自动包概述与显式指南时，包页入口按来源去重；各概念路由仍按自己的逻辑页身份返回正确包，不因同源复用而隐藏有效概述。

开发时使用 loopback-only watcher：

```bash
cjdoc serve --project . --port 8080 --open
```

它递归监视 `.cj`、`.md`、`cjpm.toml`、`cjpm.lock` 和 `cjdoc.toml`，变更后重新生成站点。`GET /__cjdoc/status.json` 可供编辑器或脚本读取构建状态；失败重建不会删除最近一次成功的文件。

`--port` 和 `--open` 只适用于 `serve`；服务不会暴露项目目录之外的文件。

## 本地多版本发布

版本发布不读取 Git 或网络。先分别生成带版本元数据的 HTML 目录，再组合：

```bash
cjdoc generate --project . --format html --doc-version 1.2.0 --output target/docs-1.2
cjdoc generate --project . --format html --doc-version 1.3.0 --output target/docs-1.3
cjdoc versions compose \
  --version 1.2.0=target/docs-1.2/html \
  --version 1.3.0=target/docs-1.3/html \
  --channel 1.2.0=stable --channel 1.3.0=preview \
  --latest 1.3.0 --output public/docs
```

组合器输出 `versions.json`、根选择页和 `latest/` 静态别名。版本页面的 selector 使用稳定 symbol ID 跨版本导航；目标不存在时回退到版本首页并保留 unavailable 标记。未显式指定 latest 时使用第一个命令行版本；channel/status 不做内置策略判断。

已有 `cjdoc.api-diff/1` 或 `cjdoc.api-diff/2` 报告时，可用 `--diff VERSION=FILE` 绑定到目标版本。报告会原样复制到该版本的 `api-diff.json`，并通过 manifest 的 `apiDiff` 字段和 selector 的 Changes 链接暴露；不会改写 Doc IR。

`versions.json` 遵循 `cjdoc.versions/2`，每个版本目录可独立通过 `file://` 打开。

## Agent-readable navigation and context

HTML 产物同时包含 `html/navigation-index.json` 和 `html/llms.txt`。它们由 Doc IR 直接生成，分别提供稳定的页面/声明目录和有界的 agent 摘要；消费者不需要解析 HTML。导航记录保留当前 audience 可见的 `symbolId`、package/module、路由和 semantic state，概念页也使用同一目录。

默认只生成短索引。需要签名、参数、返回值、throws、示例和概念 Markdown 时，在 `generate`、`render` 或 `serve` 上加 `--agent-full`，生成有界的 `html/llms-full.txt`：

```bash
cjdoc generate --project . --format html --agent-full
```

这些产物保持确定性、使用相对链接并可离线通过 `file://` 消费；private 或被 audience 过滤的声明不会出现在索引中，partial/unavailable 状态不被升级为 resolved。对应 schema 是 `cjdoc.navigation-index/1`，可用 `cjdoc schema navigation-index` 导出。

## 记录目标依赖身份与离线文档输入

`generate` 和 `check` 可接收下列输入；公共 API 的 `GenerationRequest` 提供同名 camelCase 参数：

| CLI | API 参数与默认值 | 用途 |
|---|---|---|
| `--build-context <record.json>` | `buildContext: ?String = None` | 目标项目的本地构建输入记录，不是 cjdoc 自身 SDK 的记录 |
| `--doc-source <catalog-or-dir>`（可重复） | `documentSources: Array<String> = []` | 显式本地文档目录或 catalog；不联网 |
| `--doc-inventory-pin PATH=SHA256`（可重复） | `documentInventoryPins: Array<DocumentInventoryPin> = []` | 调用方独立信任的完整 inventory 字节摘要；不接受 publisher 自报摘要授权 |
| `--doc-version <revision>` | `documentationRevision: String = ""` | 冻结文档发布/展示修订；不决定依赖 API 版本 |
| `--link-language <lang>` | `linkLanguage: String = ""` | 外部文档链接语言；空值不限制语言，等优先级不同目标仍报告歧义 |
| `--link-language-fallback` | `linkLanguageFallback: Bool = false` | 显式允许语言回退 |
| `--link-compatible` | `linkCompatible: Bool = false` | 显式允许兼容匹配；不是默认 exact 匹配 |

没有构建记录时，`dependencies` 仍包含项目自身、workspace 和 manifest path/显式 `--dependency-source` 的内容观察。普通版本/Git/lock 声明保留为 `declared`；缓存里恰好存在某目录，不证明构建选中了它。目标 compiler、std、stdx 默认是 `unknown`，不会读取生成器的 `CJDOC_TOOLCHAIN` 元数据冒充目标版本。

优先使用请求中明确给出的 cfg/源码选择；有效 receipt 可以补全未给出的 target 并把同一字节选择验证到其 project/configuration 绑定。请求、清单/lock 与记录不一致时保留 conflict，不按读取顺序静默覆盖。receipt 整体 shape 与 project/cfg 绑定校验完成前不会改变 target 或条件依赖图；运行环境、PATH SDK、worker stdx 和未绑定缓存不作为目标选择证据。

`generator.toolchain` 在自动生成时为空，明确表示**无法认证已链接 parser 的完整 SDK build**。运行时 `PATH/cjc --version`、`--cjc` 或包装器的 `CJDOC_TOOLCHAIN_*` 都不能证明真正加载的 `std.ast` 构建身份；这些宿主信息不能冒充 parser 或文档目标身份。公开 API 调用者填写的非空值也只是调用者声明，不自动成为认证事实。目标 compiler/std/stdx 继续分别由构建记录及实际选中输入字节绑定。

有 Python 3.11+ 和本仓库源码时，在实际目标构建选定输入后生成记录。下面的路径、模块名和 target 必须替换成该次构建真正使用的值，不能填写 cjdoc 的构建 SDK：

```bash
python3 scripts/capture_build_context.py \
  --project <project> --output <project>/build-context.json \
  --target <actual-target> --cfg feature=enabled \
  --dependency <module>:toolchain:toolchain=<compiler-file> \
  --dependency <module>:std:std=<selected-std-artifact-dir> \
  --dependency <module>:stdx:stdx=<selected-stdx-artifact-dir>
cjdoc generate --project <project> --cfg feature=enabled \
  --build-context build-context.json --doc-source <local-catalog> --format html
```

准备脚本不会启动 compiler、扫描 SDK 环境或缓存、运行 Git、下载依赖或宣称构建成功。它自动收集 manifest path/workspace；额外选中的源码使用 `--source-dependency OWNER:source:NAME=PATH`，生成时也应提供相同的 `--dependency-source NAME=PATH`。std/stdx 源码树可用 `--source-dependency OWNER:std:std=PATH` 或 `OWNER:stdx:stdx=PATH` 独立记录。每个模块分别填写实际输入，不默认把根模块选择传播给所有模块。

记录格式为 `cjdoc.build-context/1`。根对象只接受 `schemaVersion`、`project`、`target`、`cfg`、`modules`；重复键和未知字段拒绝。`project` 是 `{ "path": "...", "identity": "sha256:..." }`；`modules` 中每项为 `{ "name": "...", "path": "...", "identity": "sha256:...", "dependencies": [...] }`。每个 dependency 必填 `name`、`kind`、`path`、`identity`；可选 `content`、`version`、`revision`。

- `kind` 为 `source`、`binary`、`std`、`stdx` 或 `toolchain`。`content` 为 `source` 或 `artifact`；省略时 source kind 使用源码，其余使用 artifact。compiler 使用明确的可执行文件路径，不运行该文件。
- 路径只用于本地观察，可为相对记录所在目录的路径或本地绝对路径；Doc IR 不输出这些主机路径。记录可能含本地路径，不能直接提交或发布。
- `cfg` 是请求中显式 `NAME=VALUE` 按 name/value 排序去重后以换行连接的字符串；没有显式 cfg 时为 `""`。显式 cfg 的 `target` 必须与记录 `target` 相同；未显式给 target 时使用记录选择，但不推断宿主 target。
- 源码 identity 是排序的相对 `.cj`、`cjpm.toml`、`cjpm.lock` 库存与实际字节的 SHA-256；忽略隐藏项及 `target`。目录 artifact 观察所有非隐藏文件；单个 artifact 直接观察文件字节。时间、绝对根路径不参与 identity，std/stdx 分别观察，不臆造官方版本。
- 库存限制为累计 100000 项、128 层；源码文件仍限 64 MiB。产物按 64 KiB 分块观察，不整文件分配；全部 source/artifact 观察及 receipt 复核共用累计 512 MiB I/O/work 预算，不逐文件或复核阶段重置。读前、打开后和读后的大小/时间及实际读取长度不一致即拒绝；库存中的符号链接拒绝。记录限 4 MiB、4096 模块、每模块最多 16384 依赖。既有 source/output 限额不变，超界不升级 evidence。

cjdoc 会重新读取 project/module/manifest/lock/source/artifact 字节，与记录逐项比较，并检查模块所属关系、target 和 cfg。`observed` 只表示观察到字节；`verified` 表示显式选择记录与这些观察及 project/configuration 绑定一致，**不表示独立证明构建执行过或成功过**。`version`/`revision` 仍是声明，不由文件名或目录猜测。

生成后检查 `docs.json` 的 `dependencies`：每项含 owner `moduleId`、稳定 `instanceId`、`identity`、`kind`、`state`、`evidence`、`target`、`cfg` 与 `componentModuleId`。后者只指向本快照中实际选中的源码组件；没有可确认源码边时为空。实例 ID 还纳入该组件的传递源码/构建上下文，不能把相同自身源码、不同传递依赖混为一例。项目变化、lock 与选中源码版本不一致或记录摘要过期产生 `conflict` 和 `CJDOC2301`；格式/模块绑定错误为 `CJDOC2300`；无法观察/超界为 `CJDOC2302`。格式或 project/configuration 绑定无效的 receipt 整体拒绝，不能先用其 target 改变依赖图。

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

默认 source cache 位于 `target/cjdoc/cache/source-v11`。正常重复生成时不需要管理它。要排查缓存影响或强制完整读取源码：

当前私有 source-cache 格式为 v17；旧解析缓存会失效重建。源码泛型 `where` 上界、交叉约束和多参数约束保留为 `typeRelationships`，其类型节点沿用依赖导航绑定；缓存读取不会丢失这些约束。

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

`diff` 可以单独比较两个 snapshot，不需要扫描项目：

```bash
cjdoc diff --baseline api-surface.json --current api-surface-next.json --format json --deny-breaking-api
```

`diff` 默认返回 `0` 并保留报告；`--deny-breaking-api` 或 `--deny-potentially-breaking-api` 让对应分类返回 `1`，输入错误返回 `2`。v1/v2 API snapshot 只作为严格迁移输入，当前输出为 v3；`--format json` 输出稳定的 `cjdoc.api-diff/2` 文档。

只想读取覆盖率 JSON 时：

```bash
cjdoc generate --project . --format coverage --stdout > coverage.json
```

coverage artifact 当前为 `cjdoc.documentation-coverage/2`，包含七类 metric 和按 package/module 的分组；旧的 `documentation-coverage-v1` schema 以独立只读文件保留。门禁可以在同一个项目配置中声明：

```toml
[lint]
severity = "warning"
missing-example = "off"
broken-link = "error"

[coverage]
symbols = 90
parameters = 95

[coverage.package.basic]
symbols = 100
```

CLI 的 `--min-symbol-coverage` 和 `--min-parameter-coverage` 仍可作为一次性更高门槛；配置中的 returns、throws、examples、deprecated、semantic-links 以及 package 覆盖率会由 `check` 一并执行。


## 在 CI 中执行 doctest

需要把文档示例作为门禁时，在项目根 `cjdoc.toml` 启用 `mode = "deny"`，并保留 `timeout-ms`、`memory-mb` 和 `jobs` 的明确值。当前 native 后端要求 `memory-mb` 在 `2048..16384` MiB；低于该范围的配置会被拒绝，因为 `cjc` 与生成程序需要更大的虚拟地址空间才能启动。生成或 `check` 会为每个 fenced Cangjie block 创建独立工作目录，直接启动 `cjc` 和生成程序，禁止 shell 拼接；超时、非零退出码和编译失败都会产生 `CJDOC3010` 结果。生成模式把机器可读结果保存为 `doctest/results.json`，而 `check` 只使用退出码。

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

v6–v14 只能作为严格的只读输入迁移到当前 v15 输出；cjdoc 不会重新生成旧版本格式，也不为旧输入补造依赖或导航证据。

需要在 HTML 声明页显示 GitHub 源码链接时，`generate` 必须同时接收 `--repository-url` 和 `--repository-revision`，并可用 `--repository-root` 指定仓库根目录。URL 只支持 canonical GitHub HTTPS 仓库根；缺少真实 source-origin 映射、仓库外依赖或符号链接越界时，链接会被省略。`render` 只使用 JSON 中已经保存的 metadata，不接受这些生成参数。

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

当前源码与 Pages 构建使用 Cangjie **1.2.0 STS** 的 `cjc`/`cjpm` 和匹配的 `stdx` release/1.2 sidecar，并需要 `cjpm.lock` 固定的 Git 依赖，或已经准备好的对应 cjpm cache。工作流通过 [`Zxilly/setup-cangjie`](https://github.com/Zxilly/setup-cangjie) 的 `sts` + `stdx` component 获取 SDK 与 stdx，压缩包由其 `cangjie-version-manifest` 提供 SHA-256 校验；固定在 workflow `env` 中的版本与 `cjv-version` 决定实际安装内容。手工复现时可用同一工具的 `cjv install sts-1.2.0 --component stdx`。

复现 Linux 展示构建时，按该工作流准备 SDK 和 sidecar，再执行完整的 “Build cjdoc” 步骤。SDK 1.2.0 的 `llc` 在默认优化级别处理 markdown/yjson 时会崩溃；该步骤临时设置 `override-compile-option = "-O1"`，并在结束时恢复原清单。不要省略这个处理而直接使用默认构建命令。完整展示复现与验收说明见同一仓库 revision 的 `docs/showcase-contract.md`。

该候选项现在只由一个 reusable workflow [`build-linux-candidate.yml`](../.github/workflows/build-linux-candidate.yml) 构建一次，CI 的 Linux 验收与 Pages 都复用它，因此 SDK 安装、stdx sidecar 认证和 `-O1` 处理只有一处定义；产物同时携带 `build-manifest.json`，消费方在解包后会重新校验二进制摘要、大小与 `--version`，身份不符即失败。

构建完成后，在同一 SDK 环境下从仓库根目录确认工具版本：

```bash
cjc -v
cjpm -v
./cjdoc --version
```

仓库根目录的 `./cjdoc` launcher 在 binary 不存在时会尝试默认构建；SDK 1.2.0 下应先完成上面的构建步骤。维护者运行 `scripts/check.sh` 时，使用 [CI workflow](../.github/workflows/ci.yml) 中同一 SDK、sidecar 和临时 `-O1` 包装步骤。Tag 发布流程使用同一个钉死的 Cangjie 1.2.0 STS 与匹配 stdx，归档 URL 与 SHA-256 内联在 workflow 中；见 [`docs/release-process.md`](release-process.md)。

## 能力边界

- 当前生成的 Doc IR 版本是 `cjdoc.doc-ir/15`。
- 默认 `--semantic source` 使用 `std.ast` 和源码 lexer 做结构化源码遍历；注释仍来自原始源码，Doc IR 和 renderer 不依赖 CHIR。
- `generate`/`check` 可显式使用 `--semantic chir`，并须通过 `--chir-worker <path>` 指向独立 worker executable。只有 `tools/chir-worker` package 导入 `stdx.chir`；core 通过受限文件协议调用它。worker 未配置或 CHIR 处理失败时保留 source declarations，并产生 `CJDOC2101`–`CJDOC2106` warning。
- CHIR 逐个检查待编译的根包、workspace member 和已捕获依赖的 manifest。不支持的构建配置或编译选项产生 `CJDOC2102`，受影响的编译不会派发给 worker，源码/AST fallback 仍保留；TOML 注释不参与这项检查。
- 组织限定依赖须有匹配的源码 package 声明，例如 `package acme::actual_dep`。cjdoc 保留源码，不根据 manifest 的 `organization` 重写 package 头；组织名和完整的 package alias 路径参与依赖选择。
- `render` 只消费已有 Doc IR，不能使用 `--semantic`、`--cjc`、`--chir-worker` 或 `--chir-import-path`。
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
| `--jobs <1..64>` | `generate`, `check` | `1` | syntax/source worker 数量 |
| `--cfg NAME=VALUE` | `generate`, `check` | 无 | 条件编译输入，可重复 |
| `--semantic <source|chir>` | `generate`, `check` | `source` | 选择 source 或显式 CHIR enrichment |
| `--cjc <path>` | `generate`, `check` | `cjc` | CHIR 模式调用的 compiler；必须与 `--semantic chir` 同时使用 |
| `--chir-import-path <dir>` | `generate`, `check` | 无 | CHIR 编译的只读 import root，可重复 |
| `--chir-worker <path>` | `generate`, `check` | 无 | 独立 CHIR worker executable；未配置时保留 source declarations 并报告 `CJDOC2101` |
| `--include-path-dependencies` | `generate`, `check` | 关闭 | 扫描 manifest 中的 path dependency |
| `--include-cached-dependencies` | `generate`, `check` | 关闭 | 扫描可发现的 cjpm cache dependency |
| `--dependency-source NAME=PATH` | `generate`, `check` | 无 | 显式提供只读 dependency source，可重复 |
| `--cjpm-cache <dir>` | `generate`, `check` | 默认 cache | 指定 cjpm cache，需同时启用 cached dependencies |
| `--cache-dir <dir>` | `generate`, `check` | `target/cjdoc/cache/source-v11` | 指定 source cache |
| `--no-cache` | `generate`, `check` | 关闭 | 禁用 source cache |
| `--locale <name>` | `generate`, `render` | `zh-CN` | HTML/Markdown 结构语言 |
| `--markdown-layout <name>` | `generate`, `render` | `site` | `site` 或英文 `single` |
| `--api-surface-baseline <file>` | `generate`, `check` | 无 | 对账 API snapshot；当前生成 v3，严格接受 v1/v2/v3 输入 |
| `--baseline <file>` / `--current <file>` | `diff` | 无 | 指定两个 API snapshot |
| `--deny-breaking-api` / `--deny-potentially-breaking-api` | `diff` | 关闭 | 把对应 API diff 分类变成退出码 `1` |
| `--format text` / `--format json` | `diff` | `text` | 选择人读文本或 `cjdoc.api-diff/2` JSON |
| `--min-symbol-coverage <0..100>` | `generate`, `check` | 无 | 声明覆盖率门槛 |
| `--min-parameter-coverage <0..100>` | `generate`, `check` | 无 | 参数覆盖率门槛 |
| `--repository-url <url>` | `generate` | 无 | canonical GitHub HTTPS 仓库根，需与 revision 成对使用 |
| `--repository-revision <ref>` | `generate` | 无 | GitHub blob URL 使用的 revision，需与 URL 成对使用 |
| `--repository-root <dir>` | `generate` | 项目根 | 限制真实 source origin 的仓库映射范围 |
| `--agent-full` | `generate`, `render`, `serve` | 关闭 | 生成完整但有界的 `html/llms-full.txt` |
| `--doc-version <id>` | `generate`, `render` | 无 | 把版本上下文写入 HTML agent 产物和 `html/version.json` |
| `--force-owned` | `generate`, `render` | 关闭 | 显式采用已有输出目录内容 |

## 多语言模型、迁移和版本组合

Doc IR v15 保留作者变体与独立依赖导航事实，严格迁移 v6–v14 不补造依赖或工具链证据。`--require-language en` 和 `[coverage.translation]` 提供翻译门槛；版本组合读取原生 `site-manifest.json`。配置与格式版本见 [多语言文档](i18n.md)。

## 准备固定官方文档快照索引（DL05）

官方资料适配器是独立的 Python 3.10+ 标准库脚本，不在 `generate`、`render` 或 `check` 中联网。它只收录 manifest 中逐项核实的符号；当前审查范围是 std.collection 的 `ArrayDeque<T>` / `capacity` 和 stdx.encoding.json 的 `JsonArray` / `add(JsonValue)`，不是 std/stdx 全库。适配器内的 `OFFICIAL_PAGES` 显式限定这两类资料的 package 映射；新增资料需重新审查映射和声明证据。

在 cjdoc 源码仓库根目录，用已随仓库保存的最小官方资料摘录离线生成索引和分类页：

```bash
python3 scripts/prepare_official_inventory.py \
  --manifest tests/fixtures/external_docs/official83/manifest.json \
  --bundle tests/fixtures/external_docs/official83 \
  --output target/official83/symbol-index.json \
  --html-output target/official83/official-pages
```

成功信号是 `prepared 4 source-verified entries in 2 document sets`；索引格式为 `cjdoc.symbol-index/2`。`--html-output` 必须与索引位于同一父目录。生成的分类页有与原始资料行一一对应的类型/成员锚点（例如 `#L3`、`#L18`、`#L55`），可部署在本地站点中；上游固定源码链接和 SHA-256 保留在页面和索引 provenance 中。不传该选项时，条目使用固定 GitHub Markdown 文档的 `?plain=1#L...` 源码行链接。`plain=1` 按 [GitHub 的 Markdown 行链接规则](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/creating-a-permanent-link-to-a-code-snippet#linking-to-markdown) 关闭 Markdown 展示，不能省略它后仍声称已定位源码行；这些链接也不是官方 HTML API 站的锚点。

需要重新从网络取回同一份资料时，显式指定 `--download`，并把 bundle 写入自己的缓存目录，而不是改动仓库 fixture：

```bash
python3 scripts/prepare_official_inventory.py \
  --manifest tests/fixtures/external_docs/official83/manifest.json \
  --bundle target/official83/source-bundle \
  --output target/official83/symbol-index.json \
  --html-output target/official83/official-pages \
  --download
```

下载仅允许 `raw.githubusercontent.com/cangjielanguage/{cangjie_runtime,cangjie_stdx}/<完整 commit SHA>/...` 的文档路径，拒绝重定向、凭据、非 HTTPS、任意主机及环境代理。先核对完整上游文件 SHA-256，再截取并核对摘录 SHA-256；离线模式只核对已有摘录，不把本地摘录校验冒充一次新的上游下载校验。manifest 必须来自已审查的可信来源：哈希保证与该 manifest 一致，不替代发布者认证。脚本不解包归档、不执行下载内容；拒绝 JSON 重复键、重复 symbolKey、符号链接、越界路径、不存在的标题/声明和超限输入。限制为 manifest 1 MiB、单个来源 4 MiB、累计来源 16 MiB、64 个来源及 4096 条目。完整核验后原子替换索引；失败保留上次有效索引。分类页文件名包含内容身份，新的失败准备不会覆盖上次快照引用的页面。

### 固定来源与 SDK 映射边界

- std 官方文档来源：`cangjielanguage/cangjie_runtime` 的 `c844ec7556f9ab624e6a052c550444d695c44f2e`；完整分类源文件 SHA-256 为 `cdba440a9b30fb148dc2cc5307a5574baf9b5c9f26c35735556d399fdab26d45`。
- stdx 官方文档来源：`cangjielanguage/cangjie_stdx` 的 `f74bb5953547e51edff8904ae3db75ad47f17f06`；完整分类源文件 SHA-256 为 `7f9a196a8432da04125ae2599279065e95f06634389ac7a9ca5d8b79abb7362f`。
- 来源归属的证据、原始 URI、摘录行范围和 CC-BY-4.0 署名/许可说明见 `tests/fixtures/external_docs/official83/manifest.json` 与同目录 `NOTICE`。

这一级核验只证明“固定官方文档源文件中有此类型/成员及该源行”，不证明“目标 SDK 导出的 API 与资料完全一致”。索引的 documentSets 使用文档内容 identity、`state=declared`、空 target/cfg；条目保留 `semanticState=partial`，provenance 的 SDK 映射为 `none`。`apiVersion` 与 API 源码 `revision` 均为空；已核实的文档 commit 只填 `documentationRevision`。不从文档 commit、文件摘要或 README 的版本名称推断安装 SDK 的 std/stdx 身份。使用者只有在外部 catalog 中显式声明对应来源映射后才能采用这些链接；手工映射必须保持 declared，不得升级为已认证的 exact 匹配。

维护者可运行纯 Python 离线测试，不需要 Cangjie SDK：

```bash
python3 -m unittest discover -s scripts -p 'test_prepare_official_inventory.py'
```

### 从固定官方 Cangjie 源码生成库存（E2E2 的独立链路）

上面的官方 Markdown 适配库存不能替代“由 cjdoc 自己扫描真实 std/stdx Cangjie 源码生成的库存”。维护者可使用第二条独立链路，保留两条链路的不同证据等级。

先显式联网准备三个固定源码文件及两个仓库原始许可证；`<work>` 应是自己的磁盘临时目录，且 `source-projects` 尚不存在：

```bash
python3 scripts/prepare_std_source_snapshot.py \
  --cache <work>/upstream-cache \
  --output <work>/source-projects \
  --download
```

默认不带 `--download` 时，只读取并核验已有 cache。固定来源是同一已核实的公开官方镜像源码 commit：

| 来源 | 完整未改写源码 | SHA-256 |
|---|---|---|
| runtime `c844ec7556f9ab624e6a052c550444d695c44f2e` | `stdlib/libs/std/collection/array_deque.cj` | `3c6b754a5de5bb61678265124584bd16bb7414613db0c939937ab0c2228f1348` |
| stdx `f74bb5953547e51edff8904ae3db75ad47f17f06` | `src/stdx/encoding/json/json_object.cj` | `41d9de5923696f575e08ce75e71c023424ba7b1b793eeffeff1461be23134584` |
| stdx 同一 commit | `src/stdx/encoding/json/json_value.cj` | `87d8fb0674a24b9b04bc9789970dd3049ed7d43b50d3e933f26fe988d563b9b6` |

脚本只允许代码中固定的 HTTPS URI，下载核验沿用拒绝重定向和代理的实现。它原样保留 Apache-2.0 with Runtime Library Exception 的源码头与完整 LICENSE，输出 `source-provenance.json`，不裁剪声明、不补桩、不手写 index entries。两个最小 `cjpm.toml` 仅提供 cjdoc 项目布局，没有虚构的 API 版本。这三个文件不是可独立构建的 std/stdx 包，也不是安装 SDK 的源码认证。

然后在已显式选择并准备好的 SDK 环境中，串行运行验收脚本。`<sdk>` 是实际编译目标项目所选的 SDK 根，`<stdx-import>` 是独立选中的静态 stdx `.cjo` 目录；不要用文档生成器的 SDK 身份替代目标构建身份：

```bash
python3 scripts/accept_generated_std_inventory.py \
  --binary target/release/bin/main \
  --sources <work>/source-projects \
  --sdk <sdk> \
  --stdx <stdx-import> \
  --target x86_64-unknown-linux-gnu \
  --module-target linux_x86_64_cjnative \
  --output <work>/generated-source-acceptance
```

该脚本不重建 cjdoc，也不构建/改动 SDK。它实际调用当前 cjdoc 分别扫描真实源码，生成两份未经手改的 HTML 和 `symbol-index/2`，检查 `ArrayDeque` / `capacity`、`JsonArray` / `add(JsonValue)` 的真实生成条目和页面/锚点；随后编译私有 consumer，通过 build-context 分别观察实际 `std.collection.cjo`、`stdx.encoding.json.cjo` 与 compiler，再以显式 `compatibilityMappings` 和 `--link-compatible` 接入这两份自生成库存。脚本同时检查未 opt-in 和错误 target 的映射不能解析为外部链接。

结果位于 `summary.json`、`evidence/` 和 `site/html/`；后者包含从生产者原样复制的 `generated-std/`、`generated-stdx/` 目标页，便于独立执行本地与 HTTP 浏览器点击验证。脚本的 PASS 不声明浏览器已执行。真实源码 commit 只作为源码 provenance 保存；未提供给生成器的 API revision 保持空值，独立文档发布标记为 `source-subset-documentation`。库存 source identity 只覆盖实际扫描的源码子集；consumer 的 installed artifact identity 与它不同，映射因此只允许 compatible，不是 exact、官方发行映射、全库覆盖或 API/ABI/行为等价证明。

## 配置多版本文档目录并冻结导航

先对依赖的每个实际版本生成站点。HTML 自带 `html/symbol-index.json`，路由根是该 HTML 目录；独立 `symbol-index/symbol-index.json` 的路由根是整个输出目录，不要重复追加 `html/`。

```bash
cjdoc generate --project library-v1 --format html --format symbol-index --output library-v1-site
cjdoc generate --project library-v2 --format html --format symbol-index --output library-v2-site
```

把下面内容保存为与两份站点相邻的 `cjdoc-documents.json`。目录型 `--doc-source` 读取该固定文件名；文件型输入直接读取 catalog。索引路径必须是 catalog 目录内的规范相对路径。

```json
{
  "schemaVersion": "cjdoc.doc-sources/1",
  "documents": [
    {"index": "library-v1-site/html/symbol-index.json", "baseUrl": "https://docs.example.test/api/v1", "priority": 0},
    {"index": "library-v2-site/html/symbol-index.json", "baseUrl": "https://docs.example.test/api/v2", "priority": 0}
  ]
}
```

消费者的 manifest path 依赖自动观察内容身份，无需重复填写依赖版本。缓存目录存在、包声明版本或 cjdoc 的 SDK 版本不能单独证明选中身份。Git/二进制等复杂选择用构建记录绑定实际输入。先从受信任的本地生成过程或独立可信渠道取得 inventory SHA-256；下面在刚完成的受控 producer 输出上独立计算 pin，而不是读取 inventory/catalog 中自报的摘要。

```bash
read -r PIN_V1 _ < <(sha256sum library-v1-site/html/symbol-index.json)
read -r PIN_V2 _ < <(sha256sum library-v2-site/html/symbol-index.json)
cjdoc generate --project consumer --doc-source ../cjdoc-documents.json \
  --doc-inventory-pin "../library-v1-site/html/symbol-index.json=$PIN_V1" \
  --doc-inventory-pin "../library-v2-site/html/symbol-index.json=$PIN_V2" \
  --output "$PWD/consumer-site" --format html --format markdown --format json
cjdoc render --input consumer-site/docs.json --output replay --format html --format markdown
```

公开 API 接收同一组独立 pin；宿主将上例已取得的 SHA-256 字符串传给此函数，而不是接受 catalog 自报值：

```cangjie
import cjdoc.*

func consumerRequest(pinV1: String, pinV2: String): GenerationRequest {
    GenerationRequest("consumer",
        documentSources: ["../cjdoc-documents.json"],
        documentInventoryPins: [
            DocumentInventoryPin("../library-v1-site/html/symbol-index.json", pinV1),
            DocumentInventoryPin("../library-v2-site/html/symbol-index.json", pinV2)
        ],
        documentationRevision: "docs-r7")
}
```

检查 `docs.json` 中的 `dependencies`、`documentSets` 与类型/正文的 `navigation`。`exact` 必须同时满足调用方 pin、实际依赖内容、所选源码依赖闭包与 target/cfg/audience 范围；缺少独立 pin 最多是 `manual`，publisher 的 `state/source` 字符串不升级证据。`compatible` 仅是显式适用映射，不认证 ABI/行为。pin 的真实性只追溯到操作者信任的摘要，不能抵御控制该摘要的人，也不证明远端 HTML 的实际部署。合法 catalog `baseUrl` 可选择展示位置；它进入文档集 ID/绑定输入，但不反改 pin 覆盖的相对 symbol route、key、API identity 或范围。导航不把 `semantic.state` 的 partial/unavailable 改为编译器 resolved。普通 render 不读取原项目、receipt、索引、SDK 或网络，也不重新选版本。

`DocumentSetIdentity.moduleId` 是 producer inventory 内的指针，由该 inventory 的 `indexIdentity` 限定；不假定它等于消费者的 module ID。`library` 是包含组织限定符的根包作用域，import/包别名先绑定到实际选中的源码包，再比较文档身份。包/类型/成员与泛型元数、精确重载共用 portable symbol key；没有精确重载或同优先级目标冲突时不选第一个。

`apiVersion` 只保留 producer 的包清单版本声明，`revision` 是 API 源码 revision 声明，`documentationRevision` 是独立的文档发布修订。`--doc-version`/公开 `GenerationRequest.documentationRevision` 只填最后一项；三者都不以标签代替内容/作用域证据。未知为空；标签不会提升匹配等级。文档集版本声明若与其自带源码快照的同一清单声明矛盾，该 inventory 拒绝而非偷偷改写身份。HTML 标题/链接属性与 Markdown 链接 title 展示冻结的匹配等级和这些声明边界。

资源限制回退保留仍可按现有 codec 边界编码的文档发布修订；若该可选字符串本身超过字符串或完整文档预算（包括控制字符的 JSON 转义开销），回退将它留为空，表示未知，并保留 `CJDOC3027` 资源失败事实。正常、可表示的修订不被删除，也不会因为回退而升级为已验证的 API 身份。

正文 `{@link ...}`、受支持的 `@see/@throws` 与指南引用使用同一绑定服务。没有实际项目依赖的纯文档引用仍可按显式源提供 `manual` 参考链接，但其 `dependencyInstanceId` 为空，不能为项目新增依赖事实。源模式仅用捕获 AST、作用域与 import/别名规则；无法排除隐式 `std.core` 冲突的具名 import 保持 unavailable，可信 canonical provider 可消歧。可选/元组/函数、嵌套泛型及 `where T <: ...` 的类型原子递归绑定；泛型形参、普通形参、默认字符串与注释不借名字变成类型链接，签名复制文本不变。

声明及祖先类型的泛型形参也约束正文和 `@see/@throws`：在本地 ID 短路、导入别名展开及多语言条目关联前检查词法遮蔽。被遮蔽的引用保留作者文字和拒绝原因，不能留下假的本地 `resolved` 或目标 ID；明确、可证明的限定目标仍可达。指南只具有捕获的模块上下文，关联某个泛型 API 不会在整页虚构该函数的词法泛型作用域。

Doc IR `/15` 的 TypeRef wire 将三项类型语义事实命名平铺为必需的 `semanticState`、`semanticCanonical`、`semanticProvider`，后两项仍明确允许 null；公开 `TypeRef.semantic: SemanticType` 模型完整保留，不将语义合并进导航。这样每个 TypeRef 少一个真实 JSON 对象，不增加数组条目，也不丢 canonical/provider 的值。历史 `/6`–`/14` 的 schema 与 golden 仍使用原 `semantic: {state, canonical, provider}`，严格解码后按三值一一映射到新 wire；既有 provider SPI、旧 `symbol-index/1` 和 `api-surface` 自身的版本化格式不随此改变。导航的 exact/manual 不会将 `semanticState` 提升为 resolved。

为控制实际 Doc IR 大小，新生成的结构 wrapper、AST 确认的 intrinsic primitive 和作用域确认的泛型形参，在没有独立可解析目标时使用 `navigation: null`，不为它们重复发布十字段的失败对象。所有类型节点、原始拼写、语义状态和递归子节点仍保留；具备可信 provider canonical 身份的节点仍尝试独立目标并保存完整选择或拒绝原因。`String`、`Array`、`Option` 不按显示名称当作无目标 primitive。已确认的泛型形参标为 `kind: "typeParameter"`，渲染器不把其 canonical 拼写再当成同名声明。缺版本、歧义、未知依赖、隐藏目标等实际 named/generic 引用的失败决策保持非空。`null` 本身只表示没有记录独立导航决策；旧 v6–v14 迁移补出的 null 不包含新生成阶段的 AST/scope 证明，不能追认其为 not-applicable。质量报告继续列出全部结构节点、原子和非目标位置。

Doc IR `/15` 与 inventory `/2` 共用唯一导航 wire：非 resolved、`matchLevel=none` 且 dependency/document-set/index/symbol/URL/API/language 七项上下文全空的失败，以恰好两项的 `[state, reason]` 保存。state 仅为 `unresolved`、`ambiguous`、`unavailable`，reason 保留完整原文和原有字符串预算；它不是成功链接、依赖版本或兼容性证据。任何有上下文的失败和全部 resolved 记录仍保存完整十字段对象，公开 `TypeNavigation` 模型始终保留这十个字段。解码器拒绝 resolved tuple、多项、错误类型和本应使用 tuple 的无上下文对象；不兼容未发布的早期 `/15` 预览形状。维护脚本使用 `scripts/document_navigation.py` 在 wire 与完整模型之间转换，不扫描类型名或改变任何决定。该表示减少真实 JSON 对象和空 key，65,536 个对象、32 MiB Doc IR 及数组/字符串预算保持不变；所有失败引用及质量分母仍保留。

指南的 `cjdoc-bind` 也冻结到同一导航服务；不以正文链接替代关联芯片。例如页面可先绑定本模块 API，再精确指向该模块选中的外部重载：

```markdown
<!-- cjdoc-bind target="consumer.consume" selector="example" -->
<!-- cjdoc-bind target="library.Widget.lookup" selector="signature:public func lookup(value: Int64): Int64" -->
```

`DocumentationPageBinding.state/targetSymbolId` 仍只表达本地关联事实；外部已选目标放在独立 `navigation` 中，不把外链伪装成本地 semantic resolved。页面上下文来自唯一关联模块或唯一文档根模块，workspace 不按遍历顺序借最后一个模块。signature selector 保留已有的完整源码 header 拼写相等语义；新 /2 producer 自动发布 pin 覆盖的可选 `sourceHeader`，先按其准确筛选，再做依赖身份/范围/版本选择。不带该证据的库存不能凭类型名或参数个数凑一个 header，歧义不选第一个。普通 render 只消费冻结记录；source-hidden/locale-filtered 目标不经 chips、搜索或外链 fallback 重现。v6–v14 迁移给关联导航补 null，不能追认历史外部身份。

离线打包时把 catalog 的 baseUrl 改成 `./deps/v1` / `./deps/v2`，并把相应 HTML 站点显式复制到消费者的 `html/deps/v1` / `html/deps/v2`。路径以最终 HTML 文档根为基准，渲染器不读取或复制外部站点。HTTP(S) URL 不追加 `../`；片段接受规范 UTF-8 路由，拒绝危险协议、控制字符、编码分隔符和路径穿越。

inventory 准入与持久化 Doc IR 的导航消费共用同一纯 URL 策略：绝对 HTTP(S) URL 同样检查 authority、1–65535 端口、路径、片段和 percent escape，不能通过离线 `render` 绕开准入。支持 `?plain=1#L...` 所需的 query：最多 32 个非空且名称唯一的 `name=value` 项，以 `&` 分隔；名称和值均仅允许 ASCII 字母、数字和 `-_.~`。拒绝重复名称、缺失值、嵌套 `?`、`;`、多余 `=`、Unicode query 和转义 query 值。合法的 UTF-8 编码中文路径/片段仍保留；错误转义、编码控制字节、编码分隔符/路径穿越和带凭据的 authority 拒绝。`baseUrl` 仍拒绝 query/fragment，以免与相对条目拼接产生歧义。不安全输入在发布任何 HTML、Markdown 或机器索引前失败。

身份不匹配时保留文本，不改选 latest 或相邻版本。若确有范围依据，可在单个 documents 项下加 `compatibilityMappings`，成员为 `fromIdentity`、`toIdentity`、`target`、`cfg`、非空 `evidence`；target/cfg 必须对应当前目标。不同内容可从实际依赖 identity 显式映射；若自身源码相同但传递依赖/构建上下文不同，必须将 `fromIdentity` 精确设为该消费者的 `dependencies[].instanceId`，裸源码 identity 映射不能掩盖此差异。任何 conflict 都不能由兼容映射覆盖。只有同时传 `--link-compatible` 才采用，结果记录目标文档真实 API identity，并明确其声明性质。

优先级为同一确认身份的权威本地目标、独立 pin 且内容/闭包/范围精确匹配的外部目标、显式允许的兼容映射、未验证参考；`priority`（-1000..1000）仅在相同匹配等级内选展示源，不让人工参考压过精确事实。同优先级冲突报告 ambiguous，改变目录/catalog 枚举顺序不改变结果。`--link-language zh-CN` 限制语言，另加 `--link-language-fallback` 才允许已选 API 身份的其他语言，不借语言回退换 API 版本。原 `[external-docs.*]` 和 /1 索引继续用于显式正文/指南参考，只有 manual 证据，不参与自动依赖版本认证。

资源预算：最多 64 个 catalog 源；旧配置与 catalog 共用 256 个 inventory/document-set 槽位。单个 inventory 不超过 8 MiB，catalog 与 inventory 实际读取共用 32 MiB，单索引最多 32768 条目。外部依赖图累计最多 100000 边，单图最多 16384 边/4096 模块、闭包深度 128；预索引候选 100000 条。源码 import AST 每文件只捕获一次，以选择器索引查询；类型片段、源码 import、闭包/候选元数据的处理共用 262144 步与 32 MiB 字节工作预算，导航诊断最多 4096 条，不逐索引/递归子图重置。失败来源也占声明槽位，超界在读取前拒绝。真实字节变化即使 mtime、路径和版本标签不变也重新绑定；source parse cache 与导航绑定分层，不因文档源变化放弃既有源码缓存。

维护者可复现真实双版本链与负向矩阵，输出目录必须不存在且位于自己的磁盘缓存：

```bash
python3 scripts/accept_dependency_links.py --binary target/release/bin/main --output "$TMPDIR/links-acceptance" --compile-fixtures \
  --chir-worker tools/chir-worker/target/release/bin/main --cjc "<selected-sdk>/bin/cjc"
python3 scripts/accept_dependency_link_rejections.py --binary target/release/bin/main --workspace "$TMPDIR/links-acceptance"
python3 scripts/accept_dependency_scope_references.py --binary target/release/bin/main \
  --output "$TMPDIR/scope-references" --compile-fixtures
```

脚本生成实际不同 API、消费者、质量分母与降级清单、耗时/内存/索引成本和离线 replay；浏览器点击证据须另外采集，脚本不把字符串检查宣称为浏览器验收。

source 模式只采用实际导入绑定：`import library` 可证明 `library.Widget`，包别名也可限定访问；`import library.Widget` 并不引入 `library` 这个包名。普通具名导入还可能与隐式 `std.core` 成员冲突，仅外部 inventory 缺少同名项不能排除这种冲突。因此无法证明时保留原文并记录降级；上面的可选 CHIR 参数明确授权真实 compiler provider，用规范身份验证普通具名导入、别名和嵌套泛型，不把链接成功升级成语义状态。

验收脚本的 `--https-base` 可指向实际 HTTPS 测试部署根（依赖站分别位于其 `v1`、`v2` 子目录）；默认示例域名只检查路由，不声称联网点击成功。HTTP、HTTPS 和 `file://` 浏览器点击须另外记录。Markdown 中的相对外链以生成站点的 `html/` 文档根为基准，独立 symbol-index 自动增加 `html/` 前缀，HTML 内置索引不重复增加。

文档源逐 inventory 隔离损坏项；`CJDOC2312` 报告不可用源，具体引用的 `CJDOC2310` / `CJDOC2311` 解释拒绝原因。无关坏源保持 warning，不阻断其他确定匹配；严格 lint 下失败引用为 error。相同 inventory 的镜像展示位置形成不同的绑定文档集 ID，原始内容身份仍保持不变；同优先级不同目标报告歧义。

以下命令进一步覆盖真实 SDK/stdx、同标签不同构建和工作区选择；两个 SDK 必须是已安装且独立的只读目录，输出目录必须尚不存在。脚本会实际编译受控目标，不把 receipt 的存在当作编译成功证据：

```bash
python3 scripts/accept_official_dependency_links.py --binary target/release/bin/main \
  --sdk "<selected-sdk>" --stdx "<selected-stdx-import-directory>" \
  --target x86_64-unknown-linux-gnu --output "$TMPDIR/official-links"
python3 scripts/accept_dependency_identity_matrix.py --binary target/release/bin/main \
  --sdk-a "<installed-sdk-a>" --sdk-b "<installed-sdk-b>" \
  --stdx-a "<selected-stdx-a>" --stdx-b "<selected-stdx-b>" \
  --output "$TMPDIR/identity-matrix"
```

官方适配验收同时编译具体成员使用，并检查未启用兼容映射、平台范围错误时保留文本。identity matrix 分别编译独立目标；如果实际 cjpm 拒绝同名多版本的组合 workspace 或预发布版本语法，报告保留真实拒绝，不把它们宣传成可编译组合。

Linux 维护者可以进一步验证安装独立的离线重渲染，需系统提供 `strace`、`readelf` 和动态加载器：

```bash
python3 scripts/accept_dependency_offline_runtime.py --binary target/release/bin/main \
  --input "$TMPDIR/links-acceptance/consumer-v1-offline/docs.json" \
  --sdk "<read-only-sdk>" --stdx "<read-only-stdx>" \
  --output "$TMPDIR/offline-runtime"
```

准备阶段只复制运行所需的 ELF 动态库。实际 render 使用私有 runtime、空 PATH、独立 HOME 和临时目录；系统调用追踪拒绝访问原 SDK/stdx、外部索引、网络或 compiler 子进程。当前发行的 standalone 资产仍要求安装 SDK，这个验收 sidecar 不改变发布打包，也不证明跨操作系统/ABI 可移植性。

公开 `DocumentationEngine` 的维护者验收必须真正编译独立调用者，不能用仓库内部 CLI 适配器或仅 `render` 代替。先在同一源码、SDK/stdx 和编译选项环境中构建 CLI，再按既有 provider fixture 的 static path-dependency 方式构建**整套全新导出目录**。普通 executable 构建不发布根 `cjdoc.cjo/libcjdoc.a`；不能将旧 static archive 与新 model/render 混拼：

```bash
cjpm build
(cd tests/fixtures/projects/provider_plugin &&
  cjpm build --target-dir "$TMPDIR/public-static")
python3 scripts/accept_dependency_public_api.py \
  --binary target/release/bin/main \
  --public-artifacts "$TMPDIR/public-static/release" \
  --stdx "$CANGJIE_STDX_PATH" --output "$TMPDIR/public-api-links"
```

上述两个临时目录必须是本次任务的新目录。脚本只读取并逐字节固定完整 `.cjo/.a/.so` 导出，然后独立编译公开调用者与真实 producer/consumer；逐项比较 CLI/API 的完整 Doc IR，覆盖绝对 manifest path、receipt、独立 pin、语言/兼容策略、文档发布修订和宿主工具链伪声明隔离。未 pin 的显式参考只允许明确 `manual`，不能因为能点击就声称 `exact`。

重新生成当前 schema 和 golden 时，先运行 `scripts/update_schemas.sh`，再运行 `scripts/update_goldens.sh`。后者要求项目夹具与已提交的 Git 树逐项一致，再从该提交创建生成快照；历史 `/6`–`/14` 仍只读。比较按规范相对文件名排序，因此 `package-overview` 与 `package-overview-empty` 这样的前缀目录可正常共存。文件内容、可执行位、缺失或额外输入仍参与检查；失败时先处理真实输入差异，不删除夹具或关闭完整性门。
