# 静态代码高亮架构与边界

> 本文面向维护者：它记录代码高亮在生成期的实现边界、锁定版本与离线适配器约束。
> 使用层面的命令与配置示例见 [`docs/usage.md`](../usage.md)。

代码高亮在生成文档时计算分类与 UTF-8 字节范围，HTML 只对原始文本切片、转义并应用主题。它不证明代码能够编译，也不提供语义导航或执行示例；符号链接由语义信息决定，示例编译与运行由独立的 `--check-examples` 开关和 `@example` 指令决定。

## 项目配置

在项目根目录的 `cjdoc.toml` 添加以下单行配置。没有文件或没有 `[highlight]` 段时使用这些默认值：

```toml
[highlight]
mode = "static"
languages = ["cangjie"]
on-error = "warn"
```

| 键 | 可用值 | 默认值 |
|---|---|---|
| `mode` | `static`、`off` | `static` |
| `languages` | 非空、无重复的双引号语言字符串数组 | `["cangjie"]` |
| `on-error` | `warn`、`error` | `warn` |

`mode = "off"` 要求禁用高亮；`on-error` 表达高亮失败时的警告或错误策略，不控制示例检查。配置读取上限为 **64 KiB**，复用项目的有界读取路径。未知键、重复键、无效模式、无效错误策略、空数组、空语言和规范化后的重复语言都是显式配置错误。此读取器使用单行 section/value 风格；语言数组使用双引号，不支持多行数组或转义语言名。

语言名按 ASCII 去除首尾空白并转为小写，再规范化别名。未知语言可以作为配置数据保留，但不因此获得后端。`languages = ["cj", "cangjie"]` 是重复错误。生成阶段的实际生效范围由配置决定，而不是由渲染器或默认值决定：`mode = "off"` 时不调用高亮后端、不附加新的高亮元数据；所有代码入口显示转义原文且无词法颜色，可靠语义链接仍保留；`languages` 只声明哪些语言允许进行高亮工作，未列入的语言得到显式 `plain` 结果（原因 `disabled`），而不是被静默跳过或伪装成成功；`on-error = "error"` 时高亮后端的失败会让本次运行失败（`error[CJDOC4027]` 并使文档 `partial`），`warn` 时只记录警告；不受支持、被关闭或缺少元数据等预期纯文本结果不会触发该升级。渲染端只消费已持久化的元数据，因此这些开关都不需要在阅读时重新运行任何东西。

**配置语言不授权执行程序**：即使列表包含 Python 等外部语言，没有宿主显式授权也只能得到有原因的纯文本结果。项目里的 `cjdoc.toml` 不能指定可执行程序、安装依赖或获得网络权限。

## 语言和别名

只读取作者明确提供的围栏语言，不做自动语言检测，不根据代码内容猜语言。

| 语言标记 | 规范名 | 后端边界 |
|---|---|---|
| `cangjie`、`cj` | `cangjie` | 内置 Cangjie lexer；不需要 Node.js |
| `json` | `json` | 可选外部 Highlight.js JSON grammar |
| `bash` | `bash` | 可选外部 Bash grammar |
| `python`、`py` | `python` | 可选外部 Python grammar |
| `toml` | `toml` | 可选外部 TOML/INI grammar（固定上游 `ini` 模块） |
| `yaml`、`yml` | `yaml` | 可选外部 YAML grammar |
| 无语言 | 空 | 纯文本，`no-language` |
| `text`、`plaintext`、`plain`、`output`、`console`、`nohighlight`、`no-highlight` | 空 | 显式纯文本，不调用高亮后端 |
| 其他语言 | 保留规范化名称 | 没有后端时纯文本，`unsupported` |

Shell 家族**不统一**：`sh`、`zsh`、`fish`、`powershell` 不会被改成 `bash`。`output` 是展示输出文本，不是可执行代码；高亮不会改变它作为示例预期输出的比较含义。

内置 Cangjie 路径使用 lexer，不是按字符串或正则猜关键词的启发式着色。范围始终引用原始源码字节，不使用已解码的 token 值重建字符串；注释、引号、转义和 Unicode 拼写保持不变。插值字符串整体作为字符串 token，不声称为插值内部表达式提供独立高亮。lexer 抛错时整块降级为纯文本，不编造部分范围。`complete` 仅表示高亮流程完成，不表示语法合法或编译成功。

