# 常用用法

这篇说明从源码注释到文档产物的常用操作。你需要先把 `cjdoc` 加入 `PATH`，并在一个包含 `cjpm.toml` 的项目根目录中运行命令。

## 生成 HTML 和 Markdown

HTML 适合直接在浏览器中查看，Markdown 适合提交到仓库或接入现有文档站点。两种格式可以一次生成：

```bash
cjdoc generate --project . \
  --format html \
  --format markdown
```

主要文件位于：

```text
target/doc/html/index.html
target/doc/markdown/index.md
```

打开 `target/doc/html/index.html` 就能查看 HTML 站点。它是静态文件，不需要启动服务器。
代码高亮的语言、配置、离线适配器与安全边界见 [`docs/research/highlighting.md`](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/research/highlighting.md)（面向维护者）。

Doc IR v14 使用独立的 `apiCollectionState` 表示 API 是否完整收集。严格高亮失败仍产生 `CJDOC4027` error、文档 `partial` 和非零生成退出码，但不会改变确定的 API 删除及 `--deny-breaking-api` 门禁结果。旧 v6–v13 输入按原 `status` 保守迁移。`render`、语言切换和版本组合沿用已保存的 API 状态。

包页按声明种类分组，标题中的数量只统计当前 audience/cfg 下可见的直接声明。列表名称使用 Doc IR 中的泛型参数显示 `Entry<T>`、`Map<K, V>` 等身份；模型未提供参数时保留名称，不从签名猜测。扩展仍显示被扩展目标，不冒充新的类型定义。

短签名与名称并排，长签名自动换行；完整原始签名、默认值、高亮与已解析类型链接均保留。摘要最多显示两行，超出时显示省略提示，点击整行或通过 Tab、Enter 打开详情阅读全文。类型链接可独立点击和获得键盘焦点。同质分组不重复显示种类标签，同名跨种类声明和“其他声明”保留标签以区分身份。

## GitHub 源码链接与 HTML 站点

生成源码链接需要显式提供 canonical GitHub HTTPS 仓库根、revision 和可选仓库根目录：

```bash
cjdoc generate --project . --format html \
  --repository-url https://github.com/<owner>/<repo> \
  --repository-revision <commit-or-ref> --repository-root .
```

`repository-url` 与 `repository-revision` 必须成对出现；`repository-root` 还要求这组仓库元数据，只能用于 `generate`，不能用于 `render` 或 `check`。公开 `GenerationRequest` 同样拒绝没有 `RepositoryInfo` 的 `repositoryRoot`。不能证明源码文件位于仓库内时，页面省略 View source action，不生成猜测链接。HTML 站点可直接通过 `file://` 打开，包索引、声明页、搜索类别、主题和移动端抽屉均使用本地资源。

## 写文档注释

把 `/** ... */` 放在声明前面。普通的 `//` 和 `/* ... */` 注释不会绑定到声明。

