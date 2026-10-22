# 跨文档链接与依赖身份

本文面向维护者，记录依赖/外部文档链接如何被证明：`--doc-source`、`--doc-inventory-pin`、`--build-context` 的契约，identity 与 pin 的边界，官方快照准备（DL05）、E2E2 独立链路、验收脚本和资源预算。使用者级用法见[高级用法](../advanced-usage.md)；本文不重复基础命令。

## 输入契约

`generate` 和 `check` 接受下列输入；公共 `GenerationRequest` 提供同名 camelCase 参数：

| CLI | API 参数与默认值 | 用途 |
|---|---|---|
| `--build-context <record.json>` | `buildContext: ?String = None` | 目标项目的本地构建输入记录，不是 cjdoc 自身 SDK 的记录 |
| `--doc-source <catalog-or-dir>`（可重复） | `documentSources: Array<String> = []` | 显式本地文档目录或 catalog；生成期不联网 |
| `--doc-inventory-pin PATH=SHA256`（可重复） | `documentInventoryPins: Array<DocumentInventoryPin> = []` | 调用方独立信任的完整 inventory 字节摘要；不接受 publisher 自报摘要授权 |
| `--link-language <lang>` | `linkLanguage: String = ""` | 外部文档链接语言；空值不限制语言，等优先级不同目标仍报告歧义 |
| `--link-language-fallback` | `linkLanguageFallback: Bool = false` | 显式允许语言回退 |
| `--link-compatible` | `linkCompatible: Bool = false` | 显式允许兼容匹配；不是默认 exact 匹配 |

`--doc-version` 只用于 `generate`/`render` 且要求 `--format html`，它只填 `documentationRevision`，不决定依赖 API 版本。目录型 `--doc-source` 读取固定文件名 `cjdoc-documents.json`；文件型输入直接读 catalog。catalog 里的索引路径必须是 catalog 目录内的规范相对路径。

旧的 `[external-docs.*]` 配置与 `/1` 索引仍可用于显式正文/指南参考，但只有 `manual` 证据，不参与自动依赖版本认证。

## catalog 与 inventory pin

`cjdoc-documents.json` 的格式是 `cjdoc.doc-sources/1`：

```json
{
  "schemaVersion": "cjdoc.doc-sources/1",
  "documents": [
    {"index": "library-v1-site/html/symbol-index.json", "baseUrl": "https://docs.example.test/api/v1", "priority": 0},
    {"index": "library-v2-site/html/symbol-index.json", "baseUrl": "https://docs.example.test/api/v2", "priority": 0}
  ]
}
```

先对每个实际依赖版本各生成一次站点（`--format html --format symbol-index`），再从受信任的本地生成过程或独立可信渠道取得 inventory SHA-256，把摘要作为 pin 传给消费者：

```bash
cjdoc generate --project library-v1 --format html --format symbol-index --output library-v1-site
cjdoc generate --project library-v2 --format html --format symbol-index --output library-v2-site
read -r PIN_V1 _ < <(sha256sum library-v1-site/html/symbol-index.json)
read -r PIN_V2 _ < <(sha256sum library-v2-site/html/symbol-index.json)
cjdoc generate --project consumer --doc-source ../cjdoc-documents.json \
  --doc-inventory-pin "../library-v1-site/html/symbol-index.json=$PIN_V1" \
  --doc-inventory-pin "../library-v2-site/html/symbol-index.json=$PIN_V2" \
  --output "$PWD/consumer-site" --format html --format markdown --format json
cjdoc render --input consumer-site/docs.json --output replay --format html --format markdown
```

公开 API 接收同一组独立 pin：

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

关键语义：

- pin 必须来自调用方独立的摘要；catalog/inventory 自报的摘要不能给自己授权。pin 的真实性只追溯到操作者信任的摘要，不能抵御控制该摘要的人，也不证明远端 HTML 的实际部署。
- `exact` 必须同时满足调用方 pin、实际依赖内容、所选源码依赖闭包与 target/cfg/audience 范围；缺少独立 pin 最多是 `manual`。publisher 的 `state`/`source` 字符串不会升级证据。
- `compatible` 只是显式适用映射，不认证 ABI 或行为；只有加 `--link-compatible` 才采用。
- 没有实际项目依赖的纯文档引用仍可按显式源提供 `manual` 参考链接，但 `dependencyInstanceId` 为空，不能为项目新增依赖事实。
- 合法 catalog `baseUrl` 可选择展示位置；它进入文档集 ID/绑定输入，但不反改 pin 覆盖的相对 symbol route、key、API identity 或范围。`baseUrl` 拒绝 query/fragment。