布尔字面量 `true` / `false` 使用 lexer 的 `BOOL_LITERAL` 分类，对应展示类别 `literal`；不改变 `String` / `Array` / `Char` 的已测量内置标识符例外列表。

## 外部适配器：离线预安装与授权

外部 grammar 包是生成时的可选依赖，不是网站资源。固定版本为 **Node.js 26.11.1**（声明范围 `>=26.10.0 <27.0.0`，本次实测 26.11.1）、**Highlight.js 11.11.1**，映射修订 **`cjdoc-map-1`**，协议 **`cjdoc-highlight/1`**。包、锁文件、SHA-512 完整性与 BSD-3-Clause 许可证说明见 [`tools/highlight/README.md`](../../tools/highlight/README.md)。

在 npm 缓存已预置该锁文件归档的机器上，独立于文档生成进行离线安装：

```bash
cd tools/highlight
npm ci --ignore-scripts --offline
node --test
```

缓存缺少归档时会安装失败；先在受控的联网准备阶段明确安装，再分发锁文件安装得到的依赖。生成器不能自动运行 npm、下载 grammar 或访问网络。默认 Cangjie 高亮不依赖这个步骤。

宿主授权接口是 `--highlight-adapter <absolute path>` 和 `--highlight-node <absolute path>`，仅用于 `generate` / `check`。路径必须非空、绝对，不能拼接 shell 元字符或命令；含空格的路径应由调用 shell 引号保护为单个参数。不能从项目配置、`PATH` 搜索或代码块内容获得执行授权。外部执行只能通过这些显式宿主标志授权；既有有界监督器使用固定脚本和独立 executable / argv 元素，不把任何用户值拼成 shell 命令。

两个标志必须同时提供；公开 API 等价授权为 `GenerationRequest` 的 `highlightAdapter` / `highlightNode` 两个命名可选参数（非空绝对路径）。一次生成上下文默认按需启动一个 worker，单请求串行处理并复用进程。API、概述和指南共享该生命周期和总预算。每条请求使用递增唯一 ID；每条请求的写入、读取受 **5 秒** deadline 约束。stdout 每条最多 **3 MiB** 加换行，stderr 总量最多 **8 KiB**，不公开其原始内容。失败立即终止进程树；后续请求最多允许两次重启，即整次生成最多启动三次，不对当前失败块自动重试。结束及异常路径通过 `finally` 关闭 worker 并有界等待回收。仓颉线程的 `Future.cancel()` 取消信号在请求等待中被检查，并触发相同的进程树清理。

Linux/macOS 复用既有隔离进程组监督器；Windows 使用既有 kill-on-close Job Object。进程环境只保留启动必需变量，排除 `NODE_OPTIONS`、`NODE_PATH` 和预加载/模块注入设置。这些措施是资源与生命周期约束，不是系统安全沙箱；宿主不应授权不可信适配器。

公开 API 可用 `GenerationRequest(..., highlight: Some(HighlightConfig(mode: "static", languages: ["cangjie", "python"], onError: "warn")))` 覆盖项目策略；策略本身不授权执行。`None` 沿用项目配置。

主进程严格拒绝重复 JSON 键、未知字段、额外响应、缺少换行、错误类型、协议/id/语言/固定引擎身份或修订不匹配、错误状态和未知原因。主进程重新计算原文 UTF-8 SHA-256 与字节长度，验证全部范围的数量、分类词汇、正长度、顺序、不重叠、边界和 UTF-8 字符边界。失败整块纯文本，不附加部分 spans。未授权、进程缺失、崩溃或非零退出为 backend-unavailable；不接受适配器 HTML。

概念页、包/项目概述与指南的冻结 Markdown 树和高亮元数据保存在 Doc IR v14 的 `pages` 中，与 API 注释、签名和 `@example` 一同离线重放。`docs.json` 包含这些已捕获输入时，后续 `render` 不读项目文件、不启动 Lexer/Node。旧 IR 未携带的指南源文不能凭空恢复。

## 持久化、原因和资源边界

Doc IR **`cjdoc.doc-ir/14`** 的可选 `codeHighlight` / `signatureHighlight` 保存规范化语言、原始 UTF-8 长度与 SHA-256、引擎身份与修订、状态以及分类字节范围。v12 已引入代码高亮；v14 新增必填根字段 `apiCollectionState`，严格迁移 v6–v13，并冻结原版 schema/golden。颜色不进入模型，范围不复制 token 文本。范围必须正长度、有序、不重叠、位于原始字节长度内并落在 UTF-8 边界。渲染器只使用原始文本，不接收适配器 HTML。

