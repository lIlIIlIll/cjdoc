# 按症状排查生成、检查与预览问题

按你在终端或页面上看到的现象找到对应条目，先做「先检查」，再按「处理」恢复。命令以[生成第一个站点](../tutorials/first-site.md)创建的 `docdemo` 为输入并从项目根运行；排查其它项目时把 `--project .` 换成那个项目根。

## 先记住退出码

| 退出码 | 含义 |
|---|---|
| `0` | 本次命令启用的规则都通过了 |
| `1` | 文档诊断、质量门槛、示例检查或 API 门槛失败；生成本身可能仍写出了产物 |
| `2` | 命令用法、配置或输入路径错误，通常没有可用的新产物 |

看到 `1` 时先读诊断，再看产物是否够用；看到 `2` 时先修命令或输入，不要重试同一条命令。

## 命令找不到或启动失败

**现象**：`cjdoc: command not found`；或启动时提示缺少仓颉运行库，例如 `error while loading shared libraries: libcangjie-std-ast.so: cannot open shared object file: No such file or directory`；或 `cjdoc: symbol lookup error: cjdoc: undefined symbol: …`。

**先检查**：命令来自哪里、版本是多少。

```bash
command -v cjdoc
cjdoc --version
cjc -v
cjpm -v
```

**原因**：`cjdoc` 不在 `PATH` 中；或当前终端没有加载与 cjdoc 同一套仓颉 SDK 环境（新终端不会继承之前的 `export`）。

**处理**：命令找不到时按[安装说明](../getting-started/install.md)把安装前缀加入 `PATH`。运行库或符号报错时，在同一终端重新加载仓颉 SDK 的 `envsetup.sh`，并用 `hash -r` 清掉 shell 的命令缓存。

**恢复后**：`command -v cjdoc` 输出安装目录中的绝对路径，`cjdoc --version` 输出当前版本号，`cjc -v` 与 `cjpm -v` 报告同一套 SDK 的 `1.2.0`。

## 生成报项目根错误

**现象**：生成时打印 `error[CJDOC1010]: project must contain cjpm.toml`，随后仍打印 `generated <目录>`，但退出码为 `1`。

**先检查**：当前目录，以及 `--project` 指向的位置。

```bash
pwd
test -f cjpm.toml && echo ok
```

**原因**：`--project` 指到了 `src/` 之类的子目录，或当前目录不是项目根。此时 cjdoc 仍会写出页面文件，但其中没有你项目的声明，所以「目录里有 HTML」不能说明收集成功。

**处理**：先 `cd` 到含 `cjpm.toml` 的目录，或显式传入项目根：

```bash
cjdoc generate --project /你的/项目根 --format html --output target/doc
```

**恢复后**：诊断里不再出现 `CJDOC1010`，站点导航和搜索里能找到你的声明。

## 页面里看不到某个声明

**现象**：生成成功，但站点导航和搜索里找不到你写的类型或函数。

**先检查**：声明的可见修饰符，以及是否在条件编译分支里。

**原因与处理**

| 原因 | 处理 |
|---|---|
| 声明是 `internal` 或 `private` | 默认 `--audience external` 只展示 `public` 和 `protected`。`package` 包含非私有声明；要查看私有声明用 `all` |
| 声明在条件编译分支里 | 按源码实际读取的条件传值，例如 `--cfg feature=enabled`。不要为了消除提示猜值 |
| 项目是 workspace | 确认成员目录里有自己的 `cjpm.toml`，且没有越过 workspace 根；成员被跳过时诊断会说明原因 |
| 依赖库的声明没出现 | 路径依赖要 `--include-path-dependencies`，缓存依赖要 `--include-cached-dependencies`，见[选择输入](select-inputs.md) |
| 诊断里仍有 `error` | 先修正诊断指向的源码位置，再重新生成 |

查看更宽的可见范围：

```bash
cjdoc generate --project . --format html --audience all \
  --output target/troubleshoot-all
```

**恢复后**：新输出目录的 `html/index.html` 中，包页和搜索结果能找到所选受众范围内的声明，签名与源码一致。

`docs.json` 会保留收集到的声明内容。`--audience` 只决定页面展示和比较范围，不是 JSON 隐私过滤器；发布前不要把含内部声明事实的快照交给不受信任的读者。

## 声明出现了但没有说明文字

**现象**：声明能搜索到、有独立页面，但摘要、参数或返回值是空的。

