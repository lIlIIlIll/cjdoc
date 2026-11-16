# 大规模 API 阅读基准

对应 [issue #153](https://github.com/lIlIIlIll/cjdoc/issues/153)。这是生成器和真实静态网页的观测协议，不是替代现有 `showcase_contract`、reading regression、density、语言、链接或安全门禁的另一套评分。

## 固定输入与原生生成

[`reader_corpus.py`](../../scripts/reader_corpus.py) 生成实际仓颉项目，不生成手写搜索索引。`rdr-scale-v1` 包含 50/500 成员、2/4/8/16 重载、泛型约束、命名/默认参数、继承、扩展、重导出、长契约/代码、中英文与真实缺译回退。声明数指显式源码声明；原生 Doc IR 和公开搜索投影的数量另记。

固定 1k 项目还通过了 SDK 1.2.0 的实际 `cjpm build`，35 条 unused 警告未被压制。独立消费包编译运行验证了四档公开重载、默认/命名参数、第 500 个成员和泛型映射；没有把 AST 接受声明等同于编译或运行通过。

[`reader_external.py`](../../scripts/reader_external.py) 校验并展开未修改的 yjson 固定归档。revision、URL、归档字节数/SHA-256、相关源码及配置的逐文件 SHA-256 都进入 manifest。任务来自该 revision 的 README 和作者声明，不从搜索结果反向挑选成功样例。它是同等 1k 规模的真实生产依赖交叉样本，不是整套 std/stdx 的容量证明。

`reader-corpus.json` 保存固定源码清单、输入摘要和任务。测量前后都会验证源码；加入未登记的 `.cj`、丢失文件或修改已登记内容都会拒绝测量。不要为了改后数据变好而删除正文、改变受众、缩短 fixture、换排序或放宽应用上限。

## 历史已采集的本地基线

固定生成源码为 `2ef643c5d795ab2e3dfd1035517baeec3a88b0aa`，实际版本为 cjdoc 0.7.3 / `cjdoc.doc-ir/16`。本阶段不改变任何已发布 Doc IR、schema 或 golden。完整凭据摘要、原生 CPU/墙钟/RSS 和原始报告摘要见 [`reader-scale-baseline.json`](reader-scale-baseline.json)。这些是该次观测，不是其它机器或 GitHub runner 的结果。

| 语料 | 原生结果 | 浏览器证据 |
|---|---|---|
| 1k 显式源码声明 | 1,000 声明，`complete`；两次源码生成的 Doc IR SHA-256 相同 | 两种语言、三种载体、20 次查询/筛选采样；160 张生成页面截图 |
| 10k 显式源码声明 | 编码预算预检返回 `CJDOC3027`、`partial` 的有界空投影；原生命令退出 0，观测器明确记为 `resource-limited` | 未运行，不生成虚假的零延迟或 PASS |
| 50k 显式源码声明 | 固定堆配方耗尽，退出 1，`resource-limited` | 未运行，不声明支持该规模 |
| yjson 固定 revision | 2,319 声明、1,218 个公开/受保护声明，`partial`；保留未展开 Derive 宏的 `CJDOC1009` | 两种 UI 语言、三种载体；32 张生成页面截图 |

`CJDOC3027` 对应 `docIrFitsEncodedBudget` 的编码资源预检。当前产品诊断没有细分字节、对象、数组或类型子限额；不能把这次拒绝擅自解释成某个精确字节阈值，更不能推导通用的“最大声明数”。SDK 堆上限也不等于整个进程 RSS：后者包含非仓颉堆内存。

已观察到：宽查询 `member` 的目标在 552 个匹配的前 20 项之外；真实库的 `kind:function` 目标在 685 个匹配的前 20 项之外，均没有继续入口。50/500 成员正文筛选、257 项之后的精确深链，以及四档重载的选择、同时展开、历史恢复通过了脚本任务。长正文尾部 token 明确在 2,000-rune 摘录之外，不能把没有索引命中解释为原文不存在。

500 成员筛选有超过 100ms 的同步处理样本；CPU 采样热点位于 `saveMemberState` 读取滚动坐标的位置，而不是直接证明 `textContent` 或全站 rank/sort 有瓶颈。只在定位、成对复测后修改对应路径；不预先引入分片、全文复制或另一套搜索引擎。

## RDR-S2 的针对性改动

- 结果列表仍有界为每页 20 项，通过上一页/下一页继续发现；翻页复用当前查询的稳定排序，不引入另一套搜索引擎。查询、类别或包变更重置页码，原有精确身份、字段优先级、IME 与键盘交互保留。
- 翻页后结果链接继续支持方向键、Enter 和 Escape；方向键移动真实焦点，返回查询框或用 Ctrl+K 聚焦不会把当前页重置为第一页。查询、类别和包实际变更仍重置页码。Escape 保留原有清空查询语义，从结果返回搜索框。
- 空结果只表示当前索引没有命中；面板明确说明每项 2,000-rune 正文摘录边界，不提高截断上限或复制完整正文。
- `saveMemberState` 原来保存的文档滚动坐标没有恢复消费者，却会在成员 DOM 变更后强制布局。移除该无用字段，文档位置继续由原生历史负责；仅缓存实际恢复的 sidebar offset，并在 pagehide 同步取最终快照，覆盖未派发 scroll 事件就导航的情况。不能仅凭同步 JS 变快就宣称像素呈现变快；需要分开观察布局/下一帧与额外渲染机会。
- 键盘回归使用真实 DOM 事件与原生生成页面。保留 ranking/IME 单元行为检查，并让 DOM test double 提供标准事件 `target`；删除截取内部函数再用空 `render` stub 复述调用顺序的测试，不给新函数名重建 stub。生成器的导航单测保留 ARIA、真实链接和内容契约，不钉 JS 赋值语句或 CSS 选择器／断点源码；目录可见性、筛选和响应式操作由真实浏览器回归覆盖。现有真实 browser 的 Control/Meta+K 关闭移动主题 modal、解除 inert 并聚焦搜索的用例继续保留。
- 移动菜单的 pointer hit-test 先将实际 popup 原生滚入视口，再分别验证 action 位于视口内且实际接收指针；不将视口以外的坐标误判为 paint containment 裁切。菜单仍必须通过独立的浏览器 hit-testing，不能只看 DOM 存在或 `display`。
- `tests/browser/check-reader-discovery.mjs` 在实际原生 1k 站点检查完整分页身份/顺序、查询重置、IME/键盘精确尾部链接、立即导航后的 sidebar/文档历史，以及规定视口/明暗主题中的翻页控件和边界说明。它不替代冻结的三文件规模测量 harness。
- 首次完整成对 CI 的 500 成员下一帧 P95 最高 165.4ms，未达到事前 150ms 目标。独立 trace 将主要成本定位到恢复 500 行时的样式/布局（一次涉及 16,984 个样式元素、约 19k dirty layout objects），并排除仅增加 layout containment 的方案。仅在 screen media 中对未展开、无焦点且未打开操作菜单的行使用浏览器原生 `content-visibility:auto`；保留全部 DOM、作者正文和精确锚点，展开契约与 print 始终走完整布局。不支持所用 selector 的浏览器保留原布局。对所有行延后布局的早期方案曾使离屏展开契约的 rendered text 变为空，既有 showcase 检查捕获该回归；双展开后保留完整作者正文的实际场景防止重现。诊断样本不是正式通过凭据，仍以完整 cohort 的比较为准。
- 真实库的成对相对门槛也捕获了查询与冷加载退化；不同查询交替的 CPU profile 显示 `wordParts` 及逐字符分类是主要脚本成本。按原生 entry 对象惰性缓存不随查询变化的分词/缩写/拼写候选；缓存数量受当前索引条目数约束，不复制全部正文、不缓存固定查询响应，也不跳过不同查询的原始 rank/sort。正式比较继续要求原始前 20 排序和 index payload 完全一致。
- 侧栏初始化保留服务端的 5 项窗口、当前项位置与完整索引链接；partial 标记不触发自动补全。明确展开或筛选时才补齐该分支，关闭分支不构造子树。数据与真实 href 完整保留，正文成员 DOM 不因窗口缩小而减少。
- 大页面筛选复用文档创建时确定的成员身份与目录节点绑定；固定成员作用域在 controller 创建时复制、按字节归一并绑定，不为每次按键重新编码排序身份或重建限制集合。调用者修改原身份数组或先前结果不会改变已绑定作用域。请求仍逐次执行真实过滤与排序，不缓存固定查询的响应。只选择实际展开的操作菜单，目录高亮只更新前后两个链接。目录可见性显式驱动外层列布局，避免外层 `:has([hidden])` 因大量成员/目录项变更而反复失效；独立滚动目录保持布局、样式和绘制边界，正文与全部链接保持完整。
- desktop 目录保留全部成员链接与分组，叶子使用普通布局，不为每个成员再建立独立的 `content-visibility` 显示锁。筛选仍更新真实可见项，不减少 DOM、层次、身份或可达内容；独立滚动边界保留，mobile、无 JS 和 print 路径不变。
- 目录观察回调只接受送达时仍未被 `hidden` 隐藏的正文标题；筛选的同步目录刷新负责选取可见的高亮项，异步旧快照不得把高亮切回已过滤成员。可见性取自正文，不依赖尚未刷新的另一断点目录。
- 样式匹配保留零特异性，但把多类型 `:where()` 列表拆成独立的单类型选择器，让浏览器按类型索引；无 JS 控件规则同样按实际类索引。大页面闲置行在宽屏只检查原生直接成员的 `open`；窄屏另检查直接菜单 toggle 的 `aria-expanded`。宽屏操作始终行内展示，不匹配不会出现的弹出菜单；不遍历整个操作子树，也不维护额外的菜单状态副本。高开销 selector trace 仅用于定位匹配开销，不替代原生完整 cohort 的严格验收。
- 首开搜索先完成唯一一次内容渲染，再调用原生 `showModal()`，避免 controller 构造和打开各渲染一次，以及 modal 布局后再次改写内容。目录筛选只更新当前断点实际展示的目录，切换断点时刷新新激活的那一份；保留 desktop/mobile 各自原有层次、身份与链接。超过 256 成员的屏幕行用 flex 分配正文与操作区，避免恢复整组时重复求解嵌套 grid；小页面、无 JS 与 print 路径不变。
- 类别标签从无原型字典读取；未翻译的协议值保持字符串回退，不能把继承的 `constructor` 等属性当作文案。真实浏览器回归通过可见的构造器类别标签选择并核对原生构造器结果。
- 减少动态效果模式直接禁用 CSS transitions；不能用全局非零 `transition-duration` 覆盖原本没有过渡的元素，否则目录激活也会产生字重和颜色过渡。目录点击仍立即更新高亮和真实 fragment，正常动态效果模式不变。
- 大页面透明操作区中的装饰 SVG 只在 hover 或键盘焦点进入成员行时布局；真实操作控件、无障碍名称、固定点击区域和全部向量节点始终保留。不减少作者正文或导航项。支持离散 display transition 的浏览器保持原有淡出，其他浏览器沿用原布局；无 JS、窄屏和 print 路径不变。
- 成员的独立页／源码链接及复制按钮用自身 `aria-label` 与唯一 summary 拼接完整无障碍名称，不为每项再建标签 span。相同的直接文本在宽屏保持图标布局、窄屏显示为菜单文案；分组、更多操作和 live status 的原有文本与节点保留。复制反馈只更新标签文本与无障碍名称，不覆盖 SVG 子树。所有作者正文、原生目标、IDREF 和无 JS 入口不变。
- 侧栏历史回归先通过真实筛选请求完整分支，确认侧栏至少能滚动 160px，再在同一任务中设置滚动位置并立即导航。冷态 5 项窗口不一定可滚动；不能把被浏览器钳制为零的赋值当作已发生滚动，也不能为测试预先自动补全整棵树。
- 窄屏导航抽屉按真实布局可见性选择首末焦点；展开后再折叠或筛选隐藏的分支，其后代即使自身未带 `hidden` 也不能进入焦点循环。真实浏览器回归覆盖两种隐藏路径与正反 Tab。
- 搜索与设置的按钮、backdrop、原生 `cancel` 都走同步关闭路径，只恢复一次焦点；不在排队的 `close` 事件中重复恢复或清理。后来选中的正文控件和已重新打开的弹层拥有当前焦点与状态，旧关闭事件不得覆盖它们。
- 成员／重载／声明分组在页面初始化时绑定稳定的原生成员节点；按键筛选复用这些绑定并直接计数，不重复查询整组后代或分配临时筛选数组。正文行、外层操作行及当前断点目录仅在可见性实际改变时写入 `hidden`；完整分组计数、错误清空、来源筛选、精确链接与历史恢复仍同步生效。

## RDR-S4：重载任务与布局代价

固定 2/4/8/16 组的首项、中项和末项通过原生结构化参数身份选择；两语言、三载体共 66 个选择均正确，仍为查询加激活两次逻辑操作。24 个双展开比较保留两份完整原文签名、作者契约及 Back 恢复，均为筛选加两次展开三次操作。16 组末项保留命名/默认参数和真实缺失说明，不从文本猜测类型、异常、同步或复杂度。

实测不能仅汇总正确率：在同一 CI cohort 中，16 组双展开的自动化耗时从 baseline 约 90–93ms 增至 130–152ms。对同一原生站点做 20 次交替 CSS A/B（同源替换 stylesheet、不绕过 CSP），关闭小组的延迟布局后，比较 P50 为 150.3→98.0ms、P95 为 161.0→116.9ms；原始签名和作者正文逐次保持相同。这是定位布局代价的诊断，不是人类阅读时间、认知难度或冻结门槛的通过证明。

因此只在成员数超过既有 256 项大页面边界时启用闲置闭合行的延迟布局。原生 producer 在 HTML 中预先标记这一边界，让样式在首次布局前生效，而不是等目录初始化后才重新分类整页；screen 规则同时要求 `html[data-cj-js]`。2/4/8/16 重载、50 成员及无 JS 页面保留普通布局；大页面的展开行、焦点、操作菜单和 print 仍不延迟布局。不删正文 DOM、不改正文、搜索 payload、身份或排序，不引入另一套阈值配置。

源码重建后的原生站点再与原生 S2 站点做 20 次交替比较（warmup 后计数，无 asset override）：16 组比较 P50 为 153.155→99.943ms、P95 为 167.549→119.631ms，仍为三次操作。两站的 index JSON/JS 与逐项原文详情完全相同；实际新 `search.js` SHA-256 为 `afcc26dbb107f4b7f606aebab2e467d42270aecb78653dd13b4829c0e8948f08`，stylesheet 为 `76bdba8c03b296fef3ccf4c915d5a4d3c1951363317d077ede7e4bc601637e3a`。这是实际编译产物的诊断性对照，不替代冻结 cohort 的严格比较或最新 HEAD 的 CI。

不增加按字符串猜语义的重载比较 UI。给定调用形状的准确性和操作次数没有要求新模式的证据；已观察到的代价由布局路径直接处理。缺作者说明、明确无额外限制、同异常的不同条件及来源不确定性按[作者侧契约复核](api-reading-audit.md#验证入口)分别保留，当前 13 个消费者场景和 8 个指南程序的完整运行命令也在该入口。人类比较任务和读屏语音仍未测，不能从自动化脚本推导无认知退化。



## 环境与指标语义

- SDK 固定为 Cangjie 1.2.0 STS、stdx 1.2.0.1 static sidecar、仓库现有 `-O2 --fno-chir-function-inlining` wrapper。sidecar 在 SDK 的父级布局中解析，不假设在 `cangjie/` 内。按[构建指南](build.md)准备环境，不修改 SDK/compiler/std/stdx。
- 浏览器依赖使用 `tests/browser/package-lock.json` 的 Playwright 1.63.0 / Chromium 153.0.8010.12；本地 Node v26.12.0。浏览器上下文 `en-US`，文档分别选择 `en`、`zh-CN`，基准视口 1440×900、DPR 1、light、CPU throttle 1、JS old-space 512 MiB。报告没有物理 CPU 隔离或跨设备速度可比性声明。
- 应用硬上限保持：Doc IR/单 artifact 64 MiB、artifact 总量 512 MiB、65,536 个输出条目、32,768 个类型出现次数。项目配置可以更严；冻结配置也在输入摘要中。源码缓存关闭；操作系统文件缓存不受控制，不声称冷 OS 缓存。
- 真实 HTTP root、HTTP subpath 与 `file://` 分开记录。HTTP 服务不启用传输压缩；gzip 数字只是相同文件的离线体积统计，不是压缩传输耗时。
- 原生生成和 Doc IR→HTML replay 分别记录 CPU、墙钟、退出码、最大单进程 RSS。`wait4` RSS 不是同时存活的进程树总内存；不支持 POSIX `wait4` 的原生观测明确拒绝，不伪造 Windows 资源数据。
- 查询与成员筛选保留全部原始样本和 nearest-rank P50/P95。成员序列交替清空/精确目标；不能把它写成仅测更容易的同值重复。`frameMs` 是下一次 `requestAnimationFrame` 的时刻，不保证像素已经绘制。
- `automationDurationMs` 是脚本协议耗时，查询/成员任务包含采样和自动化调度；`operationCount` 是逻辑读者操作数。它们不是人类完成时间，不能用二者相除得到“每次点击成本”。重载选择另记目标调用形状到准确原生链接的操作耗时。
- 当前浏览器报告为 `cjdoc.reader-browser/2`，不接受旧形状。重载比较分别保留原始签名、按顺序的参数名/类型/默认值、返回类型，以及每个作者 `doc-field` 的身份和精确 rendered text；两侧逐项相等，不归一化作者文本或默认值中的空白。生成的参数标题分隔符不是作者契约，不能把整个详情容器的排版文本混入作者字段。完整原生 HTML 仍保留在观测产物中。
- 伴随 JSON 的解析采样是隔离的 `JSON.parse`，不是把 JS 索引的实际加载/编译时间改名为 JSON 解析时间。真实页面同时记录导航、脚本 CPU、>50ms 长任务、DOM 与 CDP JavaScript heap；后者不是浏览器进程总 RSS。
- `environment.fontFiles` 只记录固定七家族 `DejaVu Sans`、`DejaVu Sans Mono`、`Liberation Mono`、`Liberation Sans`、`Noto Sans CJK SC`、`Noto Serif CJK SC`、`WenQuanYi Zen Hei` 的 fontconfig 默认文件及真实 SHA-256，并按家族排序。before/after 的完整 environment（包括该安装清单）必须相等，不取两侧并集；缺失、新增、不可用或摘要改变均拒绝。采样节点的实际 family/PostScriptName 与 `fontUsage` 独立记录；只有明确登记的 presentation profile 可以允许实际使用集合变化。这不是枚举所有字形、字重或字体文件的声明。
- 字体节点采样使用独立 CDP session，并在 `finally` 中 detach；负责后续 `Performance` / `Network` 观测的 session 不开启 `DOM` / `CSS` domain。节点查询会让 Inspector 订阅该路径下的成员变更，不能把这些额外通知留进后续筛选计时。两侧仍采集相同字体字段；采样生命周期修复不改变样本、原始任务、environment、ARIA/presentation profile 或任何数值门槛。

非 Ubuntu 本地资格检查必须同时复现 runner 的 fontconfig 规则，而不只提供相同字体文件；一个 TTC 还可包含清单之外的实际 face。当前 Ubuntu 22.04 配方使用原始 `fontconfig-config` 规则及 `fonts-noto-cjk` 的 `70-fonts-noto-cjk.conf` 语言选择规则。可在任务私有目录中包含这些原始规则、排除宿主 user/local 配置，并引用原始七家族文件与私有 cache；不得改字体字节或以临时 family 替换放宽 profile。先核对双语实际 usage、完整 environment 和完整 ARIA，再冻结环境采正式 20 样本。

隔离 `XDG_CACHE_HOME` 时，须另用 `PLAYWRIGHT_BROWSERS_PATH` 指向已安装的锁定浏览器目录，否则 Playwright 会在新 cache 下查找另一个浏览器安装。两侧正式捕获必须使用同一份规则、字体与浏览器，资格检查不计作正式样本。

截图矩阵为 1440×900、960×900、390×844、760/761/1180/1181×900，以及 CSS 720×450 / DPR 2 的 200% 等效内容布局；light/dark、中文/英文。后者对应物理 1440×900，不声称操作了浏览器 chrome 的缩放菜单。所有截图来自原生生成站点，包含长契约、命名参数、泛型约束、500 成员和 16 重载。

无 JS 的原生 disclosure、同时展开、ARIA tree 和 print media 另记。ARIA 顺序不是读屏软件的语音会话；print media 的可见性/结构检查不是纸张打印或人工可读性评估。没有真实读屏语音或人类计时实验的部分必须继续写“未测”，不能升级为 PASS。

## 重跑一个观测 cohort

先从确定的源码 revision 构建并保留 binary；`--revision` 必须是真正生成该 binary 的源码身份，不能给当前 binary 贴旧 revision。SDK 认证和构建方法见 [build.md](build.md)。大输出必须在磁盘目录中，不使用 tmpfs `/tmp`：

```bash
mkdir -p "$HOME/.cache/agent-tmp"
TASK=$(mktemp -d "$HOME/.cache/agent-tmp/cjdoc-reader.XXXXXX")
chmod 700 "$TASK"
mkdir -m 700 "$TASK/tmp" "$TASK/browser-dependencies"
export TMPDIR="$TASK/tmp" TMP="$TASK/tmp" TEMP="$TASK/tmp"
export RUNNER_TEMP="$TASK/tmp" GITHUB_WORKSPACE="$PWD" cjHeapSize=512MB
export PYTHONDONTWRITEBYTECODE=1 PLAYWRIGHT_SKIP_BROWSER_GC=1
export PLAYWRIGHT_BROWSERS_PATH="$TASK/browsers"
export CJDOC_BROWSER_REQUIRE_ROOT="$TASK/browser-dependencies"
cp tests/browser/package.json tests/browser/package-lock.json "$CJDOC_BROWSER_REQUIRE_ROOT/"
npm ci --prefix "$CJDOC_BROWSER_REQUIRE_ROOT" --no-audit --no-fund
"$CJDOC_BROWSER_REQUIRE_ROOT/node_modules/.bin/playwright" install chromium
. scripts/with_sts_cjpm.sh

: "${BASELINE_BINARY:?指定已从固定源码构建的 baseline binary}"
: "${BASELINE_REVISION:?指定该 binary 的完整源码 revision}"
python3 scripts/with_stdx.py --variant static -- python3 scripts/reader_capture.py \
  --binary "$BASELINE_BINARY" --revision "$BASELINE_REVISION" \
  --corpus 1000 --output "$TASK/baseline-1000"
```

安装浏览器系统依赖/字体是环境准备，不在测量中途安装。`--corpus` 还支持 `10000`、`50000`、`external`。每次要求全新输出目录，拒绝覆盖已有证据。`reader_capture.py` 只把明确的非 1k 资源拒绝当作完成观测；任意源码/渲染/浏览器故障仍退出失败。`measured` 表示采样完成，不表示所有读者任务通过。

Linux 观测另记录实际 `environment.cpuAffinity`；它是 Node 启动进程的允许 CPU 列表，子进程继承该亲和性。需要隔离调度时，先从当前允许集合选择并登记固定 CPU 集合及物理核拓扑，再以同一 `taskset --cpu-list "$CPUSET"` 前缀运行完整 baseline/after 命令。隔离配方单独登记，不根据计时结果挑核，不改 governor，也不把未隔离配方的失败改记为通过；两侧完整 environment 仍须相等。

当前采集器只消费实际发布的 `cjdoc.search-index/11`；升级搜索协议时必须同步 `reader-scale-metrics.mjs` 的输入契约。历史基线保留其源码版本对应的采集器及摘要，不能把旧协议拒绝误报为容量失败，也不能为绕过拒绝放宽预算、减少样本或生成手写索引。

已有固定原生站点时可独立重跑浏览器观测，原生生成费用仍引用原来的真实凭据，不把重跑写成重新生成：

```bash
node tests/browser/measure-reader-scale.mjs \
  --site "$TASK/baseline-1000/observation/locale-en/html" \
  --manifest "$TASK/baseline-1000/corpus/reader-corpus.json" \
  --output "$TASK/browser-replay-en" --label baseline --locale en \
  --samples 20 --transports root,subpath,file --screenshots
```

## 先登记门槛，再采 after

数值门槛在 [`reader-scale-budgets.json`](reader-scale-budgets.json) 中。100ms 同步/150ms 下一帧的 500 成员目标是在看见基线、修改产品代码之前登记的目标，不是声称原有实现已经达到。现有 20+ 成员 density 的 100ms/512 KiB/8k DOM 门槛原样保留。

```bash
python3 scripts/reader_register.py \
  --baseline "$TASK/baseline-1000/observation" \
  --template docs/maintainer/reader-scale-budgets.json \
  --output "$TASK/registered-1000.json"
```

这是不带协议过渡登记的严格默认调用。固定 1k CI 的 v17→v18 比较必须在 baseline 捕获后、after 捕获前，用下面的调用替代它；不要先生成默认登记再补改文件：

```bash
python3 scripts/reader_register.py \
  --baseline "$TASK/baseline-1000/observation" \
  --template docs/maintainer/reader-scale-budgets.json \
  --output "$TASK/registered-1000.json" \
  --doc-ir-transition v17-v18-unregistered-source \
  --aria-transition docs/maintainer/reader-scale-docs-173-177.json \
  --presentation docs/maintainer/reader-scale-presentation-v18.json
```

这三个参数只用于固定 1k 比较：精确过渡冻结 IR/ARIA 的既定差异，`--presentation` 明确登记本次重设的排版与实际使用字体。三者并存时各自仍按原规则逐项校验，任何一个都不会放宽数值预算、原始任务、打印/无 JS 检查或其它视觉相等要求；其它 cohort 和普通重跑不传它们，继续使用严格默认比较。

```bash
: "${AFTER_BINARY:?指定实际改后 binary}"
: "${AFTER_REVISION:?指定该 binary 的完整源码 revision}"
python3 scripts/with_stdx.py --variant static -- python3 scripts/reader_capture.py \
  --binary "$AFTER_BINARY" --revision "$AFTER_REVISION" \
  --corpus 1000 --label after --output "$TASK/after-1000"
python3 scripts/reader_compare.py \
  --baseline "$TASK/baseline-1000/observation" --after "$TASK/after-1000/observation" \
  --manifest "$TASK/baseline-1000/corpus/reader-corpus.json" \
  --budgets "$TASK/registered-1000.json" --output "$TASK/comparison-1000.json"
```

登记只读取 baseline、数值模板和明确提供的 transition profile；Doc IR 过渡还从当前候选源码的 `cjpm.toml` 读取一次 `package.version`。登记不读取 after，并且不覆盖已有登记。比较器重算原始样本分位，拒绝更换源码/任务、SDK、浏览器、字体、harness、语言/载体或缺失测量；前 20 排序、原始重载签名/作者详情、准确性、体积、堆、DOM、打印/无 JS、布局和所有性能门槛继续照常检查。没有 transition 登记时，Doc IR 与搜索 index payload 仍按原有严格规则比较。资源受限输出保持 `pass: false`，不能补造浏览器样本。

### 固定 1k 的 v17→v18 窄过渡

workflow 只在 `READER_CORPUS=1000` 时预登记 `v17-v18-unregistered-source` 和 `docs/maintainer/reader-scale-docs-173-177.json`；10k、50k、external 及手动其它规模不继承这两项登记。它们只允许比较副本中的下列精确、可验证变化，不改变输入、任务、采样或性能预算。

- Doc IR 基线必须是 `/17`，改后必须是 `/18`。基线每个 `ModuleDoc.repositoryPath` 都必须为 `null`；改后移除此字段。改后每个 `FileDoc.provenance` 必须恰为 `state=unavailable`、`reason=no_project_repository`、`evidenceKind=none`，`repository`、`repositoryPath`、`sourceDigest`、`normalizedDigest`、`evidenceIdentity` 全为 `null`。只允许新增 `DocComment.localizationScope="all"`、`DocTag.entryId=null`、`DocTag.source=null` 和 `DocumentationText.entryId=null`。不允许出现 admonition，metadata 与其它字段仍须相等。
- native 与每种 locale 的 publisher Doc IR 分别冻结基线完整 `generator`，并在 after 捕获前冻结候选源码的 `package.version` 为 `afterGeneratorVersion`。改后的 `generator.version` 必须精确等于该登记值；generator 名称、toolchain、其它键和值仍须与基线相同。只在上述身份核验成功后，才在比较副本中配对 version；不接受任意版本漂移。
- IR 的原始 receipt/hash 在两侧分别验证。native `docs.json` 与 publisher 打包的 Doc IR 都按同一组精确默认值规则比较；publisher 快照身份还须从打包的 Doc IR 和 manifest 独立验证。登记不把原始文件改写成 v18，也不把默认来源值概括成任意来源差异。
- search-index 仍是 `/11`，search-contract 仍是 `/2`。每侧的原始 `search-index.json`、`search-index.js` 和捕获 receipt 分别核验；严格解析 JS wrapper 的两个数据赋值：index 数据须与 JSON 一致，signature payload 在配对比较中须严格一致，且不允许额外可执行片段。另从 publisher 打包的 Doc IR 独立重算 snapshot ID，并以完整 schema 11 投影、UTF-8 长度前缀输入重算 projection fingerprint。
- 只有上述证明成功后，比较副本才可配对 `scope.snapshotId`、`scope.sourceSnapshotId`、`entries[].snapshotId` 及根/coverage 的 `projectionId`。其余 schema 11 payload、正文、分类、模块/依赖/暴露、href、顺序、coverage 与 contract 全部严格相等。保留两侧原始 JSON/JS、receipt、SHA-256 和新身份，不回写产物。
- ARIA 登记使用 `cjdoc.reader-aria-transition/1` profile。它必须冻结 `en` 与 `zh-CN` 两种 locale 的完整 before/after ARIA snapshots、对应 corpus/locale 身份及完整快照摘要；摘要和实际快照都须匹配。允许的树差异仅限 #173 的反向类型使用位置文案、#174 按投影成员数省略工具栏控件的默认状态，以及 #176 的真实 current-page/ancestor 状态。未知树差异拒绝。
- ARIA profile 仅约束 ARIA snapshot 差异，不豁免字体、字体文件、实际 font usage、字号、正文排版或其它视觉指标；这些仍按原规则相等比较。数值门槛、样本数、原始任务、声明下限、排名、print 检查和性能/资源阈值均不变。

这两项是 baseline 后、after 前写入新注册预算的 preregistration。`reader_compare.py` 仍只接收已冻结的 `--budgets`，没有 after-time 豁免开关；未注册时原有严格默认继续生效。它们描述可接受的窄差异，不是任何本地或远端 Reader 运行通过的证据。


若是新机器，应重新采集其 baseline 并绑定**同一份事先登记的数值模板**，不能把本地毫秒数与 runner 直接相减，也不能看完 after 再修改模板。单个比较器通过只证明已登记的检查，不代替 issue 的质量人工复核、人类可用性或全部已有验收。

## 回归与 CI 证据

`python3 -m unittest discover -s scripts -p test_reader_benchmark.py -v` 覆盖原始分位一致性、成对身份/字体/排序、真实任务失败不能被快时延掩盖、源码漂移、已有证据保护、资源统计不串进程、超时终止后代和日志隐私。设置 `CJDOC_READER_TEST_BINARY` 与真实 `CJDOC_READER_TEST_REVISION` 后，还运行实际原生 CLI 的 1 MiB 紧预算反例：原生命令退出 0，但观测器必须识别 `CJDOC3027`，不伪造 HTML 或浏览器通过。

RSS 顺序回归在独立的小控制进程中运行，避免完整测试套件的高驻留内存经 fork/exec 前阶段污染子进程峰值。64 MiB 分配与 32 MiB 差值断言不放宽；单文件通过不能替代完整 Python suite 的执行结果。

[Reader scale observations workflow](../../.github/workflows/reader-scale.yml) 复用同源 STS candidate 并核对 binary SHA-256；固定以 `67faf0b244544a750543f049370c59479769eff4`（Doc IR/17、search-index/11）为当前 CI baseline，在 checkout 外使用同一认证 SDK 构建。该基线刷新经显式批准：此门禁仅证明后续修复相对该版本的回归，不把它表述为旧协议到新协议的完整性能比较。旧 `2ef643c5d795ab2e3dfd1035517baeec3a88b0aa` 的历史观测保持原样，原功能变更的成本另行披露。

在同一 runner 上依次采 baseline、事前登记预算、采 after、运行行为回归并严格比较。固定 1k 按上文同时冻结 Doc IR、完整双语 ARIA 快照和 v18 presentation；其它规模不使用这三项登记。比较仍要求相同原始任务、样本数、完整字体环境、声明下限及资源/延迟预算。搜索 JSON/JS 各侧按 receipt 验证，只配对已证明的派生身份，其余 payload 严格比较；原始 JSON、日志、Doc IR、截图与比较作为该 run artifact 保留 30 天。手动选择资源受限 cohort 时比较仍为 `pass: false`、退出失败，不把观测完成记作支持该规模。
固定 1k 的 ARIA tree 只接受已冻结完整快照，排版与实际 font usage 只接受 `reader-scale-presentation-v18.json` 登记的差异；七家族安装清单和整个 environment 仍严格相等，数值预算不变。旧 `reader-scale-presentation.json` 继续只作 #163 的历史凭据，不用于当前 CI。
浏览器行为回归按当前检索契约校验：filter-only 同分结果使用 UTF-8 canonical identity 顺序，package 过滤保留 canonical-or-exposure 命中。历史恢复场景用显式 `name:` 条件选择唯一成员并核对其捕获的渲染身份，不对自由文本 discovery 的结果数量固定旧假设。

build、仓颉 unit、golden/integration、真实库、本地浏览器、远端 CI 必须分别报告。源码中存在脚本、较小 fixture 通过、ARIA snapshot 或截图好看，都不是较高层级已执行的证据。


## 历史 #163 的预期展示差异登记

历史改版的固定 1k cohort 使用 [`reader-scale-presentation.json`](reader-scale-presentation.json)，该例外不用于当前 CI 基线。
基线采集完成后，`reader_register.py --presentation` 将该文件的原始摘要、规范化内容摘要及完整内容写入注册预算，随后才采集 after。
默认不提供该参数时仍要求原来的完全相同排版。其它语料需要独立登记，不自动套用 1k 的例外。

该登记仅允许下列已审查差异：

- 正文从 15px 变为 16px，并加入明确的 CJK 字体回退；before/after 必须分别精确匹配登记的 CSS family 与字号。
- 实际使用字体的家族集合按语言分别登记；两次采集还必须具有完全相同的六家族安装文件清单和 SHA-256。实际节点字体仍逐项保留，不能把改后的字体使用集合当成另一台机器的环境。
- 无 JS 原生 ARIA 树只移除重复的“声明”标题、重复的 `choose` 文本，以及操作名称中的同一冗余标识符。四份[完整树快照](../../tests/fixtures/reader-presentation/)可直接比较；任何其它角色、顺序、链接、签名或契约变化都会改变登记摘要并失败。
- 原生 Doc IR 的两侧 `generator.version` 必须分别等于登记 profile 中冻结的 `baseline` / `after` 值；不得随当前包版本改写历史 profile。比较器先校验两个原始文件各自的 receipt 摘要，再对其余全部字段作严格相等比较；不规范化声明、来源、诊断、作者正文或签名。

查询排名、搜索 payload、原生目标、重载原文、print 可见身份和三种隐藏反例仍严格检查。
`reader-scale-budgets.json` 中所有绝对/相对性能预算均未改变。该登记不是性能通过凭据，旧的 invalid-evidence 不会被改写；以最新 HEAD 的完整采集结果为准。

另经单独授权，产品 Doc IR 物理对象上限由 65,536 提高到 131,072。编码器与严格解码器共用该值，并覆盖新边界的接受、拒绝和生成回退；文档/字符串字节、数组项、类型/Markdown 出现次数等独立限制不变。
这项容量调整与展示登记分别提交；先前 10k/50k 的历史观测不据此升级为支持声明。

当前查询与标签模型另经授权，将累计数组项上限从 100,000 调整为 131,072。完整 self 捕获的独立物理 JSON 计数为 109,656 项，512 MiB 与原 smoke 2 GiB 配方得到相同 Doc IR；对象、字节、字符串、类型/Markdown、SDK、堆配方和声明下限不变。此处记录容量依据，不把旧的资源受限观测或性能结果重新标为通过；后续语料必须按当前源码与产物重新采集。


重放历史固定 0.7.3 基线时，必须使用该 revision 自带的 `with_sts_o1_cjpm.sh`，以其记录的 `-O1` 规则重建。
当前产品继续使用当前仓库的 `-O2 --fno-chir-function-inlining` 规则。不要把当前包装器套到旧源码：旧版本的 markdown/yjson 依赖在普通 `-O2` 下有已记录的 llc 崩溃；这会在采样之前失败，不能解释成读者性能退化。两份构建日志和原生身份各自保留。