## identity 语义

- `DocumentSetIdentity.moduleId` 是 producer inventory 内的指针，由该 inventory 的 `indexIdentity` 限定；不假定它等于消费者的 module ID。
- `library` 是包含组织限定符的根包作用域；import/包别名先绑定到实际选中的源码包，再比较文档身份。
- 跨根项目与依赖的精确符号键是 `完整包限定名|kind|泛型参数数目(参数类型源码拼写,...)`，例如 `fixture.Box|class|1()`；没有精确重载或同优先级目标冲突时不选第一个。
- `apiVersion` 只保留 producer 包清单的版本声明，`revision` 是 API 源码 revision 声明，`documentationRevision` 是独立的文档发布修订；三者都不以标签代替内容/作用域证据，未知为空字符串。文档集版本声明若与其自带源码快照的同一清单声明矛盾，该 inventory 拒绝而不是改写身份。
- 资源回退保留仍可编码的文档发布修订；若该可选字符串本身超过字符串或完整文档预算，回退会留空并保留 `CJDOC3027` 资源失败事实。正常可表示的修订不被删除，也不会因为回退升级为已验证的 API 身份。

## 选择、冲突与歧义

优先级从高到低：同一确认身份的权威本地目标 → 独立 pin 且内容/闭包/范围精确匹配的外部目标 → 显式允许的兼容映射 → 未验证参考。`priority`（-1000..1000）只在相同匹配等级内选展示源，不让人工参考压过精确事实。

- 身份不匹配时保留文本，不改选 latest 或相邻版本。
- 若确有范围依据，可在单个 documents 项下加 `compatibilityMappings`，成员为 `fromIdentity`、`toIdentity`、`target`、`cfg`、非空 `evidence`；target/cfg 必须对应当前目标。传递依赖/构建上下文不同时，`fromIdentity` 必须精确设为消费者的 `dependencies[].instanceId`，裸源码 identity 映射不能掩盖差异。任何 conflict 都不能由兼容映射覆盖。
- 同优先级不同目标报告 `ambiguous`；改变目录/catalog 枚举顺序不改变结果。相同 inventory 的镜像展示位置形成不同的绑定文档集 ID，原始内容身份保持不变。
- `--link-language zh-CN` 限制语言，另加 `--link-language-fallback` 才允许已选 API 身份的其他语言，不借语言回退换 API 版本。
- 缓存目录存在、包声明版本或 cjdoc 的 SDK 版本都不能单独证明选中身份；普通版本/Git/lock 声明保留为 `declared`，目标 compiler/std/stdx 默认 `unknown`。

## 构建记录 `cjdoc.build-context/1`

没有构建记录时，`dependencies` 仍包含项目自身、workspace 与 manifest path/显式 `--dependency-source` 的内容观察。需要把实际构建输入绑定到链接证据时，先用脚本生成记录（路径、模块名和 target 必须替换成该次构建真正使用的值，不能填写 cjdoc 的构建 SDK）：

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

- 记录格式只接受 `schemaVersion`、`project`、`target`、`cfg`、`modules`；重复键和未知字段拒绝。模块 dependency 的 `kind` 为 `source`、`binary`、`std`、`stdx` 或 `toolchain`，必填 `name`、`kind`、`path`、`identity`，可选 `content`、`version`、`revision`。
- 源码 identity 是排序的相对 `.cj`、`cjpm.toml`、`cjpm.lock` 库存与实际字节的 SHA-256；目录 artifact 观察所有非隐藏文件。时间、绝对根路径不参与 identity。记录限 4 MiB、4096 模块、每模块最多 16384 依赖；观察与 receipt 复核共用累计 512 MiB I/O/work 预算。
- 记录可能含本地路径，**不能直接提交或发布**。
- cjdoc 会重新读取字节与记录逐项比较；`observed` 只表示观察到字节，`verified` 表示显式选择记录与观察及 project/configuration 绑定一致，**不表示独立证明构建执行过或成功过**。
- 项目变化、lock 与选中源码版本不一致或记录摘要过期产生 `conflict` 和 `CJDOC2301`；格式/模块绑定错误为 `CJDOC2300`；无法观察/超界为 `CJDOC2302`。格式或 project/configuration 绑定无效的 receipt 整体拒绝。

生成后检查 `docs.json` 的 `dependencies`：每项含 owner `moduleId`、稳定 `instanceId`、`identity`、`kind`、`state`、`evidence`、`target`、`cfg` 与 `componentModuleId`。实例 ID 纳入该组件的传递源码/构建上下文，不能把相同自身源码、不同传递依赖混为一例。

