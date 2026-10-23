# 可操作展示站与验收契约（Issue #50）

展示站使用仓库维护的 PocketKit 教学库。`demo-v1` 和 `demo-v2` 是同一库的两个源码快照；
`support-v1` 是独立依赖文档集。这些名字不是 cjdoc、std 或 stdx 的正式版本。
API 页面、类型关系、成员锚点、搜索索引、版本映射和兼容性分类均由 cjdoc 原生生成。
Python 展示层只负责组织这些产物、展示原始报告和检验发布条件。

## 功能入口与事实来源

`site/showcase-catalog.json` 是维护者定义的功能清单。构建从最终生成的导航索引和
Doc IR 解析每个目标，产出 `showcase-plan.json` 和 `showcase-features.json`；首页卡片和
浏览器场景均使用该清单。没有独立维护的符号 URL 表，也不复刻 SymbolId 的哈希算法。

每项能力分别声明：

- **实现状态**：`complete`、`partial` 或 `not-implemented`。
- **演示状态**：`available`、`uncovered` 或 `blocked`。
- 来源文件与 SHA-256、仓库 revision、版本、语言、目标和操作说明。
- 必须执行的浏览器场景 ID；不可用项的原因和跟踪 issue。

`available` 是必须满足的发布要求，不是构建脚本自行写出的测试结论。缺少目标、报告、
锚点或任意必需浏览器结果，均不得上传发布。部分能力的有效样本仍可体验，但其边界必须
留在卡片中。未覆盖项不能被自动删除以获得绿色 CI。

`site/showcase-baseline.json` 固定本 PR 承诺的范围，用于阻止功能、版本、语言或场景
静默消失。这是首次建立的范围基线，**不是捏造的历史浏览器通过报告**。已有真实发布
manifest 也可通过 `--previous` 做跨发布回归检查。更新范围基线必须作为显式代码变更审阅。

重载使用精确 `headerSpelling` 在当前 Doc IR 中唯一选择，再通过原生 `id`/`ownerId`、
导航索引和真实成员 permalink 取得类型页锚点。歧义或目标消失直接失败。匹配源码签名
不会把 `partial` 语义升级为权威类型分析。

## 构建与本地复现

准备仓库要求的 Cangjie 1.2.0 和匹配 stdx sidecar，严格按
[Pages workflow](../../.github/workflows/pages.yml) 的固定工具链步骤构建 cjdoc。
当前 SDK 1.2.0 的 `llc` 在默认优化级别处理 markdown/yjson 时会崩溃，因此该工作流的
“Build cjdoc”步骤临时将唯一的空 `override-compile-option` 改为 `-O1`，构建后通过
`finally` 恢复原始清单。复现时沿用该完整步骤，不直接运行省略此处理的默认构建命令。
不要修改 SDK、编译器或 stdx 来迁就展示。可执行文件必须来自要验收的仓库 revision，
运行展示构建前工作区须恢复为该提交的干净状态。

```sh
python scripts/build_showcase.py \
  --binary target/release/bin/main \
  --output target/showcase-site \
  --repository-url https://github.com/lIlIIlIll/cjdoc \
  --revision "$(git rev-parse HEAD)"
```

构建生成中英文各两份原生文档，显式执行 `versions compose` 和 `diff`，再生成可读报告、
源代码下载和完整离线 ZIP。专用 `cjdoc.toml` 纳入版本管理，展示构建直接使用该配置与原生 CLI。
固定依赖索引来自同次构建的 `support-v1`，不隐式访问外部服务。

只复现教学库核心页面时，可以下载源代码 ZIP，在解压根目录执行：

```sh
python3 examples/pocketkit/reproduce.py \
  --cjdoc /absolute/path/to/cjdoc --output ./generated --locale both
```

输出目录必须不存在。下载包含示例许可证、配置、两个快照、独立依赖及诊断项目；
SDK 和 cjdoc 可执行文件不包含在下载中。源代码按钮指向固定 revision 的真实仓库位置。

