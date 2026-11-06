# 查询固定文档快照并连接 MCP

本指南为一个小型 Cangjie package 生成 HTML 与机器读取快照，用 `cjdoc query` 分页读取，再启动真实的本地 stdio MCP 子进程执行 initialize、tools/list 和 tools/call。所有查询都读取该次生成的固定快照，不重新扫描项目或解析当前 SDK。

## 前提与工具身份

- 已完成[源码安装](../getting-started/install.md)，当前 shell 已加载 cjdoc 所需的 Cangjie runtime。
- `CJDOC_SOURCE` 和 `CJDOC_REVISION` 使用安装时记录的源码 checkout 与完整提交；本指南调用该 checkout 的 `target/release/bin/main`，不从 PATH 上的版本字符串推断 binary identity。
- Bash 与 Python 3。示例项目由本页完整创建；不需要项目依赖、Node、Cangjie 编译器或网络。

在 Bash 中检查安装记录，并确认 `$HOME/.cache` 位于磁盘文件系统而非 tmpfs。新终端须恢复源码身份并重新加载 SDK runtime；本页随后创建专用临时目录，所有项目输入、生成站点、请求文件与 Python 临时数据都位于 `CJDOC_SOURCE` 之外：

```bash
: "${CJDOC_SOURCE:?先按源码安装页设置 CJDOC_SOURCE}"
: "${CJDOC_REVISION:?从构建记录恢复与二进制配对的完整提交}"
test "$(git -C "$CJDOC_SOURCE" rev-parse --verify HEAD)" = "$CJDOC_REVISION"
export CJDOC_BIN="$CJDOC_SOURCE/target/release/bin/main"
if [ -f "$CJDOC_BIN.exe" ]; then export CJDOC_BIN="$CJDOC_BIN.exe"; fi
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) test -f "$CJDOC_BIN" ;;
  *) test -x "$CJDOC_BIN" ;;
esac

mkdir -p "$HOME/.cache/agent-tmp"
chmod 700 "$HOME/.cache/agent-tmp"
export TASK_AREA="$(mktemp -d "$HOME/.cache/agent-tmp/cjdoc-query-mcp.XXXXXX")"
export RUNNER_TEMP="$(mktemp -d "$TASK_AREA/runner-temp.XXXXXX")"
export TMPDIR="$RUNNER_TEMP" TMP="$RUNNER_TEMP" TEMP="$RUNNER_TEMP"
export PYTHONDONTWRITEBYTECODE=1
case "$TASK_AREA/" in
  "$CJDOC_SOURCE/"*) printf '任务目录必须位于 CJDOC_SOURCE 之外\n' >&2; exit 1 ;;
esac
export TASK_ROOT="$TASK_AREA/project"
mkdir -p "$TASK_ROOT/src"
```

## 创建项目并生成快照

三个公开函数都匹配搜索词 `greet`，便于用每页一项的查询观察分页。`--agent-full` 为 HTML 文档根生成全文索引；它不改变被扫描的源码。

```bash
cat > "$TASK_ROOT/cjpm.toml" <<'EOF'
[package]
cjc-version = "1.2.0"
name = "querydemo"
version = "0.1.0"
output-type = "static"
EOF

cat > "$TASK_ROOT/src/api.cj" <<'EOF'
package querydemo

/** 向一个人问好。
 * @param name 原样写入问候语的姓名。
 * @return 包含姓名的问候语。
 */
public func greet(name: String): String { "Hello, ${name}!" }

/** 再次向一个人问好。
 * @param name 原样写入问候语的姓名。
 * @return 第二条问候语。
 */
public func greetAgain(name: String): String { greet(name) + " Again." }

/** 以 Welcome 开头向一个人问好。
 * @param name 原样写入问候语的姓名。
 * @return 以 Welcome 开头的问候语。
 */
public func greetWelcome(name: String): String { "Welcome, " + name + "!" }
EOF

"$CJDOC_BIN" generate --project "$TASK_ROOT" \
  --format html --agent-full --output "$TASK_ROOT/site"
```

机器读取快照 manifest 位于 `$TASK_ROOT/site/html/agent/manifest.json`。若要部署给其他 reader，复制完整 `html/` 目录；只复制 `index.html` 或 `agent/` 会破坏 manifest 记录的相对表示路径。

从生成的 manifest 读取真实 snapshot identity，不复制或猜测 ID：

```bash
export MANIFEST="$TASK_ROOT/site/html/agent/manifest.json"
python3 - "$MANIFEST" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert manifest["schemaVersion"] == "cjdoc.machine-manifest/1"
assert manifest["snapshotId"].startswith("cjdoc:snapshot:v1:")
print("snapshotId：", manifest["snapshotId"])
print("publicationRevision：", repr(manifest["publicationRevision"]))
PY
```

