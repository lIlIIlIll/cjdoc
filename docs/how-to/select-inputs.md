# 选择要生成文档的源码、依赖与条件编译

一次生成读取哪些源码、按什么条件读取，由几个互相独立的开关决定。本页用同一个 workspace 逐个打开它们，并给出确认结果出现的办法。

## 什么时候用本页

- 项目是 workspace，或通过路径依赖、Git 依赖使用别的库，而你想让依赖 API 也出现在站点里。
- 声明带 `@When` 等条件编译注解，需要给出条件值才会出现。
- 需要把私有声明一起写进文档（内部设计说明），或者已经用 cjpm 取好了依赖源码，只想让 cjdoc 读取缓存。

只想给一个普通库生成站点、没有依赖和条件编译时，不需要这里的任何选项，直接按[生成与发布](generate-and-publish.md)操作。

## 前提条件

- 已按[安装 cjdoc](../getting-started/install.md)安装 `cjdoc`，当前终端已加载仓颉 SDK 1.2.0 环境，`cjc` 与 `cjpm` 可用。
- Bash 与 Python 3；下面用 Python 读取生成出来的 JSON。
- 练习目录放在磁盘文件系统上，`$HOME/.cache` 用 `df -T "$HOME/.cache"` 确认不是 tmpfs。

生成不要求先编译项目：cjdoc 直接读 `cjpm.toml` 和源码。整个练习只读你自己的练习目录：

```bash
mkdir -p "$HOME/.cache/cjdoc/examples"
TASK_ROOT="$(mktemp -d "$HOME/.cache/cjdoc/examples/inputs.XXXXXX")"
mkdir -p "$TASK_ROOT/workspace/packages/app/src" \
  "$TASK_ROOT/workspace/packages/peer/src" \
  "$TASK_ROOT/workspace/shared/src"
```

`$TASK_ROOT` 是本次练习的根目录，后面所有命令都沿用它。这里的 workspace 有两个成员，其中一个还通过路径依赖引用 `shared`；`app` 里有一处条件编译和一个私有函数：

```bash
cat > "$TASK_ROOT/workspace/cjpm.toml" <<'EOF'
[workspace]
members = ["packages/app", "packages/peer"]
EOF

cat > "$TASK_ROOT/workspace/packages/app/cjpm.toml" <<'EOF'
[package]
cjc-version = "1.2.0"
name = "app"
version = "0.1.0"
output-type = "static"

[dependencies]
shared = { path = "../../shared", output-type = "static" }
EOF

cat > "$TASK_ROOT/workspace/packages/app/src/api.cj" <<'EOF'
package app

/** 使用 feature cfg 时才出现的 API。 */
@When[feature == "extra"]
public func featureApi(): Int64 { 1 }

/** 内部辅助函数，仅在 audience all 输出中显示。 */
private func hiddenApi(): Unit {}
EOF

cat > "$TASK_ROOT/workspace/packages/peer/cjpm.toml" <<'EOF'
[package]
cjc-version = "1.2.0"
name = "peer"
version = "0.1.0"
output-type = "static"
EOF

cat > "$TASK_ROOT/workspace/packages/peer/src/api.cj" <<'EOF'
package peer

/** 第二个 workspace 成员的 API。 */
public func peerApi(): Unit {}
EOF

cat > "$TASK_ROOT/workspace/shared/cjpm.toml" <<'EOF'
[package]
cjc-version = "1.2.0"
name = "shared"
version = "0.1.0"
output-type = "static"
EOF

cat > "$TASK_ROOT/workspace/shared/src/api.cj" <<'EOF'
package shared

/** path dependency 中的 API。 */
public func sharedApi(): String { "shared" }
EOF
```

## 第一步：确认默认收集范围

先不加任何输入选项生成一次，得到基线：

```bash
cjdoc generate --project "$TASK_ROOT/workspace" \
  --format html --format json --output "$TASK_ROOT/site-default"
```