`DocumentationSet.apiCollectionState` 是独立的 API 收集证据：`resolved`、`partial` 或 `unavailable`。生成器在加入高亮诊断之前记录它，API snapshot 只读取此字段。严格高亮失败仍保留 `error[CJDOC4027]`，使 `status = "partial"` 并让生成命令失败，但不会将原本确定的 API 删除降级成 potentially-breaking，也不会绕过 `--deny-breaking-api`。源码、绑定和其它非高亮不完整证据仍保持 `partial`；整包资源 fallback 的 API 收集为 `unavailable`。语言选择、版本发布和 JSON 离线重放保留此状态。旧 public 构造调用未提供该命名参数时，和 v6–v13 输入一样保守地映射旧 `status`：complete → resolved，partial → partial；不会从旧诊断文字猜测收集成功。

状态词汇为 `complete`、`partial`、`plain`。纯文本原因词汇固定如下，不用任意异常消息替代：

| 原因 | 含义 |
|---|---|
| `disabled` | 高亮已禁用 |
| `no-language` | 没有语言或明确要求纯文本 |
| `unsupported` | 没有支持该语言的后端 |
| `missing-metadata` | 输入没有持久化高亮元数据 |
| `backend-unavailable` | 所选后端不可用或没有执行授权 |
| `invalid-spans` | 范围或原文校验失败 |
| `resource-limit` | 超过资源边界 |
| `lexer-failed` | lexer 失败 |
| `unterminated-token` | token 未闭合 |

旧版本 Doc IR 缺少高亮元数据时按纯文本 / `missing-metadata` 兼容降级，不捏造已完成高亮。签名的持久化 `SourceApiSignature` token witness 仅用于原文对齐和可靠语义链接，不再作为第二着色来源。`signatureHighlight` 缺失、原文校验失败、禁用或预算降级时均保留原文和可靠链接但无词法颜色；仅有效高亮范围提供颜色。需要补齐旧 IR 的颜色应显式重新生成。高亮是展示元数据，不改变源码 API contract 指纹。

可选适配器的固定预算为：每块 **262144 UTF-8 字节（256 KiB）**、最多 **65536 spans**、每条输入 JSONL **2097152 字节（2 MiB）**、每条输出 JSONL **3145728 字节（3 MiB）**，不含结尾换行。超限整块纯文本，不截断源码或返回部分 spans。协议原因 unsupported-language 映射到 Doc IR 的 unsupported；invalid-request / malformed-json 映射到 backend-unavailable；resource-limit / invalid-spans 保留对应模型原因；未知原因拒绝整个响应。

`@example` 的正式展示投影只准备一次：生成端先用同一个 Markdown 引擎解析，再在受限深度/节点预算（深度 48、100000 节点）内检查是否含代码块；超限则退回旧路径。含代码的示例渲染为一个投影树，其中的本地图片、标题锚点与语义链接与正文一样参与资源发布、去重和链接解析；不含代码的示例沿用既有的 `description` 纯文本渲染（该路径本来也不产生 `<img>`），因此不会收集或发布用不到的资源。旧版本 Doc IR 的代码块缺少元数据时按 `plain` / `missing-metadata` 降级。

捕获概念页/指南存在 binding 候选行时，`prepareCapturedPageBindings` 在正式投影前额外执行一次纯 Markdown AST 语法预检（`admittedCapturedBindings` / `CapturedBindingSyntaxPass.collect`）。预检只消费已经读入的正文，沿用既有节点/深度限制，其 AST 在正式投影前释放；不准备高亮、不调用 Lexer 或 provider、不收集资产，也不启动 worker。仅 AST 证明为表格连续上下文中真实 binding marker 的位置会做等宽准备；其它真实 `HtmlBlock` / `HtmlInline` 使用原 span 转换。代码、引用和 opaque HTML 中貌似指令的字面内容不因物理行命中而改写或产生关联。`parseCapturedPageMarkdown` 随后仍只进行一次正式展示投影，使用同一个共享高亮上下文/worker，不增加源码读取。**共享高亮一次不等于所有 Markdown 都只解析一次**；带 binding 候选页的生成成本必须计入此额外语法预检。