**原因**：公开声明即使完全没有注释也会出现在站点里，页面上只有签名。要让它有说明，注释必须是紧贴在声明前的 `/** … */` 文档注释；普通 `//` 或 `/* … */` 不会绑定。

**先检查**：当前 lint 报告了什么。

```bash
cjdoc check --project .
```

| 诊断码 | 含义 |
|---|---|
| `CJDOC3034` | 可见声明完全没有注释 |
| `CJDOC3004` | 参数没有 `@param` |
| `CJDOC3036` | 有摘要但没有详细说明 |
| `CJDOC3037` | 有返回值但缺少 `@return` |
| `CJDOC3038` | 缺少 `@example` |

**处理**：按报告逐项补齐注释，例如：

```cangjie
/**
 * 为名字生成问候语。
 *
 * @param name 要问候的名字，可以为空。
 * @return 格式为 `Hello, <name>!` 的字符串。
 */
public func greet(name: String): String {
    return "Hello, ${name}!"
}
```

**恢复后**：重新生成并刷新页面，摘要、参数和返回值都显示你写的内容；再次运行 `cjdoc check --project .` 时这些条目不再出现。

`[lint]` 表可以调整各规则的严重级别（`off`、`warning`、`error`），例如把 `missing-example = "off"`。`--lint-profile off` 会关闭 lint，参数覆盖率也可能下降；需要参数覆盖率时使用 `standard` 或 `strict`，见[检查文档质量](check-quality.md)。

## 修改源码后页面没更新

**现象**：编辑了 `src/api.cj` 或指南，重新运行命令后浏览器里还是旧内容。

**先检查**：浏览器打开的是不是本次输出目录中的文件，生成命令有没有实际重跑。

**处理**：生成到明确的新目录，再打开那里的页面：

```bash
cjdoc generate --project . --format html --no-cache \
  --output target/troubleshoot-fresh
xdg-open target/troubleshoot-fresh/html/index.html
```

正在使用 `serve` 时，保存文件后等服务终端再次打印生成结果，再手动刷新浏览器；预览不会自动刷新页面。终端显示重建失败时，服务继续提供上一次成功的站点，因此「页面能打开」不代表新修改已生效。

**恢复后**：新页面显示修改后的摘要和签名。`--no-cache` 只跳过这次源码扫描的缓存读写，用来排除旧缓存的影响。

## 输出写不进去或提示目录被锁定

**现象**：退出码 `2`，终端出现下列之一。