```cangjie
/**
 * 从文本中读取一个整数。
 *
 * 这里是补充说明，会显示在 summary 后面。
 *
 * @param text 要读取的文本。
 * @return 读取到的整数。
 * @throws IllegalArgumentException 文本不是合法整数时抛出。
 * @since 0.1.0
 */
public func parse(text: String): Int64 {
    return 42
}
````

正文的第一段是 summary，后面的段落是 description。当前支持的结构化标签如下：

| 标签 | 用途 |
|---|---|
| `@param` | 说明参数 |
| `@return` | 说明返回值 |
| `@throws` | 说明可能抛出的异常 |
| `@see` | 添加相关 API 引用 |
| `@since` | 标记 API 引入的版本 |
| `@deprecated` | 标记不再建议使用的 API |
| `@author` | 记录作者 |
| `@version` | 记录 API 版本 |
| `@example` | 添加带可选标题、可选指令的代码示例 |

`@example` 后可以写标题，标题后可以写一个用 `{}` 包裹的指令块，随后使用 Markdown fenced code block 放置示例代码；示例会在 HTML 的“示例”区域单独渲染，在 Markdown 输出中保留代码围栏：

~~~cangjie
/**
 * 计算两个整数的和。
 *
 * @example 基本用法
 * ```cangjie
 * let result = add(1, 2)
 * ```
 *
 * @param left 左侧数值。
 * @param right 右侧数值。
 * @return 两数之和。
 */
~~~

示例内容会持续到下一个顶层结构化标签（例如 `@param` 或 `@return`）；代码围栏内部出现的 `@param` 等文本会保持为示例代码，不会被误解析成文档标签。

默认情况下，`@example` 只负责收集、清理并渲染示例内容，指令块只是随注释一起记录在 Doc IR 的 `directives` 字段中，不会改变输出。需要校验示例中的 API、参数和类型时，可显式启用 `--check-examples`：cjdoc 会把每个语言标记为 `cangjie` 的 fenced code block 放入声明所属的源码包中，调用 `cjc` 进行编译校验，并按指令决定是否运行。没有该开关时指令完全不生效，既不会编译也不会运行示例。编译失败会产生 error，缺少 `cangjie` fenced code block 会产生 warning；其他语言的代码块不会参与校验。该选项要求 `cjc` 已在 `PATH` 中，且示例应是可以放入函数体的代码片段。`@see` 引用仍会参与符号解析和文档 lint。

指令块写在 `@example` 标题之后，用 `{}` 包裹，指令之间用空格分隔；需要值的指令写成 `name="value"`：

| 指令 | 含义 |
|---|---|
| `must-pass` | 显式固定“该示例必须编译通过，并且必须真的被检查过” |
| `must-fail` | 该示例必须编译失败，并且失败必须发生在示例代码之内 |
| `error="…"` | 与 `must-fail` 搭配，要求编译器输出包含该片段 |
| `run` | 编译通过后把示例作为可执行程序运行，要求退出码为 0 |
| `flags="…"` | 为该示例的 `cjc` 调用追加选项，只接受下面的白名单 |

指令名区分大小写，不允许重复。`must-pass` 与 `must-fail` 互斥，`run` 不能与 `must-fail` 同时出现，`error=` 必须搭配 `must-fail`。语法错误、冲突、未知指令以及白名单之外的选项都会产生 `CJDOC3033`，此时该示例不会被排队编译：

~~~cangjie
/**
 * 计算两个整数的和。
 *
 * @example 故意失败的用法 {must-fail error="undeclared identifier"}
 * ```cangjie
 * let result = missingApi(1, 2)
 * ```
 *
 * @example 基本用法 {run flags="--int-overflow wrapping"}
 * ```cangjie
 * println(add(1, 2))
 * ```
 * ```output
 * 3
 * ```
 */
~~~

`flags="…"` 允许的 `cjc` 选项：

- `--cfg KEY=VALUE`：`KEY` 是标识符，`VALUE` 只含字母、数字与 `_.+-`。内置键名（如 `os`、`arch`）不在这里重复列举，由 `cjc` 拒绝。
- `-Woff GROUP` 与 `-Won GROUP`：`all`、`unused`、`unused-main`、`deprecated`、`unsupport-compile-source`、`package-import`、`parser`、`semantics`、`interpreter`、`apilevel-check`。`driver-arg` 不在列表中，因为它会掩盖上一条里的错误。
- `--int-overflow MODE`：`throwing`、`wrapping`、`saturating`。
- 单独出现的 `--experimental`、`-O0`、`-O1`、`-O2`、`-Os`、`-Oz`。

输出路径与源文件列表仍由 cjdoc 掌握，因此 `-o`、`--output-type`、`-p`、`-L`、`-l`、`--import-path`、`@file` 等一律被拒绝。

检查示例时会复制声明文件的 import，并保留附着的 `@When[...]` 条件；由本次真实 `cjc` 配置决定 import 是否生效，不会把未选中的平台 import 变成无条件依赖。

每个示例的 `flags="…"` 同时用于声明包和所有捕获的传递依赖。相同有序 flag 集共享依赖产物，不同 flag 集分别编译并隔离产物；示例 flags 不改变 Doc IR 的源码选择，文档条件仍由请求的 `--cfg` 决定。

带 `run` 的示例可以额外使用语言标记为 `output` 的 fenced code block 固定标准输出：每个示例最多一个 `output` 块，且必须同时带 `run`，否则产生 `CJDOC3033`。比较前两侧都会统一换行符并去掉首尾空行，因此 `println` 结尾的那一个换行不需要写出。示例本身会被包装进一个无参数的 `main`，所以引用 `args` 的示例无法通过编译；需要 `exit` 等函数时，`import` 写在示例所属的源码文件里。源码中当前配置选中的 `main` 会保留为普通函数，原返回类型不变，由示例包装器提供入口；未选中的条件入口不参与替换。命令行 `--cfg os=…` 与 `--cfg arch=…` 必须匹配构建目标，匹配值不会再转发给 `cjc --cfg`，其他用户配置正常转发。 内置 `debug` 的默认值按实际 `cjc` 调用取 `false`（示例标志白名单不允许 `-g`），所以互补的 `@When[debug]` / `@When[!debug]` 入口只替换 release 分支。

运行时的限制是固定的：单次运行上限 10 秒，stdout 与 stderr 各上限 64 KiB，一次检查最多 256 个示例。Linux 通过 `prlimit` 为每个运行进程设置 2048 MiB 地址空间上限，Windows 为进程树设置 2048 MiB Job 内存上限；无法建立限制时在启动示例前失败，不会无界运行。当前 macOS 无法提供这项地址空间限制，因此 `{run}` 示例被拒绝并报告 `CJDOC3074`，不会尝试运行用户代码。超限导致非零退出时报告 `CJDOC3071`。可执行文件用 `--static --output-type exe` 构建，这样示例即使没有把 SDK 运行库放进 `LD_LIBRARY_PATH` 也能运行。静态链接不可用的环境会报告 `CJDOC3074`。

固定结果但检查没有真正发生，同样算失败：`CJDOC3070` 表示固定结果的检查没有真正发生，例如因为数量限制或临时目录问题而被跳过；`CJDOC3071` 表示运行退出码非 0；`CJDOC3072` 表示 stdout 与 `output` 块不一致；`CJDOC3073` 表示超过运行时限被终止；`CJDOC3074` 表示构建或执行准备失败，包括无法建立所需的内存限制；`CJDOC3075` 表示输出超过上限。

文档注释应紧邻它描述的声明。默认生成 external 文档，所以示例声明应为 `public` 或 `protected`。

## 重新生成文档

修改注释后，再运行原来的命令：

```bash
cjdoc generate --project . --format html
```

然后刷新 `target/doc/html/index.html`。默认缓存放在 `target/cjdoc/cache/source-v11`，通常不需要手动处理。

## 选择语义后端

普通生成默认使用 `source` 模式。CHIR enrichment 通过独立可执行 worker 实现；worker package 位于 cjdoc 源码仓库的 `tools/chir-worker`，只有该 package 导入 `stdx.chir`。在配置好相同 Cangjie 与 stdx target 的环境中先构建 worker：

```bash
(cd tools/chir-worker && cjpm build)
cjdoc generate --project . --semantic chir \
  --chir-worker tools/chir-worker/target/release/bin/main \
  --format json --stdout