## 官方快照准备（DL05）

官方资料适配器是独立的 Python 3.10+ 标准库脚本，不在 `generate`、`render` 或 `check` 中联网。它只收录 manifest 中逐项核实的符号；当前审查范围是 std.collection 的 `ArrayDeque<T>` / `capacity` 和 stdx.encoding.json 的 `JsonArray` / `add(JsonValue)`，不是 std/stdx 全库。新增资料需重新审查 `OFFICIAL_PAGES` 映射和声明证据。

用仓库保存的最小官方资料摘录离线生成索引和分类页：

```bash
python3 scripts/prepare_official_inventory.py \
  --manifest tests/fixtures/external_docs/official83/manifest.json \
  --bundle tests/fixtures/external_docs/official83 \
  --output target/official83/symbol-index.json \
  --html-output target/official83/official-pages
```

成功信号是 `prepared 4 source-verified entries in 2 document sets`；索引格式为 `cjdoc.symbol-index/2`。`--html-output` 必须与索引位于同一父目录；生成的分类页与原始资料行一一对应。不传该选项时条目使用固定 GitHub Markdown 文档的 `?plain=1#L...` 源码行链接（`plain=1` 不能省略），这些不是官方 HTML API 站的锚点。

需要重新从网络取回同一份资料时，显式指定 `--download`，并把 bundle 写入自己的缓存目录，而不是改动仓库 fixture：

```bash
python3 scripts/prepare_official_inventory.py \
  --manifest tests/fixtures/external_docs/official83/manifest.json \
  --bundle target/official83/source-bundle \
  --output target/official83/symbol-index.json \
  --html-output target/official83/official-pages \
  --download
```

下载仅允许 `raw.githubusercontent.com/cangjielanguage/{cangjie_runtime,cangjie_stdx}/<完整 commit SHA>/...` 的文档路径，拒绝重定向、凭据、非 HTTPS、任意主机及环境代理。先核对完整上游文件 SHA-256，再截取并核对摘录 SHA-256；离线模式只核对已有摘录，不把本地摘录校验冒充一次新的上游下载校验。manifest 必须来自已审查的可信来源：哈希保证与该 manifest 一致，不替代发布者认证。限制为 manifest 1 MiB、单个来源 4 MiB、累计来源 16 MiB、64 个来源及 4096 条目。

固定来源（证据见 `tests/fixtures/external_docs/official83/manifest.json` 与同目录 `NOTICE`）：

| 资料 | 来源 commit | 分类源文件 SHA-256 |
|---|---|---|
| std | `cangjielanguage/cangjie_runtime` `c844ec7556f9ab624e6a052c550444d695c44f2e` | `cdba440a9b30fb148dc2cc5307a5574baf9b5c9f26c35735556d399fdab26d45` |
| stdx | `cangjielanguage/cangjie_stdx` `f74bb5953547e51edff8904ae3db75ad47f17f06` | `7f9a196a8432da04125ae2599279065e95f06634389ac7a9ca5d8b79abb7362f` |

证据边界：这一级核验只证明“固定官方文档源文件中有此类型/成员及该源行”，不证明“目标 SDK 导出的 API 与资料完全一致”。索引的 documentSets 使用文档内容 identity、`state=declared`、空 target/cfg；条目保留 `semanticState=partial`，provenance 的 SDK 映射为 `none`。已核实的文档 commit 只填 `documentationRevision`，不从文档 commit、文件摘要或 README 版本名推断安装 SDK 的 std/stdx 身份。使用者只有在外部 catalog 中显式声明对应来源映射后才能采用这些链接；手工映射必须保持 declared，不得升级为 exact。

维护者可运行纯 Python 离线测试，不需要 Cangjie SDK：

```bash
python3 -m unittest discover -s scripts -p 'test_prepare_official_inventory.py'
```

## E2E2：从固定官方 Cangjie 源码生成库存

上面的官方 Markdown 适配库存不能替代“由 cjdoc 自己扫描真实 std/stdx Cangjie 源码生成的库存”。维护者可用第二条独立链路，保留两条链路不同的证据等级。

先显式联网准备三个固定源码文件及两个仓库原始许可证；`<work>` 是私有磁盘临时目录，`source-projects` 尚不存在：

```bash
python3 scripts/prepare_std_source_snapshot.py \
  --cache <work>/upstream-cache \
  --output <work>/source-projects \
  --download
```