自生成文档的首页入口、HTML/Markdown 文档索引及复制发布的手册链接，使用同一份
`repository` 与 `revision` 元数据定位仓库文件与目录，保留 `blob` / `tree` 路由及锚点；
fork 和历史构建不跳到上游 `main`。
这些链接只在展示站发布层重绑定，原始作者 Doc IR 和源码下载仍保留采集时的内容。
使用 `--project` 展示其他项目时，复制的 cjdoc 手册仍按构建元数据绑定；该项目自己的
HTML/Markdown 概念索引保留作者链接，不作为 cjdoc 手册改写。
仓库根 `README.md` 随手册一起发布到站点根目录并重绑定仓库链接，保留手册中
`../README.md` 的返回路径。

本地 `serve` 教程由相同原生概念页提供。`scripts/check_showcase_authoring.py` 启动
真实服务器、读取状态、在隔离副本中修改注释，再验证成功构建计数和 HTTP 内容均更新。
原始证据位于 `artifacts/authoring.json`。静态 Pages 不运行编译器或常驻服务。

## 报告与能力边界

可读报告直接读取版本化的原生产物，并绑定其输入 SHA-256、项目、audience、版本、语言
和 revision。原始 JSON 始终可达；没有展示层覆盖率计算器、兼容性分类器或执行器。
通用报告组件复用原生验证页的布局，适用于符合相同报告契约的其它文档集。

| 产物 | 可读视图必须保留的含义 |
| --- | --- |
| Doc IR v16 | 源码声明、注释、来源位置、显式 partial 与诊断 |
| coverage / quality | 指标分母、audience、规则和具体缺失位置；比例不代表契约正确 |
| `--check-examples` | `must-pass`、`must-fail`、`run` 等作者指令的真实 CLI 验证；结果由诊断和退出码表达 |
| API diff | 同库两个版本、原生分类、匹配状态、不确定性及前后声明链接 |
| versions.json | 原生身份映射；删除的成员必须显示缺失，不猜测 latest 目标 |

示例检查的编译诊断与运行资源上限分别记录，不能把诊断文本截断当成执行成功：

| 管线 | 本次示例配置与该 revision 的原生限制 |
| --- | --- |
| 原生 `{run}` | `src/example_runner.cj` 限时 10,000 ms、内存 2,048 MiB；stdout、stderr 各保留前 65,536 bytes，并继续排空、统计真实总量。任一流超过上限产生 `CJDOC3075`；时间上限会终止进程树并产生 `CJDOC3073`，不是仅截断后算通过。 |
| 原生指令示例的编译诊断 | `src/bounded_process.cj` 的编译子进程默认限时 120,000 ms，stdout、stderr 各仅保留前 8,192 bytes，同时排空其余输出；正常退出保留实际退出码，超时终止并返回 124。`src/example_compiler.cj` 还将展示的诊断正文按 8,192-byte 预算截断并追加说明。此处是诊断保留/显示预算，不是 `{run}` 的 64 KiB 结果上限。 |

以上限制来自本次仓库 revision 的原生实现，不能通过展示 TOML 调整。普通 `generate`/`check` 不会隐式执行示例；`--check-examples` 的诊断和退出码才是检查结果，不生成逐例执行报告。SDK 版本、生成器哈希及实际命令另见 `build.json`、下载清单和 `check-modes/native-check.json`。

完整展示复现流程以 Linux SDK 1.2.0 与 `prlimit` 验证。`{run}` 需要操作系统可实施的正数地址空间限制；无法提供该限制的平台会在启动用户代码前明确拒绝，不会降级为无界运行。这不等同于 compile-only 示例检查的平台能力。

源码作者的资源责任、同步要求、复杂度和边界说明保持作者来源。展示构建不推断这些
契约。指南与精确重载的双向页面关联不代表完整外置契约合并；扩展显式约束也不代表
完整适用性推断。缺失、歧义和故意失败样本放在单独的“边界与诊断”项目中。

本地依赖 URL 只允许受控的相对路径和固定本地索引；路径遍历、任意协议、编码绕过
和测试域名不允许通过。同名本地符号与独立依赖符号必须经真实索引区分。

## 最终目录验收

先安装锁定的浏览器依赖，再对**最终待发布目录**运行：

