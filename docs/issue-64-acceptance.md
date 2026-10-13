# Issue 64 验收记录

范围：作者文字的中英文变体、完整 Doc IR v13、字段投影、翻译门槛、原生语言目录、显式页面/章节、搜索、示例证据与版本组合。重复条目采用保守关联；独立示例和无法唯一关联的契约保留全部作者条目。

本地环境为 Cangjie 1.3.0-alpha.20261010001050 / Linux。实现开始时 main 基线为 `4799f8a`，依赖 highlighting 分支的 `93f93c6`；共享工作区随后包含该分支的 `6f13649`。本任务没有构建或修改 SDK/compiler/std/stdx。后续按用户要求创建 [PR #117](https://github.com/lIlIIlIll/cjdoc/pull/117) 并修复检视意见；未合并、发布主站或关闭 issue。

## 实现与测试入口

| 范围 | 实现入口 | 实测入口 |
|---|---|---|
| I18N-01 | i18n_tag_head、i18n_comment_parser、comment_parser 的 Markdown 边界 | I18nPublicApiTest 的 malformedQualifiers、markdownBlocks 用例 |
| I18N-02 | i18n_generation、i18n_binding、reference_resolver | 单参数唯一性、重复契约、全部语言校验、英文弃用原因 |
| I18N-03 | i18n_config、GenerationRequest、LanguageRenderOptions、CLI options | legacySource、requiredLanguages、i18n_gate 的互斥参数 |
| I18N-04 | model/documentation_language、documentation_page、v13 codec/schema、source cache v16 | 426 项仓颉单测、9 组 v13 goldens、source-free / cold-warm 门禁 |
| I18N-05 | translation_coverage、i18n_quality、HTML/Markdown 字段状态 | translationCoverage、emptyTranslation、required-language 非零退出 |
| I18N-06 | site_routes、site_languages、version_languages、search-index v9 | i18n_gate 的实际文件/锚点校验，i18n.spec.mjs |
| I18N-07 | 捕获的指南、API ↔ 指南、doctest/2、PocketKit 原生 all-languages、publication_ir | capturedGuides、doctestCollection、publication-ir、PocketKit 复现 |

## LANG-T 场景

| ID | fixture / 测试 | 实际结果与边界 |
|---|---|---|
| LANG-T01 | 独立 i18n fixture；languageSelectionPreservesApiAndFallsBackPerParameter | PASS：共享声明、真实参数和语言选择 |
| LANG-T02 | duplicateLanguageIsDiagnosedEvenWhenNotRendered | PASS：en/EN 重复可定位；跨语言 return 合法 |
| LANG-T03 | markdownBlocksAndMultilineCodeSpansDoNotCreateTags；richParameterFallback | PASS：多段、列表、引用、围栏、跨行行内代码及安全 HTML |
| LANG-T04 | malformedQualifiersRecoverAtTheNextTag | PASS：11 种畸形/不支持形式恢复；语言目录只接受两个规范值 |
| LANG-T05 | legacySourceDoesNotAcquireAnEnglishTranslationFromLocale；i18n_gate source-free | PASS：locale 不重解释原文，旧项目不强制双语 |
| LANG-T06 | implicitSummaryCanHaveAnExplicitDescriptionButNotAnotherSummary | PASS：合法补充与重复冲突分开 |
| LANG-T07 | repeatedContractsRetainBothLanguagesWithoutPositionalPairing | PASS：重复条目保留，不按顺序/标题猜配对 |
| LANG-T08 | emptyTranslationAndEnglishOnlyDeprecationRetainSharedFacts；独立 fixture 的 right | PASS：空译文、字段回退、缺原文和共享弃用状态 |
| LANG-T09 | aBadParameterInAnUnselectedLanguageStillFailsValidation；required-language | PASS：未选择语言的错误仍诊断，严格门槛确实失败 |
| LANG-T10 | capturedGuidesRenderBothLanguagesWithoutSource；i18n_gate source-free；冻结 v6–v12 输入 | PASS：删除源码后仍能渲染；生成与导入产物按字节比较 |
| LANG-T11 | i18n_gate cold/warm；englishDocumentationEditsAreLanguageScopedInApiDiff | PASS：冷热字节一致；英文变更带语言证据，属于 documentation-only |
| LANG-T12 | i18n.spec 的桌面/移动内联 Int64 重载与参数深链 | PASS：真实键盘切换、展开、刷新及后退；身份来自最终实际锚点 |
| LANG-T13 | guide section identity survives translated headings；API ↔ guide 实际点击 | PASS：标题不同而逻辑 usage 相同；映射失败使用有效页面位置 |
| LANG-T14 | i18n_gate 两语言搜索/隐藏关键词；browser search；publication-ir | PASS：索引对应展示语料，公开机器 IR 经原生 decoder 验证 |
| LANG-T15 | i18n_gate v1 双语 / v2 仅英文且移除 String 重载 | PASS：缺语言和重载明确降级，不跳 latest 或按名称配对 |
| LANG-T16 | doctestCollectionIncludesEveryLanguageAndNeverBorrowsTitleProof；既有 example directive 单测 | PASS：自然语言与代码语言分开，同名代码不借用标题证据 |
| LANG-T17 | i18n.spec HTTP /docs/、真实 file://、无 JS 阅读 | PASS：真实点击读取/切换，无外部请求，原 CSP 保留 |
| LANG-T18 | 1440×900 浅色、390×844 暗色、中英文、键盘；720 CSS px / scale 2 | PASS：无 pageerror/整页横向溢出；200% 为等效布局仿真，浏览器原生 zoom 未测 |

## 构建与成本证据

最终完整 `scripts/check.sh` 为 PASS：仓颉 426/426，无跳过；Python 脚本 198 项、展示契约 174 项、CLI fixture 契约 11 项。随后展示打包和浏览器验收脚本的修复另跑展示契约 176 项，全部 PASS。独立原生 i18n 门禁覆盖 12 个命令场景，全部 PASS；真实语言浏览器 8/8 PASS，包含新标签页、章节缺译回退、无 JS 和真实 file://。

完整门禁与真实仓库 smoke 验证的代码 revision 为 `0e09e190c846a438312bff0bf2ff2010325667a7`，`src` tree 为 `f6ff5fa94391dc64bcb408cd9db0c975d54d1d4d`。后续展示打包、验收脚本与示例文字调整没有修改该源码树。生成 binary SHA-256 为 `f2421b5d7dcd59bb42276b705c5e2398270616d958f4f7ffe4001bc0592bd15c`。

真实 cjdoc 仓库两次生成一致，保留 4257 个声明和 1535 个产物；结果仍为 `partial`，不把现有 AST/provider 的能力边界描述为完整语义。两次生成的 docs SHA-256 为 `74ecaf145d8ebc8f1135369a87e9d04644f1f46a20264359247e3c4665846e3d`。

实测采用现有 CI 的进程级 `cjHeapSize=512MB`。本地默认 256 MB 对完整自文档样本出现堆碎片不足；没有修改全局 SDK 设置或放宽项目的 32 MiB JSON、64 MiB 单产物和对象数量限制。编码预算对固定位置对象按闭合形状计量，并回归最大整数位置、对象数量超限和公开 API 的过大输入回退。

固定独立 fixture 的一组本机测量：

| 项目 | 单语言 | 双语言 |
|---|---:|---:|
| 冷 generate 秒 | 4.922112 | 8.358227 |
| 热 generate 秒 | 未测 | 8.337151 |
| 产物字节 | 342989 | 703223 |
| 文件数 | 37 | 69 |
| search-index 字节 | 8614 | 17139 |

这些数字来自同一个 binary、SDK 和 fixture 的顺序命令，是成本样本，不是稳定性能承诺。所有语言仍共享原有正文、索引、Doc IR 和组合总量限制；未放宽限制或禁用大样本。

展示打包去除了重复复制的整棵双语版本树和完整作者中间 IR。最终站点 revision 为 `fd87936d068bf1e32d9641c721fe12a66cab543b`：静态全站链接、下载源码复现、12 组中英文 HTTP 根/子路径与 file:// 阅读历史和版本成员定位，以及全部 324/324 个声明浏览器场景均 PASS；随后静态/evidence 门禁再次校验 PASS。站点 digest 为 `b16272f9f4b66c44f6f95229ab4aca15f9e4dec7a942bb71c3b9326e97bffbc8`，站点 57439596 字节、离线包 8431105 字节，仍低于既有 80000000 / 16000000 字节预算。下载源码逐字节复现两版本及诊断项目的两语言原生产物；doctest 身份、状态与退出码相同，耗时单独测量。该次以后仅补验收记录，不重解释为远端部署证据。

## DONE 条件与证据边界

后续公开接口检视另行补充回归：renderer 类尊重已选择的 readingLanguage，索引摘要与字段使用 Markdown AST 纯文本，字段图片按当前投影选择并输出，外部 ambiguous 引用保持明确标签。公开语言值按大小写规范化，文档指纹拒绝非小写十六进制，resolved 文本引用必须有目标；版本章节路由按锚点排序后写出。27 项语言/公开接口用例全部通过，组合产物另有非空多锚点排序断言。

三条后续检视补充了 owner 链的目标默认语言回退、语言指纹集合的数量与规范化后唯一性校验、外部引用状态与 URL 的一致性校验；后者同步到 v13 schema 和严格导入。12 项针对性回归全部通过。图片语言投影以捕获好的 Doc IR 验证，可在三平台运行；安全本地资源捕获保留独立 Linux 用例，不将当前平台限制改成无约束读取。远端验证结论以 PR 对应提交的 checks 为准。

再补充版本化 artifact schema 的独立资源 URI、整段废弃说明的 Markdown 引用前缀、无对应符号或 owner 时的目标默认语言主页回退；冻结旧 schema 的 URI 和内容未改。14 项针对性回归全部通过，其中废弃说明重新解析后，其多段文字和嵌套列表全部仍在同一个引用块内。

另两条检视保留了无说明文字的 `@see` / `@throws` 已解析目标，并拒绝重复的页面目标。引用仍标注 empty / empty-fallback，已存在的默认语言说明文字仍优先用于回退。Linux 内部进程启动另有独立复现：STS 1.2.0、`cjProcessorNum=2`、512 MB heap 下，旧实现的最小并行进程复现被 45 秒外部超时中止；仅为 redirected launch 阶段增加互斥后，800 次调用全部通过。受影响的无 package 头依赖串行/并行生成用例和新的独立 stdout/stderr 回归，均在同一 SDK 的隔离应用构建中通过；工作进程运行与输出读取保持并行。单 unittest worker 调度不能替代这项启动防护。

最近三条检视另覆盖多行语言数组的引号/注释、各语言校验页到共享 doctest 报告的相对链接，以及 `serve` 的选项边界。20 项针对性用例和扩展后的 14 个原生命令场景通过；`serve` 以 `--locale` 预览所选语言，多语言发布使用 `generate/render --all-languages`。进程监督器在分组创建后关闭作业通知，平台流回归在失败时报告实际退出码及 stdout/stderr。

两条 PR 检视意见另有回归：多语言参数/异常/引用/契约的 Markdown 列表使用行内来源标记和续行缩进，重新解析后多段及嵌套条目仍属于对应条目；v3 API diff 在语言集合从空到非空、或从非空到空时保留新增/删除语言证据，v1/v2 缺失的语言证据仍保持未知。19 个语言用例全部通过。Linux CI 曾因 schema v13 的实际 Doc IR 身份与旧基线不符而失败；身份更新只修改两份文档 checksum，保留既有耗时/RSS 样本和硬上限，不把身份校验当作性能测量。

最新 main（`9a84c63c3411068de75d8cf9368351019c3e4177`）的独立集成检出另行验证：`scripts/check.sh` 全门禁 PASS，仓颉 426/426、脚本 243 项（preflight 41 + tools 202）、展示契约 176 项、CLI fixture 11 项。测试集按一个 unittest worker 调度；同一个依赖用例在默认调度下超时，串行调度后通过，内部 jobs=1/jobs=4 断言未改。该修复避免将编译 `--jobs 1` 误当作单测调度控制。

该集成版本的 `src` tree 为 `8b235d4f0b5050b67c2b5c83ed7f685a6601c9fb`，binary SHA-256 为 `41cfab004dbb14bf5a95a122c05308cd6f7873d9865bc3e3fce6febe88a8e672`。展示站基于 `d6f25b072e8acf488f1206c56384b19fb0ca2795` 生成，324/324 浏览器场景、12 组阅读回归（包括 main 的无 JS 触摸链接）、源码下载复现和最终静态/evidence 门禁全部 PASS；站点 digest 为 `61d8bd2723f69908cd369ed2b17017033ea0f90f8189d3e32c758fcf1633a404`，站点 61636734 字节、离线包 8560991 字节。后续修改仅涉及单测门禁调度和本段证据；站点与原生产物未改。


| ID | 交付与边界 |
|---|---|
| DONE-01 | 已读工作约定和真实基线；初始两个公开 API 回归先在旧实现失败，再通过 |
| DONE-02 | 上表保留全部 LANG-T 与 I18N 范围；无可靠重复关联时明确保留原文 |
| DONE-03 | 本地 build/unit、schema/golden、CLI/缓存和 decoder 已测；最终 check.sh 与 real-repository 单独记录 |
| DONE-04 | 浏览器操作使用原生目录和原 CSP，执行真实 click/keyboard |
| DONE-05 | 截图/trace 属于本地验收产物；原生浏览器 200% zoom 尚未测，布局仿真已明确标注 |
| DONE-06 | 上述固定规模成本实测；受众、资源和离线门禁继续保留 |
| DONE-07 | 远端 CI 与 PR 展示预览按实际 SHA 验证，状态见 PR #117 checks；不以本地结果替代。主站 Pages 未发布 |
| DONE-08 | 本地实现不自动合并、不关闭 issue；新建/推送 PR 需要后续明确指令 |

仓库全量隐私检查仍报告三个既有报告中的本机路径。这些路径未由本任务增加，也未作为提交内容扩散；本任务保留无关修改。新增文档、fixture 和提交消息使用相对路径、通用名称及便携占位符。

## 重跑

在已准备 SDK 的 shell 中先执行 `scripts/check.sh`。单独验证原生语言链路和浏览器时，使用新建的磁盘工作目录：

```bash
python3 scripts/i18n_gate.py --binary target/release/bin/main --workdir "$WORK/i18n"
CJDOC_I18N_SITE="$WORK/i18n/multi" CJDOC_I18N_SCREENSHOTS="$WORK/screenshots" \
  node tests/browser/node_modules/@playwright/test/cli.js test \
  --config tests/browser/i18n.config.mjs --output "$WORK/browser-results"
```

`WORK` 必须由调用方创建并设为该次验证独占的磁盘目录；同时将 TMPDIR/TMP/TEMP 指向它。文件中的结果不声称远端 runner 或已发布站点已验证。
