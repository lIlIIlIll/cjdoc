# Codex 复审完成门禁

本门禁针对 **OpenAI 托管的 `chatgpt-codex-connector` GitHub Code Review**，不是 `openai/codex-action`。它用于保证待合并 PR 的**最新 HEAD 已完成复审**；不替代代码正确性判断、CI 或问题分级。

## 工作机制

- PR 打开、更新、重新打开或变为可审查状态时，`pull_request_target` 触发 `.github/workflows/codex-review-gate.yml`，读取服务端**当前** PR HEAD。
- Codex 新建或编辑 Review Summary 评论时，`issue_comment` 触发同一判断。脚本只接受指定 Codex GitHub App Bot 的评论，解析 `<!-- codex-review-state:v1 ... -->` 中 `code_review.commit_sha`（**完整 40 位 SHA**）和 `code_review.status`；**不**信任评论时间、缩写 SHA、PR reaction、旧 review 或 security review 状态。
- 每次判断写入 `codex-review-current-head` Commit Status（当前 HEAD；当 GitHub 产生了与当前 base/head 对应的可信 test merge commit 时，也写入该 merge commit，以支持 Required Checks 在不同场景的判定）。
- 仅在 `code_review.status == completed` 且完整 SHA 等于当前 HEAD 时才标为 `success`；旧提交、未收到结论、正在审查标为 `pending`；失败/无法识别的结构标为 `failure`/`error`。不因找不到新 Thread 就推断审查完成。
- 如果该次审查含未解决意见，完成门禁仍为 `success`，但会在描述中提醒需要分类处理。**“审查完成”不等于“无阻塞缺陷/可合并”**，另由 Agent/维护者按 `AGENTS.md` 处理。

Gate 只读取 **默认分支上的可信脚本**，不执行 PR 代码；其 `GITHUB_TOKEN` 仅具备必需的只读权限和 `statuses: write`。PR 修改本门禁时，独立的 `pull_request` 只读测试任务验证改动。Codex Summary 的注释格式属于第三方实现细节，发生兼容性变更时必须先更新解析器与测试，不得改为“无摘要即成功”。

## 启用 Required Check

1. **先合并引入门禁的 PR**，让 `.github/workflows/codex-review-gate.yml` 存在于默认分支。不要在首次部署前就把尚未出现的检查设为 Required，以免死锁。
2. 在 [Codex Review 设置](https://chatgpt.com/codex/settings/code-review) 中为仓库保留 **On every push**；本门禁不会触发或代替 Codex Review，只验证完成证据。
3. 在一个新测试 PR 中 Push 一次，确认状态先显示 `codex-review-current-head: pending`，Codex Summary 对当前完整 SHA 标记 `completed` 后变为 `success`。带未解决意见的 Review 也应该显示“完成但需处理意见”，而不是“clean”。
4. 在 GitHub 仓库 **Settings → Rules → Rulesets**（或 Settings → Branches → Branch protection rules）找到适用于 `main` 的规则，启用 **Require status checks to pass**，将 `codex-review-current-head` 设为 Required；如可指定状态来源，选择产生该状态的 GitHub Actions App。保留已有 CI Required Checks。
5. 对更新后的 PR 再次 Push，核对旧 HEAD 的成功不能满足新 HEAD。通过前不得合并；Review 中的真实阻塞缺陷仍需单独处理。

如果 GitHub 认为 test merge commit 是 required checks 判定对象，门禁仅在确认其父提交与当前 PR 的 base/head 一致后才为该对象发布状态。对直接推送受保护分支、绕过保护和合并队列的行为，本门禁并不单独提供防护，应由 GitHub Ruleset 另行限制；使用 merge queue 前还需专门集成 `merge_group`。

## 排查与人工同步

- 未审查/未自动触发：先查看 Codex Review 设置及最新 PR Summary；必要时评论 `@codex review`。
- Review Summary 已完成，但状态仍 Pending：打开 Actions → **Codex review gate**，检查 Bot 的 summary edit 事件是否触发、GitHub Actions 权限、实际 SHA；必要时从该工作流 **Run workflow** 输入 PR 编号执行一次手动同步。
- Summary 结构变化导致 Error：修复 `scripts/codex_review_gate.py` 的解析器并补测试，**不要**临时接受仅基于时间或缩写 SHA 的结论。
- 本地快速测试：`python3 -m unittest discover -s tests -p 'test_codex_review_gate.py' -v`（不需要仓颉 SDK）。

## 局限

GitHub Status 本身不能确保外部 Codex 服务一定运行或按时返回；当它未运行时，门禁会保持 Pending，而不是错误放行。是否已有 Reviewer 批准、是否存在真实阻塞缺陷、CI 是否成功，仍需由原有独立门禁与验收流程判断。本方案尚不自动修改 GitHub Ruleset 或合并 PR。