`publicationRevision` 是文档发布标签，不是 package 或 compiler 版本。本例没有设置 `--doc-version`，所以该字段为空；`snapshotId` 仍标识这份已捕获快照。

## 用 CLI 搜索并继续翻页

查询请求明确携带 manifest 中的 snapshot identity。请求和结果 schema 分别是 `cjdoc.query-request/3` 与 `cjdoc.query-result/4`。

```bash
python3 - "$MANIFEST" "$TASK_ROOT/request.json" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
request = {
    "schemaVersion": "cjdoc.query-request/3",
    "operation": "search",
    "snapshotId": manifest["snapshotId"],
    "query": "greet",
    "mode": "discovery",
    "profile": "full-ir",
    "limit": 1,
}
Path(sys.argv[2]).write_text(json.dumps(request), encoding="utf-8")
PY

"$CJDOC_BIN" query --snapshot "$MANIFEST" \
  --request "$TASK_ROOT/request.json" > "$TASK_ROOT/page-1.json"
```

读取结果中的不透明 continuation token，并只在原请求上添加这个 server-issued cursor：

```bash
python3 - "$TASK_ROOT/request.json" "$TASK_ROOT/page-1.json" "$TASK_ROOT/page-2-request.json" <<'PY'
import json
import sys
from pathlib import Path

request = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
result = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
assert result["schemaVersion"] == "cjdoc.query-result/4"
print("状态：", result["status"])
print("本页条目数：", len(result["result"]["items"]))
cursor = result["completeness"]["query"]["next"]
if cursor is None:
    raise SystemExit("结果已完整，没有 continuation cursor")
request["cursor"] = cursor
Path(sys.argv[3]).write_text(json.dumps(request), encoding="utf-8")
PY

"$CJDOC_BIN" query --snapshot "$MANIFEST" \
  --request "$TASK_ROOT/page-2-request.json" > "$TASK_ROOT/page-2.json"
```

cursor 绑定完整的规范化请求与 snapshot。要修改查询条件，删掉旧 cursor 并从第一页重新开始；不要自行构造或在不同 snapshot 之间复用 cursor。

从搜索结果本身取得 symbol identity，再请求详情：

```bash
python3 - "$TASK_ROOT/page-1.json" "$TASK_ROOT/detail-request.json" <<'PY'
import json
import sys
from pathlib import Path

result = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
identity = result["result"]["items"][0]["identity"]
request = {
    "schemaVersion": "cjdoc.query-request/3",
    "operation": "get_symbol",
    "snapshotId": identity["snapshotId"],
    "symbolId": identity["symbolId"],
    "preset": "call",
    "maxBytes": 65536,
}
Path(sys.argv[2]).write_text(json.dumps(request), encoding="utf-8")
PY

"$CJDOC_BIN" query --snapshot "$MANIFEST" \
  --request "$TASK_ROOT/detail-request.json" > "$TASK_ROOT/detail.json"
```

## 区分领域结果与输入错误

没有匹配符号是有效的领域结果 `not_found`，CLI exit code 为 0。把第一页 cursor 用在已改变的 query 上则得到 `stale_cursor`，CLI exit code 为 2。下面用真实的第一页结果核对这两种状态：

```bash
python3 - "$CJDOC_BIN" "$MANIFEST" "$TASK_ROOT/request.json" "$TASK_ROOT/page-1.json" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

binary, manifest, request_path, page_path = sys.argv[1:]
request = json.loads(Path(request_path).read_text(encoding="utf-8"))
page = json.loads(Path(page_path).read_text(encoding="utf-8"))

not_found = dict(request, query="querydemo 中不存在的符号")
run = subprocess.run([binary, "query", "--snapshot", manifest, "--request", "-"],
                     input=json.dumps(not_found), text=True, capture_output=True)
result = json.loads(run.stdout)
assert run.returncode == 0 and result["status"] == "not_found", (run.returncode, result)
print("not_found 领域状态，exit code：", run.returncode)

stale = dict(request, query="已改变的搜索条件",
             cursor=page["completeness"]["query"]["next"])
run = subprocess.run([binary, "query", "--snapshot", manifest, "--request", "-"],
                     input=json.dumps(stale), text=True, capture_output=True)
result = json.loads(run.stdout)
assert run.returncode == 2 and result["status"] == "stale_cursor", (run.returncode, result)
print("stale_cursor 输入状态，exit code：", run.returncode)
PY
```

未知 snapshot identity 返回 `scope_mismatch`；请求 schema 或字段错误属于输入错误，不应误认为 `not_found`。完整状态与 exit code 见[查询协议参考](../reference/query-protocol.md)和[状态与限制](../reference/states-and-limits.md)。

## 启动真实 stdio MCP 并调用工具