```sh
python -m pip install -r scripts/requirements-showcase.txt
python -m playwright install --with-deps chromium
PYTHONPATH=scripts python -m showcase_contract.browser \
  --site target/showcase-site --evidence target/showcase-evidence
PYTHONPATH=scripts python -m showcase_contract verify \
  --site target/showcase-site \
  --evidence target/showcase-evidence/results.json \
  --baseline site/showcase-baseline.json
```

证据目录必须新建且位于站点目录之外，以免站点哈希自引用。浏览器失败不能生成通过
报告；验证完成后不再修改站点。可通过 `--chromium` 指定已安装的 Chromium。

| 用户路径 | 行为验收 |
| --- | --- |
| 首页 → 重载 | 一次激活到原生成员锚点并展开；筛选和同时比较两个重载 |
| 返回类型 → 接口 | 使用实际类型关系、范围和来源，能够返回 |
| 指南 → 精确成员 → 指南 | 双向归属准确，不借父类型关联替代成员关联 |
| 同一成员切版本 / 已删除成员 | 原生身份准确，缺失可见 |
| diff / 示例 / 质量 → 原始报告 | 可读视图与版本化报告、源声明一致 |
| 外部类型 → 固定依赖文档 | 本地优先、正确版本、正确成员与锚点 |
| 中文长签名和契约 | 无布局裁切，焦点可达 |
| 实际下载 ZIP → 解压 → file:// | 导航、搜索、成员展开、复制、内部及依赖链接可用 |
| HTML → JSON / Markdown / llms | 同一声明身份、文档版本与原生路由一致 |

场景覆盖 HTTP 根路径、项目子路径和真实解压目录的 `file://`，分别验证中文、英文和
桌面、分屏、移动视口，并保存 light/dark 截图。记录激活、document navigation、滚动、
首屏成员数、列表高度、构建/ZIP 体积及查询/展开耗时。受控样本预算用于检测回归，
不是对任意用户硬件的性能承诺。761–1180px 区间的正文位置与纵向空白必须检查。

当前承诺为 **324 个场景**：16 类 journey、18 个语义目标 × 2 种语言 × 3 种载体 ×
3 种视口。多版本 journey 额外覆盖普通成员、被删除成员和被删除的旧整数重载。
每个场景均通过真实控件选择 Light/Dark 并保存两张截图；首页也保存对应语言、载体、
视口的两主题截图。这是必须执行的矩阵，不代表最终目录已经全部通过。

测量字段按以下含义读取：

- `homepageActivations` 和 `homepageDocumentNavigations` 只计功能入口到准确目标，
  两者预算均为 1；整个 journey 的 `activations`/`documentNavigations` 还包括后续
  关系、报告、历史、语言或主题操作，不是用户完成任务的最短操作数。
- `landing.scrollY` 是打开准确目标后浏览器所在的纵向位置，包含原生锚点定位。
  `scrollEvents`/`scrollDistance` 是整个验收过程观测到的滚动事件与累计绝对距离，
  包括控件自动滚入视野、历史恢复和截图准备；不能把它们称为用户必须手动滚动的次数或距离。
- `queryMs`/`expandMs` 从真实 `input`/`click` 事件的 `performance.now()` 开始，
  到预期结果可见或完整详情展开的断言结束。展开前滚入视野不计入展开延迟，仍进入滚动统计；
  耗时包含事件之后的浏览器与验收调度开销，不是独立的渲染器微基准。

预算固定在 `scripts/showcase_contract/scenarios.py`。参考界面改版后的本地受控样本为
78,414,054 bytes 站点、10,354,602 bytes 离线 ZIP。站点上限调整为 100,000,000 bytes，
为该样本留出约 27.5% 的增长空间；这些测量值不代表远端部署大小。浏览器运行和最终证据
校验共用这份预算，调整后须重新生成浏览器收据，旧预算快照不能作为新预算的验收证据。

| 受控指标 | 回归预算 |
| --- | --- |
| 最终站点 / 离线 ZIP | 100,000,000 / 16,000,000 bytes |
| 成员列表高度 / 收起行最大高度 | 6,000 / 220 px |
| 分屏正文起始位置 | 距文档顶部最多 260 px |
| 查询 / 展开可见结果延迟 | 1,500 / 1,000 ms |

