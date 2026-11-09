# 选择要生成文档的源码与依赖

本页用一个本地 workspace 依次演示：cjdoc 默认发现哪些源码、怎样加入路径依赖、怎样声明条件编译值、怎样显式指定依赖源码，以及怎样读取 cjpm 已经准备好的依赖缓存。每步生成到独立输出目录，你可以在页面和 `docs.json` 里看到声明范围的差别。

## 前提

- 已按[安装 cjdoc](../getting-started/install.md)安装 `cjdoc`，并在当前终端加载仓颉 SDK 1.2.0 环境，`cjc` 和 `cjpm` 都可用。
- 使用 Bash 和 Python 3；Python 用于显示生成文件中的字段。
- 最后一节会运行 `cjpm build`，需要网络取回其中固定的 Git 依赖；前面几节只读本地源码，不需要网络。

本页只在 `$HOME/.cache/cjdoc/examples` 下创建自己的练习目录，不读取 cjdoc 源码，也不修改你已有的项目。先建好练习根目录：

```bash
mkdir -p "$HOME/.cache/cjdoc/examples"
```

`$HOME/.cache` 要位于磁盘文件系统。下面每节各自创建需要的目录和变量，每个变量在本页只定义一次，之后一直沿用同一个值。

## 准备 workspace 与路径依赖

这个 workspace 有两个成员 `app`、`peer`；`shared` 是 `app` 的路径依赖，但不是 workspace 成员。两类输入因此可以分别观察。先创建目录和变量：

```bash
TASK_ROOT="$(mktemp -d "$HOME/.cache/cjdoc/examples/inputs.XXXXXX")"
mkdir -p "$TASK_ROOT/workspace/packages/app/src" \
  "$TASK_ROOT/workspace/packages/peer/src" \
  "$TASK_ROOT/workspace/shared/src"
```

`TASK_ROOT` 是本次练习的私用根目录，下面所有 workspace 相关命令都用这个值。

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

这些文件组成一个完整的本地 workspace。生成文档不需要先编译它：cjdoc 直接读 `cjpm.toml` 和源码。

## 先看默认发现范围

不带任何依赖选项生成一次，看 cjdoc 自己会走多远：

```bash
cjdoc generate --project "$TASK_ROOT/workspace" \
  --format html --format json --output "$TASK_ROOT/site-default"
```

读出这次实际采集到的模块、页面上的声明和快照里的全部声明：

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

应看到两个 `workspace` 成员模块 `app` 和 `peer`。页面上只有 `peerApi`；`hiddenApi` 不在页面和搜索里，因为默认受众 `external` 只显示 `public` 和 `protected` 声明。`sharedApi` 缺席，因为路径依赖默认不包含。`featureApi` 也不在：这次没有提供 `feature` 值，cjdoc 不猜编译器设置，未定义的条件会让该声明被省略、记进 `unsupportedDeclarations`，并记录 `CJDOC1019`。因此这次结果的 `status` 是 `partial`，不是生成失败——已发现的声明照常输出，只是范围不完整。`docs.json` 仍会保留 `hiddenApi`，它是完整快照而不是受众过滤后的清单；诊断里还会出现空摘要、缺示例之类的文档警告，它们同样不影响本次选择范围。

## 加入路径依赖并声明条件编译

`app` 在 `cjpm.toml` 的 `[dependencies]` 中声明了 `shared`。用 `--include-path-dependencies` 把这些本地路径依赖一起扫描，并用 `--cfg` 显式给出条件编译值：

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
print("all declarations:", sorted({d["name"] for d in doc["declarations"]}))
PY
```

搜索索引里应是 `featureApi`、`peerApi`、`sharedApi`，没有 `hiddenApi`；模块列表多出一个角色为 `pathDependency` 的 `shared`。`docs.json` 则列出全部已采集声明，包括 `hiddenApi`——它是完整快照，不是按受众过滤后的 API 清单，不要把它当作已经脱敏的导出发布。

把受众放宽到 `all`，私有声明也会进入页面和搜索：

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

这次搜索索引里应出现 `hiddenApi`。`--audience package` 显示除 `private` 之外的声明，`--audience all` 显示全部；三者只改变文档视图。

条件值换成别的，同一个条件 API 会被排除，workspace 成员和路径依赖都不受影响：

```bash
cjdoc generate --project "$TASK_ROOT/workspace" \
  --format json --output "$TASK_ROOT/site-basic" \
  --include-path-dependencies --cfg feature=basic
