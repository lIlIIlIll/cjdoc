# Agent 配对评测与消费者验证

本流程把原生/协议回归、真实客户端任务、源码判分、消费者编译和行为验证分开。确定性门禁不联网调用模型；模型评测显式运行。脚本、一次协议接通或合成回答都不是模型效果证据。

## 事前固定输入

- [evaluation-protocol.json](../../tests/agent/evaluation-protocol.json)：12 个固定任务、两个消费路径、交替顺序，每任务每路径一次；客户端/模型/推理强度和预算固定。
- [evaluation-rubric.json](../../tests/agent/evaluation-rubric.json)：逐事实、身份/版本、签名/命名默认参数、引用、不确定性和成本口径。
- 基线源码 revision、源码归档 tree/hash、原生二进制及 build manifest、工具链版本/hash、每个输入 Doc IR 与静态站的 hash。

协议/评分表在产品变更和任一模型路径之前提交；没有根据回答改题、删失败、增加预算、重试择优的分支。一次完整配对观测不能声称稳定改进。若修复产品后重新观察，保留先前所有运行，分别列明二进制/协议身份，不把不同产品版本混为同一次配对。

## 捕获旧消费路径

保留旧原生二进制，用固定源码归档的已有 PocketKit reproducer 生成两个真实 API 版本、两种语言、独立依赖及原始检查/diff。不要用新 renderer 回填“旧路径”。示例环境变量指向已经固定并记录 hash 的输入；输出目录必须新建：

```bash
python3 "$CAPTURED_SOURCE/examples/pocketkit/reproduce.py" \
  --cjdoc "$BASELINE_BINARY" --output "$BASELINE" --locale both

"$BASELINE_BINARY" generate \
  --project "$CAPTURED_SOURCE/tests/fixtures/projects/reexports" \
  --include-path-dependencies --format html --format json \
  --locale en --lint-profile off --no-cache \
  --output "$BASELINE/extra/reexports-complete"

"$BASELINE_BINARY" generate \
  --project "$CAPTURED_SOURCE/tests/fixtures/projects/unsupported" \
  --format html --format json --locale en --lint-profile off --no-cache \
  --output "$BASELINE/extra/unsupported"
```

归档根的 `source.json` 可记录公共 repository/revision，供已有 reproducer 生成固定来源链接；不能填本机路径。重导出 fixture 必须包含真实 path dependencies，否则 resolved/ambiguous/unavailable 的事实不同。保留不完整状态，不通过补造目标消除歧义。

选择发布目录时检查实际导航清单和版本/语言身份。baseline server 只公开这些 allowlist 站点里的 HTML/索引/旧文本等已发布表示，不公开源码、IR、评分事实、编译结果或产品实现。新路径优先使用**同次捕获、实际发布的机器 Doc IR**，不能改用包含更多声明的生成中间输入。独立 support 站点没有发布机器 Doc IR 时，使用生成该站点的已捕获输入；不得把它追加到 baseline allowlist 来改变旧路径。逐文件记录实际路径、SHA-256、声明数及来源性质。

## 确定性门禁

```bash
cjpm test
python3 -B -m unittest scripts.test_agent_evaluation scripts.test_agent_evaluation_proof
python3 scripts/test_agent_artifacts.py --binary "$CURRENT_BINARY" --root "$DOCUMENT_ROOT"
python3 scripts/test_query_mcp.py --binary "$CURRENT_BINARY" \
  --snapshot "$DOCUMENT_ROOT/agent/manifest.json"
```

原生 MCP 集成驱动真实 stdio 进程，覆盖初始化/通知、非法 ID/消息、限额、EOF 及 CLI 等价；它**不调用模型**。正常 `scripts/check.sh cli` 也运行真实机器产物及 MCP 检查。完整 source-bound build/unit/CLI、最终发布目录、离线 ZIP、浏览器和远端 CI 仍各有独立证据，不用这些小门禁替代。

## 执行一次完整配对

下面的站点名字是固定任务的 scope 标签。路径必须对应实际捕获目录；没有该站点时先修复捕获流程，不把别的版本重命名充数。

```bash
python3 scripts/agent_evaluation.py \
  --binary "$CURRENT_BINARY" --baseline "$BASELINE" \
  --site pocketkit-v1-en=composed/demo-v1/html/en \
  --site pocketkit-v1-zh=composed/demo-v1/html/zh-CN \
  --site pocketkit-v2-en=composed/demo-v2/html/en \
  --site pocketkit-v2-zh=composed/demo-v2/html/zh-CN \
  --site pocket-support-v1=support/html \
  --site reexports-fixture=extra/reexports-complete/html \
  --site partial-source-fixture=extra/unsupported/html \
  --snapshot "$BASELINE/composed/demo-v1/html/en/machine/docs.json" \
  --snapshot "$BASELINE/composed/demo-v2/html/en/machine/docs.json" \
  --snapshot "$BASELINE/support/docs.json" \
  --snapshot "$BASELINE/extra/reexports-complete/html/machine/docs.json" \
  --snapshot "$BASELINE/extra/unsupported/html/machine/docs.json" \
  --output "$RUN"
```

加 `--dry-run` 可检查计划但不会执行客户端，不是通过记录。正常完整运行不传 `--arm`/`--task`；这些筛选只供明确标注的诊断。预算覆盖工具调用数、客户端实际可见工具结果字节和整个客户端单调时钟耗时。发现工具/传输字节另行记录，不把重复读去重，不从字符数推算 token。

