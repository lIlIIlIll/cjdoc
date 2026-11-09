# 按症状排查生成、检查与预览问题

按页面上看到的现象找到对应小节，先做里面的第一项检查，再执行恢复操作。命令以[首次生成教程](../tutorials/first-site.md)创建的 `docdemo` 为输入，并从项目根目录运行；如果你排查的是其它项目，把 `--project .` 换成那个项目根。

先记住退出码的含义，后面的小节会分别引用：

- `0`：本次命令启用的规则都通过了。
- `1`：文档诊断、质量门槛、示例检查或 API 门槛失败，生成本身可能仍然写出了产物。
- `2`：命令用法、配置或输入路径错误，通常没有可用的新产物。

## 命令找不到或启动报运行库错误

**现象**：`cjdoc: command not found`，或启动时提示缺少仓颉运行库。

**先检查**：命令来自哪个位置、版本是多少。

```bash
command -v cjdoc
cjdoc --version
cjc -v
cjpm -v
```

**操作**：命令找不到时，按[安装说明](../getting-started/install.md)把安装前缀加入 PATH；运行库报错时，在同一终端重新加载仓颉 SDK 的 `envsetup.sh`。新开的终端不会继承之前的 `export`，需要重新执行。

**恢复后**：`command -v cjdoc` 输出安装目录中的绝对路径，`cjdoc --version` 输出当前版本，`cjc -v` 和 `cjpm -v` 报告同一套 SDK 的 1.2.0。

## 页面里看不到某个声明

**现象**：生成成功，但站点导航和搜索里找不到你写的类型或函数。这通常不是注释写法的问题。

**先检查**：`--project` 是否指向真正的项目根，声明是否在默认可见范围内。

```bash
test -f cjpm.toml
cjdoc generate --project . --format html --output target/troubleshoot-visible
```

`--project` 必须是含 `cjpm.toml` 的目录。把它指到 `src/` 之类的子目录时，会报告 `CJDOC1010`（如 `project must contain cjpm.toml`）并以 `1` 退出；此时仍会写出一个 `partial` 的空站点，所以“目录里有 HTML”不能说明收集成功。

**操作**：按现象选择一种：

- 声明是 `internal` 或 `private`：默认 `--audience external` 只展示 `public` 和 `protected`。`package` 包含非私有声明；要查看私有声明，使用 `all`：

  ```bash
  cjdoc generate --project . --format html --audience all \
    --output target/troubleshoot-all
  ```

- 声明在条件编译分支里：按源码实际读取的条件传入值，例如 `--cfg feature=enabled`。不要为了消除提示猜值。
- 项目是 workspace：确认成员目录里有自己的 `cjpm.toml`，且没有越过 workspace 根。成员被跳过时诊断会说明原因。
- 上面都正常，但诊断里仍有 `error`：先修正诊断指向的源码位置，再重新生成。

**恢复后**：在本次输出目录的 `html/index.html` 中，包页和搜索结果能找到所选受众范围内的声明，签名与源码一致。

需要留意：`docs.json` 会保留收集到的声明内容。`--audience` 只决定页面展示和比较范围，不是 JSON 隐私过滤器；发布前不要把含内部声明事实的快照交给不受信任的读者。

## 声明出现了，但没有说明文字

**现象**：声明在站点里能搜索到，也有独立页面，但摘要、参数或返回值是空的。

公开声明即使完全没有注释，仍然会出现在站点里，页面上只有签名。要让它有说明，注释必须是紧贴在声明前的 `/** ... */` 文档注释；普通 `//` 或 `/* ... */` 不会绑定。

**先检查**：当前 lint 报告了什么。

```bash
cjdoc check --project .
```

标注为 `missing-symbol-doc`（`CJDOC3034`）表示可见声明完全没有注释；`missing-summary`、`missing-param`、`missing-return` 表示注释存在但对应字段为空。

**操作**：按报告逐项补齐注释，例如：

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

**恢复后**：重新生成并刷新页面，摘要、参数和返回值都显示你写的内容；再次运行 `cjdoc check --project .` 时这些条目不再出现在报告里。

