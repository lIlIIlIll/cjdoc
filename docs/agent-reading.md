# 逐声明读取、查询与 MCP

cjdoc 的机器读取以选定语言、audience、cfg 边界内的 Doc IR 为输入。静态发布、CLI、公开查询核心和本地 MCP 共用声明投影；不会从 HTML 回抓正文，不调用模型补写契约，也不重新运行示例。

## 生成与部署

```bash
cjdoc generate --project examples/pocketkit/demo-v2 \
  --format html --format json --agent-full --locale en \
  --doc-version demo-v2 --output target/agent-demo
```

已有当前版本 Doc IR 时可以离线重放：

```bash
cjdoc render --input target/agent-demo/docs.json \
  --format html --agent-full --locale en --doc-version demo-v2 \
  --output target/agent-replay
```

HTML 输出默认附带每个可见声明的 Markdown/JSON，不需要 `--agent-full`。该选项只增加聚合全文。

单独选择 `--format markdown` 保留既有包页、容器页及其中的成员正文布局；`--format json` 保留完整 Doc IR 输出。需要每声明独立 Markdown/JSON 时，发布 HTML 文档根中的 `agent/` 包。仅选 Markdown 或 JSON 格式不生成 HTML、机器包 manifest 或不存在的 HTML alternate。

| 文档根中的入口 | 用途 |
|---|---|
| `llms.txt` | 精简发现入口，链接导航、表示 manifest 和已启用的全文索引；不是全站正文。 |
| `navigation-index.json` | `cjdoc.navigation-index/2` 第一片；读取 `pagination.next` 直至结束。 |
| `agent/manifest.json` | `cjdoc.machine-manifest/1`；明确区分 symbol、concept、package、project 映射。 |
| `agent/docs.json`、`agent/symbol-index.json` | 与 manifest 快照一致的自包含模型及库存。 |
| manifest 的 `representations` | 每条记录给出实际 HTML、Markdown、JSON 相对路径；不要拼接 slug 或替换扩展名。 |
| `agent-full-index.json` | 仅 `--agent-full`：全文各片的顺序、SHA-256、单元数及完整性。 |
| `llms-full.txt` | 已有入口保留；较大全文通过索引继续读取后续完整单元。 |

路径基准是**当前文档根**，不是服务器根或其他格式的兄弟目录。部署整个 `html/`，不要只复制 HTML 文件。HTML head 的 `alternate` 指向随站点发布的逐页/逐声明 Markdown，`describedby` 指向同一根的 `llms.txt` 和 manifest。内容协商不是前提；普通静态托管、项目子路径和 `file://` 均使用这些文件。

