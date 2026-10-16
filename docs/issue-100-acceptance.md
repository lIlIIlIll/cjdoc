# 复现静态代码高亮验收

本文面向维护者，说明如何独立复现 #100 的 CLI、冻结 IR、发行适配包和浏览器验收。架构、语言别名和预算见 [高亮边界](research/highlighting.md)。运行成功仅证明对应证据层，不代表跨平台 CI 或正式发布已经成功。

## 准备固定环境

- 按仓库说明准备已认证的 Cangjie STS 1.2.0 与同版本 static stdx sidecar。stdx 是 SDK 的同级目录，不在 SDK 内。
- Node.js 26.11.1、锁定 Highlight.js 11.11.1；先在受控准备阶段预置 npm 缓存，随后在 `tools/highlight` 执行 `npm ci --ignore-scripts --offline`。
- 浏览器依赖按 `tests/browser/package-lock.json` 预置；执行时不安装或下载。
- 使用磁盘上的私有工作目录，设置 `TMPDIR`、`TMP`、`TEMP` 和 `PYTHONDONTWRITEBYTECODE=1`。每次 harness 的 `--workdir` 必须不存在。

STS 构建遵循现有 `scripts/with_sts_o1_cjpm.sh`，不要修改 SDK 或提高 codec/高亮限额。脚本要求先设置 `GITHUB_WORKSPACE` 和 `RUNNER_TEMP`，source 后明确设置已认证的 `CANGJIE_STDX_PATH`，再用 `scripts/with_stdx.py --variant static` 包装命令。

## 运行 CLI 与离线验收

先构建主程序和公开 API 取消测试宿主，再在同一环境运行真实 harness：

```bash
cjpm build --jobs 1
(cd tests/fixtures/projects/highlight_host && cjpm build --jobs 1)
python3 scripts/highlight_acceptance.py \
  --binary target/release/bin/main \
  --node "$(command -v node)" \
  --api-probe tests/fixtures/projects/highlight_host/target/release/bin/main \
  --workdir "$TMPDIR/highlight-acceptance"
```

有安装器归档 receipt 时可追加 `--sdk-receipt <receipt-path>`；harness 会核对相邻归档摘要，只在报告中写入版本、target 和摘要，不输出机器路径。`--baseline-binary <path>` 是可选的旧二进制比较，不替代同一二进制的 on/off 测量。

成功时 `report.json` 由全部断言通过后的真实结果生成，工作目录保留：

| 产物 | 用途 |
|---|---|
| `real/`、`off/`、`missing-metadata/` | 高亮开启、关闭、缺展示数据的原文与可靠链接对照 |
| `*.jsonl` | worker 请求/启动审计；仅 fixture 内容，不作为发布站点资源 |
| `cancelled-parent/` | 宿主终止的独立输出父目录与 fail-closed owner lock |
| `strict-output/` | 非零退出但保留完整原文和 error 诊断的原子生成产物 |
| `replay/` | 清空 PATH 且原项目路径移走时的冻结 IR 重放 |
| `crlf/html/` | 保留绑定 CRLF 原文的真实浏览器 fixture |
| `cjdoc-highlight-adapter.zip` | 独立发行适配器，含 lockfile、版本声明和许可证，不含依赖树 |
| `adapter-package/` | 从独立 ZIP 解压并在隔离 npm 缓存离线安装的适配器 |
| `highlight-source.zip`、`source-reproduced/` | 源码输入 ZIP 解压后重新生成，并逐字节比较 |
| `published/html/downloads/showcase-offline.zip`、`offline-extracted/` | 原始生成目录的独立发行副本及完整包；严格清单/字节校验后解压，包含 fixture 源码下载，不含高亮引擎 |

不要删除取消场景的锁继续使用同一输出父目录。`generate` 的严格失败沿用 `writeOnFailure=true`，应验证完整诊断产物；不能错误断言“失败时无 docs.json”。`serve` 的失败重建保留上次成功站点是另一契约。

API 删除门禁回归可用公开契约测试复现：

```bash
cjpm test --jobs 1 --no-progress --filter "*ApiCollectionStateContractTest*"
```

同一个两函数 baseline 删除一个公开函数后，off 与未授权 Python 后端的 strict/static 均应得到 API `collectionState = "resolved"`、breaking=1、potentiallyBreaking=0，`--deny-breaking-api` 退出 1。后者的文档仍必须是 partial，保留 error CJDOC4027。源文件解析失败的反例仍必须是 API partial。Doc IR v14 的必填 `apiCollectionState` 经 JSON 离线重放、语言选择和版本发布保持不变；v6–v13 输入按旧 status 保守迁移。整包资源 fallback 应为 unavailable，不能将空 API 当作 resolved。

## 执行浏览器与协议测试