捕获页的可见 API 目标按阅读语言建立一次指南反向索引；独立符号页与展开成员在各自正文中共用该索引输出回链，不读取原项目，也不靠生成后字符串替换补入成员内容。未绑定的重载或隐藏目标不会借用所属类型的指南关联。

生成期的签名、注释围栏和 `@example` Markdown 子树共享同一个总预算：最多 **8192 spans**、**4 MiB 高亮元数据预算**和 **4 MiB 原始代码准备量**。元数据预算包含 JSON 对象与缩进的保守开销，不只是代码长度。按已有符号、注释和代码块遍历顺序分配；首次超限后，不再附加任何后续高亮元数据，并仅报告一次 `warning[CJDOC3028]`。不截断源码或 spans；缺少元数据的代码按 `plain` / `missing-metadata` 渲染。

固定总预算不能假设其他 Doc IR 内容很小，因此整包还必须满足现有 **32 MiB codec 边界**。若高亮候选包超过该边界，先重新投影为无可选高亮元数据的完整文档；只有文档本身仍超过仓库现有限额时，才沿用已有文档 fallback。不会提高任何 `DOC_IR_MAX_*` 限额。

降级删除可选高亮元数据不能删除已经观察到的后端诊断：`CJDOC3120` warning 与严格模式 `CJDOC4027` error 均保留，后者仍使文档为 `partial`。CLI `generate` 沿用既有 `writeOnFailure=true`：严格失败退出非零，但原子发布包含完整原文与诊断的产物；`serve` 的失败重建才保留上一次成功站点。不要把两者混为“所有失败均禁止写出”。宿主被终止后遗留的 owner lock 是 fail-closed 保护，验收使用独立输出父目录并保留锁，不靠删除锁继续测试。

词法缓存只存在于一次生成上下文，键绑定原始 UTF-8 SHA-256、规范化语言、Lexer/grammar/适配器/映射修订、协议和 `ignoreIllegals`/disabled 选项。主题不参与键。成功、可靠 partial 和稳定纯文本原因可复用；超时、崩溃、不可用后端、非法响应和资源失败不缓存。缓存不携带语义链接或 owner，不导出缓存文件；隐藏成员不准备展示数据，不消耗可见内容高亮预算。引擎升级须一起更新版本锁和修订。

内建 `engineRevision` 由映射修订与 `lexer-behavior-v1` 的 SHA-256 词法行为指纹组成：每个生成上下文在首次需要内建高亮时，对固定、有界、合法的 corpus 记录实际 Lexer 返回的 token kind 和 UTF-8 字节位置；关闭高亮和普通 render 不运行此 probe。它不是完整 SDK build 身份，也不能证明全部 grammar 行为相同；缓存不跨生成或 SDK 共享。验收另记录实际二进制、加载器选择的 std.ast/配套运行库与已校验 SDK 归档 receipt 的摘要作为这次运行的可追溯证据，不使用宿主 cjc 版本冒充已链接 Lexer 身份。

## 静态站点与 CSP

网站**从不携带高亮引擎**：不发布 Node、适配器或 `node_modules`，不加载浏览器 Highlight.js，不依赖 CDN。高亮展示无需运行时 JavaScript，不注入高亮脚本或事件属性；使用固定分类 CSS class，沿用站点的转义与 CSP 边界。复制按钮读取绑定原文的 JSON-string 属性，而非 HTML 已规范化换行的 `textContent`/`innerText`；属性不是可执行脚本。选择文本遵循浏览器的 HTML 换行规范化，复制保留入口已提取代码中的 CRLF、制表符、Unicode 和末尾换行，不承诺复制围栏或整个源文件。其他站点交互功能是否使用 JavaScript 与高亮无关。离线或 `file://` 浏览时仍可展示已经生成的高亮；重新渲染持久化结果不运行 Lexer 或外部程序。

## 复现验收

完整命令、H-T 覆盖映射与证据边界见 [静态高亮验收](../maintainer/acceptance/issue-100-acceptance.md)。`scripts/highlight_acceptance.py` 在新的私有工作目录生成真实 fixture 和 `report.json`；它不使用旧日志补齐结果。报告记录固定输入摘要、SDK/运行库摘要、Node/grammar 版本、renderer 源文件摘要与三组交替 on/off 生成耗时，以及 IR/HTML 字节、DOM/span 数。浏览器的首次阅读、复制与布局证据单独记录，不把生成成本等同于阅读速度。