```

`$TASK_ROOT/site-basic/docs.json` 中没有 `featureApi`。比较不同选择时使用不同输出目录，不要复用上一次的目录。

## 显式加入依赖源码

依赖源码不在自动发现的位置时，用 `--dependency-source NAME=PATH` 直接指定一个本地 Cangjie 包。左侧名字会成为该模块的逻辑前缀 `dependencies/<名字>`，目录里必须有它自己的 `cjpm.toml`。项目有多个候选依赖目录、而这次只想选其中一个时，也可以用它。

```bash
cjdoc generate --project "$TASK_ROOT/workspace" \
  --format html --format json --output "$TASK_ROOT/site-external-source" \
  --dependency-source shared="$TASK_ROOT/workspace/shared"
```

```bash
python3 - "$TASK_ROOT/site-external-source/docs.json" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
print("modules:", [(m["role"], m["name"]) for m in doc["modules"]])
print("declarations:", sorted({d["name"] for d in doc["declarations"]}))
PY
```

`shared` 的角色应为 `externalDependency`，声明里包含 `sharedApi`。`--dependency-source` 可以重复；路径按 cjdoc 进程的当前工作目录解析，本例使用绝对路径以免受运行目录影响。不要指向压缩包、二进制目录或没有 `cjpm.toml` 的目录：名称不安全时报告 `CJDOC1018`，路径不可访问、缺清单或与已有模块身份冲突时同样跳过并说明原因。

## 读取 cjpm 已准备好的缓存依赖

依赖来自 Git 或中心仓时，源码不在你的项目里，需要 cjpm 先把它取到本地缓存，再由 cjdoc 读取。这一节新建一个独立消费项目，它固定依赖 `yjson`，并把依赖缓存放在练习目录内，练习结束后可以整目录删除。

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
```

`commitId` 写的是完整提交，`cjpm` 会把它记进 `cjpm.lock`，`cjdoc` 再按锁文件去缓存里找同一个提交，因此两边看到的依赖版本一致。

缓存位置由 cjpm 自己的配置文件决定，不是 cjdoc 的选项。在项目根放一个与 `cjpm.toml` 同级的 `cangjie-repo.toml`：

```bash
cat > "$CACHE_PROJECT/cangjie-repo.toml" <<EOF
[repository.cache]
  path = "$CACHE_ROOT"
EOF
```

这里的 heredoc 不加引号，`$CACHE_ROOT` 会展开成上面的绝对路径。cjpm 读取 `cangjie-repo.toml` 的顺序是：项目根、`$HOME/.cjpm`、SDK 的 `tools/config/`，找到第一个有效文件后忽略其余；不配置时缓存根是 `$HOME/.cjpm`。旧的 `CJPM_CONFIG` 环境变量会被废弃，不要再用来指定练习缓存。

取回依赖并生成锁文件：

```bash
(cd "$CACHE_PROJECT" && cjpm build --jobs 1)
grep yjson "$CACHE_PROJECT/cjpm.lock"
```

`cjpm build success` 之后，锁文件里记录了 `yjson` 的 Git 地址与完整提交，源码位于 `$CACHE_ROOT/git/yjson/<提交>`，其中带有 yjson 自己的 `cjpm.toml`。这一步只是准备输入；cjdoc 不会替你下载依赖。

现在生成消费方文档，并让 cjdoc 读同一个缓存：

```bash
cjHeapSize=512MB cjdoc generate --project "$CACHE_PROJECT" \
  --format json --output "$CACHE_TASK_ROOT/cached-dependency-output" \
  --include-cached-dependencies --cjpm-cache "$CACHE_ROOT"
```