```

Windows worker executable 带有 `.exe` 后缀。CHIR 模式从本次源码快照编译 raw CHIR，不读取 host 上未捕获的源文件；可用 `--cjc <path>` 指定 compiler，并可重复传入 `--chir-import-path <dir>`。worker 未配置或 compiler、输入构建约束、artifact/worker 协议、overload 映射失败时，会产生 `CJDOC2101`–`CJDOC2106` warning。任何 CHIR 失败都会保留 source declarations；注释和最终 Doc IR 仍由源码路径决定。

CHIR 的 `--cfg os=…`、`--cfg arch=…`、`--cfg debug=…` 必须与实际原生编译目标及默认 release 模式匹配；这些内置键只参与验证，不会作为用户 `cjc --cfg` 参数转发。普通用户自定义 cfg 仍会传给 worker。内置选择不匹配时报告 `CJDOC2102` 并保留源码 fallback。

每个模块及递归依赖的 `compile-option` / `override-compile-option` 都会完整检查，包括普通 key、单引号或双引号 key（以及合法的 Unicode 转义）和带注释的多行数组。任一元素包含不受支持的编译选项（如 `-p` 或 `-B`）时，在启动 worker 前报告 `CJDOC2102`，不会用忽略该构建约束的 CHIR 结果补充声明。

`render` 只读取已有 Doc IR，因此不能选择 semantic backend。

## 检查文档问题

`check` 只检查源码、声明绑定、引用和 lint，不生成 HTML 或 Markdown：

```bash
cjdoc check --project .
```

同时编译校验（并按指令运行）API 示例：

```bash
cjdoc check --project . --check-examples
```

`--check-examples` 是显式开关，不会改变普通 `generate` 或 `check` 的默认行为；没有它时 `@example` 指令完全不生效。开启后，默认只做编译，不执行示例；只有带 `run` 的示例才会被构建为可执行文件并运行。源码包本身无法由 `cjc` 编译时，诊断会区分为上下文编译失败（`CJDOC3031`）而不是示例失败。

准备提交或发布前，可以提高 lint 要求，并把 warning 也视为失败：

```bash
cjdoc check --project . \
  --lint-profile strict \
  --deny-warnings
