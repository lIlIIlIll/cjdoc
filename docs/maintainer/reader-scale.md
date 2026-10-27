# 大规模 API 阅读基准

对应 [issue #153](https://github.com/lIlIIlIll/cjdoc/issues/153)。这是生成器和真实静态网页的观测协议，不是替代现有 `showcase_contract`、reading regression、density、语言、链接或安全门禁的另一套评分。

## 固定输入与原生生成

[`reader_corpus.py`](../../scripts/reader_corpus.py) 生成实际仓颉项目，不生成手写搜索索引。`rdr-scale-v1` 包含 50/500 成员、2/4/8/16 重载、泛型约束、命名/默认参数、继承、扩展、重导出、长契约/代码、中英文与真实缺译回退。声明数指显式源码声明；原生 Doc IR 和公开搜索投影的数量另记。

固定 1k 项目还通过了 SDK 1.2.0 的实际 `cjpm build`，35 条 unused 警告未被压制。独立消费包编译运行验证了四档公开重载、默认/命名参数、第 500 个成员和泛型映射；没有把 AST 接受声明等同于编译或运行通过。

[`reader_external.py`](../../scripts/reader_external.py) 校验并展开未修改的 yjson 固定归档。revision、URL、归档字节数/SHA-256、相关源码及配置的逐文件 SHA-256 都进入 manifest。任务来自该 revision 的 README 和作者声明，不从搜索结果反向挑选成功样例。它是同等 1k 规模的真实生产依赖交叉样本，不是整套 std/stdx 的容量证明。

`reader-corpus.json` 保存固定源码清单、输入摘要和任务。测量前后都会验证源码；加入未登记的 `.cj`、丢失文件或修改已登记内容都会拒绝测量。不要为了改后数据变好而删除正文、改变受众、缩短 fixture、换排序或放宽应用上限。

## 已采集的本地基线

固定生成源码为 `2ef643c5d795ab2e3dfd1035517baeec3a88b0aa`，实际版本为 cjdoc 0.7.3 / `cjdoc.doc-ir/16`。本阶段不改变任何已发布 Doc IR、schema 或 golden。完整凭据摘要、原生 CPU/墙钟/RSS 和原始报告摘要见 [`reader-scale-baseline.json`](reader-scale-baseline.json)。这些是该次观测，不是其它机器或 GitHub runner 的结果。

| 语料 | 原生结果 | 浏览器证据 |
|---|---|---|
| 1k 显式源码声明 | 1,000 声明，`complete`；两次源码生成的 Doc IR SHA-256 相同 | 两种语言、三种载体、20 次查询/筛选采样；160 张生成页面截图 |
| 10k 显式源码声明 | 编码预算预检返回 `CJDOC3027`、`partial` 的有界空投影；原生命令退出 0，观测器明确记为 `resource-limited` | 未运行，不生成虚假的零延迟或 PASS |
| 50k 显式源码声明 | 固定 512 MiB 仓颉堆耗尽，退出 1，`resource-limited` | 未运行，不声明支持该规模 |
| yjson 固定 revision | 2,319 声明、1,218 个公开/受保护声明，`partial`；保留未展开 Derive 宏的 `CJDOC1009` | 两种 UI 语言、三种载体；32 张生成页面截图 |

`CJDOC3027` 对应 `docIrFitsEncodedBudget` 的编码资源预检。当前产品诊断没有细分字节、对象、数组或类型子限额；不能把这次拒绝擅自解释成某个精确字节阈值，更不能推导通用的“最大声明数”。SDK 堆上限也不等于整个进程 RSS：后者包含非仓颉堆内存。

已观察到：宽查询 `member` 的目标在 552 个匹配的前 20 项之外；真实库的 `kind:function` 目标在 685 个匹配的前 20 项之外，均没有继续入口。50/500 成员正文筛选、257 项之后的精确深链，以及四档重载的选择、同时展开、历史恢复通过了脚本任务。长正文尾部 token 明确在 2,000-rune 摘录之外，不能把没有索引命中解释为原文不存在。

500 成员筛选有超过 100ms 的同步处理样本；CPU 采样热点位于 `saveMemberState` 读取滚动坐标的位置，而不是直接证明 `textContent` 或全站 rank/sort 有瓶颈。只在定位、成对复测后修改对应路径；不预先引入分片、全文复制或另一套搜索引擎。

## RDR-S2 的针对性改动

- 结果列表仍有界为每页 20 项，通过上一页/下一页继续发现；翻页复用当前查询的稳定排序，不引入另一套搜索引擎。查询、类别或包变更重置页码，原有精确身份、字段优先级、IME 与键盘交互保留。
- 翻页后结果链接继续支持方向键、Enter 和 Escape；方向键移动真实焦点，返回查询框或用 Ctrl+K 聚焦不会把当前页重置为第一页。查询、类别和包实际变更仍重置页码。Escape 保留原有清空查询语义，从结果返回搜索框。
- 空结果只表示当前索引没有命中；面板明确说明每项 2,000-rune 正文摘录边界，不提高截断上限或复制完整正文。
- `saveMemberState` 原来保存的文档滚动坐标没有恢复消费者，却会在成员 DOM 变更后强制布局。移除该无用字段，文档位置继续由原生历史负责；仅缓存实际恢复的 sidebar offset，并在 pagehide 同步取最终快照，覆盖未派发 scroll 事件就导航的情况。不能仅凭同步 JS 变快就宣称像素呈现变快；需要分开观察布局/下一帧与额外渲染机会。
- 键盘回归使用真实 DOM 事件与原生生成页面。保留 ranking/IME 单元行为检查，并让 DOM test double 提供标准事件 `target`；删除截取内部函数再用空 `render` stub 复述调用顺序的测试，不给新函数名重建 stub。现有真实 browser 的 Control/Meta+K 关闭移动主题 modal、解除 inert 并聚焦搜索的用例继续保留。
- 移动菜单的 pointer hit-test 先将实际 popup 原生滚入视口，再分别验证 action 位于视口内且实际接收指针；不将视口以外的坐标误判为 paint containment 裁切。菜单仍必须通过独立的浏览器 hit-testing，不能只看 DOM 存在或 `display`。
- `tests/browser/check-reader-discovery.mjs` 在实际原生 1k 站点检查完整分页身份/顺序、查询重置、IME/键盘精确尾部链接、立即导航后的 sidebar/文档历史，以及规定视口/明暗主题中的翻页控件和边界说明。它不替代冻结的三文件规模测量 harness。
- 首次完整成对 CI 的 500 成员下一帧 P95 最高 165.4ms，未达到事前 150ms 目标。独立 trace 将主要成本定位到恢复 500 行时的样式/布局（一次涉及 16,984 个样式元素、约 19k dirty layout objects），并排除仅增加 layout containment 的方案。仅在 screen media 中对未展开、无焦点且未打开操作菜单的行使用浏览器原生 `content-visibility:auto`；保留全部 DOM、作者正文和精确锚点，展开契约与 print 始终走完整布局。不支持所用 selector 的浏览器保留原布局。对所有行延后布局的早期方案曾使离屏展开契约的 rendered text 变为空，既有 showcase 检查捕获该回归；双展开后保留完整作者正文的实际场景防止重现。诊断样本不是正式通过凭据，仍以完整 cohort 的比较为准。
- 真实库的成对相对门槛也捕获了查询与冷加载退化；不同查询交替的 CPU profile 显示 `wordParts` 及逐字符分类是主要脚本成本。按原生 entry 对象惰性缓存不随查询变化的分词/缩写/拼写候选；缓存数量受当前索引条目数约束，不复制全部正文、不缓存固定查询响应，也不跳过不同查询的原始 rank/sort。正式比较继续要求原始前 20 排序和 index payload 完全一致。

## RDR-S4：重载任务与布局代价

固定 2/4/8/16 组的首项、中项和末项通过原生结构化参数身份选择；两语言、三载体共 66 个选择均正确，仍为查询加激活两次逻辑操作。24 个双展开比较保留两份完整原文签名、作者契约及 Back 恢复，均为筛选加两次展开三次操作。16 组末项保留命名/默认参数和真实缺失说明，不从文本猜测类型、异常、同步或复杂度。

实测不能仅汇总正确率：在同一 CI cohort 中，16 组双展开的自动化耗时从 baseline 约 90–93ms 增至 130–152ms。对同一原生站点做 20 次交替 CSS A/B（同源替换 stylesheet、不绕过 CSP），关闭小组的延迟布局后，比较 P50 为 150.3→98.0ms、P95 为 161.0→116.9ms；原始签名和作者正文逐次保持相同。这是定位布局代价的诊断，不是人类阅读时间、认知难度或冻结门槛的通过证明。

因此只在成员数超过既有 256 项导航边界时启用闲置闭合行的延迟布局。2/4/8/16 重载、50 成员及无 JS 页面保留普通布局；大页面的展开行、焦点、操作菜单和 print 仍不延迟布局。不删 DOM、不改正文、搜索 payload、身份或排序，不引入另一套阈值配置。

源码重建后的原生站点再与原生 S2 站点做 20 次交替比较（warmup 后计数，无 asset override）：16 组比较 P50 为 153.155→99.943ms、P95 为 167.549→119.631ms，仍为三次操作。两站的 index JSON/JS 与逐项原文详情完全相同；实际新 `search.js` SHA-256 为 `afcc26dbb107f4b7f606aebab2e467d42270aecb78653dd13b4829c0e8948f08`，stylesheet 为 `76bdba8c03b296fef3ccf4c915d5a4d3c1951363317d077ede7e4bc601637e3a`。这是实际编译产物的诊断性对照，不替代冻结 cohort 的严格比较或最新 HEAD 的 CI。

不增加按字符串猜语义的重载比较 UI。给定调用形状的准确性和操作次数没有要求新模式的证据；已观察到的代价由布局路径直接处理。缺作者说明、明确无额外限制、同异常的不同条件及来源不确定性按[作者侧契约复核](../contract-review.md)分别保留。人类比较任务和读屏语音仍未测，不能从自动化脚本推导无认知退化。



## 环境与指标语义

- SDK 固定为 Cangjie 1.2.0 STS、stdx 1.2.0.1 static sidecar、仓库现有 `-O2 --fno-chir-function-inlining` wrapper。sidecar 在 SDK 的父级布局中解析，不假设在 `cangjie/` 内。按[构建指南](build.md)准备环境，不修改 SDK/compiler/std/stdx。
- 浏览器依赖使用 `tests/browser/package-lock.json` 的 Playwright 1.63.0 / Chromium 153.0.8010.12；本地 Node v26.12.0。浏览器上下文 `en-US`，文档分别选择 `en`、`zh-CN`，基准视口 1440×900、DPR 1、light、CPU throttle 1、JS old-space 512 MiB。报告没有物理 CPU 隔离或跨设备速度可比性声明。
- 应用硬上限保持：Doc IR/单 artifact 64 MiB、artifact 总量 512 MiB、65,536 个输出条目、32,768 个类型出现次数。项目配置可以更严；冻结配置也在输入摘要中。源码缓存关闭；操作系统文件缓存不受控制，不声称冷 OS 缓存。
- 真实 HTTP root、HTTP subpath 与 `file://` 分开记录。HTTP 服务不启用传输压缩；gzip 数字只是相同文件的离线体积统计，不是压缩传输耗时。
- 原生生成和 Doc IR→HTML replay 分别记录 CPU、墙钟、退出码、最大单进程 RSS。`wait4` RSS 不是同时存活的进程树总内存；不支持 POSIX `wait4` 的原生观测明确拒绝，不伪造 Windows 资源数据。
- 查询与成员筛选保留全部原始样本和 nearest-rank P50/P95。成员序列交替清空/精确目标；不能把它写成仅测更容易的同值重复。`frameMs` 是下一次 `requestAnimationFrame` 的时刻，不保证像素已经绘制。
- `automationDurationMs` 是脚本协议耗时，查询/成员任务包含采样和自动化调度；`operationCount` 是逻辑读者操作数。它们不是人类完成时间，不能用二者相除得到“每次点击成本”。重载选择另记目标调用形状到准确原生链接的操作耗时。
- 伴随 JSON 的解析采样是隔离的 `JSON.parse`，不是把 JS 索引的实际加载/编译时间改名为 JSON 解析时间。真实页面同时记录导航、脚本 CPU、>50ms 长任务、DOM 与 CDP JavaScript heap；后者不是浏览器进程总 RSS。
- 字体记录采样节点的实际 family/PostScriptName，并记录 fontconfig 家族默认文件的 SHA-256，而不是仅抄 CSS `font-family`。这不是枚举所有字形、字重或字体文件的声明。不要混合不同字体环境的 before/after。

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

登记只读取 baseline 和已提供的数值模板，不读取 after，不覆盖已有登记。比较器重算原始样本分位，拒绝更换源码/任务、SDK、浏览器、字体、harness、语言/载体或缺失测量；保持 Doc IR 与搜索 index payload 的 SHA-256、前 20 排序、原始重载签名/作者详情，检查准确性、体积、堆、DOM、打印/无 JS 和布局。资源受限输出保持 `pass: false`，不能补造浏览器样本。

若是新机器，应重新采集其 baseline 并绑定**同一份事先登记的数值模板**，不能把本地毫秒数与 runner 直接相减，也不能看完 after 再修改模板。单个比较器通过只证明已登记的检查，不代替 issue 的质量人工复核、人类可用性或全部已有验收。

## 回归与 CI 证据

`python3 -m unittest discover -s scripts -p test_reader_benchmark.py -v` 覆盖原始分位一致性、成对身份/字体/排序、真实任务失败不能被快时延掩盖、源码漂移、已有证据保护、资源统计不串进程、超时终止后代和日志隐私。设置 `CJDOC_READER_TEST_BINARY` 与真实 `CJDOC_READER_TEST_REVISION` 后，还运行实际原生 CLI 的 1 MiB 紧预算反例：原生命令退出 0，但观测器必须识别 `CJDOC3027`，不伪造 HTML 或浏览器通过。

RSS 顺序回归在独立的小控制进程中运行，避免完整测试套件的高驻留内存经 fork/exec 前阶段污染子进程峰值。64 MiB 分配与 32 MiB 差值断言不放宽；单文件通过不能替代完整 Python suite 的执行结果。

[Reader scale observations workflow](../../.github/workflows/reader-scale.yml) 复用同源 STS candidate 并核对 binary SHA-256；另把固定 `2ef643c5d795ab2e3dfd1035517baeec3a88b0aa` 源码移到 checkout 外，使用同一认证 SDK 构建 baseline。在同一 runner 上依次采 baseline、绑定事先登记的数值模板、采 after、运行行为回归和严格比较。原始 JSON、日志、Doc IR、截图与比较保存为该 run 的 artifact，默认保留 30 天；需要长期归档时下载并保留摘要。手动选择资源受限 cohort 时比较仍为 `pass: false`、退出失败，不能把观测已完成误写成支持该规模。每个 run 都是独立 cohort，不冒充本地快照原始文件。

build、仓颉 unit、golden/integration、真实库、本地浏览器、远端 CI 必须分别报告。源码中存在脚本、较小 fixture 通过、ARIA snapshot 或截图好看，都不是较高层级已执行的证据。


## #163 的预期展示差异登记

固定 1k cohort 使用 [`reader-scale-presentation.json`](reader-scale-presentation.json)。
基线采集完成后，`reader_register.py --presentation` 将该文件的原始摘要、规范化内容摘要及完整内容写入注册预算，随后才采集 after。
默认不提供该参数时仍要求原来的完全相同排版。其它语料需要独立登记，不自动套用 1k 的例外。

该登记仅允许下列已审查差异：

- 正文从 15px 变为 16px，并加入明确的 CJK 字体回退；before/after 必须分别精确匹配登记的 CSS family 与字号。
- 实际使用字体的家族集合按语言分别登记；两次采集还必须具有完全相同的六家族安装文件清单和 SHA-256。实际节点字体仍逐项保留，不能把改后的字体使用集合当成另一台机器的环境。
- 无 JS 原生 ARIA 树只移除重复的“声明”标题、重复的 `choose` 文本，以及操作名称中的同一冗余标识符。四份[完整树快照](../../tests/fixtures/reader-presentation/)可直接比较；任何其它角色、顺序、链接、签名或契约变化都会改变登记摘要并失败。
- 原生 Doc IR 仅允许 `generator.version` 从 0.7.3 变为 0.7.5。比较器先校验两个原始文件各自的 receipt 摘要，再对其余全部字段作严格相等比较；不规范化声明、来源、诊断、作者正文或签名。

查询排名、搜索 payload、原生目标、重载原文、print 可见身份和三种隐藏反例仍严格检查。
`reader-scale-budgets.json` 中所有绝对/相对性能预算均未改变。该登记不是性能通过凭据，旧的 invalid-evidence 不会被改写；以最新 HEAD 的完整采集结果为准。

另经单独授权，产品 Doc IR 物理对象上限由 65,536 提高到 131,072。编码器与严格解码器共用该值，并覆盖新边界的接受、拒绝和生成回退；文档/字符串字节、数组项、类型/Markdown 出现次数等独立限制不变。
这项容量调整与展示登记分别提交；先前 10k/50k 的历史观测不据此升级为支持声明。


固定 0.7.3 基线必须使用该 revision 自带的 `with_sts_o1_cjpm.sh`，以其记录的 `-O1` 规则重建。
当前产品继续使用当前仓库的 `-O2 --fno-chir-function-inlining` 规则。不要把当前包装器套到旧源码：旧版本的 markdown/yjson 依赖在普通 `-O2` 下有已记录的 llc 崩溃；这会在采样之前失败，不能解释成读者性能退化。两份构建日志和原生身份各自保留。