全站静态校验检查最终 HTML 链接、锚点、重复 ID、大小写冲突、符号链接、路径逃逸及
`docs.example.test`。不把易波动的外网在线状态作为默认构建门禁。站点保留 `api/`、
`demo/`、`artifacts/` 等兼容入口，站内链接不依赖部署根路径或符号链接。

离线 ZIP 逐文件 SHA-256 校验，拒绝重复、额外、遗漏、过期、加密、危险路径、特殊文件
和符号链接条目。ZIP 不包含自身，解压后的下载页明确标为已处于离线副本。

## S-01～S-06 交付映射

| Issue 项 | 维护位置与验收入口 |
| --- | --- |
| S-01 首页与直达 | `site/index.html`、`showcase_build/homepage.py`、原生目标解析 |
| S-02 专用可复现示例 | `examples/pocketkit/`、许可证、source ZIP、原生 CLI |
| S-03 实际功能与报告 | 功能 catalog、通用报告视图、原生 compose/diff/check/serve |
| S-04 机器清单和回归 | manifest、固定 scope baseline、严格浏览器 evidence |
| S-05 构建和发布链路 | `build_showcase.py`、输入追踪、Pages workflow、离线包 |
| S-06 最终 Pages 测试 | `showcase_contract.browser`、最终目录 verify、截图和 metrics |

## 浏览器分片与历史耗时

Pages 的两个浏览器分片按完整首页组分配，未选择历史时保持原有的稳定交替分组。
计划中的 `homeKeys[].ownerCase` 是注册顺序中该组的第一个 case，
`ownerShard` 指明由哪个分片产生共享首页截图。该组后续 case 复用首页观测，
不会因负载均衡改变 activation 次数或每个 case 的 metrics。
严格 merge 校验首页所有权、唯一性、完整覆盖以及截图 digest，再调用原有完整 evidence gate。

每个成功分片产生 `timings.json`。用 merge 的可选 `--timings PATH` 生成
`cjdoc.browser-timing/1` 历史；必须恰好包含计划中所有 case，每个 case 一次，
每个分片的观测须与自己的计划一致。缺失文件、重复或未知 case、错误 schema、
负值、非数值和非有限耗时都会失败，不能采用部分历史。

在已有同一计划的两份分片证据后执行：

```sh
PYTHONPATH=scripts python -m showcase_contract.browser merge \
  --site target/showcase-site --plan target/browser-plan.json \
  --shard-result 0=target/browser-shard-0/shard.json \
  --shard-result 1=target/browser-shard-1/shard.json \
  --evidence target/showcase-evidence --receipt target/browser-merge-receipt.json \
  --timings target/browser-timing-history.json
```

输出包含分配 mode，且生成 `browser-timing-history.json`。
下一次 plan 传入 `--history target/browser-timing-history.json`，就会按实测 case 耗时总和
对完整首页组执行 longest-processing-time 分配，mode 为 `history-weighted`。
如果 case 清单发生变化，旧历史不再完整，必须先执行一次不带历史的新 run。

Pages 的 `verify-site` 将完整历史放入 validation evidence，并单独上传为
`cjdoc-showcase-browser-history-<run-id>-<attempt>`，保留 30 天。
手动 dispatch 时，填入可选字符串输入 `browser_history_run_id` 和
`browser_history_run_attempt`（默认 `1`）。工作流只下载这个 run/attempt 的确切同名 artifact，
不搜索“最近成功”。不填 run id 时仍按 `equal-home-groups` 分配；指定的历史缺失、
过期或无效时明确失败，无自动 fallback。

每个分片上传 `browser-history-selection.json`（run id、attempt、artifact 名与 historySource）、
使用的历史原文及 `browser-plan.json`；validation evidence 收集这些文件。
计划的 `assignment.historySource` 是包含所选 run/attempt 的稳定相对路径，
可与 selection 和 `assignment.groupCosts` 对照审计。


## 证据分层

Python 单元测试使用合成导航和报告，不能证明仓颉编译、原生示例检查、真实生成页面或浏览器
交互通过。报告实际结果时分别列出 build、native unit、golden/integration、真实仓库、
最终 Pages 浏览器和远端 CI。远端结果以对应 commit 的 Actions 为准；工作流绿色也不能
代替检查功能清单与最终证据的一致性。Issue 关闭和合并由维护者验收决定。