```

退出码含义如下：

| 退出码 | 含义 |
|---:|---|
| `0` | 没有被当前规则拒绝的诊断 |
| `1` | 存在 error，或 warning 被 `--deny-warnings` 提升 |
| `2` | CLI 参数或输入错误 |

## 生成 JSON

JSON 适合交给其他工具处理，默认文件是 `target/doc/docs.json`：

```bash
cjdoc generate --project . --format json
```

如果要把 JSON 直接交给管道，使用 `--stdout`：

```bash
cjdoc generate --project . --format json --stdout > docs.json
```


`--stdout` 只能与一个 JSON 格式一起使用。诊断写入 stderr，所以重定向后的 `docs.json` 仍是单个 JSON 文档。

## 运行 doctest

`@example` 标签中的 ` ```cj ` 或 ` ```cangjie ` fenced code 可以选择性执行。项目根的 `cjdoc.toml` 使用独立的 `[doctest]` 表：

```toml
[doctest]
mode = "warn"       # off（默认）、warn 或 deny
timeout-ms = 2000
memory-mb = 2048    # Cangjie native backend requires at least 2048 MiB
jobs = 1
```

`warn` 会继续生成并返回 `0`，`deny` 在编译失败、运行失败或超时后返回 `1`。生成目录会增加 `doctest/results.json`，其版本为 `cjdoc.doctest/2`；`check` 会执行检查但不写 artifact。每个代码块在独立工作目录编译和运行，命令通过参数数组传递，不经过 shell。启用 doctest 时不能使用 `--stdout`，因为该选项必须保持单一 JSON 输出。

上述 `warn` 行为适用于已执行示例的结果；执行准备失败仍会报错。这条 legacy 管线通过 `/usr/bin/prlimit` 或 `/bin/prlimit` 实施正数地址空间上限。当前 macOS、Windows 环境没有该限制器，因此会在启动编译进程前明确拒绝，不会自动取消内存限制；这与 `check --check-examples` 的平台能力分别判断。

## 生成 API surface 和 coverage

用 `api-surface` 保存公开 API 的稳定快照：

```bash
cjdoc generate --project . --format api-surface --stdout > api-surface.json
```

用 `diff` 比较两个 API snapshot。它先按稳定 symbol id 匹配，再用模块、包、owner、kind、name 做唯一回退匹配；证据不足时报告 `potentially-breaking`，不会假装已经证明 breaking：

```bash
cjdoc diff --baseline api-surface.json --current api-surface-next.json --format text --deny-breaking-api --deny-potentially-breaking-api
```

默认只报告差异并返回 `0`。显式 deny 选项分别把 breaking 或证据不足的 potentially-breaking 变更变成失败；`--format json` 输出 `cjdoc.api-diff/2` 报告，适合 CI 采集。v1/v2 API snapshot 仍可作为只读 baseline 输入；当前生成器只生成 v3。

用 `coverage` 查看当前版本的文档覆盖率。输出版本为 `cjdoc.documentation-coverage/2`，包含 symbols、parameters、returns、throws、examples、deprecated、semanticLinks 七类总览，并按 package/module 给出确定性分组：

```bash
cjdoc generate --project . --format coverage --stdout
```

输出到目录时，`coverage` 还会生成独立的 `coverage/quality.json`。`--stdout` 保持输出原有的 presence coverage；规则与指标说明见[文档质量检查](documentation-quality.md)。

这两个命令默认使用 `external` audience。需要把它们接入 CI 时，见 [`docs/advanced-usage.md`](advanced-usage.md#在-ci-中检查-api-和文档覆盖率)。

## 查看已有 JSON

如果已经有 `docs.json`，可以只重新生成 HTML 或 Markdown，不重新扫描源码：

```bash
cjdoc render \
  --input target/doc/docs.json \
  --format html \
  --format markdown \
  --output target/rendered-doc
