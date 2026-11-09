# 查询固定文档快照并连接 MCP

生成一份文档快照，用命令行搜索和分页读取声明说明，再把同一份快照接入本地 MCP 客户端。查询读取保存下来的文档，不重新扫描源码，也不访问外部文档网站。

## 前提

- 已安装 `cjdoc`，当前终端已加载仓颉 SDK 运行环境。
- Bash 和 Python 3；Python 只用于读取 JSON、创建请求和显示结果。
- MCP 接入小节另需已经安装的 Codex CLI，或支持本地 stdio 服务的其它客户端。普通 `query` 不需要客户端。

从任意目录创建练习目录，后续命令沿用同一个 `TASK_ROOT`：

```bash
mkdir -p "$HOME/.cache/cjdoc/examples"
TASK_ROOT="$(mktemp -d "$HOME/.cache/cjdoc/examples/query.XXXXXX")"
mkdir -p "$TASK_ROOT/src"
```

这只是练习文件的存放位置，也可以换成自己的空目录。

## 创建项目并生成快照

三个函数都能匹配 `greet`，便于分页阅读。写入完整清单和源码：

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

`MANIFEST` 是本次快照的机器清单，使用绝对路径。保存或发布时保留完整 `site/html/` 树：只复制 `agent/` 会丢失清单引用的文档文件。查询与 MCP 启动后读取固定内容；重新生成站点后，重新启动读取它的服务。

## 搜索并读取下一页

从清单中读取 `snapshotId`，创建每页一项的搜索请求：

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

显示本页结果，并将服务返回的 cursor 原样加入同一个请求：

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
python3 - "$TASK_ROOT/page-2.json" <<'PY'
import json
import sys
from pathlib import Path
print(json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["text"])
PY
```

两页应显示不同的匹配声明。`completeness.query.next` 为 `null` 时已经读完；否则继续沿用相同请求，只替换 cursor。

`snapshotId` 和 cursor 都应原样传递，不手写或解析其内部格式。改变查询、筛选、语言、`limit`、预算或输入快照时，删除 cursor，从第一页重新查询；将旧 cursor 放入新查询会得到 `stale_cursor`。

## 读取声明的调用说明

从第一页返回的 `identity` 取得 `snapshotId` 和 `symbolId`，请求签名、参数、返回与调用约束：

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
python3 - "$TASK_ROOT/detail.json" <<'PY'
import json
import sys
from pathlib import Path
print(json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["text"])
PY
```

终端显示该函数的完整签名、参数 `name` 和返回说明。需要处理精确状态时读取 `detail.json` 的结构化字段：`text` 便于阅读，不能代替缺项、预算省略和完整性状态。

要先确定某个库或包对应哪份文档，可以使用 `resolve_docs`。例如把下面内容保存为 `$TASK_ROOT/resolve.json`，再执行其后的查询：

```json
{"schemaVersion":"cjdoc.query-request/3","operation":"resolve_docs","query":"querydemo"}
```

```bash
cjdoc query --snapshot "$MANIFEST" --request "$TASK_ROOT/resolve.json"
```

`selection` 中会列出匹配文档；多个候选时，使用响应里的范围和身份收窄请求，而不是按名字猜选一个版本。

## 把本地 MCP 服务加入客户端

MCP 服务通过本地标准输入输出通信，不需要 HTTP 地址或监听端口。客户端所需的配置是：

| 字段 | 填什么 |
|---|---|
| `command` | `command -v cjdoc` 输出的绝对可执行路径 |
| `args` | `mcp`、`--snapshot`、`MANIFEST` 的绝对路径，作为三个独立参数 |
| 环境 | SDK 运行库需要的平台环境变量 |

Linux 上，在已加载 SDK 的同一个终端登记 Codex CLI 服务：

```bash
CJDOC_BIN="$(command -v cjdoc)"
codex mcp add cjdoc --env "LD_LIBRARY_PATH=$LD_LIBRARY_PATH" -- \
  "$CJDOC_BIN" mcp --snapshot "$MANIFEST"
codex mcp list
```

`codex mcp list` 只确认配置已经登记，不证明服务已连接。启动 `codex`，在客户端输入 `/mcp`，确认 `cjdoc` 已连接，并列出 `resolve_docs`、`search`、`get_symbol` 三个工具。工具可见以后，才让客户端按你的任务选择是否调用它们；连接或工具发现本身不表示模型已使用工具。

其它客户端使用相同的绝对 `command` 和三个 `args`。macOS 传递 SDK 环境脚本设置的 `DYLD` 运行库变量；Windows 传递原生 `PATH`，可执行文件和 manifest 使用 Windows 原生绝对路径。客户端不会继承你的终端环境时，需要在服务配置中显式填写这些变量。完整客户端配置见[Codex MCP 文档](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)。

若 Codex 0.163 报缺少配套 `codex-code-mode-host`，修复客户端的完整安装后重新连接；它不是 cjdoc 的文档快照文件。

## 处理未命中和查询错误

先读结果的 `status` 和 `error`，再决定是否修改请求：

| 现象 | 含义与处理 |
|---|---|
| `not_found`，CLI 退出 `0` | 当前完整捕获范围中没有匹配；检查名称和范围。输入不完整时可能返回 `source_incomplete`，不能据此断言上游没有此 API。 |
| `ambiguous`，CLI 退出 `0` | 有多个候选；使用返回的文档、模块和符号身份收窄请求。 |
| `stale_cursor`，CLI 退出 `2` | cursor 与这次查询不一致；删除 cursor，从第一页开始。 |
| `invalid_request` 或 `scope_mismatch`，CLI 退出 `2` | 字段不合法，或请求范围不属于已加载快照；按协议修正字段或选择快照。 |
| `budget_exceeded`、`resource_limit`、`unavailable`，CLI 退出 `3` | 阅读具体原因。用户预算不足时按返回信息调整预算；硬资源限制或缺失快照不能靠反复续页解决。 |

MCP 要分开处理三层问题：进程启动或环境错误看客户端日志；JSON-RPC 错误看协议错误对象；查询执行结果看工具的 `structuredContent.status`。`structuredContent` 是完整结果，`content[0].text` 只是其中的可读 `text`。生命周期、资源限制和 `isError` 规则见[查询协议](../reference/query-protocol.md#本地-stdio-mcp)。维护服务适配器时，可以另外使用[维护者协议自测](https://github.com/lIlIIlIll/cjdoc/blob/main/docs/maintainer/agent-evaluation.md#确定性门禁)。

## 下一步

- [查完整请求、分页和结果字段](../reference/query-protocol.md)。
- [生成和发布完整站点](generate-and-publish.md)。
- [连接依赖库文档](link-documentation.md)。