输出末尾是 `generated <输出目录>`。终端还会出现 `CJDOC3036`、`CJDOC3037`、`CJDOC3038`、`CJDOC3041` 一类文档质量 warning，以及一条 `CJDOC1019`；它们不影响退出码，本次退出码为 `0`。

读出实际收集到的模块和声明：

```bash
python3 - "$TASK_ROOT/site-default/docs.json" \
  "$TASK_ROOT/site-default/html/search-index.json" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
search = json.load(open(sys.argv[2], encoding="utf-8"))
print("status:", doc["status"])
print("modules:", [(m["role"], m["name"]) for m in doc["modules"]])
print("on pages:", sorted({e["name"] for e in search["entries"]
                          if e["kind"] != "concept"}))
print("in docs.json:", sorted({d["name"] for d in doc["declarations"]}))
print("unsupported:", [(u["name"], u["reason"]) for u in doc["unsupportedDeclarations"]])
PY
```

预期结果：

```text
status: partial
modules: [('workspace', 'app'), ('workspace', 'peer')]
on pages: ['peerApi']
in docs.json: ['hiddenApi', 'peerApi']
unsupported: [('featureApi', 'conditional compilation expression is unsupported or unresolved')]
```

这四个默认行为都能看到：

- 两个 workspace 成员都收集，`shared` 不收集——路径依赖需要显式开启。
- `hiddenApi` 在 `docs.json` 里但不在页面和搜索里——默认受众 `external` 只展示 `public` 与 `protected`。
- `featureApi` 缺席，因为它依赖没有给出的 `feature` 值，并被记进 `unsupportedDeclarations` 与 `CJDOC1019`。`status` 因此是 `partial`，生成本身没有失败。
- `docs.json` 是完整快照，不是按受众过滤后的清单；不要把整个目录当作已脱敏的导出发布。

## 第二步：加入路径依赖并给出条件编译值

`--include-path-dependencies` 把清单里的本地路径依赖一起扫描，`--cfg NAME=VALUE` 提供条件值：

```bash
cjdoc generate --project "$TASK_ROOT/workspace" \
  --format html --format json --output "$TASK_ROOT/site-extra" \
  --include-path-dependencies --cfg feature=extra
```

```bash
python3 - "$TASK_ROOT/site-extra/html/search-index.json" \
  "$TASK_ROOT/site-extra/docs.json" <<'PY'
import json
import sys

search = json.load(open(sys.argv[1], encoding="utf-8"))
doc = json.load(open(sys.argv[2], encoding="utf-8"))
print("search:", sorted({e["name"] for e in search["entries"]
                         if e["kind"] != "concept"}))
print("modules:", [(m["role"], m["name"]) for m in doc["modules"]])
print("status:", doc["status"])
PY
```

预期结果：

```text
search: ['featureApi', 'peerApi', 'sharedApi']
modules: [('workspace', 'app'), ('workspace', 'peer'), ('pathDependency', 'shared')]
status: complete
```

条件值换成别的，同一个条件 API 会被排除，workspace 成员和路径依赖都不受影响：

```bash
cjdoc generate --project "$TASK_ROOT/workspace" \
  --format json --output "$TASK_ROOT/site-basic" \
  --include-path-dependencies --cfg feature=basic
```

**预期结果**：`$TASK_ROOT/site-basic/docs.json` 里没有 `featureApi`，`status` 回到 `complete`。比较不同选择时始终换一个新的 `--output`，不要复用上一次的目录。

## 第三步：选择受众

`--audience` 只改变文档视图，不改变收集范围：

| 取值 | 展示的声明 | 用途 |
|---|---|---|
| `external` | `public`、`protected`（默认） | 对外发布的 API 站点 |
| `package` | 除 `private` 外 | 给同包维护者看的说明 |
| `all` | 全部声明 | 内部设计文档 |