浏览器必须消费实际生成目录，保持原 CSP、资源和路由，不通过 mock clipboard 回显：

```bash
(cd tools/highlight && node --test)
python3 -m unittest scripts.test_highlight_adapter -v
cd tests/browser
CJDOC_HIGHLIGHT_EXPECT_TYPE_LINKS=0 \
CJDOC_HIGHLIGHT_FIXTURE="$TMPDIR/highlight-acceptance/crlf/html" \
  node node_modules/@playwright/test/cli.js test --config highlight.config.mjs
```

`highlight.spec.mjs` 使用真实 Clipboard API 和真实 `execCommand` 路径读取剪贴板；选择文本按 HTML 换行规则比较，复制按绑定原文比较。HTTP 子路径和 `file://` 的 JS 禁用检查不等同于把所有站点交互也禁用。200% 使用受控 Chromium 扩展调用 `chrome.tabs.setZoom(2)`，核对真实 CSS 视口、DPR 和准确类型点击，不以半宽 viewport 冒充原生 tab 缩放。

## 验收映射与证据边界

| Issue 条目 | 实现边界 | 可执行证据 |
|---|---|---|
| HL-01 / H-T01 | 共享准备与代码/签名 renderer | `HighlightGenerationContractTest`、CLI plain 对照、现有浏览器成员导航套件 |
| HL-02 / H-T02–03 | 内建 Lexer 原文字节区间 | Cangjie 高亮单测、CLI 的有效/不完整/未闭合片段及摘要/边界断言 |
| HL-03 / H-T06 | 固定五 grammar、串行 JSONL worker | adapter Node/Python tests；CLI real/wrong-id/wrong-engine/crash/timeout/oversized-output/noisy-stderr 七模式 |
| HL-04 / H-T04–05 | 展示与语义链接正交、绑定复制原文 | CLI on/off/missing-metadata 原文/href/API-surface 对照；真实浏览器 CRLF/Unicode/制表符/末尾换行复制 |
| H-T07–08 | 显式语言及安全原文 renderer | adapter 恶意 HTML/实体/范围拒绝测试；CLI text/unknown/无语言；浏览器无脚本执行 |
| HL-06 / H-T09 | 捕获指南/图片/绑定/概述/空页 | CLI source-free replay、repeat、源码 ZIP 和独立适配包输出逐字节比较 |
| H-T10–11 | 单生成词法缓存与公开投影 | `HighlightGenerationContractTest`；CLI 同内容别名请求只发一次、故障后不缓存失败、私有内容不发给 worker |
| H-T12 | 预算、重启上限、进程树清理 | CLI 七模式、SIGTERM、公开 `Future.cancel()`；预算/codec 单测。Linux 实测不能替代 macOS/Windows CI |
| HL-05 / H-T13 | 专用 token CSS、无布局裁切 | highlight 浏览器逐主题计算色值/对比度及 desktop/mobile/原生 200% tab 缩放 |
| H-T14–15 | 静态 CSP、路由和原文复制 | highlight 浏览器 file/HTTP/JS-disabled/真实复制；现有中英/版本/多成员导航套件 |
| HL-07 / H-T16 | 默认不依赖 Node、显式发行安装 | CLI 无 Node 的 generate/check、独立 ZIP 离线 npm 安装、fixture 源码 ZIP、完整离线清单 |

Source-only fixture 不会凭词法颜色产生可靠类型身份；其 `source_surface_comparison` 明确记录实际链接数，零链接比较不能作为导航证明。可靠链接另使用公开 Doc IR 中已有 `resolved` 类型证据的同一签名，分别 render static/off/missing-metadata，再调用 `assert_plain_preserves_surfaces`（强制链接数大于零）并在浏览器真实点击。浏览器的 `CJDOC_HIGHLIGHT_EXPECT_TYPE_LINKS` 必须由输入身份 oracle 显式提供：上述 source-only fixture 为 0，已有两处可靠类型证据的公开 IR fixture 为 2；禁止依据生成索引的 `returnCanonical` 或实际链接数量反推预期，链接还须落在原始签名的参数/返回类型位置而非默认字符串。不得为了让 fixture 有链接而新增类型推断或修改生产解析边界。

`report.json` 的 `cost` 保存同一输入、SDK、Node/grammar、renderer 下的三组交替 no-cache 生成时间和中位数，另记录 IR/HTML 字节与 DOM/span 数；首次审计 wrapper 的单次时间与三组直接发行适配器测量分开。静态颜色增加生成工作和输出体积，不据此宣称阅读更快。首次阅读时间、浏览器/字体和截图由浏览器报告独立记录。