| 来源 | 完整未改写源码 | SHA-256 |
|---|---|---|
| runtime `c844ec7556f9ab624e6a052c550444d695c44f2e` | `stdlib/libs/std/collection/array_deque.cj` | `3c6b754a5de5bb61678265124584bd16bb7414613db0c939937ab0c2228f1348` |
| stdx `f74bb5953547e51edff8904ae3db75ad47f17f06` | `src/stdx/encoding/json/json_object.cj` | `41d9de5923696f575e08ce75e71c023424ba7b1b793eeffeff1461be23134584` |
| stdx 同一 commit | `src/stdx/encoding/json/json_value.cj` | `87d8fb0674a24b9b04bc9789970dd3049ed7d43b50d3e933f26fe988d563b9b6` |

脚本只允许代码中固定的 HTTPS URI，下载核验沿用拒绝重定向和代理的实现；原样保留 Apache-2.0 with Runtime Library Exception 源码头与完整 LICENSE，输出 `source-provenance.json`，不裁剪声明、不补桩、不手写 index entries。这三个文件不是可独立构建的 std/stdx 包，也不是安装 SDK 的源码认证。

然后在已显式选择并准备好的 SDK 环境中串行运行验收脚本；`<sdk>` 是实际编译目标项目所选的 SDK 根，`<stdx-import>` 是独立选中的静态 stdx `.cjo` 目录，不要用文档生成器的 SDK 身份替代目标构建身份：

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

该脚本不重建 cjdoc、不构建/改动 SDK。它实际调用当前 cjdoc 分别扫描真实源码，生成两份未经手改的 HTML 和 `symbol-index/2`，检查 `ArrayDeque`/`capacity`、`JsonArray`/`add(JsonValue)` 的真实条目和页面/锚点；随后编译私有 consumer，通过 build-context 分别观察实际 `std.collection.cjo`、`stdx.encoding.json.cjo` 与 compiler，再以显式 `compatibilityMappings` 和 `--link-compatible` 接入这两份自生成库存，并检查未 opt-in 和错误 target 的映射不能解析为外部链接。

结果位于 `summary.json`、`evidence/` 和 `site/html/`；后者包含从 producer 原样复制的 `generated-std/`、`generated-stdx/` 目标页，便于独立执行本地与 HTTP 浏览器点击验证。脚本的 PASS 不声明浏览器已执行。真实源码 commit 只作为源码 provenance 保存；未提供给生成器的 API revision 保持空值，独立文档发布标记为 `source-subset-documentation`。库存 source identity 只覆盖实际扫描的源码子集；consumer 的 installed artifact identity 与它不同，映射因此只允许 compatible，不是 exact、官方发行映射、全库覆盖或 API/ABI/行为等价证明。

## 验收脚本

双版本链与负向矩阵（输出目录必须不存在，位于自己的磁盘缓存）：

```bash
python3 scripts/accept_dependency_links.py --binary target/release/bin/main --output "$TMPDIR/links-acceptance" --compile-fixtures \
  --chir-worker tools/chir-worker/target/release/bin/main --cjc "<selected-sdk>/bin/cjc"
python3 scripts/accept_dependency_link_rejections.py --binary target/release/bin/main --workspace "$TMPDIR/links-acceptance"
python3 scripts/accept_dependency_scope_references.py --binary target/release/bin/main \
  --output "$TMPDIR/scope-references" --compile-fixtures
```

脚本生成实际不同 API、消费者、质量分母与降级清单、耗时/内存/索引成本和离线 replay；浏览器点击证据须另外采集，脚本不把字符串检查宣称为浏览器验收。

真实 SDK/stdx、同标签不同构建和工作区选择：

```bash
python3 scripts/accept_official_dependency_links.py --binary target/release/bin/main \
  --sdk "<selected-sdk>" --stdx "<selected-stdx-import-directory>" \
  --target x86_64-unknown-linux-gnu --output "$TMPDIR/official-links"
python3 scripts/accept_dependency_identity_matrix.py --binary target/release/bin/main \
  --sdk-a "<installed-sdk-a>" --sdk-b "<installed-sdk-b>" \
  --stdx-a "<selected-stdx-a>" --stdx-b "<selected-stdx-b>" \
  --output "$TMPDIR/identity-matrix"
```

两个 SDK 必须是已安装且独立的只读目录；官方适配验收同时编译具体成员使用，并检查未启用兼容映射、平台范围错误时保留文本。identity matrix 分别编译独立目标；如果实际 cjpm 拒绝同名多版本组合 workspace 或预发布版本语法，报告保留真实拒绝，不把它们宣传成可编译组合。

