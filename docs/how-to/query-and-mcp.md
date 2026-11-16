# 查询固定文档快照并接入本地 MCP

用 `cjdoc query` 在已保存的文档快照里搜索、翻页、读取单个声明的调用说明，再用 `cjdoc mcp` 把同一份快照作为本地 stdio MCP 服务交给客户端。查询只读快照：不重新扫描源码，不访问外部文档站。

## 什么时候用本页

- 要在编辑器、脚本或 Agent 里按名字查 API，而不是打开浏览器翻页面。
- 要给客户端配置一个只读文档服务，并且需要确认它读到的是哪一份快照。
- 只想生成站点或检查文档质量，不需要本页。

## 前提条件

- 已安装 `cjdoc`，当前终端已加载仓颉 SDK 运行环境。
- Bash 与 Python 3；Python 只用来读写 JSON。
- MCP 小节需要一个支持本地 stdio 服务的客户端；普通 `query` 不需要客户端。

```bash
mkdir -p "$HOME/.cache/cjdoc/examples"
TASK_ROOT="$(mktemp -d "$HOME/.cache/cjdoc/examples/query.XXXXXX")"
mkdir -p "$TASK_ROOT/src"
```

## 第一步：生成带机器清单的快照

三个函数都能匹配 `greet`，便于观察分页：

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

cjdoc generate --project "$TASK_ROOT" \
  --format html --agent-full --output "$TASK_ROOT/site"
export MANIFEST="$TASK_ROOT/site/html/agent/manifest.json"
```

预期 `$MANIFEST` 存在。它是本次快照的机器清单，`snapshotId` 形如 `cjdoc:snapshot:v1:<摘要>`；`--snapshot` 接受这份清单、输出根下的 `docs.json`，或组合站点的 `versions.json`。

保存或发布时保留完整 `site/html/`：只复制 `agent/` 会丢失清单引用的文档文件。服务读取快照后内容固定，重新生成站点后要重新启动读取它的服务。

## 第二步：搜索并读取下一页

先看有哪些匹配：从清单取 `snapshotId`，构造每页一项的搜索请求：

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
cjdoc query --snapshot "$MANIFEST" \
  --request "$TASK_ROOT/request.json" > "$TASK_ROOT/page-1.json"
```

预期退出码 `0`，`page-1.json` 的 `status` 是 `ok`，`text` 以这样的行开头：

```text
Documentation search: ok. Scope: cjdoc:snapshot:v1:<摘要> (zh-CN/external).
Matched 3 declarations and guide pages; showing 1 from offset 0.
```

把服务返回的 cursor 原样放进同一个请求再查一页：

```bash
python3 - "$TASK_ROOT/request.json" "$TASK_ROOT/page-1.json" "$TASK_ROOT/page-2-request.json" <<'PY'
import json
import sys
from pathlib import Path

request = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
result = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
print(result["text"])
cursor = result["completeness"]["query"]["next"]
if cursor is None:
    raise SystemExit("结果已完整，不需要继续翻页")
request["cursor"] = cursor
Path(sys.argv[3]).write_text(json.dumps(request), encoding="utf-8")
PY
cjdoc query --snapshot "$MANIFEST" \
  --request "$TASK_ROOT/page-2-request.json" > "$TASK_ROOT/page-2.json"
```

两页显示不同的声明（`greet`，然后是 `greetAgain`），第二页 `offset` 为 `1`。`completeness.query.next` 为 `null` 表示已经读完；否则继续沿用同一请求，只替换 `cursor`。

`snapshotId` 和 cursor 都原样传递，不要手写或解析其内部格式。改变查询、筛选、语言、`limit`、预算或输入快照后，删掉 cursor 从第一页重新查。

每次查询独立启动进程，结果写入各自的文件；要阅读完整响应结构，可以用 `python3 -m json.tool "$TASK_ROOT/page-2.json"`。

## 第三步：读取单个声明的调用说明

从第一页结果的 `identity` 取 `snapshotId` 与 `symbolId`，请求签名、参数、返回与调用约束：

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
cjdoc query --snapshot "$MANIFEST" \
  --request "$TASK_ROOT/detail-request.json" > "$TASK_ROOT/detail.json"
```

预期 `detail.json` 的 `status` 为 `ok`，`text` 包含小节 `## 签名`、`## 参数`、`## 返回值`，并给出 `public func greet(name: String): String` 与 `name` 的说明。结构化字段（`result`、`completeness`、`error`）用于判断缺项、预算省略和完整性，`text` 只是可读摘要。

要确定某个库或包对应哪份文档，用 `resolve_docs`：

```bash
cat > "$TASK_ROOT/resolve.json" <<'EOF'
{"schemaVersion":"cjdoc.query-request/3","operation":"resolve_docs","query":"querydemo"}
EOF
cjdoc query --snapshot "$MANIFEST" --request "$TASK_ROOT/resolve.json"
```

预期 `text` 首行为 `# resolve_docs: ok`，`selection` 里列出匹配的文档；多个候选时用响应里的范围与身份收窄请求，而不是按名字猜一个版本。

## 第四步：把本地 MCP 服务加入客户端

