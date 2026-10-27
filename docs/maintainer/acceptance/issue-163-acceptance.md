# Issue #163：技术书页实现与本地验收

四类阅读页面及后续六项结构复核已落实到正式 HTML renderer。本文记录本地实现证据；**严格 #153 性能比较尚未通过，不能据此宣布 #163 全部验收完成**。没有推送、创建 PR、关闭 issue 或运行远端 CI。

## 固定输入与产物

| 项目 | 身份 |
| --- | --- |
| 原始 main 基线 | `2f02e08db058aebf0985ff4426d218e8614a9f18` |
| 最终生成源码 | `e77b872e8258d68157a295934f1b7b9e892e01d8` |
| 源码 archive SHA-256 | `b8a5d3558581220db1cc59820f08b47438d209868613a09a7fcdb47a8f1699b6` |
| 最终二进制 SHA-256 | `e677f90e6b0c758598e402b9b94c573cbf7f74add48aed173b4d8b3820717579` |
| 原始基线二进制 SHA-256 | `e8587bb0c34fb19e9c91273b5b0625b5ac1a68b28c970f26f987aaf4147ff5a7` |
| Doc IR | `cjdoc.doc-ir/16`；未修改公开模型或 schema |

最终生成源码固定了全部产品代码和示例内容。此后的文档、截图、发现测试入口和手机布局测试断言修订不改变生成器二进制。完整机器记录见 [evidence.json](issue-163/evidence.json)。

环境为 Linux、Cangjie STS 1.2.0、项目既有 STS `-O1` 包装器、静态 stdx、Playwright 1.63 和 Chromium 153.0.8010.12。原生测试使用 `cjHeapSize=2GB`；没有修改产品资源预算、SDK 或编译器。

完整预览从只读 `git archive` 导出的固定源码调用既有 `showcase_build.integration.build` 组装，包含双语、demo-v1/demo-v2、依赖文档、报告和离线归档，共 744 个 HTML。它实际执行了源码复制、依赖索引生成、版本组合、归档及站内链接检查。原工作区有需保留的无关未跟踪文件，因此**未宣称通过要求精确干净工作树的 canonical release gate**。

预览中的 cjdoc 自身 API 生成触发既有 `CJDOC3027`，保留有界 fallback；不能把它算作完整真实仓库 API 验收。PocketKit 四类页面与独立 `html_reference` fixture 不使用该 fallback。源码外链固定到上述本地未发布 revision，未验证 GitHub 已有对应提交。

## 实现边界

- 首页复用作者介绍和代码示例，在首个顶层代码块后提供阅读入口，再保留完整包索引和可展开的分类索引。没有作者内容时不制造教程或价值主张。
- 包页复用已有概述归属与绑定，提供真实指南和完整声明索引。自动占位页保留路由及 IR，不作为推荐指南。
- 类型页将用途、关键限制和完整声明合并成开场；成员标题与数量同排，删除重复成员显示名，保留完整签名、摘要和详情。
- 左栏负责项目、包及类型上下文；右栏使用短章节/成员定位，准确重载链接不变。搜索类别只本地化显示，索引值与查询协议不变。
- 指南使用连续文章结构和 H2 章节。“相关 API”来自已解析绑定，版本及来源退到详情。API 返回指南的章节由捕获树和实际绑定标记确定，不靠名称猜测。
- 同一外部索引失败在类型页集中列出一次，成员保留本地状态与详情入口；不同原因或歧义不合并，可用的成员专属链接仍原位保留。
- 手机成员筛选按需展开，活动条件数量可见，收起不清空条件；展开/收起成员按钮保留。无 JS 时原有字段和完整静态契约仍在。

作者示例中的用途、同步责任、快照和 `radix = 10` 由维护的 PocketKit 注释/指南提供；renderer 不改写第三方契约。写作入口与限制已更新到 [概念页与指南](../../guides.md)。实际视觉系统记录在 [DESIGN.md](../../../DESIGN.md)。

## 六项复核的处理结果

| 用户复核 | 结果及证据 |
| --- | --- |
| 首页入口晚、占位概念页被推荐 | 阅读入口放在最小例子后；实际指南优先，维护资料次级；占位包/模块页不参与推荐 |
| 类型契约混入生成器机制 | 示例类型注释保留调用约束；证明与索引机制移至维护指南；合并开场 |
| 标题 DOM/CSS 不匹配 | `.member-group-heading` 负责标题/数量同排；浏览器检查对齐；移除重复显示名 |
| 同一个外部故障重复 26 次 | 完整预览先生成并复制支持索引；另有原生回归验证共享故障只集中呈现一次 |
| 指南被绑定状态打断 | 原位置显示相关 API 短签名；状态次级；H1 → H2，稳定锚点保留 |
| 导航重复、内部类别裸露 | 类型页移除左栏成员复列，右栏短定位；中文显示“函数/指南”，原始 `function/concept` 值不变 |

独立视觉复核先查看四类页面的 24 张视口/全页图，唯一修复项 F1 为手机成员工具栏。修复后的同视图复核给出 `ship`，将 F1 评为 resolved；该结论只覆盖 F1 和本轮引入的可见回归，不替代运行测试或全部 issue 验收。

