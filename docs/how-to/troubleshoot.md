# 排查生成、检查与预览故障

按命令退出码和诊断来源定位失败，再只重跑受影响的步骤。以下命令以[首次生成教程](../tutorials/first-site.md)创建的 `docdemo` 为输入，并从项目根目录运行。

## 先确认执行环境和输入目录

```bash
cjdoc --version
cjc -v
cjpm -v
test -f cjpm.toml
test -f src/api.cj
```

`cjdoc --version` 应报告当前安装版本；`cjc` 和 `cjpm` 应来自与 cjdoc 当前源码要求匹配、且已在此终端激活的 Cangjie SDK。若命令找不到或启动时报仓颉运行库错误，按[安装说明](../getting-started/install.md)修复 PATH/SDK 环境，然后在同一终端重新检查。不要假设新开终端仍继承之前 shell 中的环境变量。

CLI 参数或配置错误返回 `2`；文档诊断、质量门槛或示例检查失败通常返回 `1`；返回 `0` 表示本次命令所启用的规则允许继续，不代表作者说明已由语义审计证明。

## 项目根目录或声明不可见

`--project` 应指向含 `cjpm.toml` 的目录。默认 audience 是 `external`，主要显示 `public` 和 `protected` API；源码注释必须使用 `/** ... */` 并紧贴声明。先检查入口文件和声明可见性：

```bash
test -f cjpm.toml
cjdoc generate --project . --format html --output target/troubleshoot-html
```

若仍看不到声明，检查 `src/api.cj` 中是否为 public/protected，以及使用的是文档注释而非普通 `//` 或 `/* ... */`。查看内部声明时可显式使用 `--audience package` 或 `--audience all`，但 `docs.json` 会保留收集到的声明内容，不能把 audience 当作 JSON 隐私过滤器。受众范围见[产物参考](../reference/artifacts.md)。

例如误把 `src/` 传给 `--project`，可能报告 `CJDOC1010`、退出 `1`，但仍写出一个 `partial` 的空站点；“目录里有 HTML”不代表项目已成功收集。先核对退出码、诊断及项目清单，再从正确的项目根生成到新的输出目录，不要把空页当作公开 API 确实为空的证明。

## 修改后页面没更新或输出报冲突

先重新生成到明确的输出根，并确认浏览器打开同一目录中的 HTML。源码变化未反映时可关闭源码缓存重试：

```bash
cjdoc generate --project . --format html --no-cache --output target/troubleshoot-fresh
```

若输出路径冲突，检查它是否曾被手工修改或是否含未知文件。不要手动清理所有权清单；选择新的、尚不存在的 `target/` 子目录。仅在检查过 cjdoc 管理内容并明确接受覆盖手工修改后，才用 `--force-owned`。输出与源码缓存目录不能互相嵌套；详见[管理输出与缓存](manage-outputs.md)。

锁冲突与所有权冲突不同：共享同一父目录的输出根会互相串行保护。若出现 `unable to verify output lock owner process ...; refusing unsafe recovery`，即使外部已确认旧 PID 消失，生成器仍可能无法安全回收旧锁。此时换一个同父目录的 `target/` 子目录或加 `--force-owned` 都不能保证解除阻塞；保留旧状态，按[输出仍被锁定时](manage-outputs.md#输出仍被锁定时)在独立、互不重叠的父目录生成新产物。不要手工删除锁来绕过不确定状态。

## `partial` 状态、依赖或条件编译诊断

`partial` 表示输入中有一部分无法确定，不是所有结果都失效。先查看诊断中的源码位置；若它指向 `@When` 条件，确认应用需要的条件值后显式传入 `--cfg NAME=VALUE`。若依赖源码未纳入，cjdoc 不会替项目下载依赖；先在项目里准备真实依赖，再按[选择输入与依赖](select-inputs.md)选择 path/cache/显式源码输入。

```bash
cjdoc generate --project . --format html --cfg feature=enabled \
  --output target/troubleshoot-cfg
```

只在源码实际读取 `feature` 条件且目标构建要求该值时使用该参数；不要为了消除 warning 随意猜值。条件表达式、依赖或来源证据不完整时，保留 `partial` 结果并按[状态与限制参考](../reference/states-and-limits.md)解释边界。

## 检查示例失败

示例默认不编译、不运行。显式启用检查并核对 `cjc` 在当前 SDK 环境中可用：

```bash
cjc -v
cjdoc check --project . --check-examples
```

- `CJDOC3030`：编译器错误归因到示例代码，检查 `@example` 代码、导入和指令。
- `CJDOC3031`：失败发生在示例所属源码上下文而非示例文件，先让该项目输入能够被解析/编译。
- `CJDOC3033`：示例指令语法、互斥关系或 `flags` 白名单错误。
- `CJDOC3072`：实际 stdout 与 `output` 围栏不同。
- `CJDOC3074`：当前环境无法建立运行所需的静态链接/内存限制能力。

示例代码只能是可放在函数体中的片段；所需 `import` 写在所属源码文件中。逐步操作见[检查示例](check-examples.md)。

## 修复 `render` 或 API diff 输入

`render` 只接受当前 `cjdoc.doc-ir/18` 的 `docs.json`，不会迁移旧 wire。若它报告旧/未知格式，而原始源码仍在，用当前 cjdoc 重新 `generate --format json`；没有源码时不存在受支持的旧快照迁移路径。离线渲染步骤见[重渲染快照](render-snapshots.md)。

API `diff` 要求两份快照的 project、audience 和 cfgProfile 一致。用相同的 `--audience`、`--cfg` 从对应版本源码重新生成，然后比较；不能把缺失输入或不同身份的快照强行作为基线。真实双源码流程见[比较 API 并组合版本站点](compare-and-version.md)。

## 预览服务无法启动或重建失败

`serve` 默认监听 `127.0.0.1:8080`。若端口已被占用，选一个空闲端口并在浏览器地址中使用同一端口：

```bash
cjdoc serve --project . --port 8081
```

另开终端访问 `http://127.0.0.1:8081/__cjdoc/status.json`。`status: error` 表示最近一次重建失败；如之前已有成功站点，服务会继续提供它。检查该服务终端中的最新诊断，修正源码或 `cjdoc.toml` 后等待监视器重建。停止服务时在服务终端按 `Ctrl+C`。完整状态字段和失败保留检查见[本地预览](preview.md)。

## 配置或选项错误

配置解析错误、未知选项、冲突选项和不支持的 schema 输入应先按 CLI 错误处理，不要用关闭质量检查来绕过：

```bash
cjdoc --help
```

cjdoc 提供顶层帮助，不提供独立子命令帮助。常见互斥条件包括 `--stdout` 与 `--output` 不能同时用、`render` 需要 `--input`、`--doc-version` 需要 HTML 格式。完整适用命令、默认值和退出码见[CLI 参考](../reference/cli.md)；配置键见[配置参考](../reference/configuration.md)。

## 下一步

- [检查文档质量](check-quality.md)：区分报告、lint 和发布门槛。
- [复核 API 契约](review-contracts.md)：核对作者说明和实际消费者行为。
- [状态与限制参考](../reference/states-and-limits.md)：查找 `partial`、错误和能力边界。
