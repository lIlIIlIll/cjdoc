# 安装 cjdoc

cjdoc 有两条安装路线，选一条即可：安装预编译发行包，或从源码构建。两条路线都要求运行 `cjdoc` 的终端已经加载仓颉 STS 1.2.0 SDK 环境：`cjdoc` 二进制动态链接 SDK 的仓颉运行库，环境没加载时启动直接失败，命令以 `127` 退出：

```text
cjdoc: error while loading shared libraries: libcangjie-std-ast.so: cannot open shared object file: No such file or directory
```

从源码构建额外需要匹配的静态 stdx 1.2.0。两条路线最后都走同一个确认步骤。

## 选择安装路线

| 路线 | 额外准备 | 你得到 |
|---|---|---|
| 安装预编译发行包 | 能下载文件；Linux 用 `curl`、`sha256sum`、`tar`，macOS 用 `shasum`，Windows 用 PowerShell | 现成的 `cjdoc 0.7.8` 可执行文件、schema 和随包文档 |
| 从源码构建 | Git、Python 3、Cangjie 编译器、静态 stdx 1.2.0 | `main` 分支当前源码构建的 `cjdoc`，产物为 `target/release/bin/main` |

v0.7.8 发行包由提交 `5c065affd2c45f61549c06808537731ce46b436b` 构建。`main` 分支可能已经包含发行包之后的改动，这份手册跟随 `main`；个别内容只适用于源码构建时，相应页面会注明。与发行包完全对应的手册见 [v0.7.8 标签下的文档](https://github.com/lIlIIlIll/cjdoc/tree/v0.7.8/docs)。

## 前提：准备 SDK 1.2.0

- **Cangjie STS 1.2.0 SDK**。下载与系统要求见 [STS 1.2.0 下载](https://cangjie-lang.cn/download/1.2.0)和[官方安装说明](https://cj-docs.gitcode.com/zh/1.2.0/dev-guide/source_zh_cn/first_understanding/install.html)。
- **静态 stdx 1.2.0**，仅从源码构建需要；安装发行包不需要单独准备。
- 从源码构建另需 Git、Bash 和 Python 3。
- 一个可写的安装前缀，下文示例使用 `$HOME/.local`。

| 平台 | 使用的终端 | 实际限制 |
|---|---|---|
| Linux x64 | Bash | 本页命令可直接执行；本地预览站点时需要 Python 3 |
| macOS ARM64 | Bash；系统默认的 zsh 先启动 Bash，或改写为等价命令 | SDK 的平台目录名与 Linux 不同，按实际解压结果填写路径 |
| Windows x64 | 源码构建用 Git Bash；安装和打开文件可用 PowerShell | Bash 中的路径经 `cygpath -m` 转换后才能交给原生 Python；没有 `python3` 时改用 `python` |

stdx 是仓颉扩展库。`cjdoc` 从源码构建时静态链接 1.2.0 的 stdx，因此构建机需要与编译器版本匹配的静态库；构建出的 `cjdoc` 运行时只需要 SDK 的仓颉运行库。

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

`cjc -v` 和 `cjpm -v` 都应报告 1.2.0。示例路径只是布局建议，不会自动下载或创建目录。`CANGJIE_STDX_PATH` 只有从源码构建才用得到。

Windows 先运行 SDK 的 Windows 环境脚本设置运行库和 PATH，再启动继承该环境的 Git Bash，并在 Bash 中使用实际可访问的 SDK/stdx 路径。`.sh` 文件在 PowerShell 中不可用，`export` 也不能粘贴到 CMD。

SDK 环境只对当前 shell 及其子进程生效。重开终端不会保留上面的 `export`；本页末尾给出新终端需要重复的命令。

## 安装预编译发行包

发行包只包含文件，不联网、不编译。下载、校验、解压、核对清单、安装五步都在同一个下载目录完成。

### 1. 下载资产和校验文件

| 平台 | 资产 | 校验文件 |
|---|---|---|
| Linux x64 | `cjdoc-0.7.8-linux-x64.tar.gz` | `cjdoc-0.7.8-linux-x64.tar.gz.sha256` |
| macOS ARM64 | `cjdoc-0.7.8-macos-arm64.tar.gz` | `cjdoc-0.7.8-macos-arm64.tar.gz.sha256` |
| Windows x64 | `cjdoc-0.7.8-windows-x64.zip` | `cjdoc-0.7.8-windows-x64.zip.sha256` |

每个文件都在 `https://github.com/lIlIIlIll/cjdoc/releases/download/v0.7.8/<资产名>`。Linux 在新的下载目录执行：

```bash
curl --fail --location -O https://github.com/lIlIIlIll/cjdoc/releases/download/v0.7.8/cjdoc-0.7.8-linux-x64.tar.gz
curl --fail --location -O https://github.com/lIlIIlIll/cjdoc/releases/download/v0.7.8/cjdoc-0.7.8-linux-x64.tar.gz.sha256
ls
```

`curl --fail` 在 HTTP 错误时以非零状态退出，不会留下错误页伪装成压缩包。预期目录里出现 `cjdoc-0.7.8-linux-x64.tar.gz` 和它的 `.sha256` 文件。

### 2. 校验下载

```bash
sha256sum -c cjdoc-0.7.8-linux-x64.tar.gz.sha256
```

预期输出 `cjdoc-0.7.8-linux-x64.tar.gz: OK`，退出码 `0`。校验基准以随资产发布的 `.sha256` 文件为准，内容为 `032002656b5ec5ff85873c49b9e2a4656a4664aad562101360f8faa67902b91c`。看到 `FAILED` 时退出码为 `1`：删掉这两个文件重新下载，不要继续解压。

macOS 用 `shasum -a 256 -c cjdoc-0.7.8-macos-arm64.tar.gz.sha256`，预期同样得到 `OK`。Windows 在 PowerShell 中比较两个摘要：

```powershell
Get-FileHash .\cjdoc-0.7.8-windows-x64.zip -Algorithm SHA256
Get-Content .\cjdoc-0.7.8-windows-x64.zip.sha256
```

`Hash` 与文件内容的摘要一致才继续。各平台资产不同，摘要不能互相复用。

### 3. 检查归档内容再解压

```bash
tar -tvzf cjdoc-0.7.8-linux-x64.tar.gz
mkdir unpacked
tar -xzf cjdoc-0.7.8-linux-x64.tar.gz -C unpacked
ls unpacked/cjdoc-0.7.8
```

`tar -tvzf` 每行第一个字符是条目类型：`-` 是普通文件，`d` 是目录；权限位、大小和时间之后是路径。Linux 和 macOS 包共 34 条，全部是 `-`，路径都在 `cjdoc-0.7.8/` 下：

```text
cjdoc  README.md  LICENSE  THIRD_PARTY_NOTICES.md
docs/schema/*.json  licenses/  release-candidate.json  release-manifest.json
```

v0.7.8 的发行包只有 `cjdoc` 一个可执行文件，后面第 4、5 步都按这份清单以及这一个文件进行。发布了配套 worker 的版本把 `cjdoc` 与 `chir-worker-main`（Windows 为 `chir-worker-main.exe`）放在同一目录一起发布，两个文件都位于包根目录下：

```text
cjdoc  chir-worker-main  README.md  LICENSE  THIRD_PARTY_NOTICES.md
docs/schema/*.json  licenses/  release-candidate.json  release-manifest.json
```

这些版本的 `cjdoc` 只在自己所在的目录里查找配套的 CHIR worker，不会搜索 `PATH` 或当前目录；两个文件装进同一个 `bin` 目录后即可使用，无需配置路径。只装 `cjdoc` 时语义补充退回源码信息并给出诊断。v0.7.8 的 `cjdoc` 没有这项自动发现，旁边多放一个文件不会改变它的行为；它对应的说明以 [v0.7.8 标签下的文档](https://github.com/lIlIIlIll/cjdoc/tree/v0.7.8/docs)为准。

无论在哪个平台，路径以 `/` 开头或包含 `..` 都不应解压；出现 `l`（符号链接）或其它条目类型时也不要解压。

`ls unpacked/cjdoc-0.7.8` 应列出你解压的那一份对应的名称。`mkdir unpacked` 在目录已存在时会报错：看到这个错误就换一个新的目录名，例如 `unpacked-2`，并把 `tar` 命令里的 `-C` 一起改成新名字；不要继续往旧目录里解压。

### 4. 核对清单

```bash
cat unpacked/cjdoc-0.7.8/release-manifest.json
```

清单描述这份包的身份和构建环境：

| 字段 | 值 |
|---|---|
| `platform` | `linux-x64` |
| `version` | `0.7.8` |
| `releaseTag` | `v0.7.8` |
| `sourceCommit` | `5c065affd2c45f61549c06808537731ce46b436b` |
| `schemaVersion` | `cjdoc.release-package/4` |
| `runtime.sdkVersion` / `runtime.stdxVersion` | `1.2.0` |
| `runtime.sdkArchiveSha256` | `8c5fd944cd9cc51ee63d4a240e3ecc4f540345dae1468e8b47c927ecf2ba998f` |
| `runtime.stdxArchiveSha256` | `c036a192e8fd4206b84ca9a94611820bc66623198975f3dff874f748d65a8b47` |

`files` 逐项给出包内每个文件的大小和 SHA-256，可以和实际文件核对。`runtime` 记录构建这个包所用的 SDK 与 stdx：运行它只需要 SDK 1.2.0 的运行库，不需要设置 `CANGJIE_STDX_PATH`。同目录的 `release-candidate.json` 记录构建参数，日常安装不必读它。

发布配套 worker 的版本使用清单 schema `cjdoc.release-package/5`，比 v0.7.8 多出两个字段：`executables` 给出两个可执行文件的安装名（例如 `{"main": "cjdoc", "worker": "chir-worker-main"}`），`chirWorker` 记录该 worker 自己报告的产品版本与协议版本（例如 `cjdoc-chir-worker 0.7.8` 与 `cjdoc-chir-worker/3`）。两者与 `cjdoc` 不匹配时，`cjdoc` 会报告诊断并保留源码结论。

平台与版本不符时不要安装：换成对应平台的资产。按清单声明准备环境，不要用另一套 SDK 的版本字符串代替匹配。

### 5. 安装到前缀并加入 PATH

```bash
export RELEASE_PREFIX="$HOME/.local"
install -d "$RELEASE_PREFIX/bin"
install -m 755 unpacked/cjdoc-0.7.8/cjdoc "$RELEASE_PREFIX/bin/cjdoc"
export PATH="$RELEASE_PREFIX/bin:$PATH"
hash -r
command -v cjdoc
"$RELEASE_PREFIX/bin/cjdoc" --version
```

`command -v cjdoc` 应输出 `$RELEASE_PREFIX/bin/cjdoc`，最后一行输出 `cjdoc 0.7.8`。这就是 v0.7.8 的全部安装步骤。

`install -m 755` 会覆盖该前缀下已有的 `cjdoc`。要保留旧版本，先把前缀换成新的私人目录，例如 `$HOME/.local/cjdoc-0.7.8`，再把它的 `bin` 加入 PATH。

Windows 在 PowerShell 中解压并复制可执行文件：

```powershell
Expand-Archive -Path .\cjdoc-0.7.8-windows-x64.zip -DestinationPath unpacked
$CjdocPrefix = Join-Path $HOME '.local'
New-Item -ItemType Directory -Force (Join-Path $CjdocPrefix 'bin') | Out-Null
Copy-Item .\unpacked\cjdoc-0.7.8\cjdoc.exe (Join-Path $CjdocPrefix 'bin\cjdoc.exe')
$env:Path = (Join-Path $CjdocPrefix 'bin') + ';' + $env:Path
Get-Command cjdoc
```

macOS 的步骤与 Linux 相同，只换资产名，并用 `shasum -a 256 -c` 校验。所有平台都要按各自清单保留 SDK runtime 环境。

### 6. 让 cjdoc 使用配套 worker（只有带该文件的版本需要）

v0.7.8 的包里没有这个文件，跳过本步即可。对发布了配套 worker 的版本，先确认解压目录里确有它：

```bash
UNPACKED="unpacked/cjdoc-0.7.8"
ls "$UNPACKED" | grep -x chir-worker-main
```

`grep` 有输出才继续。两个文件必须装进同一个目录，因为 `cjdoc` 只在自己所在的目录里查找配套 worker：

```bash
install -m 755 "$UNPACKED/chir-worker-main" "$RELEASE_PREFIX/bin/chir-worker-main"
ls "$RELEASE_PREFIX/bin"
```

`ls` 应同时列出 `cjdoc` 与 `chir-worker-main`。对发布了配套 worker 的版本，之后 `cjdoc generate`、`cjdoc check` 和 `cjdoc serve` 默认使用这个 worker 做语义补充，不需要传 `--chir-worker`。v0.7.8 的 `cjdoc` 不会按目录查找 worker，所以这一步只对带有该文件的新版本有意义；v0.7.8 需要显式语义结果时，按 [v0.7.8 标签下的文档](https://github.com/lIlIIlIll/cjdoc/tree/v0.7.8/docs)操作。

Windows 上同样先检查文件是否存在，再复制到 `cjdoc.exe` 所在目录：

```powershell
$Unpacked = Join-Path $PWD 'unpacked\cjdoc-0.7.8'
$Worker = Join-Path $Unpacked 'chir-worker-main.exe'
if (Test-Path $Worker) {
  Copy-Item $Worker (Join-Path $CjdocPrefix 'bin\chir-worker-main.exe')
}
Get-ChildItem (Join-Path $CjdocPrefix 'bin')
```

长期使用时，把 `$RELEASE_PREFIX/bin` 写进你的 shell 配置；SDK 环境需按后文“以后在新终端使用 cjdoc”在每个新终端加载。

## 从源码构建

想改代码、跟随未发布改动，或不想安装别人构建的二进制时走这条路线。构建需要 SDK 环境里已有 `cjc` 和 `cjpm`，以及前提中设置的静态 `CANGJIE_STDX_PATH`。

### 1. 获取源码并记录提交

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

### 2. 构建 cjdoc

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
  python3 scripts/with_stdx.py --variant static -- bash -c 'cd tools/chir-worker && cjpm build --jobs 1'
  worker="tools/chir-worker/target/release/bin/main"
  if [ -f "$worker.exe" ]; then
    cp -p "$worker.exe" target/release/bin/chir-worker-main.exe
  else
    cp -p "$worker" target/release/bin/chir-worker-main
  fi
)
```

构建使用仓库固定的 `-O2 --fno-chir-function-inlining`，你不需要另加编译选项。成功后产物在 `$CJDOC_SOURCE/target/release/bin/main`，Windows 为 `main.exe`；配套的 CHIR worker 被放到同一目录，名字固定为 `chir-worker-main`（Windows 为 `chir-worker-main.exe`）。`cjdoc` 只在自己所在的目录里查找这个文件，所以安装时两个文件必须一起复制。

这一步构建出的 `cjdoc` 默认启用 CHIR 语义补充。只想看源码与注释得出的结论时，不必跳过 worker 构建，在命令上加 `--semantic source` 即可；这样安装出来的仍是完整的产品。

Git Bash 中 `cygpath -m` 把路径转成 `C:/...` 形式交给原生 Python，包装脚本内部再转回 Bash 使用的形式；Linux 和 macOS 跳过这个分支。

如果出现 `no authenticated static stdx sidecar matches the selected compiler`，检查 `CANGJIE_STDX_PATH` 是否指向同时包含 `stdx.chir.cjo` 和 `libstdx.chir.a` 的静态 `stdx/` 目录，以及 SDK 是否同为 1.2.0。动态库目录不能当静态目录使用，也不要混用其它版本 SDK 的库。Windows 的 Bash 环境若只有 `python`，先确认它是 Python 3，再把命令中的 `python3` 和 `CJDOC_PYTHON` 一并改为 `python`。

### 3. 安装到前缀并加入 PATH

在任意目录执行，把构建产物安装为一个名为 `cjdoc` 的命令，并把配套 worker 放进同一个目录：

```bash
export CJDOC_PREFIX="$HOME/.local"
install -d "$CJDOC_PREFIX/bin"
install -m 755 "$CJDOC_SOURCE/target/release/bin/main" "$CJDOC_PREFIX/bin/cjdoc"
install -m 755 "$CJDOC_SOURCE/target/release/bin/chir-worker-main" "$CJDOC_PREFIX/bin/chir-worker-main"
export PATH="$CJDOC_PREFIX/bin:$PATH"
hash -r
command -v cjdoc
ls "$CJDOC_PREFIX/bin"
```

`command -v cjdoc` 应输出 `$CJDOC_PREFIX/bin/cjdoc`，`ls` 应同时列出 `cjdoc` 与 `chir-worker-main`。两者缺一说明第 2 步没跑完，回到第 2 步重新构建并在同一子 shell 中复制 worker。

`install` 会覆盖该前缀下已有的 `cjdoc`。要保留旧版本，先把 `CJDOC_PREFIX` 设为新的私人目录，例如 `$HOME/.local/cjdoc-0.7.8`，再把它的 `bin` 加入 PATH。

长期使用时，把 `$CJDOC_PREFIX/bin` 写进你的 shell 配置；SDK 环境需按后文“以后在新终端使用 cjdoc”在每个新终端加载。

Windows 在 PowerShell 中进入你的 cjdoc 克隆目录后执行：

```powershell
$CjdocPrefix = Join-Path $HOME '.local'
New-Item -ItemType Directory -Force (Join-Path $CjdocPrefix 'bin') | Out-Null
Copy-Item .\target\release\bin\main.exe (Join-Path $CjdocPrefix 'bin\cjdoc.exe')
Copy-Item .\target\release\bin\chir-worker-main.exe (Join-Path $CjdocPrefix 'bin\chir-worker-main.exe')
$env:Path = (Join-Path $CjdocPrefix 'bin') + ';' + $env:Path
Get-Command cjdoc
```

## 在源码目录外确认命令可用

两条路线都在这一步收尾。新建一个普通工作目录，避免从源码根或旧 PATH 中取到别的二进制：

```bash
mkdir -p "$HOME/cjdoc-example"
cd "$HOME/cjdoc-example"
command -v cjdoc
cjdoc --version
cjdoc --help
ls "$(dirname "$(command -v cjdoc)")"
```

预期结果：

- `command -v cjdoc` 指向你选择的前缀（发行包路线是 `$RELEASE_PREFIX/bin/cjdoc`，源码路线是 `$CJDOC_PREFIX/bin/cjdoc`）。
- `cjdoc --version` 输出 `cjdoc 0.7.8`。
- `cjdoc --help` 列出 `generate`、`check`、`serve`、`render`、`diff`、`query`、`mcp`、`schema` 等顶层命令，并以 `0` 退出。
- `ls` 列出 `cjdoc` 所在的 `bin` 目录。源码路线的安装里还应有 `chir-worker-main`（Windows 为 `chir-worker-main.exe`）；v0.7.8 发行包没有这个文件。worker 不必出现在 PATH 里，当前源码的 `cjdoc` 只在自身目录查找它。

源码路线安装的 `cjdoc` 默认使用同目录的 worker。确认它生效不需要额外参数：在包含 `.cj` 源码的项目里运行 `cjdoc check --project .`，有 worker 时语义结论更完整；worker 缺失或版本不匹配时，`cjdoc` 仍会给出源码结论并输出 `CJDOC2101`/`CJDOC2104` 诊断。v0.7.8 的 `cjdoc` 不使用这项自动发现。

当前源码版支持按命令查看帮助，例如 `cjdoc generate --help`、`cjdoc check --help`；帮助不会读取项目配置或启动 worker。已发布的 v0.7.8 仍只提供顶层 `cjdoc --help`，请使用对应版本手册。各选项默认值见[命令行参考](../reference/cli.md)。

这些命令不需要 `CJDOC_SOURCE`，也不需要源码构建那一节准备的构建临时目录，但当前终端仍需已加载的 SDK 环境。忘记加载时 `cjdoc` 会报 `error while loading shared libraries: libcangjie-std-ast.so`：在同一终端执行 `. "$CANGJIE_SDK_ROOT/envsetup.sh"` 后重试。

Windows 在另一个空目录中运行 `Get-Command cjdoc`、`cjdoc --version` 和 `cjdoc --help`，并保持 SDK runtime 环境。

## 以后在新终端使用 cjdoc

新终端每次都要加载 SDK 环境并把安装目录加入 PATH：

```bash
export CANGJIE_SDK_ROOT="$HOME/toolchains/sts-1.2.0/cangjie"
. "$CANGJIE_SDK_ROOT/envsetup.sh"
export CJDOC_PREFIX="$HOME/.local"
export PATH="$CJDOC_PREFIX/bin:$PATH"
cjdoc --version
```

安装发行包时用的是 `RELEASE_PREFIX`，把这里的 `CJDOC_PREFIX` 换成同一个目录即可；关键是 PATH 指向实际安装的 `bin`。只运行 `cjdoc` 时，加载 SDK 环境和 PATH 就够了。只有再次从源码构建，才需要重复“从源码构建”第 2 步的设置：`CANGJIE_STDX_PATH`、`GITHUB_WORKSPACE`、`RUNNER_TEMP` 和 `CJDOC_PYTHON`，并在同一个子 shell 中执行构建。

把 `envsetup.sh` 的加载行和 PATH 行写进 shell 配置后，新终端会自动获得这套环境；否则每开一个终端都要执行上面的命令。

## 下一步

[从空目录生成第一个站点](../tutorials/first-site.md)。遇到命令找不到、启动失败或项目根错误，按[按症状排错](../how-to/troubleshoot.md)处理。