```bash
cjdoc generate --project "$TASK_ROOT/workspace" \
  --format html --output "$TASK_ROOT/site-all" \
  --include-path-dependencies --cfg feature=extra --audience all

python3 - "$TASK_ROOT/site-all/html/search-index.json" <<'PY'
import json
import sys

entries = json.load(open(sys.argv[1], encoding="utf-8"))["entries"]
print("search:", sorted({e["name"] for e in entries}))
PY
```

**预期结果**：搜索索引此时包含 `hiddenApi`。改成 `--audience package` 时它仍不出现，因为它是 `private`。受众不是访问控制：三种取值下 `docs.json` 都保留全部已捕获声明，发布前自己确认输出目录里放了什么。

## 第四步：显式指定依赖源码

依赖源码不在自动发现的位置，或项目里有多个候选目录而这次只想选一个时，用 `--dependency-source NAME=PATH` 直接指向一个含 `cjpm.toml` 的 Cangjie 包：

```bash
cjdoc generate --project "$TASK_ROOT/workspace" \
  --format html --format json --output "$TASK_ROOT/site-external-source" \
  --dependency-source shared="$TASK_ROOT/workspace/shared"

python3 - "$TASK_ROOT/site-external-source/docs.json" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
print("modules:", [(m["role"], m["name"]) for m in doc["modules"]])
print("declarations:", sorted({d["name"] for d in doc["declarations"]}))
PY
```

**预期结果**：`shared` 的角色是 `externalDependency`，声明集合为 `hiddenApi`、`peerApi`、`sharedApi`（没有 `--cfg`，所以没有 `featureApi`）。

选项可以重复。`NAME` 只能由 ASCII 字母、数字、`_`、`-` 组成并用点分段，会成为该模块的逻辑前缀 `dependencies/<NAME>`；`PATH` 按 cjdoc 进程的当前工作目录解析，跨目录运行时用绝对路径。不要指向压缩包、二进制目录或不含 `cjpm.toml` 的目录。

## 第五步：读取 cjpm 已准备好的缓存依赖

Git 依赖和中心仓依赖的源码不在你的项目里，需要 cjpm 先取到本地缓存，再由 cjdoc 读取。缓存位置由 cjpm 的 `cangjie-repo.toml` 决定，不是 cjdoc 的选项：

```bash
CACHE_TASK_ROOT="$(mktemp -d "$HOME/.cache/cjdoc/examples/inputs.XXXXXX")"
CACHE_PROJECT="$CACHE_TASK_ROOT/cacheconsumer"
CACHE_ROOT="$CACHE_TASK_ROOT/cjpm-cache"
mkdir -p "$CACHE_PROJECT/src" "$CACHE_ROOT"

cat > "$CACHE_PROJECT/cjpm.toml" <<'EOF'
[package]
cjc-version = "1.2.0"
name = "cacheconsumer"
version = "0.1.0"
output-type = "static"

[dependencies]
yjson = { git = "https://github.com/lIlIIlIll/yjson.git", commitId = "54b4965dee0f0b96710cbc678ec5ec9a126b055c", output-type = "static" }
EOF

cat > "$CACHE_PROJECT/cangjie-repo.toml" <<EOF
[repository.cache]
  path = "$CACHE_ROOT"
EOF
```

这里第二个 heredoc 不加引号，`$CACHE_ROOT` 会展开为绝对路径。cjpm 读取 `cangjie-repo.toml` 的顺序是项目根、`$HOME/.cjpm`、SDK 的 `tools/config/`，取第一个有效文件；不配置时缓存根是 `$HOME/.cjpm`。

写一个调用该依赖的源文件，再让 cjpm 取回依赖并生成锁文件：

```bash
cat > "$CACHE_PROJECT/src/api.cj" <<'EOF'
package cacheconsumer

import yjson.*

/**
 * 解析一段 JSON 文本。
 *
 * @param text 一段完整的 JSON 文本，不能拼接多个文档。
 * @return 解析得到的 JSON 节点。
 */
public func parseValue(text: String): JsonNode {
    JsonNode.parse(text)
}
EOF

(cd "$CACHE_PROJECT" && cjpm build --jobs 1)
grep yjson "$CACHE_PROJECT/cjpm.lock"
```