## 截图与阅读任务

下列原生截图通过真实 `file://` 加载原 CSS、JavaScript 和 CSP；未内联资源、移除 CSP 或修改生成 HTML。完整截图目录包含 1440×900、960×900、390×844 的视口图与全页图。

| 页面 | 1440 | 960 | 390 | 全页示例 |
| --- | --- | --- | --- | --- |
| 首页 | [截图](issue-163/home-1440.png) | [截图](issue-163/home-960.png) | [截图](issue-163/home-390.png) | [手机全页](issue-163/home-390-full.png) |
| 包页 | [截图](issue-163/package-1440.png) | [截图](issue-163/package-960.png) | [截图](issue-163/package-390.png) | [桌面全页](issue-163/package-1440-full.png) |
| API | [截图](issue-163/api-1440.png) | [截图](issue-163/api-960.png) | [截图](issue-163/api-390.png) | [手机全页](issue-163/api-390-full.png) |
| 指南 | [截图](issue-163/guide-1440.png) | [截图](issue-163/guide-960.png) | [截图](issue-163/guide-390.png) | [手机全页](issue-163/guide-390-full.png) |

成对图使用**同一份最终 Doc IR**，分别交给原始 main 和最终 renderer，主题、语言、视口及字体安装环境相同；CSS 字体选择本身是本次改动之一，不能宣称前后实际使用了完全相同的字体。代码/内容输入一致，中文和英文 `search-index.js` 前后逐字节相同。

| 页面 | 桌面前 → 后 | 手机前 → 后 |
| --- | --- | --- |
| 首页 | [前](issue-163/paired-before-home-1440.png) → [后](issue-163/paired-after-home-1440.png) | [前](issue-163/paired-before-home-390.png) → [后](issue-163/paired-after-home-390.png) |
| 包页 | [前](issue-163/paired-before-package-1440.png) → [后](issue-163/paired-after-package-1440.png) | [前](issue-163/paired-before-package-390.png) → [后](issue-163/paired-after-package-390.png) |
| API | [前](issue-163/paired-before-api-1440.png) → [后](issue-163/paired-after-api-1440.png) | [前](issue-163/paired-before-api-390.png) → [后](issue-163/paired-after-api-390.png) |
| 指南 | [前](issue-163/paired-before-guide-1440.png) → [后](issue-163/paired-after-guide-1440.png) | [前](issue-163/paired-before-guide-390.png) → [后](issue-163/paired-after-guide-390.png) |

[用户提供的方向比较](issue-163/review-reference-comparison.png)及[四页复核图](issue-163/review-reference-four-pages.png)原样保留。它们比较不同编排，用于解释方向，不能作为同内容密度或性能基线。没有取得原型 zip、独立 FORM 种子或 QUALITY BAR 卡，也没有声称逐像素匹配原型。

实际阅读任务由现有浏览器测试执行：

1. 从首页例子后的指南或 API 入口进入包页，读取作者概述并找到 `TextCatalog`。
2. 同时展开 `add(Int64, Int64)` 和 `add(String)`，保留完整签名；读取整数重载仅支持 10 的作者限制。筛选 `radix` 后只保留准确重载，数量显示部分匹配。[完整重载组件截图](issue-163/add-overloads-expanded.png)。
3. 从准确重载进入指南的实际章节，再沿相关 API 返回声明；指南章节按文章层级呈现，API 关联状态不占正文主线。

固定中文、纸色主题和当前字体样本的入口位置如下。数值解释本次内容顺序，不作为跨内容/语言的硬阈值。

| 位置 | 1440×900 | 960×900 | 390×844 |
| --- | ---: | ---: | ---: |
| 首页集中阅读入口 | 607 | 671 | 716 |
| API 首个成员 | 692 | 755 | 788 |

手机 F1 修复前的 API 首个成员为 y923。英文原有契约较长，不通过删正文或缩字强制塞进首屏；两种语言均验证成员工具栏不超过一行。

## 本地验证矩阵

| 验证层 | 结果 | 范围与限制 |
| --- | --- | --- |
| 项目 build | PASS | STS 1.2 项目构建；不涉及 SDK 构建 |
| 原生 unit | 680/680 PASS | 最后产品代码后重跑；0 skip/error/failure |
| Python 工具 | 542 PASS，4 SKIP | 共 546；排除门禁 preflight 的 SDK 安装/stdx 模块；4 个既有条件跳过不算通过 |
| showcase contract | 204/204 PASS | 包括作者输入库存与组装契约 |
| 冻结 golden / integration | 9/9 PASS | v16 fixture 原文件未改；两次生成逐字节确定、严格 JSON round-trip |
| 浏览器交互 | 28/28 PASS | 中英、四角色、七宽度、八主题、root/subpath/file、版本组合及既有成员操作 |
| 静态 HTML 安全/链接 | PASS | 非 PocketKit 参考站中英各 94 HTML/48 搜索条目；canonical 脚本哈希与 CSP 校验 |
| 完整预览组装 | PASS | 744 HTML 站内引用校验及离线归档；自身 API fallback 限制见上 |
| 独立消费者 | 13/13 PASS | 实际编译运行作者输入/状态样例；测试于 `04c3fdb…`，PocketKit 树与最终源码相同：`0343f70f…` |
| 最终千声明发现 | 中英各 8/8 PASS | 971 函数/49 页；分页顺序、IME、快捷键、尾部成员、双开详情、深链、历史及手机操作命中 |
| 真实外部仓库 smoke | NOT RUN | 不用 fixture 或自身有界 fallback 替代 |
| 远端 CI / 跨平台 | NOT RUN | 没有运行 GitHub runner、Windows/macOS 浏览器或发布 |