`[lint]` 表可以调整各规则的严重级别（`off`、`warning`、`error`），例如把 `missing-example = "off"`。`--lint-profile off` 会关闭 lint，参数覆盖率也可能下降，即使页面仍显示 `@param` 说明。需要参数覆盖率时使用 `standard` 或 `strict`，详见[检查文档质量](check-quality.md)。

## 修改源码后页面没更新

**现象**：编辑了 `src/api.cj` 或指南，重新运行命令后浏览器里还是旧内容。

**先检查**：浏览器打开的是不是本次输出目录中的文件，生成命令有没有实际重跑。

**操作**：生成到明确的新目录，再打开那里的页面：

```bash
cjdoc generate --project . --format html --no-cache \
  --output target/troubleshoot-fresh
xdg-open target/troubleshoot-fresh/html/index.html
```

如果正在使用 `serve`，保存文件后等服务终端再次显示生成成功，再刷新浏览器；预览不会自动刷新页面。若终端显示重建失败，服务会继续提供上一次成功的站点，因此“页面能打开”不代表新修改已经生效。

**恢复后**：新页面显示修改后的摘要和签名。`--no-cache` 只跳过这次源码扫描的缓存读写，用来排除旧缓存的影响。

## 输出写不进去或提示目录被锁定

**现象**：退出码 `2`，提示 `output directory ... is locked by process ...`、`unable to verify output lock owner process ...`，或指出某个已登记文件被手工修改、输出目录与缓存重叠。

**先检查**：是否有仍在前台运行的生成或预览；`--output` 与 `--cache-dir` 是否落在彼此的目录里。

**操作**：