下面的 Python 客户端启动实际的 `cjdoc mcp --snapshot ...` 子进程，执行 initialize、`notifications/initialized`、tools/list 和 tools/call。它使用与 CLI 相同的 manifest 和 query core；不涉及模型客户端或网络连接。

```bash
python3 - "$CJDOC_BIN" "$MANIFEST" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

binary, manifest_path = sys.argv[1:]
manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
snapshot_id = manifest["snapshotId"]
process = subprocess.Popen(
    [binary, "mcp", "--snapshot", manifest_path],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    text=True, encoding="utf-8",
)

def exchange_raw(message):
    process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
    process.stdin.flush()
    line = process.stdout.readline()
    if not line:
        raise RuntimeError("MCP 子进程在响应前关闭了 stdout")
    return json.loads(line)

def exchange(message):
    reply = exchange_raw(message)
    if "error" in reply:
        raise RuntimeError(f"JSON-RPC error: {reply['error']}")
    return reply["result"]

initialized = exchange({
    "jsonrpc": "2.0", "id": 1, "method": "initialize",
    "params": {
        "protocolVersion": "2025-11-25",
        "capabilities": {},
        "clientInfo": {"name": "cjdoc-manual", "version": "1"},
    },
})
assert initialized["protocolVersion"] == "2025-11-25"
process.stdin.write(json.dumps({
    "jsonrpc": "2.0", "method": "notifications/initialized", "params": {},
}) + "\n")
process.stdin.flush()

listed = exchange({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
names = {tool["name"] for tool in listed["tools"]}
assert names == {"resolve_docs", "search", "get_symbol"}, names

arguments = {
    "schemaVersion": "cjdoc.query-request/3",
    "snapshotId": snapshot_id,
    "query": "greet",
    "mode": "discovery",
    "profile": "full-ir",
    "limit": 1,
}
first_call = exchange({
    "jsonrpc": "2.0", "id": 3, "method": "tools/call",
    "params": {"name": "search", "arguments": arguments},
})
first_result = first_call["structuredContent"]
assert first_result["schemaVersion"] == "cjdoc.query-result/4"
assert first_result["status"] == "ok", first_result["status"]
print("initialize：", initialized["serverInfo"]["name"], initialized["protocolVersion"])
print("tools：", ", ".join(sorted(names)))
print("search：", first_result["status"])

cursor = first_result["completeness"]["query"]["next"]
if cursor is None:
    raise SystemExit("本例预期 search 返回 continuation cursor")
next_call = exchange({
    "jsonrpc": "2.0", "id": 4, "method": "tools/call",
    "params": {"name": "search", "arguments": dict(arguments, cursor=cursor)},
})
next_result = next_call["structuredContent"]
assert next_result["schemaVersion"] == "cjdoc.query-result/4"
assert next_result["status"] == "ok"
print("continuation：", next_result["status"])

not_found = dict(arguments, query="querydemo 中不存在的符号")
not_found_call = exchange({
    "jsonrpc": "2.0", "id": 5, "method": "tools/call",
    "params": {"name": "search", "arguments": not_found},
})
not_found_result = not_found_call["structuredContent"]
assert not_found_result["status"] == "not_found"
assert not_found_call["isError"] is False
print("not_found：领域结果，isError=false")

stale = dict(arguments, query="已改变的搜索条件", cursor=cursor)
stale_call = exchange({
    "jsonrpc": "2.0", "id": 6, "method": "tools/call",
    "params": {"name": "search", "arguments": stale},
})
stale_result = stale_call["structuredContent"]
assert stale_result["status"] == "stale_cursor"
assert stale_call["isError"] is True
print("stale_cursor：工具输入错误，isError=true")

unknown = exchange_raw({
    "jsonrpc": "2.0", "id": 7, "method": "tools/call",
    "params": {"name": "unknown-tool", "arguments": {}},
})
assert unknown["error"]["code"] == -32602
print("未知工具：JSON-RPC error code", unknown["error"]["code"])

process.stdin.close()
exit_code = process.wait(timeout=30)
stderr = process.stderr.read()
if exit_code != 0:
    raise SystemExit(f"MCP 以 {exit_code} 退出：{stderr}")
print("关闭 stdin 后正常退出：", exit_code)
PY
```

MCP 的工具名选择 operation，因此 tools/call 的 `arguments` 中不能再传 `operation`。`not_found` 是 `structuredContent` 中的领域状态，`isError=false`；`stale_cursor` 是工具调用错误，`isError=true`；无效工具名是 JSON-RPC `-32602`，位于顶层 `error` 而非领域结果。初始化后关闭 stdin 会让本地 server 正常结束；直接测试 MCP 不代表模型客户端已经成功调用。

## 后续任务

- [生成与发布文档](generate-and-publish.md)
- [检查查询请求与结果 schema](../reference/query-protocol.md)
- [关联外部文档](link-documentation.md)