MCP 服务通过标准输入输出通信，不需要地址或端口。客户端配置需要的字段：

| 字段 | 填什么 |
|---|---|
| `command` | `command -v cjdoc` 输出的绝对可执行路径 |
| `args` | `mcp`、`--snapshot`、清单绝对路径，作为三个独立参数 |
| 环境 | SDK 运行库需要的平台环境变量 |

以 Codex CLI 为例，在已加载 SDK 的同一个终端登记：

```bash
CJDOC_BIN="$(command -v cjdoc)"
codex mcp add cjdoc --env "LD_LIBRARY_PATH=$LD_LIBRARY_PATH" -- \
  "$CJDOC_BIN" mcp --snapshot "$MANIFEST"
codex mcp list
```

预期 `codex mcp add` 输出 `Added global MCP server 'cjdoc'.`，`codex mcp list` 里出现名为 `cjdoc` 的条目及其命令与参数。这只证明配置已登记，不证明服务已连接。启动客户端并确认 `cjdoc` 已连接、工具列表包含 `resolve_docs`、`search`、`get_symbol`；工具可见之后，才由客户端决定是否调用。

其它客户端使用相同的绝对 `command` 和三个 `args`。macOS 传 SDK 环境脚本设置的 `DYLD` 运行库变量；Windows 传原生 `PATH`，可执行文件与清单使用 Windows 原生绝对路径。客户端不继承你的终端环境时，要在服务配置里显式填写这些变量。

不用客户端也可以直接验证协议：服务按行读写 JSON-RPC 2.0，先 `initialize`，再 `notifications/initialized`，之后才能调用工具。

```bash
python3 - "$MANIFEST" <<'PY'
import json, subprocess, sys
snap = json.load(open(sys.argv[1], encoding="utf-8"))["snapshotId"]
msgs = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize",
     "params": {"protocolVersion": "2025-11-25", "capabilities": {},
                "clientInfo": {"name": "manual-check", "version": "1.0"}}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
     "params": {"name": "search", "arguments": {"snapshotId": snap, "query": "greet", "limit": 2}}},
]
p = subprocess.run(["cjdoc", "mcp", "--snapshot", sys.argv[1]],
                   input="".join(json.dumps(m) + "\n" for m in msgs),
                   capture_output=True, text=True)
for line in p.stdout.splitlines():
    m = json.loads(line)
    if m.get("id") == 1:
        print("server:", m["result"]["serverInfo"])
    elif m.get("id") == 2:
        print("tools:", [t["name"] for t in m["result"]["tools"]])
    elif m.get("id") == 3:
        r = m["result"]
        print("isError:", r.get("isError"), "status:", r["structuredContent"]["status"])
PY
```

预期前两行类似 `server: {'name': 'cjdoc', 'version': '0.7.8'}`、`tools: ['resolve_docs', 'search', 'get_symbol']`，第三行 `isError: False status: ok`。`structuredContent` 是完整结果，`content[0].text` 只是其中的可读 `text`。

## 失败时怎么办

先读结果的 `status` 和 `error`，再决定是否改请求：

| 现象 | 含义与处理 |
|---|---|
| `not_found`，退出码 `0` | 当前捕获范围里没有匹配；检查名称与范围。结果不完整时可能是 `source_incomplete`，不能据此断言上游没有此 API |
| `ambiguous`，退出码 `0` | 有多个候选；用返回的文档、模块和符号身份收窄请求 |
| `stale_cursor`，退出码 `2` | cursor 与这次查询不一致；删除 cursor 从第一页重查 |
| `invalid_request`，退出码 `2` | 字段不合法。例如 `maxBytes` 小于 1024 会得到 `Request does not satisfy cjdoc.query-request/3. Invalid field 'maxBytes'.` |
| `scope_mismatch`，退出码 `2` | 请求的 `snapshotId` 不在本次加载的目录里，消息如 `The requested documentation scope is not loaded in this query catalog.`；改选快照 |
| `budget_exceeded`、`resource_limit`、`unavailable`，退出码 `3` | 读具体原因。预算不足时按返回信息调整，硬资源限制或快照不可读不能靠反复续页解决 |
| `unavailable` 且 `scope.snapshots` 为空，退出码 `3` | `--snapshot` 指向的文件不存在或不是可读快照 |
| MCP 报 `server is not ready; send initialize and notifications/initialized first` | 客户端在握手前调用了工具 | 按协议顺序先 `initialize`，再发 `notifications/initialized` |
| MCP 进程直接退出并打印 `cjdoc mcp: An explicit frozen documentation input could not be loaded.` | 清单路径不可读 | 修正 `--snapshot` 参数；客户端日志里也能看到这条 |

MCP 要分三层排查：进程启动或环境错误看客户端日志；JSON-RPC 错误看 `error` 对象；查询结果看 `structuredContent.status`。生命周期、资源限制和 `isError` 规则见[查询协议](../reference/query-protocol.md#本地-stdio-mcp)。

## 下一步

- [查完整请求、分页和结果字段](../reference/query-protocol.md)。
- [生成和发布完整站点](generate-and-publish.md)。
- [连接依赖库文档](link-documentation.md)。
