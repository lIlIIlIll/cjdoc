# #153：大规模 API 阅读任务与针对性优化

本记录区分已执行的原生生成、浏览器任务、作者事实复核与远端 CI。它是时间点证据，不把旧 run 外推为后来 HEAD 的通过；最终集成状态以各 PR 最新 HEAD 的 Checks 与 issue 的闭环记录为准。

阶段分别交付：[S1 / #155](https://github.com/lIlIIlIll/cjdoc/pull/155)、[S2 / #156](https://github.com/lIlIIlIll/cjdoc/pull/156)、[S3 / #157](https://github.com/lIlIIlIll/cjdoc/pull/157)、[S4/S5 / #159](https://github.com/lIlIIlIll/cjdoc/pull/159)。不重新实现原生折叠、语言切换、基础搜索或 #149 的异常翻译修复；不改变公开 Doc IR、搜索 payload、排序原则及既有资源/安全/密度预算。

## 固定输入、环境与资源边界

完整协议、复现命令、指标语义及事前预算分别见 [reader-scale.md](../reader-scale.md) 与 [reader-scale-budgets.json](../reader-scale-budgets.json)。三个浏览器 harness 文件的协议冻结；修改观测器必须重采同协议 baseline/after，不能混用历史数据。

- Cangjie 1.2.0 STS、stdx 1.2.0.1 static sibling sidecar、`-O1`、`cjHeapSize=512MB`。Playwright 1.63.0 / Chromium 153.0.8010.12 / Node 26.12.0。
- HTTP root、HTTP subpath、真实 `file://` 分开；每项查询/成员筛选 20 个原始样本。文档 en/zh-CN，浏览器 locale en-US；字体文件名、SHA-256、实际 computed fonts、viewport、主题、CPU throttle=1 和 JS old-space 512MiB 随报告保留。没有物理 CPU 隔离或跨机器速度可比性声明。
- 本机 SDK fingerprint `c854d1432ffa63b8dffb60fe75c23a9a1cd07667bfb07edb92bb0b3cb522388a`；下述 hosted cohort 为 `282c2bc7d0ba20d500d6930649c5a672c173c0b0ce1f76c8f4d8d0a7866aec0a`。只在各自同环境的成对数据内比较，不相减两处毫秒数。
- 源码缓存关闭；不声称冷 OS 文件缓存。HTTP 不做传输压缩，gzip 是离线文件统计。JSON.parse companion probe 不冒充实际 `search-index.js` 脚本载入。

| 语料 | 实测结论 | 不能声称的结论 |
|---|---|---|
| 固定 1k；50/500 成员；2/4/8/16 重载 | 1000 声明、1001 搜索条目；7,408,201-byte Doc IR，SHA-256 `f74686c099dd984a5a2ed6fc30c8e326ac0070fa0ff10dba51ee96cb9d504d53`；前后完全相同 | `CJDOC3028` 表示总 highlight metadata 预算耗尽时省略元数据但保留代码文字；`CJDOC3108` 的真实语言回退保留，不宣称所有作者字段完备 |
| 固定 10k | 改后原生退出 0，但 `CJDOC3027` 明确拒绝资源；90.940s、最大单进程 RSS 424,960,000 bytes；有界空 Doc IR | 不是 10k 阅读支持 PASS，没有浏览器样本；不臆断诊断未说明的具体子预算 |
| 固定 50k | 固定 Cangjie heap 耗尽、退出 1；274.062s、最大单进程 RSS 606,044,160 bytes；没有 Doc IR/浏览器结果 | 不是支持规模 PASS，也不是 timeout |
| 外部 yjson | 固定 `54b4965dee0f0b96710cbc678ec5ec9a126b055c`；2319 原始声明、1218 public/protected 投影、823 搜索条目 | `CJDOC1009` 的未展开 Derive 与 `CJDOC3028` 保持显式 partial；不是整套 std/stdx 或全语义证明 |

外部 archive SHA-256 为 `083861dab05c1465af607998652ec5e5817d108519c36df936809862bf0b5837`，源码清单的 `sourceSha256` 为 `d22250b060c1d8afe48bbf0da0e530e6a45c7e3a7116d09b20d5eb5e041f2a1e`，不是 manifest 文件本身的 digest。原生 CPU/墙钟/退出码/最大单进程 RSS 与浏览器成本分别记录；RSS 不是进程树同时峰值，CDP JS heap 也不是浏览器 RSS。任意超时均失败，不伪装资源拒绝。

## S2：完整发现路径与同 runner 对照

[Reader run 40051240892](https://github.com/lIlIIlIll/cjdoc/actions/runs/40051240892) 使用 baseline `2ef643c5d795ab2e3dfd1035517baeec3a88b0aa` 与实际 PR merge source `5db8af5895d71a564527afc13d857b395fb38e8f`，**248 项严格比较通过，failures=[]**。原始 artifact [12544222273](https://github.com/lIlIIlIll/cjdoc/actions/runs/40051240892/artifacts/12544222273)，ZIP 36,618,395 bytes，SHA-256 `a7234e92b5b2186be186064722dd90d9f51154adb61cf21176907571b19eb6bc`；包含原始 JSON、日志、Doc IR、未裁剪 PNG 与产物 inventory，默认保留 30 天。长期复核需下载归档，不把临时 artifact 当永久托管。

以下为该 cohort 的同环境对照；P50/P95 列是各固定查询分位的最大值，不是混合任务的新分位。三载体顺序均为 root/subpath/file。

| 指标 | baseline | S2 after |
|---|---:|---:|
| en 查询同步 P50 最大值 / ms | 11.8 | 2.3 |
| en 查询同步 P95 最大值 / ms | 17.7 | 3.3 |
| en 下一帧 P95 最大值 / ms | 20.0 | 15.6 |
| zh-CN 查询同步 P95 最大值 / ms | 17.3 | 3.0 |
| 500/50 成员任务同步 P95 最大值 / ms，en | 90.5 | 8.7 |
| 成员任务下一帧 P95 最大值 / ms，en | 120.3 | 29.2 |
| 成员任务下一帧 P95 最大值 / ms，zh-CN | 124.2 | 31.8 |
| en 冷首次交互探针 / ms | 200.4 / 200.1 / 173.3 | 195.3 / 170.6 / 167.9 |
| en 热首次交互探针 / ms | 64.8 / 68.8 / 75.8 | 62.9 / 62.0 / 76.6 |
| en 独立 JSON.parse P95 / ms | 2.0 / 1.8 / 2.1 | 1.9 / 2.0 / 1.9 |
| en 查询页 CDP heap / bytes | 4,202,252 / 4,204,856 / 4,210,000 | 7,065,120 / 7,044,248 / 7,089,436 |
| en 查询页累计 >50ms long task 数 | 0 / 1 / 0 | 1 / 1 / 0 |

不可把 heap 增长写成下降；按 entry 缓存不可变分词等事实有约 3MB 的该页成本。累计 long tasks 包含导航，不能全部归因于查询或声称零长任务；下一 rAF 不是实际 paint。

索引 JSON 1,019,866 bytes、JS 1,143,302 bytes，payload SHA-256 前后相同。S2 `search.js` 为 62,576 bytes / 离线 gzip 15,311 bytes，`style.css` 为 78,051 / 15,222 bytes；离线压缩结果不跨 zlib 环境混比。

所有 11 个固定查询 after case 均通过，其中 S011 是应明确揭示的 2,000-rune excerpt 边界，不代表全站不存在。S009 在 baseline 无继续路径，在 after 三载体均不位于前 20，但可经 27 个 continuation page、28 次逻辑操作到达。每页最多 20 条，原始 ranking/身份顺序不变；971 个 function entry 的 49 页全量逐项比对通过，不错误去重合法 re-export alias。

500 成员正文过滤、冲突 filter 后的精确深链覆盖 member0256/member0499；左栏 256 上限仍明确，完整成员 DOM 与 TOC 保留。真正的 Next→ArrowUp/Down→查询 refocus/Control+K→Enter/Escape、IME、独立 API 页与 owner fragment、立即导航后的 sidebar/document Back 恢复均在两语言原生页实测。移动菜单分别验证 viewport 内的真实 popup 和独立 pointer hit-test，不把视口外坐标误写为 paint clipping。

外部 [run 40045380073](https://github.com/lIlIIlIll/cjdoc/actions/runs/40045380073) 的实际应用二进制 SHA-256 为 `a98f176bab421d67edceaf7304af6a6b39005d4f3d0fbf1404c5d3a6182e6777`（emitted `search.js` 为 f79d…），完成 **146 项严格比较通过**；en 最坏同步 P95 23.6→3.1ms、下一帧 P95 25.8→16.8ms。E009 从前 20 外可经 33 页/34 次操作到达。此为独立真实库 cohort，不与 1k 或本机数值相减。

## S3：作者事实而不是语义评分

[contract-review.md](../../contract-review.md) 分别定义 coverage 存在性、quality/lint 非模板结构质量、作者可验证的语义充分性与一致性。八维 checklist 包括适用参数域、None/异常条件、成功与失败状态、容器/元素所有权、资源关闭、并发、复杂度和跨语言/来源；无自动推断式诊断、评分或新增公开字段。

真实未修改的 PocketKit demo-v2/support-v1 库先由 cjpm 构建，再由 cjc 编译实际消费者并执行 **13 个输入/状态用例**：复制/保序/重复/空输入；at/tryAt 的 -1、size、0 及失败后状态；默认十进制与不支持 radix；addAll 拷贝；snapshot/clear 容器独立；空输入/两行/反复 EOF；EOF 后 rewind；重复 close；关闭后 read/rewind 拒绝且保持关闭。

文档逐项列出作者说明、实现分支和实际运行，保留缺说明、确有矛盾、跨方法矛盾、合法稀疏、未知与明确无额外限制、同异常类型不同触发条件的反例。addAll 的失败原子性未被作者承诺；单线程成功示例不证明线程安全、任意分配失败或复杂度；内存 TextReader 不推广为所有同名 API 的 OS 资源语义。

## S4：四档重载与有证据的布局修正

源码绑定的新原生 main SHA-256 为 `eb18343acb039efc2898f4e6ac46edbfed21ae6aec44d5fb29bb30b162245328`；build checkout `5c6430670d5ae2748e56953b00d8f6f59e3984e7`、tree `08b3ba44cf6b5f3d8a6eaad82a151139effe47f7`。这是实际 GitButler workspace identity，不冒充后来发布分支/集成 commit；之后 self baseline checksum 的同步不被误写为同一完整 tree。

实际生成并经 strict validator 核对的 `search.js` SHA-256 为 `afcc26dbb107f4b7f606aebab2e467d42270aecb78653dd13b4829c0e8948f08`，62,854 bytes；stylesheet 为 `76bdba8c03b296fef3ccf4c915d5a4d3c1951363317d077ede7e4bc601637e3a`，78,082 bytes。两语言各验证 2008 页、1001 个搜索目标；不从源码解码 hash 代替原生 emitted proof。

该二进制的完整本机 cohort 另与固定 baseline `2ef643c5d795ab2e3dfd1035517baeec3a88b0aa` 配对，严格比较 **248 PASS / failures=[]**。使用相同源码、字体、SDK、浏览器、两语言/三载体及 20 样本；数值模板在 S1 已冻结且未改。本次实际采样顺序为 after→baseline，注册器只把 baseline 绑定到既有模板，不读取 after，也不据 after 改阈值；不是交替全 cohort 或 hosted-runner 证据。

最终原生 cohort 的两语言/三载体合并结果如下。区间为具体自动化 task 的 min–max，不是 P95 或人类阅读时间；每个组的选择均两次操作、双展开比较均三次操作。

| 同名重载数 | 准确选择用例 | 选择耗时区间 / ms | 双展开比较用例 | 比较耗时区间 / ms |
|---|---:|---:|---:|---:|
| 2 | 12/12 | 121.95–164.98 | 6/6 | 86.28–101.27 |
| 4 | 18/18 | 117.29–180.35 | 6/6 | 85.30–111.46 |
| 8 | 18/18 | 124.45–163.03 | 6/6 | 86.65–109.78 |
| 16 | 18/18 | 120.25–187.44 | 6/6 | 94.51–119.15 |

准确性不能掩盖代价：S2 的小组延迟布局让 16 组双展开产生额外成本。先用同一原生站点 CSS A/B 定位，再重建源码、对完全未修改的原生 before/after 站点作 20 次交替诊断（warmup 后计数，无 asset override/CSP bypass）：比较 P50 **153.155→99.943ms**、P95 **167.549→119.631ms**，操作数仍为三。两站 index payload、逐项原文签名/作者正文相同，独立同时展开及历史恢复逐次通过。

只在超过既有 256 成员边界的大页面启用闲置闭合行的延迟布局；小组、50 成员及无 JS 保留普通布局，展开、focus、操作菜单与 print 完整布局。不删 DOM、不缩正文、不加阈值配置。没有给定调用形状的准确性/操作数证据要求新的比较模式，已测代价由布局路径处理，因此不增加字符串猜类型或异常语义的比较 UI。人类认知任务未测，不推导“无认知退化”。

## S5：最终视觉、导航与可访问性边界

最终真实 native HTML 采集 **160 张**成员/重载/作者样本截图：1440×900、960×900、390×844、760/761/1180/1181px、720×450 DPR2，light/dark、en/zh-CN。最后一项为物理 1440×900 的 200% 等价布局，不声称操作了 Chrome zoom 菜单。所有布局记录 overflow=0；实际检查了移动中文长默认/命名参数、缺译标记、缩放下完整作者签名与焦点、桌面第 500 项展开正文，不只检查 DOM 文本。

同环境原生 baseline 的对应 160 图也已完整采集，形成 320 张 before/after 矩阵；最终搜索控件另采两语言共 32 图。最终两语言 discovery 各八个真实任务通过，包括 971 个函数的 49 页精确序列、实际焦点/IME、离屏双展开全文、移动 popup hit-testing、独立页/深链与立即 Back 恢复。

正文保持 15px。Member500 保留 21,338 DOM nodes 与 503 个 TOC 定位链接；长签名确会折行，现有 wrapped-link heuristic 不是完整逐行排版统计。重复导航的存在本身不证明任务退化：准确深链/筛选/Back 保留，删除 TOC 还会损失超过 256 项的直接定位，因此不无证据重划左右栏职责、缩字号、删信息或加主题。

两语言无 JS 的两个原生重载可独立同时展开；print media 中两份原始签名与两份契约正文可见。观察器通过真实隐藏 body/signature/main 的三种 CSS 反例验证，检查所有祖先 computed visibility 与渲染 box，不用仅长度或存在性冒充可见性。ARIA tree 不等于读屏语音，print media 不等于实体纸张/分页；语音会话没有实测。

补充原生 S2/S4 的 500 成员对照：禁用页面 JS 时，整个 main 的 ARIA tree/顺序完全一致；由自动化打开全部 500 个 details 后，在 print media 中 500 个签名及 500 个正文均可见、身份逐项相同、无横向溢出。不将这写成默认关闭状态自动全展开、语音会话或纸张分页的证明。

实际 HTTP GUI 从搜索进入 Member500，过滤并键盘展开 member0499，观察到 500 个 DOM 成员、完整作者摘要与返回值、overflow=0、无页面 JS error；辅助 managed 浏览器不混入冻结 Chromium/font/viewport 性能 cohort。

## 回归、失败记录与核验入口

- 完整 guarded STS native build 通过：main/worker、9 份 v16 golden 输入与 5 份 vendor 输入核验；这不是“完整 unit/golden 执行”的同义词。独立 search/TOC/strict HTML safety 定向 Python 测试 **13 PASS**。
- S2 首次完整 cohort 曾测出 500 成员 frame P95 165.4ms，未达到事前 150ms；保留失败，不放宽预算。全行 content-visibility 的早期方案又使离屏展开正文 rendered text 变空，真实 showcase 捕获后改为闭合闲置行，并补真实远距离双展开场景。
- 分页 Next 后键盘失败在原生页复现后修复；测试提供真实 DOM target，删除截取函数加空 render stub 的 wiring 测试，不为新函数名重新钉 stub。既有真实 Control/Meta+K modal/inert/focus 场景保留。
- S2 `d849313` 的 Reader/Showcase/macOS/Windows 通过；Linux 的 native/Python/CLI/provider/a11y/真实仓库 acceptance 通过后，独立 self Doc IR identity 捕获旧 checksum。实际两次输出均 `78c0b5b4…`，`4c3a45a` 仅同步 `referenceDocsSha256`，不改 frozen 状态、elapsed/RSS 或门槛。不把该历史 workflow failure 写成成功；后续以 PR 最新 HEAD 为准。
- `4c3a45a` 最新 HEAD 随后实际全部通过：[三平台 CI 40054825031](https://github.com/lIlIIlIll/cjdoc/actions/runs/40054825031)、[Reader 40054825122](https://github.com/lIlIIlIll/cjdoc/actions/runs/40054825122)、[Showcase 40054825060](https://github.com/lIlIIlIll/cjdoc/actions/runs/40054825060)、[review gate 40054821882](https://github.com/lIlIIlIll/cjdoc/actions/runs/40054821882)。这是 S2 的完成证据，不外推为 S3/S4 的最新 HEAD 通过。

| 完成条件 | 可复核入口与边界 |
|---|---|
| AC-01 | 固定 corpus/recipe/source manifest、原始 generation/browser JSON、字体/SDK/browser 身份、baseline/after 与事前 budget；10k/50k 明确资源拒绝，不伪造浏览器 PASS |
| AC-02 | 11 个固定查询、S009 continuation、S011 excerpt 边界、49 页完整身份顺序、member0256/0499、独立页/深链及 history |
| AC-03 | 同 runner 248 项比较、外部 146 项比较；冷/热、同步/rAF 分位、long task、CDP heap、资源字节与原生 RSS 语义分开 |
| AC-04 | 三层质量、八维作者 checklist、真实 13 用例与缺失/矛盾/合法稀疏/未知反例，不推断行为承诺 |
| AC-05 | 66 个选择、24 个双展开；精确模型身份、原文签名/契约、命名/默认参数、并行展开与历史；不新增无证据比较 UI |
| AC-06 | 最终 160 图、各 viewport/theme/locale 的布局与真实交互；print 可见性反例、无 JS/ARIA、语音未测边界 |
| AC-07 | 各阶段 PR 的最新 HEAD Checks：既有 native、golden/integration、quality、schema/version、语言/链接、offline/CSP、Showcase reading/density/browser；本机局部通过不替代它们 |
| AC-08 | #155→#156/#157→#159 独立 PR，最终 issue 汇总实际 run/head 和集成状态，不为清空 checklist 增功能 |

复现规模数据按 [reader-scale.md](../reader-scale.md) 的原生命令、冻结 harness、注册与严格比较执行；真实契约消费者按 [contract-review.md](../../contract-review.md) 执行。已有 native 1k 站点另可运行以下真实分页/键盘/菜单/历史检查（输出目录必须全新）：

```bash
node tests/browser/check-reader-discovery.mjs \
  --site "$EVIDENCE_ROOT/after-1000/observation/locale-en/html" \
  --output "$EVIDENCE_ROOT/discovery-en" --locale en
python scripts/validate_html_site.py \
  "$EVIDENCE_ROOT/after-1000/observation/locale-en/html"
```

语言分别重跑 en/zh-CN。测试、源码与文档来自同一实际待测 revision；保留 raw evidence，删除自己的临时服务/脚本时不删除失败凭据、不触碰其他工作树或会话输出。
