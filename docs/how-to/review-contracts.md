# 复核 API 契约与实际行为

把作者的说明、源码分支和真实消费者运行结果逐条对照，能发现“文档有内容但说错行为”的问题。自动覆盖率、质量分或单个示例通过，都不能单独证明完整调用契约。

## 前提

- `CJDOC_SOURCE` 指向当前源码安装 checkout；`REVISION` 与 `CJDOC_REVISION` 是安装页记录的同一个完整 40 位提交。仓库运行环境中的仓颉 SDK 1.2.0 STS 和匹配的静态 stdx sidecar 必须已激活。
- 使用 Bash、Python 3、Git、`cjc` 和 `cjpm`。`scripts/with_stdx.py` 会认证所选 SDK/stdx，不要手工替换不匹配的 sidecar。
- 报告与中间构建放在 `$HOME/.cache/agent-tmp` 下新建的任务专属目录，权限 `0700`，不放入 tmpfs。`CJDOC_SOURCE` 本身只作为被精确核对的只读输入。

## 运行固定源码与消费者检查

此 runner 从固定 revision 的 task-private 源码副本读取 `demo-v2`、`support-v1` 与消费者文件，将实际输入再复制并哈希到隔离证据目录，使用真实 `cjpm build` 构建库，再编译运行消费者。它还从副本中的中英文指南提取四个完整调用者程序，分别在独立目录编译运行，总计八个指南程序。以下 Bash 命令从任意目录运行；它只读取并核对 `CJDOC_SOURCE`，所有源码副本、报告、运行日志和中间构建均位于任务目录。

```bash
set -eu
: "${CJDOC_SOURCE:?请使用安装步骤记录的 CJDOC_SOURCE}"
: "${REVISION:?请使用安装步骤记录的 REVISION}"
: "${CJDOC_REVISION:?请使用安装步骤记录的 CJDOC_REVISION}"
test "$CJDOC_REVISION" = "$REVISION"
CJDOC_SOURCE="$(cd "$CJDOC_SOURCE" && pwd -P)"
verify_protected_inputs() {
  PYTHONPATH="$CJDOC_SOURCE/scripts" PYTHONDONTWRITEBYTECODE=1 \
    python3 - "$CJDOC_SOURCE" "$CJDOC_REVISION" <<'PY'
from pathlib import Path
import subprocess
import sys
from worktree_identity import exact_worktree_identity

root = Path(sys.argv[1])
revision = sys.argv[2]
for relative in (
    "examples/pocketkit/demo-v2",
    "examples/pocketkit/support-v1",
):
    exact_worktree_identity(root / relative, revision)

relative = "examples/pocketkit/contract_review.cj"
expected = subprocess.run(
    ["git", "-C", str(root), "rev-parse", f"{revision}:{relative}"],
    check=True, capture_output=True, text=True,
).stdout.strip()
actual = subprocess.run(
    ["git", "-C", str(root), "hash-object", "--no-filters", str(root / relative)],
    check=True, capture_output=True, text=True,
).stdout.strip()
assert actual == expected, f"protected input differs from {revision}: {relative}"
print(f"protected inputs match {revision}")
PY
}

mkdir -p "$HOME/.cache/agent-tmp"
chmod 700 "$HOME/.cache/agent-tmp"
df -T "$HOME/.cache/agent-tmp"
TASK_ROOT="$(mktemp -d "$HOME/.cache/agent-tmp/cjdoc-contract-review.XXXXXX")"
TASK_SOURCE="$TASK_ROOT/source"
EVIDENCE_ROOT="$TASK_ROOT/contracts"
mkdir -m 700 "$TASK_SOURCE" "$TASK_ROOT/tmp"
export TMPDIR="$TASK_ROOT/tmp" TMP="$TASK_ROOT/tmp" TEMP="$TASK_ROOT/tmp"
export PYTHONDONTWRITEBYTECODE=1
verify_protected_inputs
git -C "$CJDOC_SOURCE" archive --format=tar "$CJDOC_REVISION" | tar -xf - -C "$TASK_SOURCE"
verify_protected_inputs
cd "$TASK_SOURCE"
python3 scripts/with_stdx.py --variant static -- \
  python3 scripts/reader_contract_review.py \
  --revision "$CJDOC_REVISION" \
  --output "$EVIDENCE_ROOT"
verify_protected_inputs
```

