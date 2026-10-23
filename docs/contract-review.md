# 作者侧契约复核

质量必须分成三层：coverage 的字段存在性、quality/lint 的非模板结构检查、人工核对的语义充分性与一致性。前两层不能代替第三层；`meaningful`、零诊断、示例通过均不是“可放心调用”评分。

## 固定作者事实与实际运行

只审查 `examples/pocketkit/demo-v2` 的作者说明与实现，不从 API 名称、返回类型或标准库同名类推行为。以下十三条已在 STS 1.2.0 编译的未修改真实库上实际执行：

| 用例 | 文档/作者事实 | 源码行为 | 实际运行覆盖 |
|---|---|---|---|
| C01 | TextCatalog 复制初始数组、保序，保留重复/空字符串 | 构造函数逐项加入独立 ArrayList | 修改输入数组不改变目录；原顺序/重复/空字符串保留 |
| C02–03 | at 只接受 0<=index<size；tryAt 对无效索引返回 None | at 在读取前检查并抛 IllegalArgumentException；tryAt 同条件返回 None | -1、size、0；异常后原条目和 size 未变 |
| C04–05 | 整数 add 只支持默认十进制 | radix 非 10 在 values.add 之前抛异常 | 默认 42 追加为文本；16 进制拒绝且目录未变 |
| C06 | addAll 逐项复制输入 | values.add(all: entries) | 顺序/空值保留，后续修改输入数组不改变目录 |
| C07–08 | snapshot 不共享 ArrayList 容器；clear 不改变旧快照 | toArray / clear | 修改快照不改目录；clear 后追加不改旧快照 |
| R01–02 | 空文本无行；read EOF 返回 None 且不再前进 | 空数组与 position>=size 分支 | 空输入、两行顺序、重复 EOF；EOF 未关闭会话 |
| R03 | 未关闭时 rewind 回到第一行 | position=0 | 读到 EOF 后 rewind，再读 first |
| R04–05 | close 幂等；关闭后 read/rewind 抛 IllegalStateException | isClosed 标志在操作前检查 | 两次 close；两个操作均拒绝且没有重新打开 |

源依据：`catalog.cj` 类说明、构造、add/addAll、at/tryAt、snapshot/clear；`io/reader.cj` 类说明及 read/close/rewind。运行只证明上述输入/状态转换，不证明所有 Int64、内存分配失败、并发安全或复杂度。

尤其：addAll **没有作者声明失败原子性**，不能从成功拷贝测试推导“失败时完全不变”；TextReader 是作者明确的内存会话，不能推广到标准库或其它库的同名 API，不拥有 OS 文件/网络/后台线程；不得推广接口 Readable.close 的具体资源所有权。

### 重跑真实消费者

准备当前仓库要求的 STS SDK 与 sibling stdx，设置 `EVIDENCE_ROOT` 为已创建、权限为 `0700` 的磁盘证据目录，不使用 tmpfs。以下输出子目录必须尚不存在：

```bash
REVISION="$(git rev-parse HEAD)"
python scripts/with_stdx.py --variant static -- python scripts/reader_contract_review.py \
  --revision "$REVISION" --output "${EVIDENCE_ROOT:?}/contracts"
```

runner 将原始 `demo-v2`、`support-v1` 的包配置及源码复制到独立证据目录，使用真实 `cjpm build` 构建库，再编译运行 [`contract_review.cj`](../examples/pocketkit/contract_review.cj)，不替换库实现。`reader-contract-review.json` 分别保存原始源码/消费者 SHA-256、SDK 与工具版本、构建/编译/运行的退出码和资源记录、十三个实际用例；对应标准输出/错误日志保留并归一化本机路径。输出失败也是失败证据，不改写为缺少作者说明或全契约正确。

源事实入口：[`catalog.cj`](../examples/pocketkit/demo-v2/src/catalog.cj)、[`reader.cj`](../examples/pocketkit/demo-v2/src/io/reader.cj)。Reader scale 工作流在性能测量开始前执行同一 runner，报告和日志与阅读观测一起保留；它不是性能样本或跨线程安全证明。

## 发布前 checklist

每个适用维度填四项：作者声明位置、实现/测试依据、结论、仍未知的边界。结论只能是“已覆盖的事实一致”“缺少所需说明/待作者确认”“确有矛盾”“此维度不适用”；不要把未知填成无限制。

1. `@param/@precondition`：有效域、端点、单位、空/负值、默认/命名参数；前置条件不自动等于运行时验证。
2. `@return/@throws`：None 与异常各自的条件，同一种异常的不同触发条件分别保留。只有作者明确承诺时才能写无异常。
3. `@postcondition/@state`：成功/失败后的状态、顺序、重复输入、失败原子性；失败原子性缺失时保持未知。
4. 所有权与资源：拷贝的是容器还是元素/引用，旧快照是否独立，谁关闭、重复关闭、关闭后操作；不把“无 OS 资源”推成“任意方法永不抛错”。
5. `@concurrency`：作者是否声明内部同步或要求外部同步；单线程示例不能证明线程安全。
6. `@performance`：只核对适用且作者声明的复杂度/资源约束；不从名字、循环的一次运行或类型形状生成复杂度承诺。
7. 相关 API：分别列 at/tryAt、add/addAll、snapshot/clear、read/close/rewind 的共同前提和不同结果，不把相似名字当等价合同。
8. 语言/来源：译文与原文的相同条目保持身份；缺译、缺作者说明、未解析类型、条件扩展与继承来源保持显式。

## 固定反例与判定

这些是 checklist 的故意变体，不是建议写入真实库的行为变更；不能以未触发 lint 宣告它们正确。

| 反例 | 固定变体 | 第三层结论与依据 |
|---|---|---|
| 正例 | 保留 at 的区间异常、tryAt 的 None 条件、snapshot/clear 容器独立承诺 | 已覆盖事实一致；C02/03/07/08 分别运行，仍不覆盖所有失败 |
| 缺说明 | 将 addAll 说明缩成“追加这一批条目”，未声明分配失败时状态 | 若调用者需要原子性则待作者确认；不能自动补“失败不改变对象”，也不能仅因缺 @throws 判实现有矛盾 |
| 确有矛盾 | 给 tryAt 写“有效索引返回 None；无效索引返回 Some”而实现仍是当前版本 | 与明确分支及 C02 相反；是矛盾，不是仅缺字段；即使非模板文字也错误 |
| 跨方法矛盾 | 声称 clear 会同步清空旧 snapshot，而 snapshot 仍声明独立容器 | 两个作者承诺冲突，C07/08 与该变体相反；不得合并或隐藏其中一条 |
| 合法稀疏 | Readable.close 只说释放会话状态，并明确接口不规定系统文件描述符所有权 | 接口保留实现自由；不强加具体 TextReader 的 OS 资源/幂等/线程语义，不要求无关 complexity 标签 |
| 缺失不等于无限制 | 重载参数没有 @precondition 或异常条目 | 作者未说明；不是“任意输入有效”或“不会抛异常” |
| 同异常不同条件 | at 的索引错误与 add 的 radix 错误均是 IllegalArgumentException | 依符号与条件分别核对，不按异常类型合并 |

不新增自动语义评分或推断式诊断。该 checklist 是 advisory/人工发布复核；任何不确定项由作者确认，不影响现有 diagnostic code、Doc IR 或已发布质量报告格式。
