# 静态代码高亮架构与边界

> 本文面向维护者：它记录代码高亮在生成期的实现边界、锁定版本与离线适配器约束。
> 使用层面的命令与配置示例见 [`docs/usage.md`](../usage.md)。

代码高亮在生成文档时计算分类与 UTF-8 字节范围，HTML 只对原始文本切片、转义并应用主题。它不证明代码能够编译，也不提供语义导航或执行示例；符号链接由语义信息决定，doctest 编译与运行仍由独立的示例检查开关和指令决定。

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

`mode = "off"` 要求禁用高亮；`on-error` 表达高亮失败时的警告或错误策略，而不是 doctest 策略。配置读取上限为 **64 KiB**，复用项目的有界读取路径。未知键、重复键、无效模式、无效错误策略、空数组、空语言和规范化后的重复语言都是显式配置错误。此读取器沿用 doctest 的单行 section/value 风格；语言数组使用双引号，不支持多行数组或转义语言名。

语言名按 ASCII 去除首尾空白并转为小写，再规范化别名。未知语言可以作为配置数据保留，但不因此获得后端。`languages = ["cj", "cangjie"]` 是重复错误。**配置语言不授权执行程序**：即使列表包含 Python 等外部语言，没有宿主显式授权也只能得到有原因的纯文本结果。项目里的 `cjdoc.toml` 不能指定可执行程序、安装依赖或获得网络权限。

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

Shell 家族**不统一**：`sh`、`zsh`、`fish`、`powershell` 不会被改成 `bash`。`output` 是展示输出文本，不是可执行代码；高亮不会改变它的 doctest 输出比较含义。

内置 Cangjie 路径使用 lexer，不是按字符串或正则猜关键词的启发式着色。范围始终引用原始源码字节，不使用已解码的 token 值重建字符串；注释、引号、转义和 Unicode 拼写保持不变。插值字符串整体作为字符串 token，不声称为插值内部表达式提供独立高亮。lexer 抛错时整块降级为纯文本，不编造部分范围。`complete` 仅表示高亮流程完成，不表示语法合法或编译成功。

## 外部适配器：离线预安装与授权

外部 grammar 包是生成时的可选依赖，不是网站资源。固定版本为 **Node.js 26.10.0**、**Highlight.js 11.11.1**，映射修订 **`cjdoc-map-1`**，协议 **`cjdoc-highlight/1`**。包、锁文件、SHA-512 完整性与 BSD-3-Clause 许可证说明见 [`tools/highlight/README.md`](../../tools/highlight/README.md)。

在 npm 缓存已预置该锁文件归档的机器上，独立于文档生成进行离线安装：

```bash
cd tools/highlight
npm ci --ignore-scripts --offline
node --test
```

缓存缺少归档时会安装失败；先在受控的联网准备阶段明确安装，再分发锁文件安装得到的依赖。生成器不能自动运行 npm、下载 grammar 或访问网络。默认 Cangjie 高亮不依赖这个步骤。

宿主授权接口是 `--highlight-adapter <absolute path>` 和 `--highlight-node <absolute path>`，仅用于 `generate` / `check`。路径必须非空、绝对，不能拼接 shell 元字符或命令；含空格的路径应由调用 shell 引号保护为单个参数。不能从项目配置、`PATH` 搜索或代码块内容获得执行授权。外部执行只能通过这些显式宿主标志授权；既有有界监督器使用固定脚本和独立 executable / argv 元素，不把任何用户值拼成 shell 命令。

两个标志必须同时提供；公开 API 等价授权为 GenerationRequest 的 highlightAdapter / highlightNode 两个命名可选参数（非空绝对路径）。生成层对每个外部语言块启动一次固定 argv 的 Node 进程，仅传入适配器路径；stdin 转发一条换行终止 JSON 并向目标提供 EOF，stdout 必须恰好返回一条换行终止响应。SDK 管道流没有公开 close 方法，因此沿用固定监督器脚本转发精确字节数；计数仅来自程序格式化的请求 Array.size，不来自代码、语言或宿主路径。每块 deadline 为 **5 秒**，stdout 独立限制为 **3 MiB** 加换行，stderr 保留有界前缀并继续排空。成功等待退出，失败或超时终止隔离进程组并等待。此修订不采用适配器可复用 worker 模式：复用已有一次性有界生命周期，避免跨块状态与守护进程清理；不缓存瞬态失败。