**预期结果**：看到 `cjpm build success`，锁文件里记录 `yjson` 的 Git 地址与完整提交，源码位于 `$CACHE_ROOT/git/yjson/<提交>`。这一步只是准备输入：cjdoc 不会替你下载依赖。

现在让 cjdoc 读同一个缓存：

```bash
cjdoc generate --project "$CACHE_PROJECT" \
  --format json --output "$CACHE_TASK_ROOT/cached-dependency-output" \
  --include-cached-dependencies --cjpm-cache "$CACHE_ROOT"
```

`--include-cached-dependencies` 打开缓存依赖读取，`--cjpm-cache` 指定 cjpm 实际使用的缓存根；只写后者会以 `2` 退出并提示 `--cjpm-cache requires --include-cached-dependencies`。

```bash
python3 - "$CACHE_TASK_ROOT/cached-dependency-output/docs.json" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
print("status:", doc["status"])
print("modules:", [(m["role"], m["name"]) for m in doc["modules"]])
print("consumer:", sorted({d["name"] for d in doc["declarations"]
                           if d["packageName"] == "cacheconsumer"}))
print("skipped:", [d["message"] for d in doc["diagnostics"] if d["code"] == "CJDOC1021"])
PY
```

**预期结果**：有一个消费项目模块、一个角色为 `externalDependency` 的 `yjson` 模块，声明里有 `parseValue` 和 yjson 的类型。yjson 自己的锁文件还引用仅用于测试的 `yjson_macros`，缓存里没有它时会出现 `CJDOC1021`，并把 `status` 置为 `partial`；已读取的 yjson 源码仍然完整。

`--cjpm-cache` 与 `--cache-dir` 是两件事：前者是 cjpm 存放依赖源码的目录，后者是 cjdoc 解析源码时用的缓存（默认 `<项目>/target/cjdoc/cache/source-v11`，用 `--no-cache` 关闭）。不要让两者指向同一个目录。

## 第六步：用构建记录固定实际依赖选择

默认情况下 cjdoc 记录的是它自己观察到的依赖，状态为 `observed`。如果你有构建系统实际选中的依赖清单，可以用 `cjdoc.build-context/1` 记录把它标成 `verified`。仓库脚本根据目录里现成的源码与清单生成这份记录，不编译、不联网：

```bash
: "${CJDOC_SOURCE:?请设置为 cjdoc 源码目录}"
python3 "$CJDOC_SOURCE/scripts/capture_build_context.py" \
  --project "$TASK_ROOT/workspace" \
  --output "$TASK_ROOT/build-context.json" \
  --target linux_x86_64_cjnative \
  --cfg feature=extra
```

`--target` 是构建实际选中的目标，必须显式给出，不会从生成器 SDK 推断。把记录交给生成命令，并给出与记录一致的 `--cfg`：

```bash
cjdoc generate --project "$TASK_ROOT/workspace" \
  --format json --output "$TASK_ROOT/site-verified" \
  --cfg feature=extra --build-context "$TASK_ROOT/build-context.json"

python3 - "$TASK_ROOT/site-verified/docs.json" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
print("status:", doc["status"])
print("deps:", [(d["name"], d["state"], d["target"], d["cfg"])
                for d in doc["dependencies"] if d["kind"] == "source"])
PY
```

**预期结果**：`status: complete`，每个源码依赖的状态是 `verified`，并带上记录中的 `target` 与 `cfg`。记录里的 target 只有在它非空时才替换本次目标；给出的 `--cfg` 与记录不一致时，记录被忽略并报告 `CJDOC2300` 与 `CJDOC2301`，生成继续按观察到的依赖进行。

