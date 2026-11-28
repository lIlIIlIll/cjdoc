# 构建与本地验收

面向修改 cjdoc 源码的维护者。使用者从[当前源码安装](../getting-started/install.md)开始，保证工具和手册属于同一提交；发行包替代入口按自身清单的 sourceCommit 阅读同版本手册。

以下命令以 POSIX shell 为例；Windows 请在 Git Bash 中运行，`python3` 视环境换成 `python`。

## 工具链

- **Cangjie 1.2.0 STS** 的 `cjc`/`cjpm`，以及与编译器匹配的 **`stdx` release/1.2 sidecar**。`cjpm.toml` 使用固定 `commitId` 的 Git 依赖（`markdown`、`yjson`）和 `vendor/yjson_algorithms` path 依赖；`cjpm.lock` 必须与清单一致。
- CI 使用 [`Zxilly/setup-cangjie`](https://github.com/Zxilly/setup-cangjie) 的 `sts` channel + `stdx` component（workflow 中 `cjv-version: v0.3.2`），压缩包由 `cangjie-version-manifest` 提供 SHA-256 校验。手工准备同一套工具链可用 `cjv install sts-1.2.0 --component stdx`。
- 根 `cjpm.toml` 的 `link-option` 与 `bin-dependencies.path-option` 引用环境变量 `${CJDOC_STDX_LINK_OPTIONS}` 和 `${CANGJIE_STDX_PATH}`；没有经过 `scripts/with_stdx.py` 认证并导出这些变量时，构建不会链接到正确的 sidecar。
- 产品单作业构建：`cjpm build -i --jobs 1`。增量判定仍由 `cjpm -i` 执行；验收与发布仅在构建成功后保存缓存。

### 产品依赖构建缓存

Actions 在 Linux、Windows、macOS 的产品验收、Linux Pages fallback 和 Release 构建中缓存 `~/.cjpm/git`、根包 `target/release` 与 `build-script-cache/release`。缓存身份隔离 runner 平台、Cangjie target、SDK/cjpm 版本、compiler fingerprint、stdx digest、产品编译选项、根包与 CHIR worker 的清单和 lockfile、path dependencies 和构建策略输入；根包源码 hash 作为精确 key 后缀。

源码变化时，restore prefix 只允许取回相同依赖与工具链的旧缓存；随后仍执行 `cjpm build -i`，由 cjpm 决定需要重编的包。缓存仅在产品构建/验收成功后写入，测试使用隔离 target，不与产品缓存混用。CHIR worker 的 target 由验收脚本临时创建并清理，不参与共享缓存。

### 正式构建的完整旗标

正式工具构建、worker、Release、CLI 功能验收，以及编译 cjdoc 源码依赖的 fixture 使用
`-O2 --fno-chir-function-inlining -Woff deprecated`。同源诊断中，额外 no-inline 选项通过了真实 Doc IR
GC 查询与 MCP 回归；这不表示普通 `-O2` 已通过，也不认定编译器故障根因。

产品构建仅抑制 `deprecated`。Linux candidate 产品构建的 45 条弃用警告中，42 条来自 `std.posix`
fd API（`openat`、`O_NOFOLLOW`、`lseek` 等），其替代 `std.fs` API 无法表达
`src/filesystem/bounded_read.cj` 需要的描述符相对、禁止符号链接遍历；其余 3 条是
`std.sync.ReentrantMutex`。`unused` 保持开启，保留死代码告警；没有用 `-Woff all`，以免同时关闭
`semantics`、`parser`、`apilevel-check` 等组。

抑制写在产品清单 override 里，因此会作用于整个产品依赖闭包（cjdoc 自身与 `yjson`、`markdown`
等同等待遇）。代价明确：新增的产品弃用 API 调用不会出现在产品构建日志，需靠 review 与 lint
阶段发现。STS 1.2 Windows 产品编译在同时应用 `-Woff unused` 与 `-Woff deprecated` 时曾于
`match (String)` 报错；当前策略仅抑制 `deprecated`，保留 `unused`。

仅 `cjpm test` 编译使用显式 `-O1` 例外：Linux 同源对照中，STS 1.2.0、静态 stdx、
131072 KiB 栈和相同测试参数下，普通 `-O2` 与 `-O2 --fno-chir-function-inlining`
都在 cjc 编译期出现 ICE 13，零测试用例运行；`-O1` 能编译并执行单测。
这些本地结果不提供其它平台的 O2 单测通过证明。

仓库在 `scripts/sts_compile_override.py` 按子命令选择选项。临时清单覆盖只对 `cjdoc`、`cjdoc_chir_worker`、`provider_plugin_fixture`、`highlight_host_fixture` 四个包生效；不因命令失败重试或自动降级。

CI 通过 `scripts/with_sts_cjpm.sh` 为一次 shell 内的 `cjpm build/test/run` 安装临时 wrapper，调用结束由 trap 恢复原清单。使用前必须设置本次 checkout 与临时目录：

```bash
export GITHUB_WORKSPACE="$PWD"
mkdir -p "$HOME/.cache/agent-tmp"
chmod 700 "$HOME/.cache/agent-tmp"
export RUNNER_TEMP="$(mktemp -d "$HOME/.cache/agent-tmp/cjdoc-check.XXXXXX")"
export TMPDIR="$RUNNER_TEMP" TMP="$RUNNER_TEMP" TEMP="$RUNNER_TEMP"
. scripts/with_sts_cjpm.sh
```

之后在同一 shell、workspace 内，`cjpm build`/`run` 使用 `-O2 --fno-chir-function-inlining -Woff deprecated`，`cjpm test` 使用 `-O1`。其它命令和 workspace 外的调用原样透传。不要把临时覆盖写进提交。

每次单测创建 `RUNNER_TEMP` 下的新 `--target-dir`，结束后清理；wrapper 拒绝调用方另传该选项，防止单测复用或写入产品的 `target/`。测试中启动的产品构建仍选完整产品旗标，嵌套调用结束后恢复外层单测清单。

并发构建或测试的 shell 必须各用独占的 `RUNNER_TEMP`，即使 checkout 和产品 `target/` 已经分开。wrapper 可执行文件和调用日志也位于该目录，不能在运行期间被另一任务覆盖。

`CJDOC_STS_INVOCATION_LOG` 记录实际 argv、完整清单选项、阶段、阶段理由、退出码，以及策略和 wrapper 的源码摘要；只有 `build` 记录绑定产品二进制。发布凭证仍要求使用完整旗标且成功的产品 build 及其二进制摘要，`-O1 test` 记录不能替代产品构建凭证。候选 receipt 读取真实调用日志、核对产品二进制和策略源码，并记录日志摘要；独立调用时使用 `--invocation-log`，CI 默认读取 `RUNNER_TEMP` 下的同一日志。

检查某个清单当前声明的选项：

```bash
python3 scripts/sts_compile_override.py --declared cjpm.toml
```

## 准备已认证的 stdx sidecar

`scripts/with_stdx.py` 从 `CANGJIE_HOME`/`CANGJIE_SDK_ROOT`/`PATH` 定位 `cjc`，核对 version 与 target，再找匹配的 static stdx sidecar；只接受含常规文件 `stdx.chir.cjo` 与 `libstdx.chir.a` 的静态 sidecar，不完整的根会被拒绝。

CI 把认证结果写入 `GITHUB_ENV`：

```bash
python3 scripts/with_stdx.py --variant static --print-env --
```

本地单条命令推荐用 wrapper（避免手工导出含空格路径）：

```bash
python3 scripts/with_stdx.py --variant static -- cjpm build -i --jobs 1
```

需要让 `scripts/check.sh` 这类间接调用也拿到环境时，通过 wrapper 启动整个命令；需要编译的阶段仍先按前文加载 `scripts/with_sts_cjpm.sh`：

```bash
python3 scripts/with_stdx.py --variant static -- bash scripts/check.sh preflight --repo .
```

`--print-env` 输出的键包括 `CANGJIE_STDX_PATH`、`CJDOC_STDX_PATH`、`CJDOC_STDX_VARIANT`、`CJDOC_STDX_DIGEST`、`CJDOC_STDX_LINK_OPTIONS`、`CJDOC_STDX_DEPENDENCY_DIGEST` 与 `CJDOC_TOOLCHAIN_VERSION/TARGET/FINGERPRINT`。这是供 CI 环境文件读取的原始 `KEY=VALUE`，不是 shell 脚本；版本字符串含空格和括号，不要用 `eval` 执行。wrapper 会把这些值直接传给子进程，无需手工解析。

## 构建与运行

```bash
python3 scripts/with_stdx.py --variant static -- cjpm build -i --jobs 1
cjc -v
cjpm -v
./cjdoc --version
```

产物是 `target/release/bin/main`（Windows 为 `main.exe`）。仓库根目录的 [`./cjdoc`](../../cjdoc) launcher 只是便捷入口：binary 不存在时它会尝试默认 `cjpm build`。正式验收和发布仍按上述 wrapper 路径构建，以记录实际选项、调用和二进制身份。

`cjpm test` 运行仓颉单测；正式验收通过同一 wrapper 显式选择单测专属 `-O1` 和隔离目录。产品构建继续要求完整产品旗标。任何阶段失败都保留首次退出码，不重试或自动降低优化级别。安装 `just` 后也可用 `just doctor`、`just build`、`just test`、`just schema`、`just check`、`just smoke`、`just provider-smoke`、`just real-smoke`、`just perf`、`just release-check`。

## 本地验收门禁 `scripts/check.sh`

要求：已准备 SDK 与 sidecar、Bash、Python 3.12 或更新版本（`CJDOC_PYTHON` 可覆盖解释器）。全量门禁和 `python-tools` 阶段还需要 Python 验收依赖：

```bash
python3 -m pip install -r scripts/requirements-python-tools.txt
```

SDK 1.2.0 上调用前先 source `scripts/with_sts_cjpm.sh`（见上）。门禁会拒绝覆盖已存在的构建输出：`tests/fixtures/**/target` 或 `tools/chir-worker/target` 已存在时先报错，需要先处理那份旧输出。`preflight`/`build` 还要求仓库输入已提交且可跟踪；请从干净 checkout 运行。

维护 query/离线读取 fixture 时，输入路径及祖先仍禁止符号链接。测试创建自己的临时目录后，应先用 `Path(...).resolve()` 得到 canonical 路径再写入并传递 snapshot，避免平台临时目录别名触发正常的输入拒绝；不能为测试放松产品的路径安全检查。CLI 失败断言同时保留 stdout 的结构化错误与 stderr；只有对应正例已生成响应后才执行该响应的非法输入变体，避免级联的未绑定变量错误。

输出清单的 8 MiB 上限按序列化后的 UTF-8 字节计算，包含 JSON 转义、文件记录和去重后的目录记录。验证发布规模时，应检查实际写出的 `.cjdoc-output.json`，不要按路径字符数推算。

不带参数运行完整门禁：

```bash
bash scripts/check.sh
```

按阶段运行（CI 和 Pages 只跑需要的阶段）：

| 阶段 | 内容 |
|---|---|
| `preflight` | 已跟踪仓库输入、SDK 安装器与 `with_stdx` 单测 |
| `build` | 构建主程序与 CHIR worker，写 build manifest |
| `native` | `cjpm test` 仓颉单测（显式 `-O1`、隔离 target、超时与降级计数） |
| `python-tools` | Pyflakes、`scripts/test_*.py` 与 `tests/showcase_contract/` |
| `cli` | CLI、schema、golden、HTML、输出安全与 fixture 契约 |
| `provider` | provider-plugin fixture |
| `smoke` | 真实仓库双次生成 smoke |
| `html-a11y` | 真实 Chromium 包索引响应式/语义/可访问性矩阵；需要 Playwright + Chromium，不在默认链路里 |
| `browser` | 真实生成站点上的六个 Node Playwright spec；独立于默认链路，在 Linux CI 中是必需步骤 |
| `render-mutations` | 可选；在独立源码副本中分别引入四个回归，要求对应断言失败 |

`scripts/check.sh` 负责阶段分发和证据记录；`scripts/check_cli.sh` 负责 `cli` 阶段内的检查。

`cjpm test` 通过 STS wrapper 输出 `degraded: N`，并逐条说明哪些行为没验证及其原因。计数按标记本身统计，不依赖日志行首或行前缀，因此被测试框架重新打印的用例输出同样计入。Linux、Windows 与 macOS 的 CI 都准备 CHIR worker、Node 与锁定的 Highlight.js adapter，并用 `CJDOC_TEST_REQUIRE_VERIFIED=1` 拒绝任何降级；`CJDOC_TEST_PROVE_MISSING_WORKER=1` 再要求一次反向对照：在未设 `CJDOC_CHIR_WORKER` 的情况下用同一个 wrapper 重跑一个已选回退用例，它的降级总数必须非 0 且严格模式必须失败，否则“不会触发的计数”同样被判失败。

示例运行只有两种可接受结果：本机真正执行，或 macOS 文档化的 fail-closed 拒绝。macOS 拒绝必须同时带有限制器给出的原因（`address-space memory limit is unavailable on this platform`），这类记录单独计为 `CJDOC_TEST_PLATFORM_REFUSAL`，不计入降级；其他主机出现该拒绝、或出现编译/链接失败形式的 `CJDOC3074`，都不算已验证。CI 用 `CJDOC_TEST_PLATFORM_REFUSALS=required`（macOS）与 `forbidden`（Linux、Windows）区分这两种要求。

测试不再从环境变量拿仓库根：fixture 路径由编译进二进制的源码位置（异常栈中的绝对路径）或测试二进制自身路径向上找到声明本模块的清单得到，进程工作目录不参与，因此从任意目录、以及不带任何项目环境的裸 `unittest_bin` 执行都不改变结果。在准备好的环境运行 `python3 scripts/check_native_environment.py --repo .`：它先经同一个 wrapper 在未设 CHIR worker 时确认降级计数与严格失败（正负对照），再在仓库外的目录、且移除 `CJDOC_TEST_ROOT` 的环境里逐个执行测试二进制。

`browser` 阶段使用 Node.js 26.11.1，并安装锁定的 Playwright 和 Chromium。Linux 上 `TMPDIR` 应使用路径较短的私有目录，以免 Chromium 原生缩放测试的 Unix socket 路径超长；生成站点和测试报告仍写入 `--output-root`。

CI 中的阶段调用方式可直接照搬（二进制换成你刚构建的）：

```bash
bash scripts/check.sh preflight --repo .
bash scripts/check.sh native --repo . --identity target/ci-build/build-manifest.json \
  --worker-binary target/release/bin/chir-worker-main
bash scripts/check.sh python-tools --repo . --identity target/ci-build/build-manifest.json
bash scripts/check.sh cli --repo . --identity target/ci-build/build-manifest.json \
  --main-binary target/release/bin/main \
  --worker-binary target/release/bin/chir-worker-main \
  --output-root "$RUNNER_TEMP/cjdoc-stage-cli"
bash scripts/check.sh provider --repo . --identity target/ci-build/build-manifest.json
bash scripts/check.sh browser --repo . --identity target/ci-build/build-manifest.json \
  --main-binary target/release/bin/main \
  --output-root "$RUNNER_TEMP/cjdoc-stage-browser"
bash scripts/check.sh smoke --repo . --identity target/ci-build/build-manifest.json \
  --main-binary target/release/bin/main \
  --output-root "$RUNNER_TEMP/cjdoc-stage-smoke"
```

`smoke` 还会从[排障指南](../how-to/troubleshoot.md#生成时出现-out-of-memory)读取 OOM 建议命令，在独立 fixture 上执行，核对可打开的 HTML、两种限制的区别和 #229 的历史观测。真实仓库的当前运行不复现旧版的 256 MiB 失败。

`build` 阶段可以一次产出主程序、worker 与身份清单：

```bash
bash scripts/check.sh build --repo . \
  --main-binary-out target/release/bin/main \
  --worker-binary-out target/release/bin/chir-worker-main \
  --manifest target/ci-build/build-manifest.json
```

`--main-binary-out` 只接受 `target/release/bin/main`；`--worker-binary-out` 只接受主程序同级的 `chir-worker-main`（Windows 为 `chir-worker-main.exe`，省略后缀时自动补齐）。构建成功后删除本次创建的 worker 临时构建树，后续阶段直接使用同级 worker。证据默认写到 `target/ci-evidence/`，可用 `--evidence` 或 `CJDOC_CI_EVIDENCE` 改位置。

## 可选 CHIR worker

CLI 的 `generate`、`check`、`serve` 默认通过配套 worker 使用 `stdx.chir` 做结构化语义补充；`--semantic source` 禁用该路径。只有 `tools/chir-worker` 包导入 `stdx.chir`，core 通过受限文件协议调用它；协议常量 `CHIR_WORKER_PROTOCOL = "cjdoc-chir-worker/3"` 与共享产品版本定义在 `tools/chir-protocol`。

在已认证 stdx 的同一环境构建：

```bash
python3 scripts/with_stdx.py --variant static -- bash -c 'cd tools/chir-worker && cjpm build -i --jobs 1'
```

产物是 `tools/chir-worker/target/release/bin/main`（Windows 为 `main.exe`）。正式构建把它与主程序一起封存，并将 worker 暂存到主程序同级的 `chir-worker-main[.exe]`。安装时保留这个同目录关系；主程序按操作系统提供的真实可执行文件位置自动定位 worker，不依赖当前工作目录、启动别名或 PATH。

普通 CLI 用法：

```bash
cjdoc generate --project . --format json --stdout
```

约束与失败行为：

- `generate`、`check`、`serve` 接受语义选项，默认 `chir`。项目 `[semantic].mode` 和显式 `--semantic` 可选择 `source`；`--cjc`、`--chir-worker`、`--chir-import-path` 与显式源码模式互斥。`render` 只消费已有 Doc IR，不接受这些选项。
- `--chir-worker` 只在开发或特殊部署时覆盖自动定位。worker 缺失产生 `CJDOC2101`，产品版本或协议不匹配产生 `CJDOC2104`，两者都保留源码声明；普通项目不配置 worker 路径。
- CHIR 编译或读取失败时保留 AST/source fallback，并产生 `CJDOC2101`–`CJDOC2106` warning；CHIR 不覆盖源码/注释真值，也不把 `partial` 语义升级为 resolved。
- 仓颉单测用环境变量 `CJDOC_CHIR_WORKER` 指向 worker 可执行文件；未设置时相关用例跳过 CHIR 路径。
- CHIR capability 调查与历史结论见 [../research/api-capability-matrix.md](../research/api-capability-matrix.md)、[../research/stdx-chir-findings.md](../research/stdx-chir-findings.md)。当前内置 provider 只提供保守补充，不替代源码/AST fallback。

## Linux 候选构建（CI/Pages 复用的唯一构建）

[`build-linux-candidate.yml`](../../.github/workflows/build-linux-candidate.yml) 是钉死工具链的唯一构建入口：安装 STS 1.2.0 + stdx sidecar、导出认证环境、source 完整旗标 wrapper，然后调用 `check.sh build` 一次。CI 的 Linux 验收与 Pages 消费同一个候选产物，并重新校验 `build-manifest.json` 里的二进制摘要、大小与 `--version`，身份不符即失败。

本地复现同一步骤：

```bash
export GITHUB_WORKSPACE="$PWD"
mkdir -p "$HOME/.cache/agent-tmp"
chmod 700 "$HOME/.cache/agent-tmp"
export RUNNER_TEMP="$(mktemp -d "$HOME/.cache/agent-tmp/cjdoc-check.XXXXXX")"
export TMPDIR="$RUNNER_TEMP" TMP="$RUNNER_TEMP" TEMP="$RUNNER_TEMP"
python3 scripts/with_stdx.py --variant static -- bash -c '
  . scripts/with_sts_cjpm.sh
  bash scripts/check.sh build --repo . \
    --main-binary-out target/release/bin/main \
    --worker-binary-out target/release/bin/chir-worker-main \
    --manifest target/ci-build/build-manifest.json
'
```

候选产物包含 `target/release/bin/main`、`target/release/bin/chir-worker-main` 与 `target/ci-build/build-manifest.json`；workflow 用固定 ustar 参数打包后上传，消费方解包后必须重新校验身份。

## 目录输出与故障恢复

目录输出逐项写入父目录锁内的 `.cjdoc-output-parent.lock/spool/`，内存只保留产物元数据。完整 spool 清单封存后，仍按完整 plan → plan 摘要 → marker 的顺序进入原有 stage、提交和恢复流程。渲染或发布门禁失败时保留既有 owned/unowned 文件；资源上限 fallback 先销毁本次私有 spool，再从空清单重试一次。公开数组 API 仍按调用者请求收集产物。

Linux 锁回收先核对同一次 kernel boot、PID namespace 和一致的 procfs PID 视图，再使用原有 PID/start-time 观测或内核明确的 `ESRCH` 缺失证明。权限失败、查询失败、域不匹配和无法确定的 PID 都保留锁与 spool，不把异常当作 owner 已退出。

私有 owner 记录使用 `cjdoc.output-lock/2`，包含可空的 `processDomainSha256`，不保存原始 boot/namespace 标识。缺少域证明的 Linux 记录及旧版 owner 不自动迁移或回收。处理这类遗留锁前，须在原运行环境确认持有者已经退出；`--force-owned` 不绕过锁活性和目录身份守卫。

## 浏览器回归

先按本文构建主程序与同目录的 CHIR worker，使用[主 CI](../../.github/workflows/ci.yml)固定的 Node 26.11.1，并安装 Chromium 所需的系统库。用与 Linux CI 相同的入口：

```bash
bash scripts/check.sh browser --repo . \
  --identity target/ci-build/build-manifest.json \
  --main-binary target/release/bin/main \
  --output-root "$RUNNER_TEMP/cjdoc-stage-browser"
```

输出目录必须是新的。此阶段复制浏览器套件，在副本中按 `tests/browser/package-lock.json` 安装依赖与匹配的 Chromium。它生成参考页、双语分组和标签页、多个版本、PocketKit 阅读页、概览、高亮及告警站点，再运行全部六个 spec。缺失 fixture 或跳过用例都会使门禁失败；报告、截图与追踪保留在该输出目录。源码链接使用示例仓库地址，只检验链接结构。

`html-a11y` 仍是独立的 Python Playwright 阶段，验证包索引的响应式布局、语义和可访问性。Pages 的 Python 浏览器验收不变；[Reader scale 工作流](../../.github/workflows/reader-scale.yml)也继续使用独立的 Node 版本与测量入口。

## 验证层级

不要把较低层级的通过当成更高层证据：

| 层级 | 入口 | 不证明什么 |
|---|---|---|
| 构建 | `cjpm build` | 测试、生成产物、其他 SDK |
| 单元/契约 | `cjpm test` | golden/schema 同步、CLI 事务、hosted CI |
| 本地验收 | `scripts/check.sh` | 真实仓库规模、性能、其他 OS/SDK、发布 |
| 真实仓库 | `python3 scripts/real_repository_smoke.py --project .` | 性能或 hosted runner |
| 性能硬上限 | `python3 scripts/perf_gate.py check` | 回归比较或其他 CPU/SDK |
| 发布 | `CJDOC_RELEASE_TAG=vX.Y.Z scripts/release_check.sh` | GitHub-hosted matrix 直到 workflow 实际运行 |

各层级的完整定义、性能基线和发布 checklist 见 [release-process.md](release-process.md)。改 Doc IR 或 golden 后的同步流程见 [doc-ir.md](doc-ir.md)。