| 提示 | 原因 | 处理 |
|---|---|---|
| `output directory '<路径>' is locked by process <pid>` | 同一父目录下还有生成或预览在写 | 等它结束；预览在其终端按 `Ctrl+C`，然后重试 |
| `unable to verify output lock owner process <pid>; refusing unsafe recovery` | 旧锁的属主进程状态无法验证 | 不要删锁目录或改写 `owner.json`；换一个与旧输出、旧事务和缓存都不重叠的新父目录生成独立产物，见[输出仍被锁定时怎么办](manage-outputs.md#输出仍被锁定时怎么办) |
| `owned output artifact '<相对路径>' was modified; use --force-owned to replace it` | 登记过的产物被手工改动 | 换新输出目录，或确认可丢弃修改后加 `--force-owned` |
| `bounded read could not access file: '<目录>/.cjdoc-output.json'` | `--output` 指向已存在但不是 cjdoc 生成的目录 | 换一个尚不存在的目录；`--force-owned` 也不会接管它 |
| `output directory '…' and source cache directory '…' overlap` | 缓存落在输出根内或反之 | 把 `--cache-dir` 移到输出根之外 |

**恢复后**：命令以 `0` 结束并打印 `generated …`，新输出目录中的页面可打开。旧输出和旧锁保持原样，不会被这次操作修复或接管。

## 生成结果是 `partial`

**现象**：命令结束但提示生成结果不完整，或 `docs.json` 里 `status` 为 `partial`。

先确保本次输出里包含 JSON 快照，再读取状态字段：

```bash
cjdoc generate --project . --format json --output target/doc-ir-capture
python3 -c "import json;d=json.load(open('target/doc-ir-capture/docs.json'));print(d['status'], d['apiCollectionState'])"
```

`status` 取 `complete` 或 `partial`；`apiCollectionState` 独立取 `resolved`、`partial` 或 `unavailable`。两者可以不一致：API 完整收集时，可选高亮后端失败也会让 `status` 为 `partial`。`partial` 表示有一部分输入无法确定，不是所有结果都失效；先确认不完整部分是否影响你要做的覆盖率检查、基线比较或外部链接。

**处理**：按诊断来源处理。

| 诊断来源 | 处理 |
|---|---|
| `@When` 条件 | 确认应用需要的条件值后显式传入，例如 `--cfg feature=enabled` |
| workspace 成员（如 `CJDOC1010`） | 确认成员目录存在且含 `cjpm.toml`，再从 workspace 根重新生成 |
| 依赖源码 | cjdoc 不代你下载依赖；先准备好依赖，再按[选择输入与依赖](select-inputs.md)引入 |
| CHIR 语义补充 | 按 `CJDOC2101`–`CJDOC2106` 检查 worker 与编译器，见[CHIR 指南](chir.md) |
| 仍无法消除 | 保留 `partial` 结果，按[状态与限制参考](../reference/states-and-limits.md)判断它适合哪类用途 |

依赖 warning 不一定把结果标为 `partial`；例如缺失 path 依赖的 `CJDOC2302` 可以与 `complete` 并存，仍应单独处理。

**恢复后**：重新生成后诊断里不再有刚才处理的来源问题，`status` 与 `apiCollectionState` 符合你的输入条件。

## 示例检查失败

**现象**：加了 `--check-examples` 后退出码 `1`，诊断指向示例代码。

**先检查**：`cjc` 在当前 SDK 环境中可用，示例写在所属源码文件里，且片段只包含函数体内语句。

```bash
cjc -v
cjdoc check --project . --check-examples
```

**处理**：按诊断码处理。

| 诊断码 | 含义与处理 |
|---|---|
| `CJDOC3030` | 示例代码自身编译失败；检查 `@example` 中的代码和指令 |
| `CJDOC3031` | 失败来自所属源码上下文；也用于超过 256 个示例的上限；先让该文件能在当前输入中编译 |
| `CJDOC3032` | `@example` 中没有 `cangjie` 代码围栏（warning） |
| `CJDOC3033` | 指令语法、互斥关系或 `flags` 白名单错误 |
| `CJDOC3070` | 写了指令但没得到预期检查结果 |
| `CJDOC3071` | 示例程序以非零状态退出，消息中带 stderr |
| `CJDOC3072` | 实际 stdout 与 `output` 围栏不一致 |
| `CJDOC3073` | 单次运行超过 10 秒被终止 |
| `CJDOC3074` | 无法构建可执行文件或建立运行所需的内存限制 |
| `CJDOC3075` | stdout 或 stderr 超过 64 KiB |

示例代码只能是函数体内的片段，需要的 `import` 写在所属源码文件中。每个示例最多运行 10 秒，stdout 和 stderr 各 64 KiB，内存上限 2048 MiB，单次检查最多 256 个示例。完整步骤见[检查示例](check-examples.md)。

**恢复后**：`cjdoc check --project . --check-examples` 退出 `0`；带 `run` 的示例实际运行完成，有 `output` 围栏时其内容与实际输出一致。

## 质量门槛失败

**现象**：`cjdoc check` 打印 `error: global <指标> coverage <实际>% is below <门槛>%` 或 `error: package <包名> …`，退出码 `1`。

**原因**：`cjdoc.toml` 的 `[coverage]` 门槛高于当前报告值，或 CLI 临时门槛高于实际覆盖。

**处理**：先看失败指标的分母规则（`examples` 把没有注释的可见声明计入分母；`semanticLinks` 只算解析成功的链接；`parameters` 忽略 `_` 开头的参数），再补齐注释或调整阈值。键名拼错或阈值越界会以退出码 `2` 结束，提示 `unknown [coverage] setting '…'` 或 `coverage thresholds must be in 0..100`。

**恢复后**：`cjdoc check --project .` 退出 `0`。门禁设置与计数口径见[检查文档质量](check-quality.md)。

## `render` 或 API 比较拒绝输入

**现象**：`render` 报旧或未知的 Doc IR 版本；`diff` 报两份快照不一致。

**先检查**：快照是不是当前格式、是不是用相同选项从对应版本源码生成的。

```text
error: invalid Doc IR at $.schemaVersion: expected 'cjdoc.doc-ir/19'
error: API diff inputs must match project, audience, and cfgProfile
```

**处理**

- `render` 只接受当前 `cjdoc.doc-ir/19`。源码还在时用当前 cjdoc 重新 `generate --format json`；源码已不在时没有受支持的旧快照迁移路径。
- `diff` 要求两份快照的项目、受众和 cfgProfile 一致。用相同的 `--audience`、`--cfg` 从对应版本源码重新生成两份快照再比较。

**恢复后**：`render` 从保存的快照生成 HTML/Markdown；`diff` 输出只反映两份同源快照之间的真实差异。流程见[重渲染快照](render-snapshots.md)和[比较 API 并组合版本站点](compare-and-version.md)。

## 预览打不开或重建失败

**现象**：`cjdoc serve` 启动后浏览器无法访问；或保存文件后终端显示生成失败。

**先检查**：端口是否被占用，最近一次构建的状态是什么。

**处理**

| 现象 | 原因 | 处理 |
|---|---|---|
| `error: Failed to bind 98: Address already in use.` | 端口已被占用 | 换一个空闲端口，浏览器地址同步修改 |
| 终端已返回提示符且连接被拒绝 | 服务已退出（如 `--project` 不可用） | 修正 `--project` 后重启 |
| `serve: rebuild failed; keeping the last successful site` | 重建抛错，服务继续用上次成功站点 | 读终端 `error:` 行修正输入，保存触发重建或重启 |
| `serve: generated html with diagnostics` 且页面未变 | 本次构建有 error 级诊断 | 按终端诊断修正后再次保存 |
| `serve: output or cache location changed; restart serve` | 重建时解析出不同输出或缓存位置 | 停止并用新的 `--output`/`--cache-dir` 重启 |
| `status` 为 `error` | 最近一次构建失败 | 查看 `lastError` 与终端诊断，修正后等重建 |

换端口：

```bash
cjdoc serve --project . --port 8081
```

再读取状态：

```bash
curl -fsS http://127.0.0.1:8081/__cjdoc/status.json
```

`status` 为 `ok` 表示最近一次构建成功；为 `error` 时查看 `lastError`（通常是 `documentation build failed`）。之前已有成功站点时，服务会继续提供它。停止服务在运行它的终端按 `Ctrl+C`。

**恢复后**：`status` 回到 `ok`，刷新浏览器能看到最新内容。`builds`、`successfulBuilds` 等字段含义见 [CLI 的 serve 参考](../reference/cli.md#serve)。若是输出目录或锁冲突，先停止服务，按[管理输出](manage-outputs.md)处理。

## 命令报配置或选项错误

**现象**：退出码 `2`，提示未知选项、冲突选项或配置无法解析。

**先检查**：完整命令的拼写，以及 `cjdoc.toml` 中的键名。

```bash
cjdoc --help
cjdoc generate --help
```

`cjdoc --help` 列出全部命令；子命令帮助是静态文本，例如 `cjdoc generate --help`、`cjdoc versions compose --help`，它们不读项目配置，所以配置写错时也能查阅。未知命令加 `--help` 仍按未知命令处理，退出码 `2`。

常见冲突与提示：

| 提示 | 原因 |
|---|---|
| `error: --stdout and --output are mutually exclusive` | 同时要标准输出和目录输出 |
| `error: --stdout requires exactly one JSON-producing format` | 选了 HTML、Markdown 或多个格式 |
| `error: render requires --input` | `render` 缺输入快照 |
| `error: --project is not valid for render` （或其他选项） | 给 `render` 加了只适用于其他命令的选项 |
| `error: --doc-version requires --format html` | 加了版本标签但没有生成 HTML |
| `error: --cjpm-cache requires --include-cached-dependencies` | 只给了缓存目录 |
| `error: --format is not valid for check` （或 `--output`、`--stdout`） | `check` 不写站点或 JSON 产物 |
| `error: --force-owned is not valid for check` | `check` 不接受所有权选项 |
| `error: --jobs must be in 1..64` | 并行度越界 |
| `error: [highlight].mode must be static or off` | 高亮模式拼错 |
| `unknown [coverage] setting '…'` | 覆盖率键名拼错 |

若管道收到的内容不是完整 JSON，检查是否只选了一个 `json`、`api-surface`、`coverage` 或 `symbol-index` 格式。诊断始终写到标准错误，重定向时只保留标准输出才能得到单个 JSON 文档。

**处理**：按提示修正命令或配置。不要用关闭质量检查来绕过真实的输入错误。

**恢复后**：修改后的命令不再报用法错误，并按预期执行。完整选项、默认值和退出码见 [CLI 参考](../reference/cli.md)，配置键见[配置参考](../reference/configuration.md)。

## 下一步

- [检查文档质量](check-quality.md)：区分报告、lint 和发布门槛。
- [管理输出与缓存](manage-outputs.md)：重复生成、处理冲突和锁。
- [状态与限制参考](../reference/states-and-limits.md)：查找 `partial`、诊断码和能力边界。