两个路径都经过相同 recording/budget relay，使用同一固定客户端、模型、推理强度及非文档工具禁用策略。记录实际工具定义、初始化/发现、请求和返回、原始客户端事件、最终回答、usage、进程退出与预算错误。没有真实工具调用、客户端错误、超时、无回答、违反答案结构都留在 12 任务分母内。调用成功和任务正确分别报告。

## 编译、运行，再判分

对原始回答逐项验证，不能修好模型代码后再算模型通过：

```bash
python3 scripts/agent_evaluation_proof.py verify \
  --output "$RUN" --project-root "$CAPTURED_SOURCE" --sdk-root "$CANGJIE_HOME"
```

实际 source dependencies 的 name/version、manifest hash 与 #83 的可移植源码内容身份绑定。先捕获只读源码闭包、构建新的静态库和一致的 `.a` / `.cjo` 导出，再对每段非空 `consumerCode` 调用一次 `cjc` 生成可执行程序。**原始 UTF-8 字节不变**：不增加 package 行、不修复 import、参数、调用、断言或异常处理；仅含空白的正文也必须尝试编译。不因模型任务超时或字节超额而跳过已有代码。合理拒绝不提供代码时为 not-applicable，不是 compile-pass。

验证运行要求 Linux x86-64、`bwrap` 和 `prlimit`。编译器在清理环境、无主机 home/凭据/网络的命名空间内运行；源码和 SDK 只读，只有本次私有构建目录可写。消费者运行时只挂载运行库，文件系统只读，禁止新进程而允许运行时线程；日志、文件、进程数、地址空间和 data 有界。默认编译/运行期限分别为 300/60 秒，超时清理整个进程组，包括已退出的组长遗留的后代。环境或源闭包准备失败也先保留全部 24 条记录。目标库构建失败时仍尝试原程序编译，但回执明确标记请求库绑定不可用，不将 SDK-only 成功升级为目标版本编译通过，也不运行它冒充行为证据。

`verify` 生成逐任务/路径判分模板。人工评审每个固定 requiredFacts，记录原回答片段、supported/contradicted/omitted 判定和真实源码/Doc IR 证据；每个引用也单独判定。证据需有固定源文件 hash、行范围/原文，或指定 Doc IR 的声明与字段。自然语言不使用关键词命中代替判分。

Doc IR 证据必须来自捕获 manifest 中的文件 hash，并绑定真实源码的 library/version/content identity。声明归属按 `componentModuleId`，不能把消费者根模块 ID 或导入文档集的 root 借给依赖声明。可以用另一版本或依赖的真实证据证明差异，但 `apiSelection = 1` 仍需当前任务主库/版本的证据。报告重新检查源文件和 Doc IR 未变化；编译回执必须与原始程序、编译退出/超时、实际 ELF、原始日志字节/hash、运行程序及沙箱策略一致。

行为判分还需显式的全程序人工审查；它不是自动控制流证明或关键词匹配：

| 字段 | 要求 |
|---|---|
| `behaviorReview.method` | `manual-source-and-control-flow-audit`，明确人工判断边界。 |
| `consumerCodeSha256`、`codeQuote` | 绑定实际原程序及其中真实片段。 |
| `verdict`、`coversTaskBoundaries`、`reason` | adequate / inadequate / unverified；说明是否覆盖冻结任务的全部状态和边界，检查是否可达并影响程序成功/失败。 |
| 每条 `behaviorAssertions` | 给出 assertion、observed / not-observed / unverified，以及原程序里的 `exerciseCode` 和 `checkCode`。 |
| `sourceEvidence` | 固定实现源文件的 hash、行范围和原文，而不是打印成功标记所声称的行为。 |
| `evidence` | 实际捕获的 stdout / stderr 原文或整数退出码；不得由编译成功补造。 |

只打印成功标记、断言不可达或未覆盖要求时应判 inadequate；零退出也不是行为通过。尚未审查为 unverified；非法或与程序不符的审查不会升级任何行为或 API 选择分数。

```bash
python3 scripts/agent_evaluation_proof.py report \
  --output "$RUN" --project-root "$CAPTURED_SOURCE" \
  --doc-ir pocketkit-0.2.0="$BASELINE/composed/demo-v2/html/en/machine/docs.json" \
  --doc-ir pocketkit-0.1.0="$BASELINE/composed/demo-v1/html/en/machine/docs.json" \
  --doc-ir pocket-support-0.1.0="$BASELINE/support/docs.json" \
  --doc-ir reexports-fixture="$BASELINE/extra/reexports-complete/html/machine/docs.json" \
  --doc-ir partial-source-fixture="$BASELINE/extra/unsupported/html/machine/docs.json" \
  --adjudications "$RUN/adjudications.json"
```

尚有未判事实/引用、编译回执缺失或行为未验证时不产出完成报告；可以显式导出 observations，但不能据此宣布效果或 Epic 通过。最终列出两路径每任务结果、API 选择、错版本、签名/契约遗漏、引用与不确定性、实际读字节/调用/耗时以及编译/行为的原始数值与分母，同时保留两边所有失败。

## 发布证据

提交的是脱敏、可复算的报告与验收映射，不是本机的完整运行目录。路径用相对路径或 `<repo>`、`<workspace>`、`$HOME`；不包含本机用户名、主机、私有地址、认证信息或原始私有配置。报告归一化已注册的 capture、verification、源码、SDK、临时目录和 home 根；这不能替代对其他身份信息的人工检查和发布隐私门禁。原始字节 hash 指向私有捕获，显示文本可能经过根路径归一化。保留有价值的失败轨迹及其 hash/大小，注明其私有证据位置。远端最新 HEAD 与最终 main 的 CI 单独读回，不能把本机通过写成 runner 已通过。
