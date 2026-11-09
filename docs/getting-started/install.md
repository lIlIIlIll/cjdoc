# 安装 cjdoc

从源码构建 `cjdoc`，安装到你的用户目录，并在源码目录之外确认命令可用。这样工具与这份手册来自同一个提交，你可以在任意工作目录生成、检查和预览文档。不想从源码构建时，文末有预编译发行包入口。

## 前提：准备 SDK 和 stdx

- Git、Bash 和 Python 3。
- **Cangjie STS 1.2.0 SDK** 和配套的**静态 stdx 1.2.0**。下载与系统要求见 [STS 1.2.0 下载](https://cangjie-lang.cn/download/1.2.0)和[官方安装说明](https://cj-docs.gitcode.com/zh/1.2.0/dev-guide/source_zh_cn/first_understanding/install.html)。
- 一个可写的安装前缀。下文的示例使用 `$HOME/.local`。

| 平台 | 使用的终端 | 实际限制 |
|---|---|---|
| Linux x64 | Bash | 本页命令可直接执行；本地预览站点时需要 Python 3 |
| macOS ARM64 | Bash；系统默认的 zsh 先启动 Bash，或改写为等价命令 | SDK 的平台目录名与 Linux 不同，按实际解压结果填写路径 |
| Windows x64 | 源码构建用 Git Bash；安装和打开文件可用 PowerShell | Bash 中的路径经 `cygpath -m` 转换后才能交给原生 Python；没有 `python3` 时改用 `python` |

stdx 是仓颉扩展库。`cjdoc` 构建时静态链接 1.2.0 的 stdx，因此构建机需要与编译器版本匹配的静态库；构建出的 `cjdoc` 运行时只需要 SDK 的仓颉运行库。

手工解压 SDK 后，版本目录下同时有 `cangjie/` 和按平台命名的目录，静态库位于后者之中：

```text
<payload-root>/cangjie/
<payload-root>/linux_x86_64_cjnative/static/stdx/stdx.chir.cjo
<payload-root>/linux_x86_64_cjnative/static/stdx/libstdx.chir.a
```

把 `<payload-root>` 换成实际解压目录。两个文件必须直接位于你设置的 `stdx/` 目录里。macOS ARM64 的平台目录是 `darwin_aarch64_cjnative`，Windows x64 是 `windows_x86_64_cjnative`，其余结构相同。已有可用的 SDK 时不需要重装。

也可以先按 [cjv 的安装说明](https://github.com/Zxilly/cjv)安装 cjv，再执行 `cjv install sts-1.2.0 --component stdx` 取得同一套工具链。

在**当前 shell** 加载 SDK 环境，并把变量设成实际解压位置：

```bash
export CANGJIE_SDK_ROOT="$HOME/toolchains/sts-1.2.0/cangjie"
. "$CANGJIE_SDK_ROOT/envsetup.sh"
export CANGJIE_STDX_PATH="$HOME/toolchains/sts-1.2.0/linux_x86_64_cjnative/static/stdx"
cjc -v
cjpm -v
```

`cjc -v` 和 `cjpm -v` 都应报告 1.2.0。示例路径只是布局建议，不会自动下载或创建目录。

Windows 先运行 SDK 的 Windows 环境脚本设置运行库和 PATH，再启动继承该环境的 Git Bash，并在 Bash 中使用实际可访问的 SDK/stdx 路径。`.sh` 文件在 PowerShell 中不可用，`export` 也不能粘贴到 CMD。

SDK 环境只对当前 shell 及其子进程生效。重开终端不会保留上面的 `export`；本页末尾给出新终端需要重复的命令。

## 1. 获取源码并记录提交

在 Bash 中克隆源码，并保存源码位置和完整提交：

```bash
git clone https://github.com/lIlIIlIll/cjdoc.git
cd cjdoc
export CJDOC_SOURCE="$PWD"
export CJDOC_REVISION="$(git rev-parse HEAD)"
printf '%s\n' "$CJDOC_REVISION"
```

输出是一串 40 位提交号，记下它。这份手册描述的就是这个提交；源码更新后需要重新构建。`CJDOC_SOURCE` 和 `CJDOC_REVISION` 只供需要读取源码的可选任务使用，例如复制仓库样例或构建 CHIR worker；普通生成、检查和预览只需要安装好的 `cjdoc` 和 SDK 环境。

首次构建会下载清单中锁定版本的 Git 依赖，需要网络访问。cjdoc 不会替你下载被文档化项目的依赖。

## 2. 构建 cjdoc

在同一个子 shell 里准备临时目录和构建环境，构建结束后这些变量不会影响后续命令。`GITHUB_WORKSPACE` 告诉仓库脚本源码根的位置，`RUNNER_TEMP` 是本次构建的私有临时目录。这两个名字来自仓库脚本，本地照设即可，不需要 GitHub Actions。临时目录放在磁盘上，不要用内存文件系统承载构建输出。

仍在源码根执行。构建沿用第 1 步的 `CJDOC_SOURCE`；如果换了终端，只需在该终端重新设置 `CJDOC_SOURCE` 为你克隆的目录并重新加载 SDK 环境，不必再次克隆。

```bash
(
  mkdir -p "$HOME/.cache/cjdoc"
  chmod 700 "$HOME/.cache/cjdoc"
  export RUNNER_TEMP="$(mktemp -d "$HOME/.cache/cjdoc/build.XXXXXX")"
  export TMPDIR="$RUNNER_TEMP" TMP="$RUNNER_TEMP" TEMP="$RUNNER_TEMP"
  export GITHUB_WORKSPACE="$CJDOC_SOURCE"
  export CJDOC_PYTHON=python3
  export PYTHONDONTWRITEBYTECODE=1
  if command -v cygpath >/dev/null 2>&1; then
    export GITHUB_WORKSPACE="$(cygpath -m "$GITHUB_WORKSPACE")"
    export RUNNER_TEMP="$(cygpath -m "$RUNNER_TEMP")"
    if [ -n "${CANGJIE_STDX_PATH:-}" ]; then
      export CANGJIE_STDX_PATH="$(cygpath -m "$CANGJIE_STDX_PATH")"
    fi
    export TMPDIR="$RUNNER_TEMP" TMP="$RUNNER_TEMP" TEMP="$RUNNER_TEMP"
  fi
  cd "$CJDOC_SOURCE"
  . scripts/with_sts_cjpm.sh
  python3 scripts/with_stdx.py --variant static -- cjpm build --jobs 1
)
```

构建使用仓库固定的 `-O2 --fno-chir-function-inlining`，你不需要另加编译选项。成功后产物在 `$CJDOC_SOURCE/target/release/bin/main`，Windows 为 `main.exe`。

Git Bash 中 `cygpath -m` 把路径转成 `C:/...` 形式交给原生 Python，包装脚本内部再转回 Bash 使用的形式；Linux 和 macOS 跳过这个分支。

如果出现 `no authenticated static stdx sidecar matches the selected compiler`，检查 `CANGJIE_STDX_PATH` 是否指向同时包含 `stdx.chir.cjo` 和 `libstdx.chir.a` 的静态 `stdx/` 目录，以及 SDK 是否同为 1.2.0。动态库目录不能当静态目录使用，也不要混用其它版本 SDK 的库。Windows 的 Bash 环境若只有 `python`，先确认它是 Python 3，再把命令中的 `python3` 和 `CJDOC_PYTHON` 一并改为 `python`。

## 3. 安装到前缀并加入 PATH

在任意目录执行，把构建产物安装为一个名为 `cjdoc` 的命令：

```bash
export CJDOC_PREFIX="$HOME/.local"
install -d "$CJDOC_PREFIX/bin"
install -m 755 "$CJDOC_SOURCE/target/release/bin/main" "$CJDOC_PREFIX/bin/cjdoc"
export PATH="$CJDOC_PREFIX/bin:$PATH"
hash -r
command -v cjdoc
```

`command -v cjdoc` 应输出 `$CJDOC_PREFIX/bin/cjdoc`。

`install` 会覆盖该前缀下已有的 `cjdoc`。要保留旧版本，先把 `CJDOC_PREFIX` 设为新的私人目录，例如 `$HOME/.local/cjdoc-0.7.7`，再把它的 `bin` 加入 PATH。

长期使用时，把 `$CJDOC_PREFIX/bin` 写进你的 shell 配置；SDK 环境需按后文“以后在新终端使用 cjdoc”在每个新终端加载。

Windows 在 PowerShell 中进入你的 cjdoc 克隆目录后执行：

```powershell
$CjdocPrefix = Join-Path $HOME '.local'
New-Item -ItemType Directory -Force (Join-Path $CjdocPrefix 'bin') | Out-Null
Copy-Item .\target\release\bin\main.exe (Join-Path $CjdocPrefix 'bin\cjdoc.exe')
$env:Path = (Join-Path $CjdocPrefix 'bin') + ';' + $env:Path
Get-Command cjdoc
```

## 4. 在源码目录外确认命令可用

新建一个普通工作目录，避免从源码根或旧 PATH 中取到别的二进制：

```bash
mkdir -p "$HOME/cjdoc-example"
cd "$HOME/cjdoc-example"
command -v cjdoc
cjdoc --version
cjdoc --help
```

`command -v cjdoc` 应指向第 3 步的前缀，`cjdoc --version` 输出 `cjdoc 0.7.7`，`cjdoc --help` 列出顶层命令。只有顶层提供 `--help`，子命令没有独立帮助。

这些命令不需要 `CJDOC_SOURCE`，也不需要第 2 步的构建临时目录。当前终端仍需已加载的 SDK 环境。Windows 在另一个空目录中运行 `Get-Command cjdoc`、`cjdoc --version` 和 `cjdoc --help`，并保持 SDK runtime 环境。

## 以后在新终端使用 cjdoc

新终端每次都要加载 SDK 环境并把安装目录加入 PATH：

```bash
export CANGJIE_SDK_ROOT="$HOME/toolchains/sts-1.2.0/cangjie"
. "$CANGJIE_SDK_ROOT/envsetup.sh"
export CJDOC_PREFIX="$HOME/.local"
export PATH="$CJDOC_PREFIX/bin:$PATH"
cjdoc --version
```

`CJDOC_PREFIX` 应与安装时选择的前缀一致；如果另选了目录，在这里使用相同位置。只运行 `cjdoc` 时，加载 SDK 环境和 PATH 就够了。只有再次从源码构建，才需要重复第 2 步的设置：`CANGJIE_STDX_PATH`、`GITHUB_WORKSPACE`、`RUNNER_TEMP` 和 `CJDOC_PYTHON`，并在同一个子 shell 中执行构建。

把 `envsetup.sh` 的加载行和 PATH 行写进 shell 配置后，新终端会自动获得这套环境；否则每开一个终端都要执行上面的命令。

## 替代：安装公开发行包 v0.7.7

不想从源码构建时，可以安装 v0.7.7 发行包。它提供该版本的 `cjdoc`、schema 和最小生成能力；当前源码新增的行为不在其中。该包的源码提交是 `8cc8f71a296b1c6321e575b56fadbd0c379e242a`，Doc IR 为 v16，当前源码为 v18，两者不能互换。对应的完整手册在[这个提交的 docs](https://github.com/lIlIIlIll/cjdoc/tree/8cc8f71a296b1c6321e575b56fadbd0c379e242a/docs)。

在新的下载目录、已加载 SDK 的 Bash 中执行（需要 curl、sha256sum 和 tar）：

```bash
curl --fail --location -O https://github.com/lIlIIlIll/cjdoc/releases/download/v0.7.7/cjdoc-0.7.7-linux-x64.tar.gz
printf '%s  %s\n' ee328b037828891534d34b17a0691ee95ad521125868200f0ba2a37f58a89de4 cjdoc-0.7.7-linux-x64.tar.gz | sha256sum -c -
tar -tvzf cjdoc-0.7.7-linux-x64.tar.gz
```

`tar -tvzf` 每行第一个字符是条目类型：`-` 是普通文件，`d` 是目录；权限位、大小和时间之后是路径。v0.7.7 的 Linux 包只包含 `cjdoc-0.7.7/` 下的普通文件。无论在哪个平台，路径以 `/` 开头或包含 `..` 都不应解压；出现 `l`（符号链接）或其它条目类型时也不要解压。

解压到新建目录，并读取清单：

```bash
mkdir unpacked
tar -xzf cjdoc-0.7.7-linux-x64.tar.gz -C unpacked
cat unpacked/cjdoc-0.7.7/release-manifest.json
```

`mkdir unpacked` 在目录已存在时会报错。看到这个错误就换一个新的目录名，例如 `unpacked-2`，并把 `tar` 命令里的 `-C` 一起改成新名字；不要继续往旧目录里解压。

核对清单中的平台 `linux-x64`、版本 `0.7.7` 和上面的 sourceCommit。运行环境同样要求 SDK 与 stdx 均为 1.2.0：清单声明 SDK archive SHA-256 为 `8c5fd944cd9cc51ee63d4a240e3ecc4f540345dae1468e8b47c927ecf2ba998f`，stdx archive SHA-256 为 `c036a192e8fd4206b84ca9a94611820bc66623198975f3dff874f748d65a8b47`；按该发行版声明准备环境，不要用另一套 SDK 的版本字符串代替匹配。

安装到独立前缀，避免与源码构建的命令混淆：

```bash
export RELEASE_PREFIX="$PWD/release-install"
install -d "$RELEASE_PREFIX/bin"
install -m 755 unpacked/cjdoc-0.7.7/cjdoc "$RELEASE_PREFIX/bin/cjdoc"
"$RELEASE_PREFIX/bin/cjdoc" --version
"$RELEASE_PREFIX/bin/cjdoc" schema list
```

先按[首站教程](../tutorials/first-site.md)准备不依赖外部库的 `docdemo` 文件，再从该项目根目录用发行包的绝对路径生成到一个新输出目录：

```bash
"$RELEASE_PREFIX/bin/cjdoc" generate --project . --format html --output target/doc-release
```

该入口只保证 v0.7.7 自身的最小生成；本手册后面描述的能力以当前源码构建为准。

macOS 资产为 `cjdoc-0.7.7-macos-arm64.tar.gz`，用 `shasum -a 256 -c` 核对它自己的 `.sha256` 文件；Windows 资产为 `cjdoc-0.7.7-windows-x64.zip`，在 PowerShell 中用 `Get-FileHash -Algorithm SHA256` 对照它自己的校验文件，再用 `Expand-Archive` 解压到空目录并复制 `cjdoc.exe`。各平台的摘要不同，不能复用 Linux 的值。所有平台都要按各自清单保留 SDK runtime 环境。

包内的 README、schema 和文档负载属于该发行提交；要阅读当前手册，以本页第 1 步构建的版本或上面的同版本源码链接为准。

## 下一步

[从空目录生成第一个站点](../tutorials/first-site.md)。遇到命令找不到、启动失败或项目根错误，按[按症状排错](../how-to/troubleshoot.md)处理。