首次并行运行 Python 工具测试时，三个构建参数用例读到 STS 包装器暂时改写的 manifest 而失败；原生构建结束后完整串行重跑通过，保留两轮原始日志，没有修改测试来掩盖失败。

八主题与两种语言、四角色共 64 组普通可见文本采样，对比度最低为 **4.500396:1**。实际平台字体记录包含 Noto Sans、Noto Sans CJK SC、Noto Serif CJK SC、Liberation Mono，均为本地字体，未下载 webfont。该采样不等于所有可能展开状态、屏幕阅读器或跨平台字体的全量证明。

已检查 760/761、1180/1181 两侧，核心正文/摘要/代码保持 16/15/14 CSS px，无整页横向溢出。200% 使用既有 CSS zoom 及等效 720px reflow/no-JS/print 路径；**未验证桌面浏览器 UI 的实际 200% 缩放和屏幕阅读器发声**。

## #153 证据边界

原有小型参考密度脚本的数值门槛未变。25 个声明保持不变，完整 inline 详情仍在：

| 指标 | 原始 main | 最终实现 |
| --- | ---: | ---: |
| 成员区域起点视口内成员 | 5 | 7 |
| 折叠成员总高度 | 2956.61px | 2127.69px |
| 平均成员高度 | 118.26px | 85.11px |
| DOM 节点 | 1833 | 1742 |
| 类型页大小 | 268712B | 266194B |
| 参考资源合计 | 468060B | 465282B |
| 筛选帧中位数 | 16.6ms | 16.6ms |

这不是完整的大规模 P95 性能门禁。脚本仅补充实际 revision 元数据，并把未测生成时间记为 `null`；没有改 100ms、512KiB 或 8000 DOM 的既有门槛。

曾按原注册预算运行千声明完整成对观测，包含 20 样本、两种语言和 root/subpath/file。第一轮因实际字体集合改变被拒；固定字体安装环境重跑后，比较器仍因有意调整的正文 CSS 字体/字号返回：

```text
status: invalid-evidence
pass: false
reason: visual ["desktop", "light", "overload16", "en"]: body typography changed
```

这批观测对应较早实现，不是最终二进制的完整性能结果。没有改比较器的相同排版前提、冻结预算或原始观测，没有将其重标为 PASS。最终二进制补跑了千声明功能发现与上述小型密度检查；10k/50k/外部语料性能未运行。

因此 E-09 仍为 **PARTIAL**：已有功能与局部预算证据，但缺少可接受的最终严格成对性能证明。E-05 的实际浏览器 UI 缩放、屏幕阅读器及跨平台层面也不作完成声明。其余实现与本机证据以本文逐项范围为准，不以原型、截图或较低层级测试替代。

## 复现与保留证据

最小生成与回归入口：

```bash
cjpm build
cjpm test
python3 examples/pocketkit/reproduce.py --help
# CJDOC_READING_FIXTURE 指向真实生成的双语 HTML 根目录
node tests/browser/node_modules/@playwright/test/cli.js test \
  --config tests/browser/playwright.config.mjs
```

完整原始日志、浏览器报告、字体观测、原始失败、固定源码 archive、完整预览和原工作区备份保留在任务私有目录 `$HOME/.cache/agent-tmp/issue-163-5iXwTS32`（整理前约 1.4GiB）。主要文件：`final-identity.json`、`native-final.log`、`python-tools-serial.log`、`accepted-browser.log`、`accepted-browser-report/index.html`、`golden-final/results.json`、`final-discovery-{en,zh}/reader-discovery.json`、`density-final.json`、`reader-fixed-comparison.json`、`final-preview.log`。

预览离线包为该目录下 `final-preview/downloads/showcase-offline.zip`，约 5.4MiB。解包后从 `index.html` 或 `examples/demo-v2/html/zh-CN/index.html` 打开；保留整个目录以支持资源和跨页导航。


## PR #165 CI 修复补充

远端展示站点检查已在 `ce583fa3d92ae9ae955946de3d02405d603703d7` 通过两组浏览器场景与阅读回归。
后续经用户明确授权，新增固定 1k 的[展示差异登记](../reader-scale.md#163-的预期展示差异登记)，并提高产品 Doc IR 物理对象上限。
这些是后续修复，不改写上述历史观测或将旧 invalid-evidence 重标为 PASS。远端最新提交仍需重新完成原生、集成、展示站点和阅读性能门禁。