成本输入必须包含带 binding 候选的指南：这类页面在唯一正式展示投影前还有一次纯 Markdown AST 语法预检，用于确认真实 marker 与表格连续上下文，避免改写代码、引用或 opaque HTML 中的字面内容。预检使用已读入正文和既有资源限制，不启动高亮/Lexer/provider/资产收集或额外 worker，但仍有额外解析成本。实现或准备路径发生变化后，旧二进制的时间测量不能移用于新 revision；必须在新冻结身份上重跑生成成本。仅“共享 worker 一次”或复用字节相同的浏览器站点，不能代替这项重新测量。

## 三平台必需 worker CI


CI workflow 的既有 `linux-acceptance` 与 `candidate-other`（Windows x64 / macOS arm64）在普通构建、源码身份与性能门之后，固定安装 Node.js **26.11.1**，执行 `scripts/highlight_ci.py`。新步骤没有 optional/continue-on-error 分支；它们失败时，既有 `CI required` 聚合门也失败。普通仓颉产品生成与读取产物不因此获得 Node 运行依赖。

runner 首先重验当前 HEAD 的构建 manifest 与真实 main 摘要，然后只从该精确 commit 的 tracked Git archive 创建私有源码副本。公开取消宿主在副本内、独立 target-dir 下以现有 STS `-O1` wrapper 和已认证 static stdx 构建；只有 PATH 命中已标记的继承 wrapper 时才复用底层真实 cjpm，新选择的 SDK 路径仍优先，不能把外层 wrapper 再当真实工具递归调用。显式 npm 安装、node_modules、构建脚本缓存及完整 harness 输出均留在磁盘上的私有 runner-temp 根，不污染原 checkout 或默认 target，也不放宽 source-input 门。runner 各步骤复用既有 `run_with_timeout.py` 约束进程树，不仅终止超时步骤的直接 shell。

公开 artifact 保存构建身份、固定版本与产物摘要，以及仅含固定步骤名、状态、reason code、退出码、超时秒数与耗时的结构化步骤记录。异常 repr、完整命令 argv 和原始 stdout/stderr 只留 runner 私有工作根，不上传或回显；不依赖跨平台路径替换来发布错误文本。命令 stdout 与 stderr 分别保存：HEAD、Node 版本等机器字段仅消费 stdout，SDK/动态加载器的 stderr 诊断保留但不混入身份解析，也不被过滤或丢弃。

受控源码、配置、Markdown、worker 脚本和冻结 IR 输入明确以 UTF-8/LF 写入，避免 Windows 默认编码或换行改变固定 corpus；原始 corpus 和断言不变。专门的 CRLF IR/浏览器复制场景仍证明已提取显示代码的绑定原文，不声称 Markdown 解析从不归一化整个源文件换行。

取消验收必须先等真实 worker 与后代进入就绪状态，再登记仍存活的进程身份。`Popen` 返回不能代替解释器就绪：macOS framework Python 启动器还会以相同 PID 执行实际解释器并替换 `argv[0]`，因此进程测试等待解释器内的就绪信号，不把启动中的命令变化误认成退出。macOS 仍以 birth/完整命令和 kqueue 观察取消目标，并用 `proc_pidpath` 验证实际执行映像；查询失败仍抛错，不能当作退出或放宽映像校验。

Windows stdx 启动器必须等待真实子进程结束并传播非零退出码，不能套用 POSIX 的原位 `exec` 退出语义。workflow 的父、子 Python 入口使用 `-u -X faulthandler`，使证据目录创建前的原生启动崩溃仍可观察，且不输出环境转储。具体平台修复是否成立仍以最新 HEAD 的实际 hosted CI 为准。

这些是已接入的远端执行门，而不是三平台已通过的声明；只有最新提交的三平台实际运行全部成功后，才能报告该层级通过。

## 完整仓库与最终发行门

以下门必须在实现与文档已提交且工作树身份可验证后运行；未提交实现的拒绝不是功能测试通过，也不能通过绕过 `--require-tracked` 消除：

```bash
bash scripts/check.sh --evidence "$TMPDIR/check-evidence"
python3 scripts/build_showcase.py --binary target/release/bin/main \
  --output "$TMPDIR/full-showcase"
python3 scripts/check_showcase_source.py --site "$TMPDIR/full-showcase" \
  --binary target/release/bin/main --evidence "$TMPDIR/full-source-reproduction.json"
```

`build_showcase.py` 生成真实双语 PocketKit 站点、源码下载和完整离线包；`check_showcase_source.py` 从该下载 ZIP 执行真实复现。CLI harness 的独立 fixture ZIP 成功不能替代此完整仓库/最终发布门。schema/golden 应由现有更新脚本生成并复核，不手改历史 golden。独立生产代码审查、最新 HEAD 三平台 CI 和正式发布分别报告，不能用本机结果代替。