成功判据是命令返回 `0`，且 `$EVIDENCE_ROOT/reader-contract-review.json` 的 `status` 为 `pass`，`cases` 收录 13 个固定消费者场景，`guidePrograms` 收录 8 个已通过程序。报告绑定源码副本摘要、消费者摘要、SDK 与工具版本、各阶段退出码及资源记录；应同时保留报告和同目录的阶段日志，完成后不要覆盖这份证据。

固定消费者场景覆盖目录构造复制、顺序/重复/空字符串、索引边界、十进制追加、addAll 复制、snapshot/clear 容器独立性，以及内存 TextReader 的 EOF、rewind 和 close 状态。中英文指南包含保存/读取、快照/清空、索引错误和关闭读取器四项完整程序。查看[中文指南](https://github.com/lIlIIlIll/cjdoc/blob/main/examples/pocketkit/demo-v2/docs/guide.md)、[英文指南](https://github.com/lIlIIlIll/cjdoc/blob/main/examples/pocketkit/demo-v2/docs/en/guide.md)和[源码实现](https://github.com/lIlIIlIll/cjdoc/blob/main/examples/pocketkit/demo-v2/src/catalog.cj)。

## 手工复核未被测试证明的承诺

自动 runner 只覆盖固定输入和状态，不判定每条自然语言是否完整。发布前逐个适用维度记录作者声明位置、源码/测试依据、结论和未覆盖边界；结论限于“已覆盖事实一致”“缺少说明/待作者确认”“确有矛盾”或“此维度不适用”。

| 复核维度 | 要确认的事实 |
|---|---|
| 输入与前置条件 | 有效范围、端点、默认值、空/负值、单位；不要把调用前置条件写成实现会自动校验。 |
| 返回与异常 | 每种结果/异常各自的触发条件；同一个异常类型不代表所有方法的条件相同。 |
| 状态和失败 | 成功/失败后的状态、顺序、重复调用和失败原子性；未声明或未测试的失败原子性保持未知。 |
| 所有权与资源 | 是复制容器还是共享引用，旧快照是否独立，谁关闭资源、关闭后哪些操作被拒绝。 |
| 并发与性能 | 单线程运行不能证明线程安全；不要由方法名、循环或一次运行推导复杂度。 |
| 翻译与来源 | 检查译文是否指向同一逻辑条目，并显式保留缺译、未解析类型、继承/条件来源等不确定性。 |

以已知实现作判定例子：把 `tryAt` 写成“越界时返回 `Some`”与 `tryAt` 的实际边界分支和 C02 消费者观察到的 `None` 相矛盾；把 `addAll` 写成“分配失败时对象完全不变”则没有相应故障注入证据，结论应是待作者确认/未知，而不是自动判成正确或错误。`TextReader` 是内存会话的行为证据，不能推广到系统文件、网络资源、线程安全或其它同名 API。

## 证据边界

`pass` 只说明上述 13 个选定消费者场景和 8 个指南程序在报告中绑定的输入副本上通过。它不证明完整 API 契约、所有 Int64 输入、内存分配失败、并发安全、复杂度、所有 SDK/平台或任意调用方式。报告中的来源哈希说明编译器读取了哪些副本，不等同于全源审计。指南 Markdown 中的普通代码围栏不是 `@example` doctest 结果；不要混淆两种证据。

若命令或任何程序失败，保留实际报告与日志作为失败证据，确认输入/工具链身份后再调查；不要把失败改写成“缺少说明”，也不要把旧报告归给新提交。

## 下一步

- [检查文档质量](check-quality.md)：理解字段存在、结构质量和语义复核的分界。
- [检查示例](check-examples.md)：验证源码注释中的 `@example` 编译和运行。
- [比较 API 与版本](compare-and-version.md)：核对不同源码快照的 API 变化。