Linux 维护者可以进一步验证安装独立的离线重渲染（需要 `strace`、`readelf` 和动态加载器）：

```bash
python3 scripts/accept_dependency_offline_runtime.py --binary target/release/bin/main \
  --input "$TMPDIR/links-acceptance/consumer-v1-offline/docs.json" \
  --sdk "<read-only-sdk>" --stdx "<read-only-stdx>" \
  --output "$TMPDIR/offline-runtime"
```

准备阶段只复制运行所需的 ELF 动态库；实际 render 使用私有 runtime、空 PATH、独立 HOME 和临时目录，系统调用追踪拒绝访问原 SDK/stdx、外部索引、网络或 compiler 子进程。当前发行的 standalone 资产仍要求安装 SDK，这个验收 sidecar 不改变发布打包，也不证明跨操作系统/ABI 可移植性。

公开 `DocumentationEngine` 的维护者验收必须真正编译独立调用者，不能用仓库内部 CLI 适配器或仅 `render` 代替。先在同一源码/SDK/stdx/编译选项环境构建 CLI，再按 provider fixture 的 static path-dependency 方式构建整套全新导出目录（普通 executable 构建不发布根 `cjdoc.cjo`/`libcjdoc.a`，不能把旧 static archive 与新 model/render 混拼）：

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

`--https-base` 可指向实际 HTTPS 测试部署根（依赖站分别位于其 `v1`、`v2` 子目录）；默认示例域名只检查路由，不声称联网点击成功。HTTP、HTTPS 与 `file://` 浏览器点击须另外记录。Markdown 中的相对外链以生成站点的 `html/` 文档根为基准；独立 symbol-index 自动增加 `html/` 前缀，HTML 内置索引不重复增加。

## 诊断、URL 策略与预算

- 文档源逐 inventory 隔离损坏项：`CJDOC2312` 报告不可用源，具体引用的 `CJDOC2310`/`CJDOC2311` 解释拒绝原因。无关坏源保持 warning，不阻断其他确定匹配；严格 lint 下失败引用为 error。
- 指南的 `cjdoc-bind` 与正文 `{@link ...}`、受支持的 `@see/@throws` 使用同一绑定服务。页面上下文来自唯一关联模块或唯一文档根模块，workspace 不按遍历顺序借最后一个模块；signature selector 保留完整源码 header 拼写相等语义，新 `/2` producer 自动发布 pin 覆盖的可选 `sourceHeader`。
- 离线打包时把 catalog 的 `baseUrl` 改成 `./deps/v1`/`./deps/v2`，并把相应 HTML 站点显式复制到消费者的 `html/deps/v1`/`html/deps/v2`；路径以最终 HTML 文档根为基准，渲染器不读取或复制外部站点。
- URL 策略：绝对 HTTP(S) URL 检查 authority、1–65535 端口、路径、片段和 percent escape；`?plain=1#L...` 的 query 最多 32 个非空且名称唯一的 `name=value` 项，名称和值仅允许 ASCII 字母、数字和 `-_.~`；拒绝重复名称、缺失值、嵌套 `?`、`;`、多余 `=`、Unicode/转义 query 值，以及错误转义、编码控制字节、编码分隔符/路径穿越和带凭据 authority。`baseUrl` 拒绝 query/fragment。不安全输入在发布任何 HTML、Markdown 或机器索引前失败。
- 资源预算：最多 64 个 catalog 源；旧配置与 catalog 共用 256 个 inventory/document-set 槽位；单个 inventory 不超过 8 MiB；catalog 与 inventory 实际读取共用 32 MiB；单索引最多 32768 条目。外部依赖图累计最多 100000 边，单图最多 16384 边/4096 模块、闭包深度 128；预索引候选 100000 条。类型片段、源码 import、闭包/候选元数据处理共用 262144 步与 32 MiB 字节工作预算；导航诊断最多 4096 条。失败来源也占声明槽位，超界在读取前拒绝。
- 真实字节变化即使 mtime、路径和版本标签不变也会重新绑定；source parse cache 与导航绑定分层，不因文档源变化放弃既有源码缓存。

## 相关文档

- [doc-ir.md](doc-ir.md)：Doc IR v16、导航 wire 的紧凑表示与 schema/golden 同步。
- [build.md](build.md)：CHIR worker 的构建与 `--semantic chir` 参数。
- [release-process.md](release-process.md)：证据层级与发布 checklist。
