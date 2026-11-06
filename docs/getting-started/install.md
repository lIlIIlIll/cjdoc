# 安装与当前手册匹配的 cjdoc

主路径从当前源码构建，保证工具和手册属于同一个提交。发行包是另一个明确区分的入口：相同 `0.7.7` 版本字符串不代表实现、Doc IR 或所有选项相同。

## 选择平台与准备环境

| 平台 | 本轮验证范围 | shell |
|---|---|---|
| Linux x64 | 当前源码完整用户流程实操 | Bash |
| macOS ARM64 | 根据脚本、官方 SDK 说明和发行配置静态核对，未实操 | Bash；系统默认 zsh 中先启动 Bash |
| Windows x64 | 根据脚本、官方 SDK 说明和发行配置静态核对，未实操 | 源码构建需要 Git Bash；安装/打开文件可用 PowerShell |

准备 Git、Bash、Python 3，以及 **Cangjie STS 1.2.0 SDK 和匹配的静态 stdx 1.2.0**。下载与系统前提见 [STS 1.2.0 下载](https://cangjie-lang.cn/download/1.2.0)和[官方安装说明](https://cj-docs.gitcode.com/zh/1.2.0/dev-guide/source_zh_cn/first_understanding/install.html)。不要使用 nightly 或另一个 SDK 的 stdx。

手工解压时 SDK 的 `cangjie/` 与包含 stdx 的平台目录是同层 sidecar，不是 `cangjie/stdx/`。`CANGJIE_STDX_PATH` 应指向实际包含 `stdx.chir.cjo` 和 `libstdx.chir.a` 的静态 `stdx/` 目录；后面的认证脚本会检查。已有健康 SDK 不需要重装。

也可以先按 [cjv 的安装说明](https://github.com/Zxilly/cjv)安装 cjv，再用其支持 STS 组件的版本（本项目 CI 固定 `v0.3.2`）执行 `cjv install sts-1.2.0 --component stdx`。cjv 不是本教程的必需命令，不能在没有安装它时直接复制这条命令。

POSIX 在**当前 shell**加载 SDK 自带的环境脚本（把变量设成实际解压位置）：

```bash
export CANGJIE_SDK_ROOT="$HOME/toolchains/sts-1.2.0/cangjie"
. "$CANGJIE_SDK_ROOT/envsetup.sh"
export CANGJIE_STDX_PATH="$HOME/toolchains/sts-1.2.0/linux_x86_64_cjnative/static/stdx"
cjc -v
cjpm -v
```

路径是建议布局，不是自动创建或下载命令。macOS 的 sidecar 使用实际 ARM64 平台目录，不照抄 Linux 路径。确认两个版本均为 1.2.0。Windows 先按 SDK 的 Windows 环境脚本设置运行库和 PATH，再启动继承该环境的 Git Bash；在 Bash 中使用实际可访问的 SDK/stdx 路径。不要把 `.sh` 当作 PowerShell 命令，或把 Bash 的 `export` 粘贴到 CMD。

SDK 环境只在当前 shell 及其子进程生效。新终端需要再次加载环境脚本；仅重开终端不会保存本次 `export`。cjdoc 运行仍需要匹配的 SDK runtime，不能把单个二进制当作无环境依赖的程序。

## 1. 获取源码并固定提交

起点是你选择的源码工作目录。在 Bash 中执行：

```bash
git clone https://github.com/lIlIIlIll/cjdoc.git
cd cjdoc
export CJDOC_SOURCE="$PWD"
export REVISION="$(git rev-parse HEAD)"
export CJDOC_REVISION="$REVISION"
printf '%s\n' "$REVISION"
```

记录输出的完整提交。后续阅读这个 checkout 的手册，不把 main 的更新套到旧二进制上。首次构建需要访问清单中锁定的 Git 依赖；cjdoc 不负责下载被文档化项目的依赖。

`CJDOC_SOURCE` 与 `CJDOC_REVISION` 是后续独立进阶任务的源码位置和完整提交前提；它们描述这次源码构建，不用于给另一份 PATH 二进制补造身份。新终端使用它们时，应从你保存的构建记录重新设置。

## 2. 准备隔离临时目录并构建

仍在 cjdoc 源码根。临时目录应在磁盘文件系统，不放 tmpfs `/tmp`。Linux 先用 `df -T "$HOME/.cache"` 检查文件系统与可用空间；macOS 用 `df -h "$HOME"` 并确认目标在磁盘卷；Windows 确认 `$HOME` 在有足够空间的磁盘。然后执行：

```bash
mkdir -p "$HOME/.cache/agent-tmp"
chmod 700 "$HOME/.cache/agent-tmp"
export RUNNER_TEMP="$(mktemp -d "$HOME/.cache/agent-tmp/cjdoc-install.XXXXXX")"
export TMPDIR="$RUNNER_TEMP" TMP="$RUNNER_TEMP" TEMP="$RUNNER_TEMP"
export GITHUB_WORKSPACE="$PWD"
export CJDOC_PYTHON=python3
export PYTHONDONTWRITEBYTECODE=1
if command -v cygpath >/dev/null 2>&1; then
  export GITHUB_WORKSPACE="$(cygpath -m "$GITHUB_WORKSPACE")"
  export RUNNER_TEMP="$(cygpath -m "$RUNNER_TEMP")"
  export CANGJIE_STDX_PATH="$(cygpath -m "$CANGJIE_STDX_PATH")"
  export TMPDIR="$RUNNER_TEMP" TMP="$RUNNER_TEMP" TEMP="$RUNNER_TEMP"
fi
. scripts/with_sts_cjpm.sh
python3 scripts/with_stdx.py --variant static -- cjpm build --jobs 1
```

正式产品旗标由现有入口固定为 `-O2 --fno-chir-function-inlining`；不要用单测专属的 O1 替代。构建成功后得到 `target/release/bin/main`，Windows 为 `main.exe`。静态 stdx 负责构建期链接；SDK runtime 仍是运行前提。

Git Bash 的 `cygpath -m` 分支把传给原生 Windows Python 的环境路径转成 `C:/...` 形式；包装脚本内部会再转回 Bash 使用的形式。Linux/macOS 不执行这个分支。本轮仅按脚本路径处理进行 Windows 静态核对，未实操。

若认证报 `no authenticated static stdx sidecar`，检查显式 `CANGJIE_STDX_PATH` 和 SDK 是否配套。不要把动态目录冒充静态目录、随意拼接另一个 SDK 的库，或修改 SDK 来迁就项目。Windows 的 Bash 环境若只有 `python`，先确认该命令为 Python 3，再将本页 `python3` 及 `CJDOC_PYTHON` 一并改为 `python`。

## 3. 安装到用户前缀

Linux/macOS 仍在源码根：

```bash
export CJDOC_PREFIX="$HOME/.local"
install -d "$CJDOC_PREFIX/bin"
install -m 755 target/release/bin/main "$CJDOC_PREFIX/bin/cjdoc"
export PATH="$CJDOC_PREFIX/bin:$PATH"
hash -r
```

这会替换该前缀下的同名工具；要并存或先验收，可将前缀设成新建的私人目录。Windows 在原生 PowerShell 中对应安装实际 `.exe`（从源码根开始）：

```powershell
$CjdocPrefix = Join-Path $HOME '.local'
New-Item -ItemType Directory -Force (Join-Path $CjdocPrefix 'bin') | Out-Null
Copy-Item .\target\release\bin\main.exe (Join-Path $CjdocPrefix 'bin\cjdoc.exe')
$env:Path = (Join-Path $CjdocPrefix 'bin') + ';' + $env:Path
Get-Command cjdoc
```

当前 shell 的 PATH 与 SDK 环境应同时有效。持久化前按你使用的 shell 配置 PATH；不要把本次临时目录变量写入长期配置。

## 4. 离开源码目录验证

Linux/macOS 在同一 Bash 中执行：

```bash
cd "$RUNNER_TEMP"
command -v cjdoc
cjdoc --version
cjdoc --help
```

当前源码版本字符串为 `cjdoc 0.7.7`，身份仍以第 1 步提交为准。只有顶层支持 `--help`，子命令没有独立帮助。随后在这个空目录执行[第一个站点](../tutorials/first-site.md)的初始化与生成，证明没有依赖源码根 launcher 或旧 PATH 二进制。Windows 在另一空目录运行 `Get-Command cjdoc`、`cjdoc --version`、`cjdoc --help`，保持 SDK runtime 环境。

## 替代：安装公开发行包 v0.7.7

此入口使用历史发布源码 `8cc8f71a296b1c6321e575b56fadbd0c379e242a`，不是当前源码手册全部能力的证明。它的 Doc IR 为 v16，不能拿来读取当前 v18 输入。以包内 `release-manifest.json.sourceCommit` 进入[该提交手册](https://github.com/lIlIIlIll/cjdoc/tree/8cc8f71a296b1c6321e575b56fadbd0c379e242a/docs)。

在新的下载目录、已准备 SDK 的 Bash 中执行（需要 curl、sha256sum、tar）：

```bash
curl --fail --location -O https://github.com/lIlIIlIll/cjdoc/releases/download/v0.7.7/cjdoc-0.7.7-linux-x64.tar.gz
printf '%s  %s\n' ee328b037828891534d34b17a0691ee95ad521125868200f0ba2a37f58a89de4 cjdoc-0.7.7-linux-x64.tar.gz | sha256sum -c -
tar -tzf cjdoc-0.7.7-linux-x64.tar.gz
```

检查清单只包含 `cjdoc-0.7.7/` 下的普通文件/目录，无绝对路径、`..` 或链接；不向已有目录覆盖解包。然后：

```bash
mkdir unpacked
tar -xzf cjdoc-0.7.7-linux-x64.tar.gz -C unpacked
cat unpacked/cjdoc-0.7.7/release-manifest.json
```

核对平台 `linux-x64`、版本 `0.7.7`、上述 sourceCommit。清单声明 SDK/stdx 都为 `1.2.0`，SDK archive SHA-256 为 `8c5fd944cd9cc51ee63d4a240e3ecc4f540345dae1468e8b47c927ecf2ba998f`，stdx archive SHA-256 为 `c036a192e8fd4206b84ca9a94611820bc66623198975f3dff874f748d65a8b47`；按该发行版要求准备运行环境，不拿另一套 SDK 的版本字符串代替匹配。

独立前缀安装，避免和当前源码工具混淆：

```bash
export RELEASE_PREFIX="$PWD/release-install"
install -d "$RELEASE_PREFIX/bin"
install -m 755 unpacked/cjdoc-0.7.7/cjdoc "$RELEASE_PREFIX/bin/cjdoc"
"$RELEASE_PREFIX/bin/cjdoc" --version
"$RELEASE_PREFIX/bin/cjdoc" schema list
```

最小生成可使用[首站教程](../tutorials/first-site.md)的无依赖 `docdemo` 文件，但必须以这个**绝对路径二进制**运行 `generate --project <docdemo目录> --format html --output <新输出目录>`。本替代入口只保证该发行版自身的最小生成，不承诺本手册后续全部功能。

macOS 资产为 `cjdoc-0.7.7-macos-arm64.tar.gz`，用 `shasum -a 256 -c` 核对其自己的 `.sha256`；Windows 为 `cjdoc-0.7.7-windows-x64.zip`，PowerShell 用 `Get-FileHash -Algorithm SHA256` 对照自己的校验文件、`Expand-Archive` 到空目录，再复制 `cjdoc.exe`。不能复用 Linux digest。所有平台都要读各自清单，保留 SDK runtime 环境。

发行包保持同提交 README 原字节，只带其既有文档/schema 负载，不包含预览图片与整套当前手册。在线视觉与详细流程应通过清单 sourceCommit 查看同版本源码，不修改包内 README 伪装成新版。

## 下一步

[从空目录生成第一个站点](../tutorials/first-site.md)。遇到启动、依赖或项目根错误，按[排错入口](../how-to/troubleshoot.md)区分处理。
