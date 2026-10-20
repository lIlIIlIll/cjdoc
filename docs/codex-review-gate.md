# Codex 复审完成门禁

本门禁针对 **OpenAI 托管的 `chatgpt-codex-connector` GitHub Code Review**，不是 `openai/codex-action`。它用于保证待合并 PR 的**最新 HEAD 已完成复审**；不替代代码正确性判断、CI 或问题分级。

## 工作机制

- PR 打开、更新、重新打开、变为可审查状态**或关闭**时，`pull_request_target` 触发 `.github/workflows/codex-review-gate.yml`，读取服务端**当前** PR HEAD。
- Codex 新建、编辑或删除 Review Summary 评论时，`issue_comment` 触发同一判断；删除 canonical summary 时直接将原有成功状态撤回为 `pending`，即便 API 暂时仍返回旧摘要或留有更早版本也不放行。脚本只接受指定 Codex GitHub App Bot 的评论，解析 `<!-- codex-review-state:v1 ... -->` 中 `code_review.commit_sha`（**完整 40 位 SHA**）和 `code_review.status`；**不**信任评论时间、缩写 SHA、PR reaction、旧 review 或 security review 状态。
- **base 分支被推送（重写 main）时**，`publish` job 的 `if` 也必须包含 `push`，否则触发器只会拉起一个被跳过的 job；base push 会在评估前**先撤销所有候选 PR 的 HEAD**（撤销阶段使用小规模线程池并发发布，避免逐条串行 POST 在大规模 push 时耗尽 job 超时）（HEAD 直接取自已列出的开放 PR 快照，不再为每个候选额外发一次 GET，以缩小硬超时窗口）（防止 5 分钟硬超时中途终止时后续 HEAD 仍带着旧 base 的授权），并把 job 超时提高以容纳该 fanout。并发**不使用**共享 key：GitHub 每个 group 只保留一个 pending run，第三个事件会静默丢弃排队的事件（例如 summary-deletion 的撤销），因此每次运行使用独立 group、绝不丢弃或取消事件；运行之间的竞态由 `evaluate_pr` 的"发布前重读 PR + 先撤销后发布"来防止。
- **base 分支被推送（重写 main）时**，各 PR 的 HEAD 不变，因此没有任何 per-PR 事件；若 HEAD 上留有 `success`，它会继续授权一次基于旧 base 的验证。故 `push` 到 `main` 会重新评估**所有以该分支为 base 的开放 PR**。
- 当一个 HEAD 被多个开放 PR 共享时，该 SHA 对它们都保持 `pending`。若其中一个 PR 关闭或推送到新提交，剩下唯一持有者需要被重新评估，否则其已完成的审查会永久停在 `pending`。因此 `closed` 与 `synchronize` 事件会额外对**受影响的旧 HEAD** 的其余持有者各评估一次（不重复评估触发事件的那条 PR）。若触发 PR 的评估抛错，其余持有者的重评仍会执行（best effort）后再抛出原错误；若触发 PR 正常而某个幸存者重评失败，则**不吞掉错误**、令本次运行失败，因为此后没有事件保证会重试它。重评前会先无条件撤销该 HEAD（撤销只能拒绝），因此即使**已无任何开放 PR 持有它**、没有任何 re-evaluation 可写，旧 `success` 也不会留给之后复用该提交的 PR。base push 会对所有候选逐个尽力重评，最后聚合错误——一次瞬时失败不得让其余仍带着旧 base 的授权。发布前会**重新读取 PR 快照**：若 base/head/test-merge 在评估期间已变化，则本次不发布结论。被删除的 summary 若**早于**当前最新 canonical summary，则该删除事件视为过期投递（延迟到达），此时仍按最新 summary 正常分类，不会把更新的 `success` 覆盖为 `pending`。`closed` 事件如果实际已重开（延迟投递），该 PR 不会被排除在 HEAD 持有者重评之外；`synchronize` 的跳过集仅在触发 PR **当前不拥有**受影响 HEAD 时才排除它：延迟投递可能在 PR 已经回到该提交（A→B→A）之后才到达，此时排除它会撤销当前 HEAD 且无人恢复。被取代（HEAD 已移动）的目标若撤销失败会使本次运行失败——那意味着旧提交上仍留有可被后续 PR 继承的证据。HEAD 持有者清理在**开始时就先无条件撤销该 HEAD**（撤销只能拒绝），且该撤销失败会被聚合并继续处理其余持有者，而不是中断整个 fanout。重评估循环的**上限用尽**时（快照持续变化、无法确认结论），会先撤销当前 PR 指向的 head/test-merge 上可能存在的 `success`；**若撤销失败则令本次运行失败**（fail closed），因为此后没有事件保证会清除它——绝不留下未经确认的授权。每次运行都会在**有界的重评估循环**中评估当前快照：若发现 head/base/test-merge 在评估期间被移动（例如较新的 base-push 运行已经发布了有效 `success`），旧运行会**重新评估当前快照**而不是撤销那个 HEAD（撤销可能永久覆盖更新的有效结果，且此后没有事件保证会恢复）；**仅 base 变化（HEAD 未变）时仍会撤销已被取代的 test-merge 状态**，但不撤销仍是当前的 HEAD。发布成功后若发现本次结论已被更新的数据取代，门禁**不会写回 `pending`**，而是按**当前数据重新计算并发布**该结论（用同一个 `decide`，因此不是凭旧推理升级）；因为每次运行有独立并发组，较旧的运行可能最后结束，写回 `pending` 会永久覆盖更新的有效结果。发布成功后还会**重新校验两个前提**——HEAD 归属与 Codex 审查证据本身——任一变化立即撤回为 `pending`（两个目标都撤回：HEAD 与 test-merge 携带同一结论）（这关闭了"summary 被删除的并发运行已写 pending、而本次较旧的运行又把 success 写回"的竞态）。既然测试合并提交在本运行更早处已写入同一结论，**发布之后**的任何失败（作用域读取失败、复核失败、写入失败）都会**同时撤回 HEAD 与 test-merge**并令运行失败——否则会在 HEAD 停在 `pending`、或旧 `success` 仍在的情况下报告成功。若 HEAD 发布前的作用域读取失败（此前未发生任何发布），则本运行无法判断是否授权，**直接失败**而不是报告成功。若发布写入本身失败，则先撤回；撤回也失败时**令运行失败**，因为此时既不能确认授权、也不能撤销它。
- 门禁对经验证的 **当前 PR 测试合并提交** 写入 `codex-review-current-head` Commit Status；同时，**仅当该 HEAD 恰好只被当前这一个开放 PR 拥有时**，把同一结论也写到 PR **HEAD**（`main` ruleset 的必需检查按 HEAD 评估，只写测试合并提交会导致任何 PR 都无法满足必需检查，见 #138）。HEAD 被多个开放 PR 共用（哪怕 base 不同）时，两侧都只保持 `pending`，不发布任何结论。确认测试合并提交具有当前 `base`、`head` 两个父提交，并检查仓库所有开放 PR，遇到共享测试合并 SHA 或同一 head+base 的模糊情况则保持 `pending`。测试合并提交缺失、不可验证或数据不完整时也不放行。
- 仅在 `code_review.status == completed` 且完整 SHA 等于当前 HEAD 时才标为 `success`；旧提交、未收到结论、正在审查标为 `pending`；失败/无法识别的结构标为 `failure`/`error`。不因找不到新 Thread 就推断审查完成。
- 如果该次审查含未解决意见，完成门禁仍为 `success`，但会在描述中提醒需要分类处理。**“审查完成”不等于“无阻塞缺陷/可合并”**，另由 Agent/维护者按 `AGENTS.md` 处理。

