# #113：验收包索引中的作者概述

本验收只覆盖已有概念文档与 API 包页的整合，不实现 #112/#115，也不重新实现 #64 的语言模型。

## 来源和归属

- 配置仍是 `[docs.packages]`、默认包概述路径和已有 `[[docs.pages]]` 的 `package` 关联。渲染器只读捕获的 Doc IR，不访问项目源文件或网络。
- 自动包概述仅在作者文件成功读取后保留包关联。旧 v13 自动生成包页从未设置 `packageName`，因此其默认占位不会变成包简介。作者恰好写出同样的句子不受文本黑名单影响。
- Markdown 解析/资源失败的捕获页不携带包关联；旧快照的 `CJDOC3026` 来源诊断也会阻止该页充当作者概述。
- 关联按完整文档集的包集合查找，随后要求对应 moduleId + package 的 API 包产物在当前投影可见。同名跨模块时，只有属于概念页声明包的可见 API binding 目标才能证明 moduleId；辅助包的 binding 只参与可见性判断，不能决定本包归属。缺乏本包唯一证据时安全省略。
- 概述使用现有逻辑页面的 locale 选择和回退。入口是选中页的真实 route，返程是同一站点树中的包页 `#declarations`，不跳到 latest。
- 同源同包页面保留一个权威入口，不因为共享 source 丢弃有效作者内容；概念 shell 按实际 route 识别逻辑页并返回其正确包。相同 source 不再被误当成归属歧义。

## 生成真实 HTML fixture

先按项目的源码构建说明准备仓颉和 stdx。用磁盘上的全新验收目录运行（输出目录不能与其他运行复用）：

```bash
export TMPDIR="$HOME/.cache/agent-tmp/package-overview-check"
export TMP="$TMPDIR" TEMP="$TMPDIR"
mkdir -p "$TMPDIR"
chmod 700 "$TMPDIR"
python3 scripts/test_package_overviews.py \
  --binary target/release/bin/main \
  --output "$TMPDIR/sites"
```

输入来自 tests/fixtures/projects/package-overview 和 package-overview-empty，不是 HTML 手工替身。生成器为模块、包、逻辑 page id、route、source、语言和发布版本分别规定输入 oracle；各模块/版本有不同 API 声明、摘要及全文标记。receipt 的 guide 来自输入配置，不从输出 href 反推。生成后先核对快照归属和预定路径，再把这些独立期望交给浏览器。

本地生成级实测输出：

```text
PASS: 45 independently specified package/page identity scenarios
```

这 45 项按输入规定的 moduleId + package、page id、route、source 和独有声明/正文标记验证生成与快照回放。包括自动概述与同源显式页复用、两个同源显式指南；同名包的本包显式 binding、跨辅助包 binding、无 binding、private 受众与 cfg 投影；中文/英文和两个正文标记不同的发布版本。检查还要求目标文件及返程锚点存在，包页不含全文标记。scripts/check.sh cli 已纳入同一检查。

固定 Cangjie 1.2.0 STS + 已认证的 stdx 1.2.0.1（仓库标准静态 wrapper、-O1）已完成最终源码 build；cjpm test --filter='*HtmlPackageConceptsTest*' 的五项定向用例全部通过，随后同一 STS 二进制通过全部 45 项身份场景。其余 540 项因定向过滤未执行，不以此替代完整 gate。

独立审查发现旧版 19/76 检查从实际 href 构造期望目标，不能证明同名模块及版本身份；该检查已被输入 oracle 替换，旧计数不作为完整身份验收证据。未改基线 0de9388d 曾在旧脚本首个有内容场景因缺少概述组件失败（exit 1），只证明功能原先缺失。

## 实际点击而不是只检查 href

安装浏览器测试依赖与 Chromium 后，在同一份生成结果上运行：

```bash
npm --prefix tests/browser ci
npx --prefix tests/browser playwright install chromium
CJDOC_PACKAGE_OVERVIEW_SITE="$TMPDIR/sites" \
CJDOC_PACKAGE_OVERVIEW_SCREENSHOTS="$TMPDIR/screenshots" \
PLAYWRIGHT_HTML_OUTPUT_DIR="$TMPDIR/report" \
npx --prefix tests/browser playwright test \
  -c tests/browser/package-overview.config.mjs \
  --output "$TMPDIR/browser-results"
```

本地 Chromium 实测 **270 passed**：45 个输入身份场景 × file:// / HTTP /reference/subpath/ × 桌面浅色 / 移动深色 / 禁用 JavaScript 的桌面环境。每个有内容场景实际点击入口，对照预定 route 和独有模块/版本/语言正文标记、排除外来标记，再点击“包 API”返程并重载确认相同声明身份和 #declarations 的实际视口位置。无内容场景没有空组件，声明锚点在首屏，且实际进入 Entry 后返回。新计数替代旧 76 项检查，包含同名包的正确显式归属、跨包误绑和过滤降级，而不只检查共用标题。

最终源码的 12 个代表站点均通过 scripts/validate_html_site.py：authored-en、authored-zh-CN、unconfigured、missing、configured、same-source-auto-explicit、same-source-two-guides、multi-correct、multi-cross-package、multi-hidden、multi-cfg-filtered、multi-cfg-enabled。按此顺序分别验证 13/13/9/12/12/13/14/25/24/24/24/28 个 HTML 页面与 7/7/3/6/6/7/8/14/13/13/13/15 条搜索记录；检查包括本地链接、锚点、CSP 和脚本 sink。

两个 fixture 已在 scripts/test_fixture_contracts.py 的 CLI_CONTRACT_FIXTURES 显式登记，归属现有 package overview CLI gate；test_every_project_fixture_has_an_explicit_gate_owner 定向执行通过，没有放宽原有集合相等约束。

另外对仓库原始 `examples/pocketkit/demo-v1`（英文）和 `demo-v2`（中文）运行 `generate --format html --locale ... --doc-version ... --no-cache`，未关闭其 deny doctest 配置，命令均退出 0；实际浏览器点击了两份产物中的已有 Catalogue and lifetime 指南入口，再点击包 API 返回同一包的 `#declarations`。原始指南的双语混排保持作者原样，不在 #113 中推断或拆分翻译。全站检查使用原有 `--publication-root` 指向各自完整输出目录（包含 doctest/results.json），分别通过 119/120 页和 60/61 条搜索记录。

## 阅读结果

有作者内容时，包标题后应立即看到有来源的首段摘要（最多 240 个 Unicode scalar values），并能进入完整概念页。包页不重复标题、import 代码块或全文。示例和指南保留在概念页这个唯一权威位置；已有 API 分组、源文件折叠、搜索和声明详情入口不改顺序。

无作者文件、缺文件的原有合成回退、空正文、只有标题/注释、当前投影不可用或归属不唯一时，没有简介标题、空容器或假按钮。生成器仍可按已有概念页机制生成 fallback 页，但不会把它冒充作者用途说明。

上述结果是 Linux 本地验收，不代表 macOS/Windows 或 GitHub 远端 CI 已通过。完整仓库 gate 与独立实现审查仍是发布前独立门槛。
