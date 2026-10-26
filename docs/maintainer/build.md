# 构建与本地验收

面向修改 cjdoc 源码的维护者。普通使用者应下载 release binary（见[使用者文档索引](../README.md)）；只有在发布页没有对应资产，或你正在修改 cjdoc 时，才从源码构建。

以下命令以 POSIX shell 为例；Windows 请在 Git Bash 中运行，`python3` 视环境换成 `python`。

## 工具链

- **Cangjie 1.2.0 STS** 的 `cjc`/`cjpm`，以及与编译器匹配的 **`stdx` release/1.2 sidecar**。`cjpm.toml` 使用固定 `commitId` 的 Git 依赖（`markdown`、`yjson`）和 `vendor/yjson_algorithms` path 依赖；`cjpm.lock` 必须与清单一致。
- CI 使用 [`Zxilly/setup-cangjie`](https://github.com/Zxilly/setup-cangjie) 的 `sts` channel + `stdx` component（workflow 中 `cjv-version: v0.3.2`），压缩包由 `cangjie-version-manifest` 提供 SHA-256 校验。手工准备同一套工具链可用 `cjv install sts-1.2.0 --component stdx`。
- 根 `cjpm.toml` 的 `link-option` 与 `bin-dependencies.path-option` 引用环境变量 `${CJDOC_STDX_LINK_OPTIONS}` 和 `${CANGJIE_STDX_PATH}`；没有经过 `scripts/with_stdx.py` 认证并导出这些变量时，构建不会链接到正确的 sidecar。
- 单作业构建：`cjpm build --jobs 1`。`scripts/check.sh` 保持同一调用参数，便于三平台构建与发布回执核对。

### 正式构建的完整旗标

正式工具构建、worker、Release、CLI 功能验收，以及编译 cjdoc 源码依赖的 fixture 使用
`-O2 --fno-chir-function-inlining`。同源诊断中，额外 no-inline 选项通过了真实 Doc IR
GC 查询与 MCP 回归；这不表示普通 `-O2` 已通过，也不认定编译器故障根因。

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

之后在同一 shell、workspace 内，`cjpm build`/`run` 使用 `-O2 --fno-chir-function-inlining`，`cjpm test` 使用 `-O1`。其它命令和 workspace 外的调用原样透传。不要把临时覆盖写进提交。

每次单测创建 `RUNNER_TEMP` 下的新 `--target-dir`，结束后清理；wrapper 拒绝调用方另传该选项，防止单测复用或写入产品的 `target/`。测试中启动的产品构建仍选 `-O2 --fno-chir-function-inlining`，嵌套调用结束后恢复外层单测清单。

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
python3 scripts/with_stdx.py --variant static -- cjpm build --jobs 1
```

需要让 `scripts/check.sh` 这类间接调用也拿到环境时，把 `--print-env` 的键导出到当前 shell：

```bash
set -a
eval "$(python3 scripts/with_stdx.py --variant static --print-env --)"
set +a
```

输出的键包括 `CANGJIE_STDX_PATH`、`CJDOC_STDX_PATH`、`CJDOC_STDX_VARIANT`、`CJDOC_STDX_DIGEST`、`CJDOC_STDX_LINK_OPTIONS`、`CJDOC_STDX_DEPENDENCY_DIGEST` 与 `CJDOC_TOOLCHAIN_VERSION/TARGET/FINGERPRINT`。路径含空格时不要用 `eval`，改为逐项 `export`。

## 构建与运行

```bash
python3 scripts/with_stdx.py --variant static -- cjpm build --jobs 1
cjc -v
cjpm -v
./cjdoc --version
```

产物是 `target/release/bin/main`（Windows 为 `main.exe`）。仓库根目录的 [`./cjdoc`](../../cjdoc) launcher 只是便捷入口：binary 不存在时它会尝试默认 `cjpm build`。正式验收和发布仍按上述 wrapper 路径构建，以记录实际选项、调用和二进制身份。

`cjpm test` 运行仓颉单测；正式验收通过同一 wrapper 显式选择单测专属 `-O1` 和隔离目录。产品构建继续要求 `-O2 --fno-chir-function-inlining`。任何阶段失败都保留首次退出码，不重试或自动降低优化级别。安装 `just` 后也可用 `just doctor`、`just build`、`just test`、`just schema`、`just check`、`just smoke`、`just provider-smoke`、`just real-smoke`、`just perf`、`just release-check`。

## 本地验收门禁 `scripts/check.sh`

要求：已准备 SDK 与 sidecar、Bash、Python 标准库（`CJDOC_PYTHON` 可覆盖解释器）。SDK 1.2.0 上调用前先 source `scripts/with_sts_cjpm.sh`（见上）。门禁会拒绝覆盖已存在的构建输出：`tests/fixtures/**/target` 或 `tools/chir-worker/target` 已存在时先报错退出，需要自己清理。`preflight`/`build` 还要求仓库输入都已提交且可跟踪；干净 checkout 上运行最省事。

不带参数运行完整门禁：

```bash
bash scripts/check.sh
```

按阶段运行（CI 和 Pages 只跑需要的阶段）：

| 阶段 | 内容 |
|---|---|
| `preflight` | 已跟踪仓库输入、SDK 安装器与 `with_stdx` 单测 |
| `build` | 构建主程序与 CHIR worker，写 build manifest |
| `native` | `cjpm test` 仓颉单测（显式 `-O1`、隔离 target、超时与进程快照保护） |
| `python-tools` | `scripts/test_*.py` 与 `tests/showcase_contract/` |
| `cli` | CLI、schema、golden、HTML、输出安全与 fixture 契约 |
| `provider` | provider-plugin fixture |
| `smoke` | 真实仓库双次生成 smoke |
| `html-a11y` | 真实 Chromium 包索引响应式/语义/可访问性矩阵；需要 Playwright + Chromium，不在默认链路里 |

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
bash scripts/check.sh smoke --repo . --identity target/ci-build/build-manifest.json \
  --main-binary target/release/bin/main \
  --output-root "$RUNNER_TEMP/cjdoc-stage-smoke"
```

`build` 阶段可以一次产出主程序、worker 与身份清单：

```bash
bash scripts/check.sh build --repo . \
  --main-binary-out target/release/bin/main \
  --worker-binary-out target/release/bin/chir-worker-main \
  --manifest target/ci-build/build-manifest.json
```

`--main-binary-out` 只接受 `target/release/bin/main`；`--worker-binary-out` 只接受 worker 的 canonical 路径或其同级 `chir-worker-main`。证据默认写到 `target/ci-evidence/`，可用 `--evidence` 或 `CJDOC_CI_EVIDENCE` 改位置。

## 可选 CHIR worker

`--semantic chir` 通过独立 worker 进程使用 `stdx.chir` 做结构化语义补充。只有 `tools/chir-worker` 包导入 `stdx.chir`，core 通过受限文件协议调用它；协议常量 `CHIR_WORKER_PROTOCOL = "cjdoc-chir-worker/2"` 定义在 `tools/chir-protocol`。

在已认证 stdx 的同一环境构建：

```bash
python3 scripts/with_stdx.py --variant static -- bash -c 'cd tools/chir-worker && cjpm build --jobs 1'
```

产物是 `tools/chir-worker/target/release/bin/main`（Windows 为 `main.exe`）。`scripts/check.sh build` 会把它复制到 `target/release/bin/chir-worker-main` 并记录身份。

CLI 用法（只属于 `generate`/`check`）：

```bash
cjdoc generate --project . --format json --stdout \
  --semantic chir \
  --chir-worker tools/chir-worker/target/release/bin/main \
  --cjc "$(command -v cjc)" \
  --chir-import-path "$CANGJIE_STDX_PATH"
```

约束与失败行为：

- 只有 `generate` 和 `check` 接受 `--semantic chir`；`--cjc`、`--chir-worker`、`--chir-import-path` 必须与 `--semantic chir` 同用，`--chir-import-path` 可重复；`render` 只消费已有 Doc IR，不接受这些选项。
- 未配置 `--chir-worker` 时 `--semantic chir` 仍可运行，但保留 source declarations 并产生 `CJDOC2101` warning。
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
set -a
eval "$(python3 scripts/with_stdx.py --variant static --print-env --)"
set +a
export CANGJIE_STDX_PATH="${CJDOC_STDX_PATH}"
. scripts/with_sts_cjpm.sh
bash scripts/check.sh build --repo . \
  --main-binary-out target/release/bin/main \
  --worker-binary-out target/release/bin/chir-worker-main \
  --manifest target/ci-build/build-manifest.json
```

候选产物包含 `target/release/bin/main`、`target/release/bin/chir-worker-main` 与 `target/ci-build/build-manifest.json`；workflow 用固定 ustar 参数打包后上传，消费方解包后必须重新校验身份。

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