- 有生成或预览在运行：等它结束；预览在其终端按 `Ctrl+C`，然后重试。
- 已登记文件被手工修改：换一个新输出目录，或在确认不需要那些修改后加 `--force-owned`。
- 输出与缓存重叠：把 `--cache-dir` 移到输出根之外。
- 锁的所有者无法确认：不要删除锁目录或改写 `owner.json`，改用与旧输出、旧事务和缓存都不重叠的新父目录生成一份独立产物，步骤见[输出仍被锁定时怎么办](manage-outputs.md#输出仍被锁定时怎么办)。

**恢复后**：命令以 `0` 结束并打印 `generated ...`，新输出目录中的页面可打开。旧输出和旧锁保持原样，不会被这次操作修复或接管。

## 生成结果是 `partial`

**现象**：命令结束但提示生成结果不完整，或 `docs.json` 里 `status` 为 `partial`。

**先检查**：诊断指向哪些输入，以及 `apiCollectionState` 的值。

`partial` 表示有一部分输入无法确定，不是所有结果都失效。先确认不完整部分是否影响你要执行的覆盖率检查、基线比较或外部链接，不要直接把它当作完整快照。

**操作**：按诊断来源处理：

- 指向 `@When` 条件：确认应用需要的条件值后显式传入，例如 `--cfg feature=enabled`：

  ```bash
  cjdoc generate --project . --format html --cfg feature=enabled \
    --output target/troubleshoot-cfg
  ```

- 指向依赖源码：cjdoc 不会替你下载依赖。先在项目里准备好依赖，再按[选择输入与依赖](select-inputs.md)用 path、cjpm 缓存或显式源码引入。
- 仍无法消除：保留 `partial` 结果，按[状态与限制参考](../reference/states-and-limits.md)判断它适合哪类用途。

**恢复后**：重新生成，确认诊断中不再有刚才处理的来源问题，再查看 `status` 与 `apiCollectionState`。仍有其它不完整项时，继续按其诊断处理，不要只凭网页可打开就忽略它们。

## 示例检查失败

**现象**：加了 `--check-examples` 后退出码 `1`，诊断指向示例代码。

**先检查**：`cjc` 在当前 SDK 环境中可用，示例写在所属源码文件里。

```bash
cjc -v
cjdoc check --project . --check-examples
```

**操作**：按诊断码处理：

| 诊断码 | 含义与处理 |
|---|---|
| `CJDOC3030` | 示例代码自身编译失败；检查 `@example` 中的代码和指令。 |
| `CJDOC3031` | 失败来自示例所属源码上下文；先让那个文件能在当前输入中解析、编译。 |
| `CJDOC3033` | 指令语法、互斥关系或 `flags` 白名单错误。 |
| `CJDOC3072` | 实际 stdout 与示例的 `output` 围栏不一致。 |
| `CJDOC3074` | 当前环境无法建立运行所需的静态链接或内存限制能力。 |

示例代码只能是函数体内的片段，需要的 `import` 写在所属源码文件中。每个示例最多运行 10 秒，stdout 和 stderr 各 64 KiB，内存上限 2048 MiB，单次检查最多 256 个示例；超出限制时检查会失败。完整步骤见[检查示例](check-examples.md)。

**恢复后**：`cjdoc check --project . --check-examples` 退出 `0`，所选示例的编译约定通过。带 `run` 的示例还实际运行完成；有 `output` 围栏时，其内容与实际输出一致。

## `render` 或 API 比较拒绝输入

**现象**：`render` 报旧或未知的 Doc IR 版本；`diff` 报两份快照的 project、audience 或 cfgProfile 不一致。

**先检查**：输入快照是不是当前格式、是不是用相同选项从对应版本源码生成的。

**操作**：

- `render` 只接受当前 `cjdoc.doc-ir/18`。原始源码还在时，用当前 cjdoc 重新执行 `generate --format json`；没有源码时，没有受支持的旧快照迁移路径。
- `diff` 要求两份快照的项目、audience 和 cfgProfile 一致。用相同的 `--audience`、`--cfg` 从对应版本的源码重新生成两份快照再比较。

**恢复后**：`render` 从保存的快照生成 HTML/Markdown；`diff` 输出只反映两份同源快照之间的真实差异。流程见[重渲染快照](render-snapshots.md)和[比较 API 并组合版本站点](compare-and-version.md)。

## 预览打不开或重建失败

**现象**：`cjdoc serve` 启动后浏览器无法访问；或保存文件后终端显示生成失败。

**先检查**：端口是否被占用，最近一次构建的状态是什么。

**操作**：端口冲突时换一个空闲端口，并让浏览器地址使用同一端口：

```bash
cjdoc serve --project . --port 8081
```

访问 `http://127.0.0.1:8081/__cjdoc/status.json`。`status` 为 `ok` 表示最近一次构建成功；为 `error` 时查看 `lastError`，修正对应的源码、指南或配置后等待重建。之前已有成功站点时，服务会继续提供它。停止服务在运行它的终端按 `Ctrl+C`。

**恢复后**：`status` 回到 `ok`，刷新浏览器能看到最新内容。`builds`、`successfulBuilds` 等字段的含义见 [CLI 的 serve 参考](../reference/cli.md#serve)。若是输出目录或锁冲突，先停止服务，按[管理输出](manage-outputs.md)处理。

## 命令报配置或选项错误

**现象**：退出码 `2`，提示未知选项、冲突选项或配置无法解析。

**先检查**：完整命令与 `cjdoc.toml` 中的拼写。

```bash
cjdoc --help
```

`cjdoc --help` 只提供顶层帮助，子命令没有独立帮助。常见冲突包括：`--stdout` 不能与 `--output` 同用、`render` 必须给 `--input`、`--doc-version` 必须同时生成 HTML、`--cjpm-cache` 必须与 `--include-cached-dependencies` 一起使用、`check` 不接受输出和 `--force-owned` 选项。

若管道收到的内容不是完整 JSON，检查是否只选了一个 `json`、`api-surface`、`coverage` 或 `symbol-index` 格式；`--stdout` 不接受 HTML、Markdown 或多个格式。诊断始终写到标准错误，重定向时只保留标准输出才能得到单个 JSON 文档。

**操作**：按提示修正命令或配置。不要用关闭质量检查来绕过真实的输入错误。

**恢复后**：修改后的命令不再报用法错误，并按预期执行。完整选项、默认值和退出码见[CLI 参考](../reference/cli.md)，配置键见[配置参考](../reference/configuration.md)。

## 下一步

- [检查文档质量](check-quality.md)：区分报告、lint 和发布门槛。
- [管理输出与缓存](manage-outputs.md)：重复生成、处理冲突和锁。
- [状态与限制参考](../reference/states-and-limits.md)：查找 `partial`、诊断码和能力边界。
