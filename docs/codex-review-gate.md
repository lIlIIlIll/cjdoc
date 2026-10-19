# Codex 复审完成门禁

本门禁针对 **OpenAI 托管的 `chatgpt-codex-connector` GitHub Code Review**，不是 `openai/codex-action`。它用于保证待合并 PR 的**最新 HEAD 已完成复审**；不替代代码正确性判断、CI 或问题分级。

## 工作机制

- PR 打开、更新、重新打开、变为可审查状态**或关闭**时，`pull_request_target` 触发 `.github/workflows/codex-review-gate.yml`，读取服务端**当前** PR HEAD。
- Codex 新建、编辑或删除 Review Summary 评论时，`issue_comment` 触发同一判断；删除 canonical summary 时直接将原有成功状态撤回为 `pending`，即便 API 暂时仍返回旧摘要或留有更早版本也不放行。脚本只接受指定 Codex GitHub App Bot 的评论，解析 `<!-- codex-review-state:v1 ... -->` 中 `code_review.commit_sha`（**完整 40 位 SHA**）和 `code_review.status`；**不**信任评论时间、缩写 SHA、PR reaction、旧 review 或 security review 状态。
- 当一个 HEAD 被多个开放 PR 共享时，该 SHA 对它们都保持 `pending`。若其中一个 PR 关闭或推送到新提交，剩下唯一持有者需要被重新评估，否则其已完成的审查会永久停在 `pending`。因此 `closed` 与 `synchronize` 事件会额外对**受影响的旧 HEAD** 的其余持有者各评估一次（不重复评估触发事件的那条 PR）。
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