## 该打开哪个开关

| 目标 | 命令行选项 | `cjdoc.toml` 的 `[analysis]` 键 |
|---|---|---|
| 让路径依赖源码出现在站点里 | `--include-path-dependencies` | `include-path-dependencies` |
| 让 cjpm 已下载的 Git/中心仓依赖出现在站点里 | `--include-cached-dependencies`（配 `--cjpm-cache`） | `include-cached-dependencies`、`cjpm-cache` |
| 指定一个确切的依赖源码目录 | `--dependency-source NAME=PATH` | `dependency-sources` |
| 选中条件编译分支 | `--cfg NAME=VALUE` | `cfg` |
| 展示私有或全部声明 | `--audience package` 或 `--audience all` | `audience` |
| 用构建实际选择替换“观察到”的依赖 | `--build-context FILE` | 无；只能在 `generate` 或 `check` 的命令行指定 |

这些选项可以组合，但每个只负责一件事：受众不改收集范围，`--cfg` 不改依赖选择，缓存依赖和源码缓存使用不同的目录。

配置键的取值和合并规则见[配置参考](../reference/configuration.md)。

## 失败时怎么办

| 现象 | 原因 | 处理 |
|---|---|---|
| 生成成功，但页面比预期少声明 | 依赖类型没有对应的开关 | 路径依赖加 `--include-path-dependencies`，缓存依赖加 `--include-cached-dependencies`，指定目录用 `--dependency-source` |
| 带 `@When` 的声明消失，出现 `CJDOC1019` | 没有给出该条件名，或值与注解不一致 | 用 `--cfg NAME=VALUE` 给出完全一致的名字和值；`--cfg` 缺 `=` 会以 `2` 退出并提示 `--cfg requires NAME=VALUE` |
| `docs.json` 里出现私有声明 | 完整快照的既有行为 | 受众只筛选展示产物；发布前确认放进输出的文件 |
| warning `CJDOC1018: configured dependency source '...' is not accessible; skipped` | `--dependency-source` 的路径不存在或不可读 | 改为绝对路径后重试；相对路径以当前工作目录为基准 |
| warning `CJDOC1018: configured dependency source '...' must contain cjpm.toml; skipped` | 指定目录不是 Cangjie 包 | 指向含 `cjpm.toml` 的包根 |
| `error: dependency name must use non-empty ASCII alphanumeric, '_' or '-' dot-separated segments`，退出码 `2` | `NAME=PATH` 左侧含空格、`/` 等字符 | 用 ASCII 字母、数字、`_`、`-`，必要时用点分段 |
| 缓存依赖被跳过，出现 `CJDOC1021` | 缓存里没有该提交、`--cjpm-cache` 指向别的目录，或锁文件缺失 | 消息提到 `yjson_macros` 一类测试依赖可以忽略；否则回到消费项目重跑 `cjpm build --jobs 1`，确认 `cangjie-repo.toml` 的 `path` 与 `--cjpm-cache` 是同一目录 |
| `error: --cjpm-cache requires --include-cached-dependencies`，退出码 `2` | 只给了缓存根 | 两个选项一起给 |
| `error: --cjc, --chir-worker, and --chir-import-path require --semantic chir` | 语义选项没有配套开关 | 见[为声明补充类型和签名信息](chir.md) |
| 输出目录报冲突 | 目录已存在且不是本次生成的结果 | 换一个新的 `--output`，或按[管理生成产物](manage-outputs.md)处理 |
| 报告找不到项目根 | 当前目录没有 `cjpm.toml` | 用 `--project <项目根>` 指定，或先切换到项目根 |

## 下一步

- [配置输入与输出](../reference/configuration.md)：项目首页、包概述与多仓来源写进配置。
- [管理生成产物与缓存](manage-outputs.md)：重复生成、输出冲突与源码缓存位置。
- [比较两个版本的 API](compare-and-version.md)：为两份源码分别生成快照。
