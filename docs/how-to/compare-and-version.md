# 比较 API 并组合多版本站点

本指南从两份真实不同的 PocketKit 源码生成 API 快照和 HTML 站点，输出差异报告，再组合成可切换版本的文档站。版本标签只标记站点身份，不能让同一份源码变成不同版本。

## 前提

- 已完成[当前源码安装](../getting-started/install.md)，当前 shell 中保留安装步骤记录的 `CJDOC_SOURCE`、`REVISION` 与 `CJDOC_REVISION`。安装页在构建时设置 `REVISION="$(git rev-parse HEAD)"`，并令 `CJDOC_REVISION="$REVISION"`；本页不从当前目录或 PATH 二进制重新推断身份。
- `CJDOC_SOURCE` 指向该 cjdoc checkout；`CJDOC_REVISION` 是本次二进制对应的完整 40 位源码提交。checkout 中存在 `examples/pocketkit/demo-v1`、`demo-v2` 和 `support-v1`。
- 使用 Bash、Git 和 GNU/POSIX tar。命令可从任意工作目录运行：源码输入先从固定提交归档到任务专属副本，所有 cjdoc 输出位于该副本之外的磁盘任务目录。

## 在隔离副本中比较并组合

完整工作流验证三个受保护输入目录的精确提交身份，把它们从记录的提交归档到私有副本，再以 `--no-cache` 生成两份真实 API 快照。身份检查通过仓库内 `worktree_identity.exact_worktree_identity` 比较原始文件字节，不使用会把 CRLF 行尾规范化误判为改动的 `git status --porcelain`。

```bash
set -eu
: "${CJDOC_SOURCE:?请使用安装步骤记录的 CJDOC_SOURCE}"
: "${REVISION:?请使用安装步骤记录的 REVISION}"
: "${CJDOC_REVISION:?请使用安装步骤记录的 CJDOC_REVISION}"
test "$CJDOC_REVISION" = "$REVISION"
CJDOC_SOURCE="$(cd "$CJDOC_SOURCE" && pwd -P)"

verify_source_inputs() {
  PYTHONPATH="$CJDOC_SOURCE/scripts" PYTHONDONTWRITEBYTECODE=1 \
    python3 - "$CJDOC_SOURCE" "$CJDOC_REVISION" <<'PY'
from pathlib import Path
import sys
from worktree_identity import exact_worktree_identity

root = Path(sys.argv[1])
revision = sys.argv[2]
for relative in (
    "examples/pocketkit/demo-v1",
    "examples/pocketkit/demo-v2",
    "examples/pocketkit/support-v1",
):
    identity = exact_worktree_identity(root / relative, revision)
    print(f"{relative}: {identity['pathTree']}")
PY
}

mkdir -p "$HOME/.cache/agent-tmp"
chmod 700 "$HOME/.cache/agent-tmp"
df -T "$HOME/.cache/agent-tmp"
TASK_ROOT="$(mktemp -d "$HOME/.cache/agent-tmp/cjdoc-versions.XXXXXX")"
INPUT="$TASK_ROOT/input"
WORK="$TASK_ROOT/output"
mkdir -p "$INPUT" "$WORK"
verify_source_inputs
git -C "$CJDOC_SOURCE" archive --format=tar "$CJDOC_REVISION" \
  examples/pocketkit/demo-v1 \
  examples/pocketkit/demo-v2 \
  examples/pocketkit/support-v1 | tar -xf - -C "$INPUT"
verify_source_inputs
V1="$INPUT/examples/pocketkit/demo-v1"
V2="$INPUT/examples/pocketkit/demo-v2"
test -f "$V1/cjpm.toml"
test -f "$V2/cjpm.toml"

cjdoc generate --project "$V1" --no-cache \
  --format html --format api-surface \
  --doc-version 0.1.0 --output "$WORK/v1"
cjdoc generate --project "$V2" --no-cache \
  --format html --format api-surface \
  --doc-version 0.2.0 --output "$WORK/v2"
cjdoc diff \
  --baseline "$WORK/v1/api-surface/api-surface.json" \
  --current "$WORK/v2/api-surface/api-surface.json" \
  --format text
cjdoc diff \
  --baseline "$WORK/v1/api-surface/api-surface.json" \
  --current "$WORK/v2/api-surface/api-surface.json" \
  --format json > "$WORK/v1-to-v2.json"
cjdoc versions compose \
  --version "0.1.0=$WORK/v1/html" \
  --channel 0.1.0=stable \
  --version "0.2.0=$WORK/v2/html" \
  --channel 0.2.0=preview \
  --diff "0.2.0=$WORK/v1-to-v2.json" \
  --latest 0.2.0 \
  --output "$WORK/site"
test -f "$WORK/site/index.html"
test -f "$WORK/site/versions.json"
test -f "$WORK/site/0.1.0/index.html"
test -f "$WORK/site/0.2.0/index.html"

cjdoc generate --project "$V2" --no-cache \
  --audience all --format api-surface --output "$WORK/v2-all"
if cjdoc diff \
    --baseline "$WORK/v1/api-surface/api-surface.json" \
    --current "$WORK/v2-all/api-surface/api-surface.json"; then
  echo '错误：不同 audience 的快照被比较' >&2
  exit 1
else
  status=$?
fi
test "$status" -eq 2
verify_source_inputs
```

`demo-v1/cjpm.toml` 声明包版本 `0.1.0`，`demo-v2/cjpm.toml` 声明 `0.2.0`；两者是不同源码目录，后者新增了 `TextCatalog.nonEmpty()`。它们使用同一个真实 `support-v1` path dependency。默认 audience 为 `external`，因此依赖源码参与构建输入，但不混入 PocketKit 的 API 文档。

成功后，差异报告描述两份当前 cjdoc API surface 快照；组合站点包含版本选择页和两份 HTML 树。浏览器打开 `$WORK/site/index.html`，检查版本选择页；静态托管时上传整个 `$WORK/site/`。目标版本若没有相同符号或概念页，站点会回退到版本首页或显示缺失提示。`--channel`、`--status` 和 `--release` 是展示元数据，不会验证发布流程或生成外链；`--release ID=TEXT` 接收纯文本。

`--deny-breaking-api` 会在 diff 含 breaking 项时退出 `1`；`--deny-potentially-breaking-api` 还会拒绝 potentially-breaking 项。没有 deny flag 时，`diff` 报告差异但不因差异本身失败。若要求完全没有变化（包括新增 API 和文档变化），使用 `check --api-surface-baseline`，这比只拒绝破坏性变化更严格。

如果身份检查失败，先恢复 `CJDOC_SOURCE` 所指 checkout 到安装记录中的 `CJDOC_REVISION`，不要忽略检查或直接从被修改的 fixture 生成。若 `diff` 因 project/audience/cfgProfile 不匹配而以 `2` 失败，确认快照均使用相同的 `--audience` 与 `--cfg`；不要通过改版本标签规避输入身份检查。分类和格式细节见[CLI 参考](../reference/cli.md)与[产物参考](../reference/artifacts.md)。

## 下一步

- [重渲染离线快照](render-snapshots.md)：从现有 `docs.json` 更新展示格式。
- [管理输出与缓存](manage-outputs.md)：安全处理多个独立输出目录。
- [排查常见故障](troubleshoot.md)：处理身份不匹配和旧快照。