主进程严格拒绝重复 JSON 键、未知字段、额外响应、缺少换行、错误类型、协议/id/语言/固定引擎身份或修订不匹配、错误状态和未知原因。主进程重新计算原文 UTF-8 SHA-256 与字节长度，验证全部范围的数量、分类词汇、正长度、顺序、不重叠、边界和 UTF-8 字符边界。失败整块纯文本，不附加部分 spans。未授权、进程缺失、崩溃或非零退出为 backend-unavailable；不接受适配器 HTML。

概念指南代码块在生成时仅在内存中高亮，其高亮元数据不持久化到 Doc IR；从 docs.json 执行后续 render 不会重放指南。API 注释与 @example 的持久化范围可以离线重渲染。最终网站及后续 render 都不需要 Node。

## 持久化、原因和资源边界

Doc IR **`cjdoc.doc-ir/12`** 的可选 `codeHighlight` / `signatureHighlight` 保存规范化语言、原始 UTF-8 长度与 SHA-256、引擎身份与修订、状态以及分类字节范围。颜色不进入模型，范围不复制 token 文本。范围必须正长度、有序、不重叠、位于原始字节长度内并落在 UTF-8 边界。渲染器只使用原始文本，不接收适配器 HTML。

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

旧版本 Doc IR 缺少元数据时按纯文本 / `missing-metadata` 兼容降级，不捏造已完成高亮。高亮是展示元数据，不改变源码 API contract 指纹。

可选适配器的固定预算为：每块 **262144 UTF-8 字节（256 KiB）**、最多 **65536 spans**、每条输入 JSONL **2097152 字节（2 MiB）**、每条输出 JSONL **3145728 字节（3 MiB）**，不含结尾换行。超限整块纯文本，不截断源码或返回部分 spans。协议原因 unsupported-language 映射到 Doc IR 的 unsupported；invalid-request / malformed-json 映射到 backend-unavailable；resource-limit / invalid-spans 保留对应模型原因；未知原因拒绝整个响应。

生成期的签名、注释围栏和 `@example` Markdown 子树共享同一个总预算：最多 **8192 spans**、**4 MiB 高亮元数据预算**和 **4 MiB 原始代码准备量**。元数据预算包含 JSON 对象与缩进的保守开销，不只是代码长度。按已有符号、注释和代码块遍历顺序分配；首次超限后，不再附加任何后续高亮元数据，并仅报告一次 `warning[CJDOC3028]`。不截断源码或 spans；缺少元数据的代码按 `plain` / `missing-metadata` 渲染。

固定总预算不能假设其他 Doc IR 内容很小，因此整包还必须满足现有 **32 MiB codec 边界**。若高亮候选包超过该边界，先重新投影为无可选高亮元数据的完整文档；只有文档本身仍超过仓库现有限额时，才沿用已有文档 fallback。不会提高任何 `DOC_IR_MAX_*` 限额。

引擎升级必须审查原文保留、scope 映射与许可证，并一起更新版本锁和修订；缓存身份必须绑定引擎修订、规范化语言与源码 hash，不能拿旧引擎结果冒充新结果。

## 静态站点与 CSP

网站**从不携带高亮引擎**：不发布 Node、适配器或 `node_modules`，不加载浏览器 Highlight.js，不依赖 CDN。高亮展示无需运行时 JavaScript，不注入高亮脚本或事件属性；使用固定分类 CSS class，沿用站点的转义与 CSP 边界。其他站点交互功能是否使用 JavaScript 与高亮无关。离线或 `file://` 浏览时仍可展示已经生成的高亮；重新渲染持久化结果不运行 lexer 或外部程序。