```

`render` 读取并验证输入的 Doc IR。输出目录应使用一个尚不存在的目录，或使用之前由 cjdoc 管理的目录；不要把包含无关文件的目录直接交给 cjdoc。

### Schema 与旧版迁移

当前 JSON 输出版本是 `cjdoc.doc-ir/15`。`render` 严格验证 v6–v14 的原始 schema 后迁移为 v15；未知属性、重复 JSON 键和不满足原版本约束的输入会被拒绝。迁移保留已有源码与语义事实，新增 `dependencies`、`documentSets` 为空数组，类型、标签、语言正文和正文引用的导航事实为空，不从旧版的名称、版本标签或已有 URL 推造依赖身份。

根字段 `apiCollectionState` 为 `resolved`、`partial` 或 `unavailable`，独立于展示用 `status`。生成时在 source/provider 绑定后、highlight/lint/i18n/导航处理前采集；呈现错误不会把已采集的 API 改为不完整。v14 输入保留已有值；v6–v13 缺少该字段时仅按历史 `status` 映射（`complete` → `resolved`，`partial` → `partial`）。公开 `DocumentationSet` 的同名字段是不可变 `String`；构造器命名参数为 `apiCollectionState!: ?String = None`，省略时使用相同历史映射，显式值必须属于上述枚举。

查看当前 schema、指定版本 schema 或支持的 schema 名称：

```bash
cjdoc schema doc-ir
cjdoc schema doc-ir-v15
cjdoc schema doc-ir-v14
cjdoc schema doc-ir-v13
cjdoc schema symbol-index
cjdoc schema list
```

`generator.toolchain` 与目标项目 compiler/std/stdx 身份分离。自动生成和旧版迁移都将它留为空字符串，因为运行时 compiler 路径或版本不能认证实际链接的 parser SDK 构建；公开 API 中调用者填写的非空值也只是声明，不会自动成为认证事实。

`TypeRef.semantic` 继续描述语义证据。独立的 `navigation` 描述文档链接决策：`resolved`、`unresolved`、`ambiguous` 或 `unavailable`；`matchLevel` 为 `exact`、`compatible`、`manual` 或 `none`，`reason` 说明依据。找到文档链接不会把 unavailable/partial 语义升级为 resolved。正文显式引用保留相同事实于 `semanticNavigation`。

指南的 `DocumentationPageBinding.navigation` 也使用独立、可空的 `TypeNavigation`。原有 `state` 与 `targetSymbolId` 仍只描述本地 API 关联，外部链接解析成功不会把 `unresolved` 关联冒充为本地 `resolved`。current15 的每个 binding 必须编码 `navigation`（无导航写 `null`）；严格6–14输入迁移后该字段为空。受众或条件编译隐藏的关联不得保留 resolved 外链。

`symbol-index` 当前输出 `cjdoc.symbol-index/2`，HTML 内嵌索引和独立索引共用生产逻辑。顶层 `dependencies` 保存依赖实例证据，`documentSets` 保存文档集的内容身份与可移植来源；每项的 `identity` 来自对应模块的自身内容快照，`documentSetId` 指向文档集。文档版本标签只用于展示，不能代替内容身份。

`DependencyInstance.moduleId` 是依赖边的 owner，`componentModuleId` 指向实际选中的 source-graph 模块；binary 或未知选择保留空字符串。`DocumentSetIdentity.moduleId` 是 producer 库存描述的模块 ID，作用域由该库存的 `indexIdentity` 限定，不能与 consumer 模块 ID 直接等同。v15 Doc IR 和当前 `/2` 库存要求编码这两个字段；缺少图绑定字段的旧 `/2` 库存只能作为 manual 参考，不能仅凭相同源码、版本或自身内容身份获得 exact 匹配。

根 `DocumentationSet.documentationRevision` 是独立的文档发布标记，构造器命名参数默认 `""`，不放入 `GeneratorInfo`。`DocumentSetIdentity.apiVersion` 保存对应 API 包声明的版本，`revision` 保留 API 源码 revision，`documentationRevision` 单独保存文档发布 revision；新增命名参数 `apiVersion`、`documentationRevision` 均默认 `""`。这些版本字符串不等于官方发行认证，不能替代内容身份或库存 pin。生产库存时 API 包版本取自身依赖记录的 `version`，文档 revision 取文档根对象；未知值保持空字符串。v6–v14 迁移不补造文档发布 revision，也不会生成虚构依赖或文档集。

跨根项目与依赖的精确符号键是 `完整包限定名|kind|泛型参数数目(参数类型源码拼写,...)`。已有包前缀不会重复添加；例如 `fixture.Box|class|1()` 和 `fixture.Box.add|function|0(Int64)`。它与包含模块角色的本地 `id` 分离，重载保留不同参数键。HTML 内嵌索引的 href 不带 `html/` 前缀，独立索引带该前缀。

维护 schema 时修改 `src/schema_data/`，构建后运行 `bash scripts/update_schemas.sh` 同步 `docs/schema/`；运行 `bash scripts/update_goldens.sh` 生成 `tests/fixtures/golden-v15/`。已发布 v6–v14 schema/golden 为只读迁移输入，v13/v14 另有 `tests/fixtures/legacy13/`、`tests/fixtures/legacy14/` 字节冻结副本；不要手工修改 current golden。

## 常见问题

### 页面没有声明

确认声明是 `public` 或 `protected`，并且使用的是 `/** ... */`。默认 `external` audience 会隐藏 private 声明。查看内部 API 时运行：

```bash
cjdoc generate --project . --format html --audience all
```

### 生成结果是 partial

这表示部分源码、语义信息或引用没有完整解析。先查看命令输出的诊断，再确认是否需要为条件编译传入 `--cfg`，或是否需要把依赖源码显式纳入扫描范围。生成器会保留能够解析的部分，不会把不确定信息标成已解析。

### 输出目录报所有权或冲突错误

首次生成时不要预先创建 `target/doc`。cjdoc 会验证输出目录的所有权，并拒绝覆盖无法确认归属的内容。换用一个不存在的新输出目录；再次生成时，可以继续使用此前由 cjdoc 管理的目录。已有目录中的内容需要被明确采用时，见 [`高级用法`](advanced-usage.md#管理输出目录)。

## 下一步

需要处理 workspace、依赖、条件编译、缓存、多个输出格式或 CI 时，继续阅读 [`docs/advanced-usage.md`](advanced-usage.md)。

## 生成中英文作者正文

使用 `--locale en` 选择单语言读取视图，或配置 `[i18n]` 后用 `--all-languages` 分析一次并生成独立语言目录。语法、缺译策略和可运行示例见 [生成中英文文档](i18n.md)。