`--all-languages` 为各语言生成独立文档根。多版本组合沿用 [高级用法](advanced-usage.md#组合多版本文档站)：组合完整版本目录，保留各语言根、manifest 和分片。`--doc-version` 是**文档发布标签**，不是依赖包版本或编译器认证。

## CLI：读取固定输入

使用已安装或已明确构建的原生 `cjdoc` 可执行文件。进程仍需要匹配的仓颉运行时库；读取不要求编译器、项目源码、原外部 inventory 或网络。源码仓库的 `./cjdoc` 开发包装器在缺少构建产物时会构建 cjdoc 本身，不是无编译器部署入口。

`--snapshot` 可重复，接受当前 Doc IR、文档根/`agent/manifest.json`，或已有 `versions.json`：

```bash
python3 - <<'PY'
import json
from pathlib import Path
Path('request.json').write_text(json.dumps({
    'schemaVersion': 'cjdoc.query-request/1',
    'operation': 'search',
    'query': 'pocketkit.TextCatalog.add',
    'apiVersion': '0.2.0',
    'limit': 1,
}), encoding='utf-8')
PY
cjdoc query --snapshot target/agent-demo/html/agent/manifest.json \
  --request request.json > result.json
```

`--request -` 从 stdin 读取一个 JSON 对象。stdout 只包含一个 `cjdoc.query-result/1` 对象；诊断不混入 stdout。输入源在会话创建时严格装载，随后继续读取相同捕获内容，不按 PATH 里的 SDK 或当前工作区重新选版本。

### 三个操作

| 操作 | 核心输入 | 返回范围 |
|---|---|---|
| `resolve_docs` | library、模块/包范围、捕获的 dependency/context、API 版本和显式策略；`query` 只匹配库/模块/包名，符号名使用 `search` | 选中项、可区分候选、matchLevel、原因与原始依赖证据。 |
| `search` | Symbol ID/key、限定名、名称/别名、参数类型/泛型数量或用途文字 | 精确身份/重载特征优先，随后名称及正文；短摘要、完整源码签名、详情身份与规范路由。 |
| `get_symbol` | `symbolId`、`symbolKey`、`pageId` 恰好一个；固定快照/文档集 | 所选完整章节、关系、来源与附带报告；概念页没有伪造的 Symbol ID。 |

完整字段、操作适用性和取值以 `cjdoc schema query-request` 为准。未知字段、身份选择冲突、`sections` 与 `preset` 同时出现、不适用的操作选项都会被拒绝。名称命中不证明重载适用性；同名、重载及同优先级文档候选不会按遍历顺序选第一条。

`resolve_docs` 复用依赖文档选择规则。`contextSnapshotId`、`contextModuleId`、`dependencyInstanceId` 指向**已捕获**上下文；不会重新解依赖或观察 SDK。`compatible` 和 `languageFallback` 是显式策略。`latest` 只有输入版本 catalog 已声明对应别名时才有意义，解析后回显固定快照；它不能替代明确请求的 API 版本。

### 续取与精确读取

用原请求加服务返回的 opaque cursor，其他条件保持不变：

```bash
python3 - <<'PY'
import json
from pathlib import Path
request = json.loads(Path('request.json').read_text(encoding='utf-8'))
result = json.loads(Path('result.json').read_text(encoding='utf-8'))
request['cursor'] = result['completeness']['query']['next']
if request['cursor'] is None:
    raise SystemExit('query is already complete; no continuation is needed')
Path('next-request.json').write_text(json.dumps(request), encoding='utf-8')
PY
cjdoc query --snapshot target/agent-demo/html/agent/manifest.json \
  --request next-request.json > next-result.json
```

取某个候选的身份，不复制截断摘要或猜测 ID：

```bash
python3 - <<'PY'
import json
from pathlib import Path
result = json.loads(Path('result.json').read_text(encoding='utf-8'))
identity = result['result']['items'][0]['identity']
request = {'operation': 'get_symbol', 'snapshotId': identity['snapshotId'],
           'symbolId': identity['symbolId'], 'preset': 'call', 'maxBytes': 65536}
Path('detail-request.json').write_text(json.dumps(request), encoding='utf-8')
PY
cjdoc query --snapshot target/agent-demo/html/agent/manifest.json \
  --request detail-request.json > detail-result.json
```

cursor 绑定内容、查询条件、排序、语言/回退和受众；换输入或改条件不能继续用旧 cursor。更大预算重试若改变请求，应按结果中的说明重新开始，而不是同时修改预算又沿用旧 cursor。

仅装载 Doc IR 时，`scope.snapshots[].packagedRepresentations` 为 false：结果中的规范路由不是文件已随输入打包的证明，完整正文仍可通过 `get_symbol` 取得。装载机器 manifest 才校验已打包资源的 hash、快照、库存及完整表示映射。外部源码 URL 是捕获的出处，不要求随离线包复制源码。

## 章节、状态和预算

声明预设：`summary` 取签名与说明；`call` 保留完整签名、参数、返回及必要契约，并按预算加入完整示例；`reference` 选择全部已支持章节。显式 `sections` 可选 signature、parameters、returns、contracts、examples、description、relations、source、diagnostics、validation、diff。概念页只支持 description、source、validation、diff，不适用调用预设。

参数、返回、泛型、源码 token、Markdown AST、完整 DocTag 与导航直接保留已有记录。没有结构化命名参数字段时保留源码签名/`sourceApiSignature`，不自行解析头部补造布尔值。九类行为契约以及 throws、deprecated、since 与完整示例不被折成一行。

`Unit` 的冗余返回类型行可以省略，但作者的 `@return` / `@returns` 正文（包括多条说明）不省略。返回类型未知时也保留已有返回说明，不补造类型。

| 维度 | 读取位置及含义 |
|---|---|
| API 收集 | `completeness.apiCollection`：resolved/partial/unavailable，与当前 top-k 无关。 |
| 查询枚举 | `completeness.query`：实际范围、offset、returned、total、complete、next。未知总数为 null；关系续取的 scope 为 relations，returned 数关系而不是重复的主体声明。 |
| 内容 | `completeness.content`：selectedSections、missingSections、omittedSections、retry；区分来源缺失、未选择与预算省略。 |
| 匹配/语义/导航 | 保留各自状态；manual、verified dependency、resolved navigation 都不代表类型检查或消费者行为通过。 |
| 正文语言 | reading language 是阅读偏好；DocTag 的 contentLanguage/translationState 和页面 language 说明实际作者正文及回退。回退不切换 API 版本。 |

| 限制 | 当前值 |
|---|---|
| 显式快照输入 | 1–64 个；规范 Doc IR 合计最多 64 MiB，读入文件累计最多 512 MiB。 |
| 请求 | 一个 UTF-8 JSON 对象，最多 1 MiB，嵌套深度 64。 |
| 结果数量 | 搜索默认 20，最大 100；0 表示主动不读取，不是不存在声明。 |
| 内容字节预算 | 默认 64 KiB，可请求 1 KiB–64 MiB；按完整章节的正文和结构化值计算，不是 token 保证。 |
| 核心结果 wire | 序列化 JSON 最多 64 MiB，和内容预算独立；超限返回 resource_limit，不截断 JSON。 |
| 关系 | 默认深度 1、数量 25；深度最多 4、数量最多 100，可筛 direction/kinds。仅沿捕获关系走，按快照内准确身份防环。 |
| 静态分片 | navigation/full 每片 16 MiB；摘要 16 KiB；单产物 64 MiB、总产物 512 MiB、条目 65536。 |

必要调用单元放不下时返回 `budget_exceeded`、真实 requiredBytes 和可行重试；超出硬资源范围时是 `resource_limit`，不提供不存在的完整读取入口。可选章节只整章省略。关系第一条记录都放不下时不给原地循环的 cursor。额外上下文只进入 `relatedSnapshotIds` 显式选择的快照；跨 root/dependency 不用裸本地 Symbol ID 认定同一目标。

| status | CLI 退出码 | 解释 |
|---|---|---|
| ok、ambiguous、not_found、source_incomplete | 0 | 正常领域结果；后两者只说明已声明的捕获范围。 |
| invalid_request、scope_mismatch、stale_cursor | 2 | 请求或固定范围不成立。 |
| budget_exceeded、resource_limit、unavailable | 3 | 预算、硬限制或输入可用性问题。 |

## 本地 stdio MCP

MCP 是可选消费适配，不是生成或静态阅读的前提。使用同一组固定输入：

```bash
cjdoc mcp --snapshot target/agent-demo/html/agent/manifest.json
```

stdio 遵循 [MCP 2025-11-25 生命周期](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)：initialize → notifications/initialized → 工具请求；关闭 stdin 后退出。仅声明 resolve_docs、search、get_symbol。参数就是对应操作字段，不再重复传 operation。`content[0].text` 是核心正文，structuredContent 是完整核心结果；领域失败与 JSON-RPC 协议错误分开。

Codex CLI 的 TOML 配置示例（从能解析这些输入路径的目录启动）：

```toml
[features]
code_mode_host = true

[mcp_servers.cjdoc]
command = "cjdoc"
args = ["mcp", "--snapshot", "target/agent-demo/html/agent/manifest.json"]
required = true
startup_timeout_sec = 120
tool_timeout_sec = 180
# Linux 且运行库不在系统搜索路径时，替换为实际运行库搜索路径：
env = { LD_LIBRARY_PATH = "<Cangjie-runtime-library-path>" }
```

Codex 0.163 需要配套的 `codex-code-mode-host` 才能发现和调度 MCP 工具，即使 `code_mode` 未启用也不能禁用该 host。它是客户端调度前提，不等于启用 shell 或网页工具。Codex 不保证把启动终端的运行库环境传给 MCP 子进程：Linux 显式配置适用的 `LD_LIBRARY_PATH`，macOS 使用对应的 DYLD 搜索路径，Windows 则配置包含运行库 DLL 的 `PATH`；运行库已经安装到系统搜索路径时可省略环境项。

`required = true` 要求客户端等真实连接完成初始化，不能在较大的多 snapshot 输入尚未加载时就把文档工具当作不存在。启动与工具超时仍受客户端整体任务期限约束。

MCP 消息使用一行一个 UTF-8 JSON 对象；请求仍是 1 MiB。传输会再次携带可读正文，因此外层最多 130 MiB，不能把核心内容预算冒充整个协议包预算。`serve` 保持项目预览/重建用途；不要把它当作只读 MCP。

## 已有验证与 diff 报告

只发布已经存在的 JSON 报告，不执行新的检查：

```bash
cjdoc render --input target/agent-demo/docs.json --format html \
  --validation-report validation.json --api-diff-report api-diff.json \
  --output target/agent-with-reports
```

两个选项也适用于 generate，但要求 HTML 目录输出，不能与 stdout 组合。原始报告随 `agent/reports/` 发布，SHA-256 与 manifest 关联。查询 validation/diff 章节按需返回原始报告和绑定状态；报告中的未检查、编译、运行、失败或跳过信息保持原意。

`not_attached` 不是通过；只有报告关联不代表其生产者可信。缺少内容 hash、实际输入/工具链/配置记录时保留 binding_unavailable，快照或配置不符是 binding_mismatch。源码/诊断、示例代码存在或站点构建成功都不是执行回执。已有 api-diff/2 缺少双输入内容指纹时，保留 baseline/current 原文，不从文档标签回填认证。

## schema 与升级

```bash
cjdoc schema list
cjdoc schema navigation-index-v2
cjdoc schema agent-full-index
cjdoc schema declaration
cjdoc schema page
cjdoc schema machine-manifest
cjdoc schema query-request
cjdoc schema query-result
```

`schema navigation-index` 指向当前 v2；`schema navigation-index-v1` 和已发布的旧 schema 保持冻结。v1 没有整体完整性/续取证据，不能据其语法合法认定全站枚举完整。当前 decoder/query 接受 Doc IR v16；旧版本输入不会被补造为当前证据，须保留对应历史工具或从真实来源重新生成。

公开仓颉入口为 `cjdoc.DocumentationQuerySession`，可从显式路径、一个 `cjdoc.model.DocumentationSet` 或其数组创建；`execute(String)` 返回同一版本化 JSON，`catalogIdentity` 暴露捕获内容身份。静态投影由 `cjdoc.render.DocumentationReadSnapshot` 及现有 renderer 提供。运行可重现模型对照、消费者编译与行为验收见维护者的 [Agent 评测流程](maintainer/agent-evaluation.md)；普通静态使用不要求模型或网络。