Gate 只读取 **默认分支上的可信脚本**，不执行 PR 代码；其 `GITHUB_TOKEN` 仅具备必需的只读权限和 `statuses: write`。PR 修改本门禁时，独立的 `pull_request` 只读测试任务验证改动。Codex Summary 的注释格式属于第三方实现细节，发生兼容性变更时必须先更新解析器与测试，不得改为“无摘要即成功”。

## 启用 Required Check

1. **先合并引入门禁的 PR**，让 `.github/workflows/codex-review-gate.yml` 存在于默认分支。不要在首次部署前就把尚未出现的检查设为 Required，以免死锁。
2. 在 [Codex Review 设置](https://chatgpt.com/codex/settings/code-review) 中为仓库保留 **On every push**；本门禁不会触发或代替 Codex Review，只验证完成证据。
3. 在一个新测试 PR 中 Push 一次，确认 **HEAD 与测试合并提交** 都先显示 `codex-review-current-head: pending`，Codex Summary 对当前完整 HEAD SHA 标记 `completed` 后两处都变为 `success`（HEAD 状态仅在该 HEAD 只被本 PR 拥有时发布）。未生成测试合并提交前门禁可能显示缺失/Pending，不会退回使用原始 HEAD 的成功状态。带未解决意见的 Review 也应该显示“完成但需处理意见”，而不是“clean”。
4. 在 GitHub 仓库 **Settings → Rules → Rulesets**（或 Settings → Branches → Branch protection rules）找到适用于 `main` 的规则，启用 **Require status checks to pass**，将 `codex-review-current-head` 设为 Required；如可指定状态来源，选择产生该状态的 GitHub Actions App。保留已有 CI Required Checks。
5. 对更新后的 PR 再次 Push，核对旧 HEAD 和旧测试合并提交的成功不能满足新提交。再测试删除 Codex Summary 时原有 Success 能恢复为 Pending。通过前不得合并；Review 中的真实阻塞缺陷仍需单独处理。

门禁始终仅在证明 test merge commit 属于当前 PR 后才发布状态；HEAD 上的结论还要额外满足“该 HEAD 在本列出仅被本 PR 拥有”。若当前 PR 无测试合并提交或它缺失本门禁状态，则不得把另一个 PR 在相同原始 HEAD 上的结果当作替代。HEAD 状态与测试合并提交状态同时撤回：重新验证开始时两者先置 `pending`，且**在任何提前返回分支之前**完成，因此即使本次没有可验证的测试合并提交、或中途 API 失败，也不会留下旧的 `success` 作为授权。发布 `success` 前会紧邻重读开放 PR 作用域、发布后再复核一次；若复核发现该 HEAD 已被第二个开放 PR 共享，立即撤回为 `pending`（status 属于 SHA 而非 PR，这个窗口无法彻底关闭，因此取"能在窗口内撤销"的最强保证）。撤销路径只允许发布非 `success` 状态（断言强制），因为它只能拒绝、不能授权。对直接推送受保护分支、绕过保护和合并队列的行为，本门禁并不单独提供防护，应由 GitHub Ruleset 另行限制；使用 merge queue 前还需专门集成 `merge_group`。

## 排查与人工同步

- 未审查/未自动触发：先查看 Codex Review 设置及最新 PR Summary；必要时评论 `@codex review`。
- Review Summary 已完成，但状态仍 Pending：打开 Actions → **Codex review gate**，检查 Bot 的 summary edit/deleted 事件是否触发、GitHub Actions 权限、完整 HEAD 与测试合并 SHA、是否存在共享 SHA 或 head+base 的其他开放 PR；必要时从该工作流 **Run workflow** 输入 PR 编号执行一次手动同步。
- Summary 结构变化导致 Error：修复 `scripts/codex_review_gate.py` 的解析器并补测试，**不要**临时接受仅基于时间或缩写 SHA 的结论。
- 本地快速测试：`python3 -m unittest discover -s tests -p 'test_codex_review_gate.py' -v`（不需要仓颉 SDK）。

## 局限

GitHub Status 本身不能确保外部 Codex 服务一定运行或按时返回；当它未运行时，门禁会保持 Pending，而不是错误放行。若 GitHub 尚未算出可验证的测试合并提交，先解决合并冲突或使用手动同步重新计算，不应切换到可被多个 PR 共享的 HEAD 成功状态；HEAD 只有一个拥有者时门禁会自动补写，无需人工镜像。若两个开放 PR 具有相同 head+base（无法通过提交状态区分），需调整其中一条 PR 的提交或关闭多余 PR，才能恢复成功门禁。是否已有 Reviewer 批准、是否存在真实阻塞缺陷、CI 是否成功，仍需由原有独立门禁与验收流程判断。本方案尚不自动修改 GitHub Ruleset 或合并 PR。

## 语义裁定：门禁能保证什么、不能保证什么

37 轮自动复审的结论收敛为下面这一组语义。**能保证的**是契约，**不能保证的**是 GitHub status 模型本身的限制，必须显式记录而不是继续打补丁。

### 根因（去重后只有四条）

1. **status 属于 SHA，不属于 PR。** 一个状态一旦写到某个提交上，任何后续运行都无法知道它当初为何写、属于谁。所有竞态、遗留授权、跨 PR 继承都源于此。
2. **必需检查在合并时对 HEAD 求值，而门禁最初只写 test-merge。** 这直接导致必需检查永不满足（#138 的原始症状）。
3. **每个运行有独立并发组，因此"最后一次写入"不确定。** 旧的运行可能比新的运行结束得更晚，于是"撤销到底"和"写回 pending"都可能覆盖更新的有效结论。
4. **快照在评估期间会变。** head/base/test-merge 任一项变化都使已发布结论失去依据，而写入发生在网络往返之间，无法原子化。

### 门禁保证的（每一轮复审都在验证这些）

| 保证 | 机制 |
|---|---|
| `success` 仅当 PR **独占** HEAD 时才写到 HEAD | `_head_scope_is_unique` |
| 非 `success` 可无条件发布（只能拒绝，不能授权） | `revoke_head_status` 拒绝发布 `success` |
| 结论与**当前**快照一致 | 发布前后各一次身份复核 + 有界重评估循环 |
| 本次运行写过的所有 `success`，在**任何未确认的退出**（快照变化、异常、重试用尽、PR 在发布期间关闭）时**全部**撤销 | `PublishedStatuses` 台账 + 单一 `_reconcile` |
| 只有**已确认**的发布才保留：发布后再校验一次 PR 仍为 open | `ReportingFailed` 与未确认退出区分 |
| 重新校验只可能撤销或收敛到**当前数据**的结论，绝不凭旧推理升级 | `decide()` 复用 + `fresh_decision` |
| 发布后的任何失败：撤销两个目标并传播 | `withdraw_all` / `SupersededStatusNotWithdrawn` |
| 重试上限用尽：撤销并**失败关闭** | `evaluate_pr` 末端 |
| fanout（base push / 持有者清理）尽力而为、逐候选隔离、聚合失败、有限并发 | `ThreadPoolExecutor(max_workers=4)` |
| 延迟事件（`closed` 后重开、`synchronize` 的 A→B→A、过期删除投递）不误撤销或搁置有效结论 | `reopen_aware_skip_set` + `deletion_is_stale` |

### 门禁**不**保证的（记录为已知边界，不再继续打补丁）

- **无法阻止两个开放 PR 共享同一 HEAD 时其中一方继承状态。** 这是 SHA 级状态的固有性质；门禁只能做到"不主动发布"和"发现共享后立即撤销"。彻底解决需要把状态绑到 PR（GitHub 的 check run 可带 `external_id`，但那需要改成 App 鉴权，超出本仓库令牌能力）。
- **无法把"最终写入者"排序。** 因为并发组独立，门禁只能保证每次写入都经过守卫与复核，不能保证时序。若需要严格串行，必须改用带 `merge_group` 的合并队列，而本仓库当前未启用（`grep -rl merge_group .github/workflows/` 为空）。
- **无法在硬超时杀死进程时完成撤销。** 只能把撤销前置并用有限并发缩小窗口；这是被记录的残余风险。
- **`success` 表示"审查已完成"，不表示"无阻塞缺陷"。** 与 #134 文档一致。