`--include-cached-dependencies` 打开缓存依赖读取，`--cjpm-cache` 显式指定 cjpm 实际使用的缓存根。只给后者会以用法错误退出，并提示它需要 `--include-cached-dependencies`。`cjHeapSize=512MB` 是本例的仓颉运行时堆设置，不会改变 cjdoc 的资源预算。

查看采集结果：

```bash
python3 - "$CACHE_TASK_ROOT/cached-dependency-output/docs.json" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
print("status:", doc["status"])
print("modules:", [(m["role"], m["name"]) for m in doc["modules"]])
print("consumer:", [d["name"] for d in doc["declarations"]
                    if d["packageName"] == "cacheconsumer"])
yjson = sorted({d["name"] for d in doc["declarations"] if d["packageName"] == "yjson"})
print("yjson declarations:", len(yjson))
print("sample:", yjson[:5])
print("skipped:", [d["message"] for d in doc["diagnostics"] if d["code"] == "CJDOC1021"])
PY
```

应看到消费项目模块和一个角色为 `externalDependency` 的 `yjson` 模块，并能在声明中找到自己的 `parseValue` 和 yjson 的类型。yjson 自己的锁文件还声明了仅用于测试的 `yjson_macros`；缓存里缺少它时会出现 `CJDOC1021`，结果可为 `partial`。这不影响已读取的 yjson 库源码，但仍应阅读其它诊断，确认没有漏掉你实际需要的依赖。

`skipped` 里出现的 `CJDOC1021` 按消息区分两种情况：

- 消息提到 `yjson_macros`：就是上面的测试依赖，可以忽略。
- 消息提到 `yjson` 或所选缓存根不可访问：缓存里没有该提交，或者 `--cjpm-cache` 指向了别的目录。回到消费项目重跑 `cjpm build --jobs 1`，再确认 `cangjie-repo.toml` 的 `path` 与 `--cjpm-cache` 是同一个目录。

cjdoc 只读缓存，不会替你补下载；缺失时它跳过该依赖并给出 `CJDOC1021`，生成仍然产出一份不含该依赖的结果。

`--cjpm-cache` 与 `--cache-dir` 是两件事：前者是 cjpm 存放依赖源码的目录，后者是 cjdoc 自己解析源码时用的缓存，默认位于项目的 `target/cjdoc/cache/source-v11`，用 `--no-cache` 可以关闭。两者不要指向同一个目录。cjpm 侧的配置格式与优先级见 [STS 1.2.0 cjpm 手册的项目管理配置文件说明](https://cj-docs.gitcode.com/zh/1.2.0/tools/source_zh_cn/cmd-tools/cjpm_manual.html#项目管理配置文件说明)。

## 遇到问题怎么办

- 生成成功但页面少声明：先看 `docs.json` 的 `modules` 和 `diagnostics`。路径依赖需要 `--include-path-dependencies`，缓存依赖需要 `--include-cached-dependencies`，显式源码需要 `--dependency-source`。
- 声明带了 `@When` 却消失：核对 `--cfg` 的名字和值是否与注解完全一致。未提供的条件名会让声明被省略并记录 `CJDOC1019`，生成本身不失败。
- `docs.json` 里出现私有声明：这是完整快照的行为，受众只筛选 HTML、搜索和覆盖率等展示产物。发布前请确认放进输出的文件。
- 缓存依赖被跳过：按上节区分 `yjson_macros` 与 `yjson` 两类 `CJDOC1021`；缺缓存时先运行 `cjpm build`，不要手工创建空缓存目录。
- 输出目录报冲突：换一个新的 `--output`，或按[管理生成产物](manage-outputs.md)处理已存在的目录。
- 报告项目根错误：用 `pwd` 确认当前目录含 `cjpm.toml`，或从任意目录传入 `--project <项目根>`。

## 下一步

- [配置输入与输出](../reference/configuration.md)：把项目首页、包概述和多仓来源写进配置。
- [管理生成产物与缓存](manage-outputs.md)：重复生成、输出冲突与源码缓存位置。
- [生成与发布文档](generate-and-publish.md)：一次生成多种格式并发布完整站点。
