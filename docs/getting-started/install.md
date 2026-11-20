# 安装 cjdoc

安装后，将 `cjdoc` 和配套的 `chir-worker-main` 放在同一个目录。使用时把这个目录加入 `PATH`，并在当前终端加载仓颉 SDK。

| 想使用哪个版本 | 安装方式 |
|---|---|
| 已发布的 v0.7.9 | [下载预编译发行包](#安装预编译发行包)，配合 [v0.7.9 手册](https://github.com/lIlIIlIll/cjdoc/tree/v0.7.9/docs) |
| 正在阅读的源码版本 | [从同一提交构建](#从源码构建)，配合该提交的手册 |

## 前提：准备 SDK 1.2.0

安装 [Cangjie STS 1.2.0 SDK](https://cangjie-lang.cn/download/1.2.0)，按[仓颉安装说明](https://cj-docs.gitcode.com/zh/1.2.0/dev-guide/source_zh_cn/first_understanding/install.html)加载环境。Linux x64 和 macOS ARM64 的 Bash 示例：

```bash
export CANGJIE_SDK_ROOT="$HOME/toolchains/sts-1.2.0/cangjie"
. "$CANGJIE_SDK_ROOT/envsetup.sh"
cjc -v
cjpm -v
```

将路径换成含 `envsetup.sh` 的实际 SDK 根目录。两条版本命令都应报告 `1.2.0`。在 Windows x64 上，PowerShell 使用 SDK 的 `envsetup.ps1`，Git Bash 使用 `envsetup.sh`；在哪个终端安装或构建，就先在那个终端加载 SDK。

预编译包不需要单独准备 stdx。**从源码构建**另需 Git、Bash、Python 3、网络和匹配的**静态 stdx 1.2.0**。也可以用 [`cjv`](https://github.com/Zxilly/cjv) 安装 SDK 和 stdx：

```bash
cjv install sts-1.2.0 --component stdx
```

## 安装预编译发行包

### 1. 下载并校验

从 [v0.7.9 发布页](https://github.com/lIlIIlIll/cjdoc/releases/tag/v0.7.9)下载压缩包及同名的 `.sha256` 文件。单独的可执行文件不含配套 worker。

| 平台 | 压缩包 | 在下载目录校验 |
|---|---|---|
| Linux x64 | `cjdoc-0.7.9-linux-x64.tar.gz` | `sha256sum -c cjdoc-0.7.9-linux-x64.tar.gz.sha256` |
| macOS ARM64 | `cjdoc-0.7.9-macos-arm64.tar.gz` | `shasum -a 256 -c cjdoc-0.7.9-macos-arm64.tar.gz.sha256` |
| Windows x64 | `cjdoc-0.7.9-windows-x64.zip` | 在 PowerShell 比较下列摘要 |

```powershell
Get-FileHash .\cjdoc-0.7.9-windows-x64.zip -Algorithm SHA256
Get-Content .\cjdoc-0.7.9-windows-x64.zip.sha256
```

Linux 和 macOS 应显示 `OK`；Windows 上 `Hash` 应与校验文件中的摘要一致。不一致时重新下载，不要解压。

### 2. 解压并安装

检查归档只包含 `cjdoc-0.7.9/` 下的普通文件和目录。不要解压含绝对路径、`..` 路径或符号链接的归档。Linux 示例（macOS 换成对应包名）：

```bash
tar -tvzf cjdoc-0.7.9-linux-x64.tar.gz
mkdir unpacked && tar -xzf cjdoc-0.7.9-linux-x64.tar.gz -C unpacked
```

Windows 可在资源管理器中检查 ZIP 后解压到新的 `unpacked` 目录。打开 `unpacked/cjdoc-0.7.9/release-manifest.json`，确认 `platform` 和 `version`。按 `sourceCommit` 查该包对应的手册，文件名见 `executables`。

在下载目录执行。下例使用版本专属目录，不覆盖其他版本：

```bash
prefix="$HOME/.local/cjdoc-0.7.9"
install -d "$prefix/bin"
install -m 755 unpacked/cjdoc-0.7.9/cjdoc "$prefix/bin/cjdoc"
install -m 755 unpacked/cjdoc-0.7.9/chir-worker-main "$prefix/bin/chir-worker-main"
export PATH="$prefix/bin:$PATH"
```

Windows PowerShell：

```powershell
$bin = Join-Path $HOME '.local\cjdoc-0.7.9\bin'
New-Item -ItemType Directory -Force $bin | Out-Null
Copy-Item .\unpacked\cjdoc-0.7.9\cjdoc.exe $bin
Copy-Item .\unpacked\cjdoc-0.7.9\chir-worker-main.exe $bin
$env:Path = "$bin;$env:Path"
```

跳到[确认安装](#在源码目录外确认命令可用)。主程序只从自身所在目录查找配套 worker。

## 从源码构建

### 1. 进入要使用的源码版本

```bash
git clone https://github.com/lIlIIlIll/cjdoc.git
cd cjdoc
export CJDOC_SOURCE="$PWD"
export CJDOC_REVISION="$(git rev-parse HEAD)"
```

已有源码可直接进入该目录。使用指定提交时，先切换提交再设置变量。日常运行不需要这两个变量；复制该版本样例或手动重建 worker 时会用到。

### 2. 指向静态 stdx

将 `CANGJIE_STDX_PATH` 指向同时含有 `stdx.chir.cjo` 和 `libstdx.chir.a` 的静态 `stdx/` 目录。手工解压布局如下：

```text
<解压根>/cangjie/
<解压根>/<平台>/static/stdx/stdx.chir.cjo
<解压根>/<平台>/static/stdx/libstdx.chir.a
```

平台目录名为 `linux_x86_64_cjnative`、`darwin_aarch64_cjnative` 或 `windows_x86_64_cjnative`。将下例换成实际位置：

```bash
export CANGJIE_STDX_PATH="$HOME/toolchains/sts-1.2.0/linux_x86_64_cjnative/static/stdx"
```

### 3. 构建主程序和 worker

仍在 cjdoc 源码根目录，在 Bash 中执行。Windows 使用 Git Bash；若 Python 3 的命令名是 `python`，下文三处 `python3` 都改成 `python`。

```bash
(
  set -e
  umask 077
  mkdir -p "$HOME/.cache/cjdoc"
  build_temp="$(mktemp -d "$HOME/.cache/cjdoc/build.XXXXXX")"
  export GITHUB_WORKSPACE="$PWD" RUNNER_TEMP="$build_temp"
  export CJDOC_PYTHON=python3
  if command -v cygpath >/dev/null 2>&1; then
    export GITHUB_WORKSPACE="$(cygpath -m "$GITHUB_WORKSPACE")"
    export RUNNER_TEMP="$(cygpath -m "$RUNNER_TEMP")"
    export CANGJIE_STDX_PATH="$(cygpath -m "$CANGJIE_STDX_PATH")"
  fi
  export TMPDIR="$RUNNER_TEMP" TMP="$RUNNER_TEMP" TEMP="$RUNNER_TEMP"
  . scripts/with_sts_cjpm.sh
  python3 scripts/with_stdx.py --variant static -- cjpm build --jobs 1
  python3 scripts/with_stdx.py --variant static -- bash -c 'cd tools/chir-worker && cjpm build --jobs 1'
  worker=tools/chir-worker/target/release/bin/main
  if [ -f "$worker.exe" ]; then
    cp -p "$worker.exe" target/release/bin/chir-worker-main.exe
  else
    cp -p "$worker" target/release/bin/chir-worker-main
  fi
)
```

成功后 `target/release/bin/` 同时有 `main` 和 `chir-worker-main`，Windows 上都带 `.exe`。若报 `no authenticated static stdx sidecar matches the selected compiler`，检查静态目录及两个文件，再确认 `cjc` 和 stdx 同为 1.2.0。

若 `cjpm` 无法解析 `cjpm.lock`，核对当前 SDK 版本和所选提交的锁文件格式。不要用其他 SDK 生成的锁文件覆盖该提交的锁文件。

### 4. 安装并加入 PATH

仍在源码根目录执行。将 `main` 安装为 `cjdoc`，worker 保持原名：

```bash
prefix="$HOME/.local/cjdoc-source"
install -d "$prefix/bin"
install -m 755 target/release/bin/main "$prefix/bin/cjdoc"
install -m 755 target/release/bin/chir-worker-main "$prefix/bin/chir-worker-main"
export PATH="$prefix/bin:$PATH"
```

Windows PowerShell：

```powershell
$bin = Join-Path $HOME '.local\cjdoc-source\bin'
New-Item -ItemType Directory -Force $bin | Out-Null
Copy-Item .\target\release\bin\main.exe (Join-Path $bin 'cjdoc.exe')
Copy-Item .\target\release\bin\chir-worker-main.exe $bin
$env:Path = "$bin;$env:Path"
```

## 在源码目录外确认命令可用

切到任意其他目录。在 Bash 中执行：

```bash
command -v cjdoc
cjdoc --version
cjdoc --help
```

Windows PowerShell 将第一行换成 `Get-Command cjdoc`。确认命令指向刚安装的位置，版本类似 `cjdoc 0.7.9`，帮助列出 `generate`、`check`、`serve` 等命令。默认生成时会调用同目录的 worker 补充类型信息，无需另设路径。

| 看到什么 | 怎么处理 |
|---|---|
| 找不到 `cjdoc`，或版本不对 | 把正确的安装目录放在 `PATH` 前面，再确认命令路径 |
| `error while loading shared libraries`（例如缺 `libcangjie-std-ast.so`），或 Windows 找不到仓颉运行库 | 在同一个终端重新加载对应 SDK 环境 |
| 生成时报 `CJDOC2101` 或 `CJDOC2104` | 检查 worker 是否与 `cjdoc` 同目录，且来自同一个发行包或同一次源码构建；见 [CHIR 排错](../how-to/chir.md) |

## 以后在新终端使用 cjdoc

每次在新终端加载 SDK 环境并把安装目录加入 `PATH`。可以把这两项写进 shell 启动配置。仅运行 cjdoc 时不需要设置 `CANGJIE_STDX_PATH`，也不需要留在源码目录。

已有项目，从[快速开始](../../README.md#快速开始)生成站点。没有项目，跟着[第一个站点](../tutorials/first-site.md)从空目录练习。
